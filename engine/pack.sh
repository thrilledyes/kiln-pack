#!/usr/bin/env bash
# kiln-pack 通用打包脚本：读一份 pack.conf，产出“看不到源码、能起服、能查版本、能做验收”的镜像。
# 用法: pack.sh <项目目录，含 pack.conf> [额外 docker build 参数...]
#
# 对不同推理框架（vLLM / SGLang / 自研）新增支持时，一般只需要新写一份 pack.conf，
# 本脚本和 Dockerfile 不用改。差异点集中在 pack.conf 的这几项：
#   RUNTIME_BASE / BUILDER_BASE（底座镜像）
#   PROTECT_GLOBS（哪些 .py 要编译保护）
#   START_CMD（起服命令）
#   HEALTHCHECK_CMD（健康检查）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
PROTECT_GLOBS="${PROTECT_GLOBS:-}"
PIP_REQUIREMENTS="${PIP_REQUIREMENTS:-}"
EXPOSE_PORT="${EXPOSE_PORT:-8000}"
HEALTHCHECK_CMD="${HEALTHCHECK_CMD:-true}"
SECRET_MARKER="${SECRET_MARKER:-}"
REQUIRED_ENV="${REQUIRED_ENV:-}"

SRC_ABS="$(cd "${PROJECT_DIR}/${SRC_DIR}" && pwd)"
BUILD_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(( RANDOM % 9000 + 1000 ))"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
IMAGE_TAG="${APP_NAME}:${VERSION}"

echo "== kiln-pack =="
echo "项目目录   : $PROJECT_DIR"
echo "源码目录   : $SRC_ABS"
echo "镜像标签   : $IMAGE_TAG"
echo "build_id   : $BUILD_ID"
echo "runtime 底座: $RUNTIME_BASE"
echo "builder 底座: $BUILDER_BASE"
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
cp "${SCRIPT_DIR}/compile_protect.py" "${BUILD_CTX}/.kiln/compile_protect.py"
cp "${SCRIPT_DIR}/launch.sh" "${BUILD_CTX}/.kiln/launch.sh"
cp "${SCRIPT_DIR}/healthcheck.sh" "${BUILD_CTX}/.kiln/healthcheck.sh"
printf '%s\n' "$START_CMD" > "${BUILD_CTX}/.kiln/start_cmd.sh"
printf '%s\n' "$HEALTHCHECK_CMD" > "${BUILD_CTX}/.kiln/health_cmd.sh"
# 运行必需的 env 清单（每行一个），launch.sh 起服前据此校验，缺失即拒绝启动
set -f  # 关文件名通配，避免 env 名含特殊字符时被 glob 展开
printf '%s\n' ${REQUIRED_ENV:-} > "${BUILD_CTX}/.kiln/required_env.list"
set +f
chmod +x "${BUILD_CTX}/.kiln/"*.sh

# healthcheck.sh 是 HEALTHCHECK 的入口（Dockerfile 里 CMD 指向它），
# 它只负责 exec 上面渲染自 pack.conf HEALTHCHECK_CMD 的 health_cmd.sh。

echo "-- 2/3 docker build（两阶段：builder 编译保护 → runtime 干净底座）"
docker build \
  --build-arg BUILDER_BASE="$BUILDER_BASE" \
  --build-arg RUNTIME_BASE="$RUNTIME_BASE" \
  --build-arg PROTECT_GLOBS="$(echo "$PROTECT_GLOBS" | tr '\n' ' ')" \
  --build-arg PIP_REQUIREMENTS="$PIP_REQUIREMENTS" \
  --build-arg KILN_APP="$APP_NAME" \
  --build-arg KILN_VERSION="$VERSION" \
  --build-arg KILN_BUILD_ID="$BUILD_ID" \
  --build-arg KILN_BUILT_AT="$BUILT_AT" \
  -f "${SCRIPT_DIR}/Dockerfile" \
  -t "$IMAGE_TAG" \
  ${EXTRA_BUILD_ARGS[@]+"${EXTRA_BUILD_ARGS[@]}"} \
  "$BUILD_CTX"

echo
echo "-- 3/3 验收：交给 verify.sh 做『源码看不见 + 服务正常 + 可运维』三件事的完整检查"
VERIFY_RC=0
bash "${SCRIPT_DIR}/verify.sh" "$PROJECT_DIR" || VERIFY_RC=$?

echo
if [ "$VERIFY_RC" -eq 0 ]; then
  echo "== 完成 =="
  echo "镜像: $IMAGE_TAG"
  echo "build_id: $BUILD_ID"
  echo "可以: docker run -d -p 8000:${EXPOSE_PORT} --name ${APP_NAME} ${IMAGE_TAG}"
else
  echo "== 构建成功，但验收没过，见上面的 [FAIL] ==" >&2
fi
exit "$VERIFY_RC"
