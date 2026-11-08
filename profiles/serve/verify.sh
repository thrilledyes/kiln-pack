#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# kiln-pack 验收：确认镜像“源码看不见 + 服务正常 + 可运维”三件事同时成立。
# 用法: verify.sh <项目目录>
# 本脚本只认 pack.conf，不含任何具体项目/demo 的硬编码——受保护文件、来源痕迹、
# 健康检查和接口探针都从 pack.conf 推导（PROTECT_GLOBS / ORIGIN_MARKERS / HEALTHCHECK_CMD / VERIFY_CMD）。
set -uo pipefail

PROJECT_DIR="$(cd "${1:?用法: verify.sh <项目目录>}" && pwd)"
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../engine" && pwd)/sensitive.sh"
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../engine" && pwd)/verify_lib.sh"
# shellcheck disable=SC1090
source "$PROJECT_DIR/pack.conf"
TAG="${APP_NAME}:${VERSION}"
CNAME="kiln-verify-$$"
PORT="${VERIFY_HOST_PORT:-18000}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-60}"            # 等服务变健康的秒数，要加载模型的服务调大
VERIFY_STOP_TIMEOUT="${VERIFY_STOP_TIMEOUT:-30}"  # docker stop 后等服务退出的秒数
# 可选：除内置的 github.com 外，额外视为“来源痕迹”的标记（如自家 GitHub 账号/仓库名），
# 空格分隔，按正则交替匹配。项目特有，放在 pack.conf 里，不写死进引擎。
ORIGIN_MARKERS="${ORIGIN_MARKERS:-}"
FAIL=0

ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }

cleanup() { docker rm -f "$CNAME" >/dev/null 2>&1 || true; rm -rf "${EXPORT_DIR:-/nonexistent-kiln}"; }
trap cleanup EXIT

echo "== 1. 镜像里的文件 =="
LISTING="$(docker run --rm --entrypoint /bin/sh "$TAG" -c 'find /app -type f | sort')"
echo "$LISTING" | sed 's/^/    /'

echo "== 2. 受保护的 .py 不在镜像里（清单取自打包阶段写入的 .kiln/protected.list）=="
# 不再在验收端自行解释 PROTECT_GLOBS：改用 compile_protect.py 实际编译后记录的
# 受保护清单，两边口径一致，支持任意 glob / 子目录。
PROT_LIST="$(docker run --rm --entrypoint /bin/sh "$TAG" -c 'cat /app/.kiln/protected.list 2>/dev/null')"
if [ -z "$PROT_LIST" ]; then
  bad "镜像里没有 /app/.kiln/protected.list（请用新版引擎重新打包）"
else
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    base="${rel%.py}"
    if echo "$LISTING" | grep -qx "/app/${rel}"; then bad "明文仍在: /app/${rel}"; else ok "无明文: ${rel}"; fi
    if echo "$LISTING" | grep -qE "^/app/${base}\..*\.so$"; then ok "有编译产物: ${base}*.so"; else bad "缺编译产物: ${base}*.so"; fi
  done <<KILN_PROT_EOF
$PROT_LIST
KILN_PROT_EOF
fi
if echo "$LISTING" | grep -qE '\.(c|pyx)$'; then bad "镜像里有 .c/.pyx 中间产物"; else ok "无 .c/.pyx 中间产物"; fi
if echo "$LISTING" | grep -q 'pack.conf'; then bad "镜像里有 pack.conf"; else ok "无 pack.conf"; fi
SENSITIVE_HITS="$(kiln_sensitive_in_listing "$LISTING" "${PACK_KEEP:-}")"
if [[ -n "$SENSITIVE_HITS" ]]; then bad "镜像里有敏感文件（确实要带上就写进 PACK_KEEP）:"; echo "$SENSITIVE_HITS" | sed 's/^/    /'; else ok "无敏感文件"; fi

