# kiln-pack 使用指南

从「一套已经调通的推理服务」到「一个可交付的 `.tar` 镜像包」，全程五步。
目标：把值钱的自研 Python 逻辑编译成 `.so` 保护进镜像，源码不外发，服务照常可起。

## 0. 前置

- 你已经有一套能跑起来的推理服务：一个框架底座（vLLM / SGLang / 自研编排）+ 你自己的若干 `.py`，其中有要保护的自研逻辑（调度 / 路由 / 采样 / 量化等）。
- 本机装了 Docker。
- `.so` 认 CPU 架构和 Python 版本，**builder 与 runtime 必须一致**（同一个底座镜像最省心）。

## 1. 准备底座镜像

把推理框架装进一个镜像当底座，builder（编译阶段）和 runtime（运行阶段）共用它。
已有框架官方镜像就直接用；没有就自己装一个，例如：

```bash
printf 'FROM python:3.11-slim-bookworm\nRUN pip install --no-cache-dir vllm\n' \
  | docker build -t my-base .  -f -
```

> 底座只需装好框架本体；编译器（gcc / Cython）由 kiln-pack 在 builder 阶段自动装，不进最终镜像。

## 2. 组织工程目录

```
myproj/
  pack.conf                 # 打包配置（见第 3 步）
  app/
    __init__.py
    server.py               # 起服入口（薄壳，无 IP 价值，可留明文）
    proprietary_logic.py    # 要保护的自研逻辑 —— 会被编成 .so
```

`server.py` 正常 `from app.proprietary_logic import ...` 调用；编译成 `.so` 后 import 方式完全不变。

## 3. 写 pack.conf

```bash
APP_NAME="my-svc"                 # 产出镜像名
VERSION="1.0.0"                   # 版本（会写进 /version 指纹）
RUNTIME_BASE="my-base"            # 运行底座（第 1 步的镜像）
BUILDER_BASE="my-base"            # 编译底座（同上）
SRC_DIR="."                       # 源码目录（相对 pack.conf）
PROTECT_GLOBS="app/proprietary_logic.py"   # 要保护的 .py，支持 glob / 多行
START_CMD="python -m uvicorn app.server:app --host 0.0.0.0 --port 8000"
EXPOSE_PORT="8000"
HEALTHCHECK_CMD="python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz',timeout=3).status==200 else 1)\""

# 敏感常量别硬编码进源码（否则 strings 能从 .so 抠出）；改为运行时注入：
SECRET_MARKER="CHANGE_ME_UNIQUE_MARKER"   # 验收用：确认它不随镜像发出
REQUIRED_ENV="MY_SECRET"                  # 起服必需的环境变量，缺了拒绝启动
VERIFY_ENV="MY_SECRET=whatever-for-verify"   # 验收时临时注入
```

换推理框架时，通常**只改这一个文件**（底座 + PROTECT_GLOBS + 起服命令），`engine/` 一字不动。

## 4. 打包 + 自动验收

```bash
bash engine/pack.sh myproj
```

它会两阶段构建（builder 编译保护 → runtime 干净底座），产出镜像 `my-svc:1.0.0`，
并自动跑验收：**源码看不见 + 服务正常起 + 可运维**。看到结尾 `验收通过` 即成功。
任何 `[FAIL]` 都会在上面列出原因。

## 5. 导出成 `.tar` 交付

`pack.sh` 产出的是本地 Docker 镜像；要离线交付就 `docker save` 成 `.tar`：

```bash
docker save my-svc:1.0.0 -o my-svc-1.0.0.tar
# 想更小可顺手压缩：
docker save my-svc:1.0.0 | gzip > my-svc-1.0.0.tar.gz
```

交付物 `.tar` 里只有 `.so`、没有受保护源码。对方加载起服：

```bash
docker load -i my-svc-1.0.0.tar
docker run -d -p 8000:8000 -e MY_SECRET=... my-svc:1.0.0
curl http://127.0.0.1:8000/healthz     # {"status":"ok"}
curl http://127.0.0.1:8000/version     # 构建指纹
```

## 边界（务必知道）

- 保护的是**代码逻辑**，不是字符串常量：硬编码密钥用 `strings` 仍可从 `.so` 抠出，敏感值一律走 `REQUIRED_ENV` 外置。
- 这是**抬高抄袭门槛**，不是绝对加密。要「逻辑绝对不可得」，只能把算法留在自己服务器、对外只给 API。
- 需要写 `~/.cache` 的重框架（torch / transformers 等）已被支持：runtime 以非 root 用户运行并提供可写家目录。
