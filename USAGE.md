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
VERIFY_TIMEOUT="60"                       # 验收时等服务变健康的秒数，要加载模型的服务调大
HEALTH_START_PERIOD="20s"                 # 容器启动后这段时间内健康检查失败不算数，比如 10m
VERIFY_CMD='
R="$(curl -fsS --max-time 30 "$VERIFY_BASE_URL/v1/models")"
echo "$R"
grep -q my-model <<<"$R"
'
```

- `HEALTHCHECK_CMD` 在容器内执行，通过前一直重试，直到 `VERIFY_TIMEOUT`。镜像里的 `HEALTHCHECK` 用的也是它。
- `EXPOSE_PORT` 会写进镜像的 `EXPOSE`，也是验收时映射的端口。
- 第 4 步的来源痕迹（`github.com` 和 `ORIGIN_MARKERS`）只查本次构建写入的内容，底座自带的 label 和构建历史不算。
- `VERIFY_CMD` 是接口探针，健康检查通过后在打包机上用 `bash -euo pipefail` 执行一次，退出码非 0 判失败。
  可以用 `$VERIFY_BASE_URL`（映射到本机的服务地址）、`$VERSION`、`$VERIFY_CONTAINER`（容器名）、`$PROJECT_DIR`。
  探针写得长就放进脚本：`VERIFY_CMD='bash "$PROJECT_DIR/probe.sh"'`。写 `curl` 时记得带 `--max-time`。
- **不写 `VERIFY_CMD` 也能通过验收，但只会给一条 `[WARN]`**：这时只确认了服务健康，没有验证接口和受保护逻辑。
  引擎不再写死 `/healthz`、`/version`、`/infer`。以前靠这三个端点验收的项目，要把检查搬进 `VERIFY_CMD`，写法见 `tests/demo-fastapi/pack.conf`。

### 4. 打包 + 自动验收
```bash
bash engine/pack.sh myproj
```
两阶段构建 → 产出 `my-svc:1.0.0`，自动验收「源码看不见 + 服务正常起 + 可运维」。看到 `验收通过` 即成功。
注意 `[WARN]`：它表示有一项没有验证到，比如没设 `SECRET_MARKER` 时跳过了机密标记扫描。

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
LAUNCHER="single"                  # single | torchrun | deepspeed | accelerate
NPROC_PER_NODE="1"                 # 启动器的单机进程数
# TORCHRUN_ARGS / DEEPSPEED_ARGS / ACCELERATE_ARGS：透传给对应启动器的额外参数
OUTPUT_DIR="/workspace/output"     # 容器内产物目录，运行时挂卷取回
CKPT_GLOB="*.pt"                   # 验收期望落下的 checkpoint
START_CMD="python -m trainer.train --steps 50"
SECRET_MARKER="CHANGE_ME_UNIQUE_MARKER"
REQUIRED_ENV="KILN_SECRET_MARKER"
VERIFY_ENV="KILN_SECRET_MARKER=whatever-for-verify"
CONFIG_ENCRYPT="off"               # on 时加密配置，见下一步
```

用 `deepspeed` 或 `accelerate` 时，把它们加进项目的 `requirements.txt`，没装会在起训时报错。

- `deepspeed` 默认按 GPU 数起进程，也会给脚本加 `--local_rank` 参数，脚本不接受时要带 `--no_local_rank`。
  没有 GPU 时用 `DEEPSPEED_ARGS="--hostfile=hostfile --no_ssh_check --master_addr=127.0.0.1 --no_local_rank"`
  （`hostfile` 放在源码目录，内容如 `localhost slots=2`；镜像里没有 `ssh`，单机要跳过它的连通检查）。
- `accelerate` 带 `--cpu` 时只起一个进程，会忽略 `--num_processes`。没有 GPU 又要多进程时用 `ACCELERATE_ARGS="--multi_gpu"`。