echo "== 3. 整个文件系统扫描机密标记 =="
EXPORT_DIR="$(mktemp -d)"
docker create --name "$CNAME-x" "$TAG" >/dev/null
docker export "$CNAME-x" | tar -x -C "$EXPORT_DIR" 2>/dev/null
EXPORT_RC="${PIPESTATUS[0]}"
docker rm -f "$CNAME-x" >/dev/null
# tar 可能因为设备文件报错，不能看它的退出码。launch.sh 里的固定字符串当控制样本：
# 同样的搜索扫不到它，就说明内容没解出来，后面的「无标记」不可信。
SCAN_OK=0
if [[ "$EXPORT_RC" -ne 0 ]]; then
  bad "docker export 失败（码 ${EXPORT_RC}），无法扫描"
elif ! grep -rIl --exclude-dir=proc --exclude-dir=sys -e '\[kiln\] app=' "$EXPORT_DIR/app" 2>/dev/null | grep -q .; then
  bad "控制样本没扫到，扫描本身不可信"
else
  ok "控制样本扫到了，文件系统扫描有效"
  SCAN_OK=1
fi
if [[ -z "${SECRET_MARKER:-}" ]]; then
  echo "  [WARN] 没设 SECRET_MARKER，跳过机密标记扫描，这一项没有验证过。"
elif [[ "$SCAN_OK" -eq 1 ]]; then
  HITS="$(grep -rIl --exclude-dir=proc --exclude-dir=sys -e "$SECRET_MARKER" "$EXPORT_DIR" 2>/dev/null | head)"
  if [ -n "$HITS" ]; then bad "文本文件里发现标记:"; echo "$HITS" | sed 's/^/    /'; else ok "文本文件无标记"; fi
  BHITS="$(grep -rl --exclude-dir=proc --exclude-dir=sys -a -e "$SECRET_MARKER" "$EXPORT_DIR/app" 2>/dev/null | head)"
  if [ -n "$BHITS" ]; then
    echo "  [WARN] 二进制里仍能 strings 出该值，说明还有硬编码未外置（见教程“密钥外置”）:"; echo "$BHITS" | sed 's/^/    /'
  else ok "静态交付物（镜像/归档）中无此敏感值——已外置为运行时注入"; fi
  echo "  [i] 边界：服务运行后该值会驻留进程内存，dump /proc/<pid>/mem 仍可取回；env 外置只保证不随镜像发出。"
fi
# 只查 /app：底座里框架自带的 .git（比如 clone 下来的依赖）不是这个项目的。
if find "$EXPORT_DIR/app" -name '.git' | grep -q .; then bad "镜像里有 .git"; else ok "无 .git"; fi

echo "== 4. 镜像元数据不含来源痕迹 =="
kiln_check_origin "$TAG" "$ORIGIN_MARKERS"

echo "== 5. 起服 + 健康检查 + 接口探针 =="
# 敏感 env 由验收侧注入（真实部署由运维提供，不随镜像发出）；缺了 launch.sh 会拒绝起服。
ENV_ARGS=()
for kv in ${VERIFY_ENV:-}; do ENV_ARGS+=(-e "$kv"); done
# VERIFY_DOCKER_ARGS：验收时多传给 docker run 的参数，比如 --gpus、模型目录的 -v。
# shellcheck disable=SC2086
docker run -d --name "$CNAME" ${VERIFY_DOCKER_ARGS:-} ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} -p "$PORT:${EXPOSE_PORT:-8000}" "$TAG" >/dev/null
# 每个框架的接口都不一样，这里不写死端点：健康检查用项目的 HEALTHCHECK_CMD（和镜像里的 HEALTHCHECK 同一条，
# 在容器内执行），接口探针用项目的 VERIFY_CMD（在打包机上执行）。
if [[ "${HEALTHCHECK_CMD:-true}" == true ]]; then
  echo "  [WARN] 没设 HEALTHCHECK_CMD，判断不了服务有没有真正起来。"
