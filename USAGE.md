# kiln-pack 使用指南

从「一套已经调通的服务/训练」到「一个可交付的 `.tar` 镜像包」。
目标：把值钱的自研 Python 逻辑编译成 `.so` 保护进镜像，源码不外发，功能照常可跑。

先选**交付形态**（`pack.conf` 的 `PROFILE`）：

- `PROFILE="serve"`（默认）—— 常驻推理服务，验收 = 起服 + 健康检查 + 接口。见下面「一、推理服务」。
- `PROFILE="train"` —— 训练作业，验收 = 冒烟训练（正常退出 + 落 checkpoint + loss 下降）。见下面「二、训练作业」。

两种形态共用引擎与编译保护，只是 `profiles/<形态>/` 下的 Dockerfile 和启动/验收脚本不同。

---

## 一、推理服务（PROFILE=serve）

### 0. 前置
- 已有能跑起来的推理服务：框架底座（vLLM / SGLang / 自研）+ 你自己的若干 `.py`（含要保护的自研逻辑）。
- 本机装了 Docker；`.so` 认架构和 Python 版本，**builder 与 runtime 必须一致**。

### 1. 准备底座镜像
把推理框架装进一个镜像当底座，builder 与 runtime 共用：

```bash
printf 'FROM python:3.11-slim-bookworm\nRUN pip install --no-cache-dir vllm\n' \
  | docker build -t my-base . -f -
```
> 底座只需装好框架本体；编译器 gcc/Cython 由 kiln-pack 在 builder 阶段自动装，不进最终镜像。

### 2. 组织工程目录
```
myproj/
  pack.conf
  app/
    __init__.py
    server.py            # 起服入口（薄壳，无 IP 价值，可留明文）
    proprietary_logic.py # 要保护的自研逻辑 —— 会被编成 .so
```
`server.py` 正常 `from app.proprietary_logic import ...`；编译成 `.so` 后 import 方式不变。

### 3. 写 pack.conf
```bash
PROFILE="serve"
APP_NAME="my-svc"
VERSION="1.0.0"
RUNTIME_BASE="my-base"
BUILDER_BASE="my-base"
SRC_DIR="."
PROTECT_GLOBS="app/proprietary_logic.py"
START_CMD="python -m uvicorn app.server:app --host 0.0.0.0 --port 8000"
EXPOSE_PORT="8000"
HEALTHCHECK_CMD="python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz',timeout=3).status==200 else 1)\""
SECRET_MARKER="CHANGE_ME_UNIQUE_MARKER"   # 敏感常量别硬编码进源码
REQUIRED_ENV="MY_SECRET"                  # 起服必需的环境变量，缺了拒绝启动
VERIFY_ENV="MY_SECRET=whatever-for-verify"
```

### 4. 打包 + 自动验收
```bash
bash engine/pack.sh myproj
```
两阶段构建 → 产出 `my-svc:1.0.0`，自动验收「源码看不见 + 服务正常起 + 可运维」。看到 `验收通过` 即成功。

### 5. 导出 `.tar` 交付
```bash
docker save my-svc:1.0.0 -o my-svc-1.0.0.tar
docker load -i my-svc-1.0.0.tar
docker run -d -p 8000:8000 -e MY_SECRET=... my-svc:1.0.0
```

---

## 二、训练作业（PROFILE=train）

### 0. 前置
- 已有能跑的训练：框架底座（PyTorch / DeepSpeed / Megatron 等）+ 你自己的若干 `.py`，
  其中模型结构、数据配方、loss、调度、单步/编排逻辑是要保护的 IP。
- 真实训练需要带 CUDA/ROCm/CANN 的底座 + GPU；无卡环境可用 CPU torch 底座跑通流程（见 demo-train）。

### 1~2. 底座与目录
底座镜像装好训练框架本体（builder/runtime 共用）。目录与 serve 同理：
```
myproj/
  pack.conf
  requirements.txt
  trainer/
    __init__.py
    train.py    # 训练入口（薄壳，留明文：torchrun 会重导入、spawn 要能 import）
    recipe.py   # 要保护的 IP：模型/数据/loss/调度/单步逻辑 —— 编成 .so
  configs/
    recipe.yaml # 要保护的超参配方 —— 打包时加密成 .enc（可选，见第 3.1 步）
```

