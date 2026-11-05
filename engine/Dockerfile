# syntax=docker/dockerfile:1
# SPDX-License-Identifier: Apache-2.0
# 通用两阶段打包 Dockerfile（由 pack.sh 调用，一般不用手改）。
#   builder  阶段：装编译器 + Cython，把受保护的 .py 编译成 .so，删掉明文源码。
#   runtime  阶段：干净底座，只拷贝“已去源码”的应用目录 + 装运行期依赖。
# 编译器、Cython、.c 中间产物都留在 builder 阶段，不进最终镜像。

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
# 装运行期依赖：受保护模块顶层会 import 第三方库（如 fastapi），
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
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    KILN_APP=${KILN_APP} \
    KILN_VERSION=${KILN_VERSION} \
    KILN_BUILD_ID=${KILN_BUILD_ID} \
    KILN_BUILT_AT=${KILN_BUILT_AT} \
    HOME=/home/appuser
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
# 非 root 运行：抬高同容器内 ptrace / 读 /proc/<pid>/mem 等攻击的门槛。
# 依赖已在上面以 root 装好，运行期只读执行 /app，不需要写权限。
# 注：需要写缓存目录或访问设备（如 GPU）的框架，后续用 pack.conf 开关放宽。
# 构建上下文（mktemp -d 0700 + rsync）目录权限不含 others 位，
# 切非 root 前先给 /app 放开只读访问（a+rX：只加读和目录执行位，不给写）。
RUN useradd -u 10001 -m -d /home/appuser -s /usr/sbin/nologin appuser \
 && chmod -R a+rX /app
USER appuser
LABEL kiln.app="${KILN_APP}" \
      kiln.version="${KILN_VERSION}" \
      kiln.build_id="${KILN_BUILD_ID}" \
      kiln.built_at="${KILN_BUILT_AT}"
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["/bin/sh", "/app/.kiln/healthcheck.sh"]
ENTRYPOINT ["/bin/sh", "/app/.kiln/launch.sh"]
