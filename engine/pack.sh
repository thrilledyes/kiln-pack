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

# --- 配置加密（train 专属）：on 时把 CONFIG_GLOBS 匹配的配置加密成 .enc，明文不进构建上下文 ---
CONFIG_ENCRYPT="${CONFIG_ENCRYPT:-off}"
CONFIG_GLOBS="${CONFIG_GLOBS:-}"
case "$CONFIG_ENCRYPT" in
  off) ;;
  on)
    if [ "$PROFILE" != train ]; then
      echo "!! CONFIG_ENCRYPT=on 目前只支持 PROFILE=train（当前 ${PROFILE}）。" >&2
      exit 2
    fi
    if [ -z "$CONFIG_GLOBS" ]; then
      echo "!! CONFIG_ENCRYPT=on 时必须设置 CONFIG_GLOBS，例如 configs/*.yaml。" >&2
      exit 2
    fi
    # 密钥只从环境变量读：写进 pack.conf 会进版本库，走 --build-arg 会留在镜像历史里。
    if [ -z "$(printenv KILN_CONFIG_KEY 2>/dev/null)" ]; then
      echo "!! CONFIG_ENCRYPT=on 时必须 export KILN_CONFIG_KEY（可用 openssl rand -base64 32 生成，自己保管好）。" >&2
      exit 2
    fi
    ;;
  *)
    echo "!! 未知 CONFIG_ENCRYPT='${CONFIG_ENCRYPT}'。支持: on | off。" >&2
    exit 2
    ;;
esac

SRC_ABS="$(cd "${PROJECT_DIR}/${SRC_DIR}" && pwd)"