启动器退回单进程时作业照样能跑通，建议让验收检查进程数确实对得上：
```bash
VERIFY_LOG_CONTAINS="world_size=2"   # 作业日志里必须出现的内容，按项目实际打印的内容写
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

框架只接受配置文件路径、改不了读取方式时，让启动脚本先把配置解密到内存盘（单引号不能省，变量要留到运行时才展开）：
```bash
CONFIG_MATERIALIZE="configs/recipe.yaml"
START_CMD='python -m some_framework --config ${KILN_CONFIG_DIR}/configs/recipe.yaml'
```
这样作业期间明文在 `/dev/shm`，能进容器的人直接 `cat` 就能读到，所以默认关闭，能用 `load_yaml` 就别开。
它只写内存盘（不是内存盘就拒绝启动），文件随容器消失，内存盘默认只有 64MB，配置很大时调 `--shm-size`。

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

## 敏感文件（serve 和 train 都生效）

这些文件默认不进镜像，打包时会逐个提示：

- 环境变量文件：`*.env`、`.env.*`、`.envrc`
- 密钥和证书：`*.pem`、`*.key`、`*.p12`、`*.pfx`、`*.jks`、`*.keystore`、`id_rsa`、`id_dsa`、`id_ecdsa`、`id_ed25519`
- 凭据：`.netrc`、`.pypirc`、`.npmrc`、`pip.conf`、`.git-credentials`、`credentials.json`、`service-account*.json`
- 凭据目录：`.ssh/`、`.aws/`、`.gnupg/`

验收时如果在 `/app` 里发现命中规则的文件，会直接判失败。确实要随镜像发出的文件（比如公开的 CA 证书），逐个写完整路径：

```bash
PACK_KEEP="certs/ca.pem certs/intermediate.pem"   # 相对 SRC_DIR，不支持通配，凭据目录里的文件不能放行
```

这份规则只认文件名，查不出名字普通、内容却是密钥的文件，配置文件内容里的凭据也不在范围内。

## 私有依赖

`requirements`（包括它 `-r`、`-c` 引用的文件）和 `PIP_INSTALL_ARGS` 里，带账号密码或令牌的地址会在打包前被拒绝，因为它们会随镜像发出。
报错只给文件和行号，不会把凭据打印出来。

目前打包器不支持在构建时注入凭据。私有依赖的做法是提前下载成 wheel，放进源码目录：

```bash
pip download -d wheels --no-deps my-private-pkg==1.2.3   # 在有权限的机器上执行，平台要和镜像一致
```
```text
# requirements.txt
--find-links wheels
my-private-pkg==1.2.3
```

`--find-links` 的路径相对 requirements 文件。这些 wheel 会进镜像，里面的代码没有编译保护。

## 停止信号（serve 和 train 都生效）

容器的 PID 1 是 `.kiln/kiln_init.py`，它把 `SIGTERM` 等信号转给作业的整个进程组，等整组退完才结束，并传回退出码。

- **训练想在被抢占时存 checkpoint：** 在代码里装 `SIGTERM` 处理函数。没装的话，作业收到信号就直接退出。
- **处理函数最好能重复进入：** 启动器自己也可能转发信号。CPU 上 `torchrun` 两进程实测每个 worker 只收到一次，`deepspeed` 和 `accelerate` 没有测过。
- **退出码看启动器：** `single` 存完正常退出时是 0；`torchrun` 被停止时实测是 1，就算 worker 都存完了也一样。判断有没有存完要看产物，别只看退出码。
- **留够退出时间：** `docker stop` 默认的等待时间不够存 checkpoint，要用 `docker stop -t 120` 这样显式给够，K8s 对应 `terminationGracePeriodSeconds`。
- **验收：** 会真的 `docker stop` 一次，退出码 137 判失败。收尾慢的服务调大 `VERIFY_STOP_TIMEOUT`（默认 30 秒）。

## 依赖安装加固（可选，serve 和 train 都能用）

项目的依赖由 `PIP_REQUIREMENTS` 指定，默认按 pip 的常规方式安装。要锁定哈希或禁止执行安装脚本，在 `pack.conf` 里加：

```bash
PIP_INSTALL_ARGS="--require-hashes --only-binary :all:"
```

- `--require-hashes`：requirements 里每个包（包括间接依赖）都要写版本和哈希，可以用 `pip-compile --generate-hashes` 生成。
- `--only-binary :all:`：只装 wheel，不执行源码包的安装脚本；没有 wheel 的依赖会装不上，打包直接失败。
- 这个开关只作用于项目的 requirements。打包器自己装的 `Cython` 和 `cryptography` 不受影响，也没有锁定版本。
- 它的值会留在镜像历史里，所以写了账号密码的索引地址会被拒绝。

## 边界（务必知道）

- 保护的是**代码逻辑**，不是字符串常量：敏感值一律走 `REQUIRED_ENV` 外置。
- **配置加密防的是镜像外泄**：没有密钥读不到配置，但拿到密钥的人、能进运行中容器的人都能拿到明文（环境变量、`docker inspect`、进程内存）。文件名和大小不加密，数据集不在范围内。详见 README「边界」。
- **`torch.compile` 冲突**：编成 `.so` 的模块 dynamo 无法追踪，会退回 eager；热点逻辑「保护」与「被 compile 优化」需二选一。
- 这是**抬高抄袭门槛**，不是绝对加密。要「逻辑绝对不可得」，只能把算法留在自己服务器、对外只给 API。
