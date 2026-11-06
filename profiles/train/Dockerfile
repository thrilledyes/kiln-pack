# SPDX-License-Identifier: Apache-2.0
# 训练作业版两阶段打包 Dockerfile（由 pack.sh 在 PROFILE=train 时调用）。
# 刻意不写 `# syntax=docker/dockerfile:1`：避免每次构建去 docker.io 拉外部 frontend（受限网络易失败）。
#   builder  阶段：与 serve 完全一致——装编译器 + Cython，把受保护的 .py 编成 .so，删明文。
#   runtime  阶段：和 serve 的差异集中在这里——
#     · 训练要写 checkpoint / 日志 / 框架缓存（torch_extensions、triton、HF），需要可写目录；
#     · 批作业不是常驻服务，不设 docker HEALTHCHECK、不 EXPOSE 端口；
#     · 数据进、产物出都走挂载卷，镜像里不烘任何数据。
# 编译器、Cython、.c 中间产物仍只留在 builder 阶段，不进最终镜像。
# 注：builder 段与 profiles/serve/Dockerfile 保持同步，改一处记得改两处。

ARG BUILDER_BASE=python:3.11-slim-bookworm
ARG RUNTIME_BASE=python:3.11-slim-bookworm

# ---------- builder ----------
FROM ${BUILDER_BASE} AS builder
ARG PROTECT_GLOBS=""
ARG PIP_REQUIREMENTS=""
RUN set -eux; \
    if command -v apt-get >/dev/null 2>&1; then \
      apt-get update; \
      apt-get install -y --no-install-recommends gcc g++ binutils python3-dev; \
      rm -rf /var/lib/apt/lists/*; \
    fi
RUN pip install --no-cache-dir Cython
WORKDIR /src
COPY . /src
# 去掉可能混进来的 VCS / 字节码缓存
RUN rm -rf /src/.git /src/.gitignore && find /src -name '__pycache__' -type d -prune -exec rm -rf {} + || true
# 装运行期依赖：受保护模块顶层会 import 第三方库（如 torch），
# compile_protect.py 的 import 自检需要这些库才能加载 .so。
# 这些依赖只留在 builder 阶段，不会进最终 runtime 镜像。
RUN set -eux; \
    if [ -n "${PIP_REQUIREMENTS}" ] && [ -f "/src/${PIP_REQUIREMENTS}" ]; then \
      pip install --no-cache-dir -r "/src/${PIP_REQUIREMENTS}"; \
    fi
# 编译受保护源码 → .so，并删除对应 .py / .c
RUN python /src/.kiln/compile_protect.py /src ${PROTECT_GLOBS}
# 编译助手本身不是产物，去掉
RUN rm -f /src/.kiln/compile_protect.py

# ---------- runtime ----------
FROM ${RUNTIME_BASE} AS runtime
ARG KILN_APP=app
ARG KILN_VERSION=dev
ARG KILN_BUILD_ID=unknown
ARG KILN_BUILT_AT=unknown
ARG PIP_REQUIREMENTS=""
# 容器内产物目录（checkpoint/日志）。运行时用 -v 挂到宿主；默认 /workspace/output。
ARG KILN_OUTPUT_DIR=/workspace/output
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    KILN_APP=${KILN_APP} \
    KILN_VERSION=${KILN_VERSION} \
    KILN_BUILD_ID=${KILN_BUILD_ID} \
    KILN_BUILT_AT=${KILN_BUILT_AT} \
    KILN_OUTPUT_DIR=${KILN_OUTPUT_DIR} \
    HOME=/home/appuser \
    HF_HOME=/home/appuser/.cache/huggingface \
    TORCH_EXTENSIONS_DIR=/home/appuser/.cache/torch_extensions \
    TRITON_CACHE_DIR=/home/appuser/.cache/triton
WORKDIR /app
# 拷贝已去源码的应用树（含 .so、.kiln 脚本，不含受保护 .py）
COPY --from=builder /src /app
# 清掉 import 自检残留的字节码缓存：.pyc 的 co_filename 会泄露 builder 工作路径 /src。
RUN find /app -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true; \
    find /app -name '*.pyc' -delete 2>/dev/null || true
# 运行期依赖（纯 wheel，无需编译器）
RUN set -eux; \
    if [ -n "${PIP_REQUIREMENTS}" ] && [ -f "/app/${PIP_REQUIREMENTS}" ]; then \
      pip install --no-cache-dir -r "/app/${PIP_REQUIREMENTS}"; \
    fi
# 非 root 运行：抬高同容器内 ptrace / 读 /proc/<pid>/mem 等攻击门槛。
# 代码 /app 仍只读（a+rX，不给写）；训练需要写的只有产物目录和框架缓存，
# 它们建在 appuser 的可写路径下，与只读代码分离。
# 构建上下文（mktemp -d 0700 + rsync）目录权限不含 others 位，切非 root 前先放开 /app 只读访问。
RUN useradd -u 10001 -m -d /home/appuser -s /usr/sbin/nologin appuser \
 && chmod -R a+rX /app \
 && mkdir -p "${KILN_OUTPUT_DIR}" "${HF_HOME}" "${TORCH_EXTENSIONS_DIR}" "${TRITON_CACHE_DIR}" \
 && chown -R appuser:appuser "${KILN_OUTPUT_DIR}" /home/appuser
USER appuser
# 产物目录声明为卷：运行时挂宿主目录即可取回 checkpoint，不挂则随容器生命周期。
VOLUME ["${KILN_OUTPUT_DIR}"]
LABEL kiln.app="${KILN_APP}" \
      kiln.version="${KILN_VERSION}" \
      kiln.build_id="${KILN_BUILD_ID}" \
      kiln.built_at="${KILN_BUILT_AT}" \
      kiln.profile="train"
# 批作业无常驻端口，不设 HEALTHCHECK / EXPOSE：作业跑完即退出，由退出码与产物判断成败。
ENTRYPOINT ["/bin/sh", "/app/.kiln/launch.sh"]