# 展开 CONFIG_GLOBS，每行输出一个相对路径。任何一条有问题都中止，宁可打包失败也不让明文漏进镜像。
expand_config_globs() (
  cd "$SRC_ABS" || exit 1
  for pat in $CONFIG_GLOBS; do
    case "$pat" in
      *'**'*)
        # macOS 自带 bash 3.2 没有 globstar，** 会被当成 * 悄悄少配，深层明文就进镜像了。
        echo "!! CONFIG_GLOBS 不支持 **，请逐层写明: ${pat}" >&2
        exit 2
        ;;
      /*|..|../*|*/..|*/../*)
        echo "!! CONFIG_GLOBS 必须是源码目录内的相对路径: ${pat}" >&2
        exit 2
        ;;
    esac
    matched=0
    for f in $pat; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      if [ -L "$f" ] || [ ! -f "$f" ]; then
        echo "!! CONFIG_GLOBS 匹配到的不是普通文件: ${f}" >&2
        exit 2
      fi
      printf '%s\n' "${f#./}"
      matched=1
    done
    if [ "$matched" = 0 ]; then
      echo "!! CONFIG_GLOBS 的 '${pat}' 没有匹配到文件。" >&2
      exit 2
    fi
  done
)

CONFIG_FILES=()
CONFIG_EXCLUDES=()
if [ "$CONFIG_ENCRYPT" = on ]; then
  CONFIG_LIST="$(expand_config_globs)"
  while IFS= read -r f; do
    CONFIG_FILES+=("$f")
    CONFIG_EXCLUDES+=("--exclude=/${f}")
  done <<KILN_CONFIG_EOF
$(printf '%s\n' "$CONFIG_LIST" | sort -u)
KILN_CONFIG_EOF
fi

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
[ "$PROFILE" = train ] && echo "配置加密   : $CONFIG_ENCRYPT"
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
  ${CONFIG_EXCLUDES[@]+"${CONFIG_EXCLUDES[@]}"} \
  "${SRC_ABS}/" "${BUILD_CTX}/"

mkdir -p "${BUILD_CTX}/.kiln"
if [ "$CONFIG_ENCRYPT" = on ]; then
  for f in "${CONFIG_FILES[@]}"; do
    if [ -e "${BUILD_CTX}/${f}" ]; then
      echo "!! 配置明文混进了构建上下文，中止: ${f}" >&2
      exit 1
    fi
  done
  # 没被 CONFIG_GLOBS 覆盖的配置会以明文进镜像，提醒一声；有些确实不需要加密，所以不中止。
  UNENCRYPTED="$(cd "$BUILD_CTX" && find . -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) | sed 's|^\./||')"
  if [ -n "$UNENCRYPTED" ]; then
    echo "  [WARN] 这些配置不在 CONFIG_GLOBS 里，会以明文进镜像:" >&2
    printf '%s\n' "$UNENCRYPTED" | sed 's/^/    /' >&2
  fi
  # 加密放在一次性容器里做：打包机不用装 cryptography；容器断网，密钥和明文只在这一步出现，
  # 工具镜像由没有上下文的 Dockerfile 构建，所以两者都不会进任何镜像层或构建缓存。
  echo "   加密配置（断网的一次性容器）"
  printf 'FROM %s\nRUN pip install --no-cache-dir cryptography\n' "$BUILDER_BASE" \
    | docker build -q -t kiln-config-tool:local - >/dev/null
  docker run --rm --network none \
    --user "$(id -u):$(id -g)" \
    -e KILN_CONFIG_KEY \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -v "${SRC_ABS}:/kiln/in:ro" \
    -v "${BUILD_CTX}:/kiln/out" \
    -v "${ENGINE_DIR}:/kiln/tool:ro" \
    kiln-config-tool:local \
    python /kiln/tool/encrypt_config.py /kiln/in /kiln/out "${CONFIG_FILES[@]}"
  printf '%s\n' "${CONFIG_FILES[@]}" > "${BUILD_CTX}/.kiln/config.list"
fi
# train 镜像里的配置读取助手：不管加不加密，项目代码都用同样的方式读配置。
if [ "$PROFILE" = train ]; then
  mkdir -p "${BUILD_CTX}/.kiln/lib"
  cp "${ENGINE_DIR}/kiln_config.py" "${BUILD_CTX}/.kiln/lib/kiln_config.py"
fi
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
[ "$CONFIG_ENCRYPT" = on ] && echo KILN_CONFIG_KEY >> "${BUILD_CTX}/.kiln/required_env.list"
# profile 运行期配置（launch.sh 在镜像内用 /bin/sh source 它决定怎么起）。
# 用单引号包值，保证 POSIX sh 能安全 source；值本身别含单引号（路径/启动器名不会有）。
{
  printf 'PROFILE=%s\n' "$PROFILE"
  printf 'LAUNCHER=%s\n' "$LAUNCHER"
  printf 'NPROC_PER_NODE=%s\n' "$NPROC_PER_NODE"
  printf "TORCHRUN_ARGS='%s'\n" "$TORCHRUN_ARGS"
  printf "OUTPUT_DIR='%s'\n" "$OUTPUT_DIR"
  printf 'CONFIG_ENCRYPT=%s\n' "$CONFIG_ENCRYPT"
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
  BUILD_ARGS+=(--build-arg KILN_OUTPUT_DIR="$OUTPUT_DIR" --build-arg CONFIG_ENCRYPT="$CONFIG_ENCRYPT")
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
  if [ "$PROFILE" = train ] && [ "$CONFIG_ENCRYPT" = on ]; then
    echo "可以: docker run --rm -e KILN_CONFIG_KEY -v \$(pwd)/data:/workspace/data:ro -v \$(pwd)/out:${OUTPUT_DIR} ${IMAGE_TAG}"
  elif [ "$PROFILE" = train ]; then
    echo "可以: docker run --rm -v \$(pwd)/data:/workspace/data:ro -v \$(pwd)/out:${OUTPUT_DIR} ${IMAGE_TAG}"
  else
    echo "可以: docker run -d -p 8000:${EXPOSE_PORT} --name ${APP_NAME} ${IMAGE_TAG}"
  fi
else
  echo "== 构建成功，但验收没过，见上面的 [FAIL] ==" >&2
fi
exit "$VERIFY_RC"