fi
HEALTHY=0
SECONDS=0
while [[ "$SECONDS" -lt "$VERIFY_TIMEOUT" ]]; do
  if [[ "$(docker inspect -f '{{.State.Running}}' "$CNAME" 2>/dev/null)" != true ]]; then
    break
  fi
  if docker exec "$CNAME" /bin/sh /app/.kiln/healthcheck.sh >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  sleep 1
done
if [[ "$HEALTHY" -eq 1 ]]; then
  ok "健康检查通过（等了 ${SECONDS} 秒）"
elif [[ "$(docker inspect -f '{{.State.Running}}' "$CNAME" 2>/dev/null)" != true ]]; then
  bad "服务提前退出（码 $(docker inspect -f '{{.State.ExitCode}}' "$CNAME" 2>/dev/null)）"
  kiln_show_failure_log "$CNAME"
else
  bad "${VERIFY_TIMEOUT} 秒内健康检查没有通过（模型加载慢的服务可以调大 VERIFY_TIMEOUT）"
  kiln_show_failure_log "$CNAME"
fi
if [[ -z "${VERIFY_CMD:-}" ]]; then
  echo "  [WARN] 没设 VERIFY_CMD，只确认了服务健康，没有验证接口和受保护逻辑。"
elif [[ "$HEALTHY" -eq 1 ]]; then
  VERIFY_OUT="$(VERIFY_BASE_URL="http://127.0.0.1:${PORT}" VERIFY_CONTAINER="$CNAME" VERSION="$VERSION" PROJECT_DIR="$PROJECT_DIR" \
    bash -euo pipefail -c "$VERIFY_CMD" 2>&1)"
  VERIFY_RC=$?
  if [[ -n "$VERIFY_OUT" ]]; then echo "$VERIFY_OUT" | sed 's/^/    /'; fi
  if [[ "$VERIFY_RC" -eq 0 ]]; then ok "接口探针通过"; else bad "接口探针失败（码 ${VERIFY_RC}）"; fi
fi

echo "== 6. 运维入口 =="
docker logs "$CNAME" 2>&1 | tail -3 | sed 's/^/    log: /'
sleep 1
ST="$(docker inspect -f '{{.State.Health.Status}}' "$CNAME" 2>/dev/null || echo none)"; echo "    health: $ST"
# 取受保护清单的第一个文件做“容器内 cat 不到明文”探针——清单即实际编译结果。
FIRST_PROT="$(echo "$PROT_LIST" | head -n1)"
if [ -n "$FIRST_PROT" ]; then
  if docker exec "$CNAME" /bin/sh -c "cat /app/${FIRST_PROT}" >/dev/null 2>&1; then
    bad "容器内 cat 到了源码: /app/${FIRST_PROT}"
  else
    ok "容器内 cat 源码失败（符合预期）: /app/${FIRST_PROT}"
  fi
fi

echo "== 7. 停止信号 =="
# 退出码 137 说明 SIGTERM 没起作用，服务是被 SIGKILL 杀掉的，来不及做收尾。
if [[ "$(docker inspect -f '{{.State.Running}}' "$CNAME" 2>/dev/null)" == true ]]; then
  docker stop -t "$VERIFY_STOP_TIMEOUT" "$CNAME" >/dev/null 2>&1
  STOP_RC="$(docker inspect -f '{{.State.ExitCode}}' "$CNAME" 2>/dev/null)"
  if [[ "$STOP_RC" == 137 ]]; then
    bad "docker stop 后服务被强杀（码 137）：没收到 SIGTERM，或 ${VERIFY_STOP_TIMEOUT} 秒内没退出（可调 VERIFY_STOP_TIMEOUT）"
  else
    ok "docker stop 后服务正常退出（码 ${STOP_RC}）"
  fi
else
  bad "服务已经不在运行，无法验证停止信号"
fi

echo
[ "$FAIL" -eq 0 ] && echo "验收通过" || { echo "验收失败"; exit 1; }
