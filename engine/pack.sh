#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# kiln-pack 通用打包脚本：读一份 pack.conf，产出“看不到源码、能跑、能查版本、能做验收”的镜像。
# 用法: pack.sh <项目目录，含 pack.conf> [额外 docker build 参数...]
#
# 引擎按 pack.conf 的 PROFILE 选一套“交付形态”：
#   serve  —— 常驻推理服务（起服 + 健康检查 + 接口验收），见 profiles/serve/
#   train  —— 训练作业（按 LAUNCHER 起训 + 冒烟训练验收），见 profiles/train/
# 公共部分（两阶段构建、Cython 编译保护、机密扫描验收）由 engine/ + profiles/<p>/ 共享。
#
# 新增一个框架/项目时，通常只写一份新的 pack.conf；engine/ 与 profiles/ 一字不动。
# 差异点集中在 pack.conf：PROFILE / 底座 / PROTECT_GLOBS / START_CMD / 验收相关项。
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ENGINE_DIR}/.." && pwd)"

if [ $# -lt 1 ]; then
  echo "用法: $0 <项目目录，含 pack.conf> [额外 docker build 参数...]" >&2
  exit 2
fi
PROJECT_DIR="$(cd "$1" && pwd)"
shift
EXTRA_BUILD_ARGS=("$@")

CONF="${PROJECT_DIR}/pack.conf"
if [ ! -f "$CONF" ]; then
  echo "!! 找不到 $CONF" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$CONF"

: "${APP_NAME:?pack.conf 必须设置 APP_NAME}"
: "${VERSION:?pack.conf 必须设置 VERSION}"
: "${RUNTIME_BASE:?pack.conf 必须设置 RUNTIME_BASE}"
: "${BUILDER_BASE:?pack.conf 必须设置 BUILDER_BASE}"
: "${SRC_DIR:?pack.conf 必须设置 SRC_DIR}"
: "${START_CMD:?pack.conf 必须设置 START_CMD}"

# PROFILE 默认 serve，兼容未声明 PROFILE 的旧推理配置。
PROFILE="${PROFILE:-serve}"
PROFILE_DIR="${REPO_ROOT}/profiles/${PROFILE}"
if [ ! -d "$PROFILE_DIR" ]; then
  echo "!! 未知 PROFILE='${PROFILE}'，profiles/ 下可用: $(ls -1 "${REPO_ROOT}/profiles" 2>/dev/null | tr '\n' ' ')" >&2
  exit 2
fi
if [ ! -f "${PROFILE_DIR}/Dockerfile" ] || [ ! -f "${PROFILE_DIR}/launch.sh" ] || [ ! -f "${PROFILE_DIR}/verify.sh" ]; then
  echo "!! profile '${PROFILE}' 不完整：需要 Dockerfile / launch.sh / verify.sh" >&2
  exit 2
fi

PROTECT_GLOBS="${PROTECT_GLOBS:-}"
PIP_REQUIREMENTS="${PIP_REQUIREMENTS:-}"
EXPOSE_PORT="${EXPOSE_PORT:-8000}"
HEALTHCHECK_CMD="${HEALTHCHECK_CMD:-true}"
SECRET_MARKER="${SECRET_MARKER:-}"
REQUIRED_ENV="${REQUIRED_ENV:-}"

# --- train profile 专属项（serve 用不到，留默认空值即可） ---
LAUNCHER="${LAUNCHER:-single}"            # single | torchrun（deepspeed/accelerate 预留）
NPROC_PER_NODE="${NPROC_PER_NODE:-1}"     # torchrun 单机进程数
TORCHRUN_ARGS="${TORCHRUN_ARGS:-}"        # 透传给 torchrun 的额外参数
OUTPUT_DIR="${OUTPUT_DIR:-/workspace/output}"  # 容器内产物目录（checkpoint/日志），运行时挂卷到宿主

# --- 配置/数据“真加密”开关位（v1 仅占位，不实装；见 README“边界”与 v2 计划） ---
CONFIG_ENCRYPT="${CONFIG_ENCRYPT:-off}"
if [ "$CONFIG_ENCRYPT" != "off" ]; then
  echo "!! CONFIG_ENCRYPT='${CONFIG_ENCRYPT}'：配置/数据真加密在 v1 尚未实装，请置为 off（见 README 边界）。" >&2
  exit 2
fi

SRC_ABS="$(cd "${PROJECT_DIR}/${SRC_DIR}" && pwd)"
BUILD_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(( RANDOM % 9000 + 1000 ))"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
IMAGE_TAG="${APP_NAME}:${VERSION}"

echo "== kiln-pack =="
echo "profile    : $PROFILE"
echo "项目目录   : $PROJECT_DIR"
echo "源码目录   : $SRC_ABS"
echo "镜像标签   : $IMAGE_TAG"
echo "build_id   : $BUILD_ID"
echo "runtime 底座: $RUNTIME_BASE"
echo "builder 底座: $BUILDER_BASE"
[ "$PROFILE" = train ] && echo "launcher   : $LAUNCHER (nproc=$NPROC_PER_NODE)"
echo

# 用临时构建上下文，避免污染/依赖源码目录本身的 .dockerignore 之类的东西，
# 也方便把 .git、证据目录等排除在外。
BUILD_CTX="$(mktemp -d)"
trap 'rm -rf "$BUILD_CTX"' EXIT

echo "-- 1/3 复制构建上下文（排除 .git / 证据目录 / 预编译产物）"
# 排除源码树里的预编译产物（.so/.pyd/.pyc）：它们应在 builder 阶段由 .py 重新编译。
# 源树里的旧 .so 会被原样带进镜像，可能残留已从 .py 删除的旧密钥（这个坑踩过，见教程）。
rsync -a \
  --exclude='.git' \
  --exclude='.git/***' \
  --exclude='evidence/***' \
  --exclude='experiments/***' \
  --exclude='__pycache__/***' \
  --exclude='*.pyc' \
  --exclude='*.so' \
  --exclude='*.pyd' \
  --exclude='pack.conf' \
  "${SRC_ABS}/" "${BUILD_CTX}/"

mkdir -p "${BUILD_CTX}/.kiln"
# 公共：编译保护助手（builder 阶段用）
cp "${ENGINE_DIR}/compile_protect.py" "${BUILD_CTX}/.kiln/compile_protect.py"
# profile 专属：启动入口 +（serve 才有的）健康检查入口
cp "${PROFILE_DIR}/launch.sh" "${BUILD_CTX}/.kiln/launch.sh"
if [ -f "${PROFILE_DIR}/healthcheck.sh" ]; then
  cp "${PROFILE_DIR}/healthcheck.sh" "${BUILD_CTX}/.kiln/healthcheck.sh"
fi
printf '%s\n' "$START_CMD" > "${BUILD_CTX}/.kiln/start_cmd.sh"
printf '%s\n' "$HEALTHCHECK_CMD" > "${BUILD_CTX}/.kiln/health_cmd.sh"
# 运行必需的 env 清单（每行一个），launch.sh 起服/起训前据此校验，缺失即拒绝启动
set -f  # 关文件名通配，避免 env 名含特殊字符时被 glob 展开
printf '%s\n' ${REQUIRED_ENV:-} > "${BUILD_CTX}/.kiln/required_env.list"
set +f
# profile 运行期配置（launch.sh 在镜像内用 /bin/sh source 它决定怎么起）。
# 用单引号包值，保证 POSIX sh 能安全 source；值本身别含单引号（路径/启动器名不会有）。
{
  printf 'PROFILE=%s\n' "$PROFILE"
  printf 'LAUNCHER=%s\n' "$LAUNCHER"
  printf 'NPROC_PER_NODE=%s\n' "$NPROC_PER_NODE"
  printf "TORCHRUN_ARGS='%s'\n" "$TORCHRUN_ARGS"
  printf "OUTPUT_DIR='%s'\n" "$OUTPUT_DIR"
} > "${BUILD_CTX}/.kiln/profile.conf"
chmod +x "${BUILD_CTX}/.kiln/"*.sh

# healthcheck.sh（serve）是 HEALTHCHECK 的入口（Dockerfile 里 CMD 指向它），
# 它只负责 exec 上面渲染自 pack.conf HEALTHCHECK_CMD 的 health_cmd.sh。

echo "-- 2/3 docker build（两阶段：builder 编译保护 → runtime 干净底座）"
BUILD_ARGS=(
  --build-arg BUILDER_BASE="$BUILDER_BASE"
  --build-arg RUNTIME_BASE="$RUNTIME_BASE"
  --build-arg PROTECT_GLOBS="$(echo "$PROTECT_GLOBS" | tr '\n' ' ')"
  --build-arg PIP_REQUIREMENTS="$PIP_REQUIREMENTS"
  --build-arg KILN_APP="$APP_NAME"
  --build-arg KILN_VERSION="$VERSION"
  --build-arg KILN_BUILD_ID="$BUILD_ID"
  --build-arg KILN_BUILT_AT="$BUILT_AT"
)
# train runtime 需要一个可写产物目录；serve 的 Dockerfile 不声明该 arg，故仅 train 传。
if [ "$PROFILE" = train ]; then
  BUILD_ARGS+=(--build-arg KILN_OUTPUT_DIR="$OUTPUT_DIR")
fi

docker build \
  "${BUILD_ARGS[@]}" \
  -f "${PROFILE_DIR}/Dockerfile" \
  -t "$IMAGE_TAG" \
  ${EXTRA_BUILD_ARGS[@]+"${EXTRA_BUILD_ARGS[@]}"} \
  "$BUILD_CTX"

echo
echo "-- 3/3 验收：交给 profiles/${PROFILE}/verify.sh 做『源码看不见 + 能正常跑 + 可运维』的完整检查"
VERIFY_RC=0
bash "${PROFILE_DIR}/verify.sh" "$PROJECT_DIR" || VERIFY_RC=$?

echo
if [ "$VERIFY_RC" -eq 0 ]; then
  echo "== 完成 =="
  echo "镜像: $IMAGE_TAG"
  echo "build_id: $BUILD_ID"
  if [ "$PROFILE" = train ]; then
    echo "可以: docker run --rm -v \$(pwd)/data:/workspace/data:ro -v \$(pwd)/out:${OUTPUT_DIR} ${IMAGE_TAG}"
  else
    echo "可以: docker run -d -p 8000:${EXPOSE_PORT} --name ${APP_NAME} ${IMAGE_TAG}"
  fi
else
  echo "== 构建成功，但验收没过，见上面的 [FAIL] ==" >&2
fi
exit "$VERIFY_RC"