### 3. 写 pack.conf（train 专属项）
```bash
PROFILE="train"
APP_NAME="my-train"
VERSION="1.0.0"
RUNTIME_BASE="my-torch-base"       # 真实训练：带 CUDA/CANN 的框架镜像
BUILDER_BASE="my-torch-base"
SRC_DIR="."
PROTECT_GLOBS="trainer/recipe.py"  # 只保护 IP 模块，入口 train.py 留明文
PIP_REQUIREMENTS="requirements.txt"
LAUNCHER="single"                  # single | torchrun（deepspeed/accelerate 预留）
NPROC_PER_NODE="1"                 # torchrun 单机进程数
OUTPUT_DIR="/workspace/output"     # 容器内产物目录，运行时挂卷取回
CKPT_GLOB="*.pt"                   # 验收期望落下的 checkpoint
START_CMD="python -m trainer.train --steps 50"
SECRET_MARKER="CHANGE_ME_UNIQUE_MARKER"
REQUIRED_ENV="KILN_SECRET_MARKER"
VERIFY_ENV="KILN_SECRET_MARKER=whatever-for-verify"
CONFIG_ENCRYPT="off"               # on 时加密配置，见下一步
```

### 3.1 加密 YAML 配置（可选）
在 `pack.conf` 里打开：
```bash
CONFIG_ENCRYPT="on"
CONFIG_GLOBS="configs/*.yaml"      # 要加密的文件，空格分隔；不支持 **，多层目录逐层写
CONFIG_MARKER="CHANGE_ME_UNIQUE"   # 配置明文里的一段特征字符串，验收用它扫描泄漏
```
代码里这样读配置。明文只在内存里，`CONFIG_ENCRYPT` 开或关都不用改代码：
```python
from kiln_config import load_yaml
cfg = load_yaml("configs/recipe.yaml")   # 相对 /app 的路径
```
- `load_yaml` 需要 PyYAML，把它加进项目的 `requirements.txt`；`cryptography` 由引擎自动安装。
- 别在模块顶层读配置，builder 阶段的 import 自检拿不到密钥；放进函数里调用。
- 别把配置内容打进日志或存进 checkpoint，这样明文就又出去了。

密钥不写进 `pack.conf`，打包和运行都用环境变量：
```bash
export KILN_CONFIG_KEY="$(openssl rand -base64 32)"   # 自己保管好，丢了只能重新打包
```

### 4. 打包 + 冒烟验收
```bash
bash engine/pack.sh myproj
```
验收会跑一个短作业，断言「正常退出 + 落下 checkpoint + loss 有限且下降」，看到 `验收通过` 即成功。
开了配置加密时还会确认：镜像里没有配置明文、解密结果和明文一致、没有密钥或密钥不对时起不了训、
所有镜像层和元数据里都没有明文特征和密钥。验收需要 `docker save` 整个镜像，要留够临时空间。

### 5. 交付与运行
```bash
docker save my-train:1.0.0 -o my-train-1.0.0.tar
docker load -i my-train-1.0.0.tar
# 数据只读挂入，产物目录挂出；真实 GPU 训练加 --gpus all
docker run --rm \
  -e KILN_SECRET_MARKER=... \
  -e KILN_CONFIG_KEY \
  -v $(pwd)/data:/workspace/data:ro \
  -v $(pwd)/out:/workspace/output \
  my-train:1.0.0
```
> 挂产物卷时确保宿主目录可被容器内用户（uid 10001）写入（如先 `chmod 777`，或用具名卷）。
> `-e KILN_CONFIG_KEY` 只写名字，值取自当前 shell，不会留在命令历史里；没开配置加密就去掉这一行。

---

## 边界（务必知道）

- 保护的是**代码逻辑**，不是字符串常量：敏感值一律走 `REQUIRED_ENV` 外置。
- **配置加密防的是镜像外泄**：没有密钥读不到配置，但拿到密钥的人、能进运行中容器的人都能拿到明文（环境变量、`docker inspect`、进程内存）。文件名和大小不加密，数据集不在范围内。详见 README「边界」。
- **`torch.compile` 冲突**：编成 `.so` 的模块 dynamo 无法追踪，会退回 eager；热点逻辑「保护」与「被 compile 优化」需二选一。
- 这是**抬高抄袭门槛**，不是绝对加密。要「逻辑绝对不可得」，只能把算法留在自己服务器、对外只给 API。
