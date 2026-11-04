#!/usr/bin/env bash
# kiln-pack 验收：确认镜像“源码看不见 + 服务正常 + 可运维”三件事同时成立。
# 用法: verify.sh <项目目录>
# 本脚本只认 pack.conf，不含任何具体项目/demo 的硬编码——受保护文件、来源痕迹
# 都从 pack.conf 推导（PROTECT_GLOBS / ORIGIN_MARKERS）。
set -uo pipefail

PROJECT_DIR="$(cd "${1:?用法: verify.sh <项目目录>}" && pwd)"
# shellcheck disable=SC1090
source "$PROJECT_DIR/pack.conf"
TAG="${APP_NAME}:${VERSION}"
CNAME="kiln-verify-$$"
PORT="${VERIFY_HOST_PORT:-18000}"
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

echo "== 2. 受保护的 .py 不在镜像里 =="
for g in $PROTECT_GLOBS; do
  base="${g%.py}"
  if echo "$LISTING" | grep -qx "/app/${base}.py"; then bad "明文仍在: /app/${base}.py"; else ok "无明文: ${base}.py"; fi
  if echo "$LISTING" | grep -q "^/app/${base}\..*\.so$"; then ok "有编译产物: ${base}*.so"; else bad "缺编译产物: ${base}*.so"; fi
done
if echo "$LISTING" | grep -qE '\.(c|pyx)$'; then bad "镜像里有 .c/.pyx 中间产物"; else ok "无 .c/.pyx 中间产物"; fi
if echo "$LISTING" | grep -q 'pack.conf'; then bad "镜像里有 pack.conf"; else ok "无 pack.conf"; fi

echo "== 3. 整个文件系统扫描机密标记 =="
EXPORT_DIR="$(mktemp -d)"
docker create --name "$CNAME-x" "$TAG" >/dev/null
docker export "$CNAME-x" | tar -x -C "$EXPORT_DIR" 2>/dev/null
docker rm -f "$CNAME-x" >/dev/null
HITS="$(grep -rIl --exclude-dir=proc --exclude-dir=sys -e "$SECRET_MARKER" "$EXPORT_DIR" 2>/dev/null | head)"
if [ -n "$HITS" ]; then bad "文本文件里发现标记:"; echo "$HITS" | sed 's/^/    /'; else ok "文本文件无标记"; fi
BHITS="$(grep -rl --exclude-dir=proc --exclude-dir=sys -a -e "$SECRET_MARKER" "$EXPORT_DIR/app" 2>/dev/null | head)"
if [ -n "$BHITS" ]; then
  echo "  [WARN] 二进制里仍能 strings 出该值，说明还有硬编码未外置（见教程“密钥外置”）:"; echo "$BHITS" | sed 's/^/    /'
else ok "静态交付物（镜像/归档）中无此敏感值——已外置为运行时注入"; fi
echo "  [i] 边界：服务运行后该值会驻留进程内存，dump /proc/<pid>/mem 仍可取回；env 外置只保证不随镜像发出。"
if find "$EXPORT_DIR" -name '.git' -maxdepth 4 | grep -q .; then bad "镜像里有 .git"; else ok "无 .git"; fi

echo "== 4. 镜像元数据不含来源痕迹 =="
META="$(docker inspect "$TAG"; docker history --no-trunc "$TAG")"
ORIGIN_PAT='github\.com'
for m in $ORIGIN_MARKERS; do ORIGIN_PAT="${ORIGIN_PAT}|${m}"; done
if echo "$META" | grep -qiE "$ORIGIN_PAT"; then bad "元数据里有来源痕迹（匹配 /$ORIGIN_PAT/）"; else ok "元数据无来源痕迹"; fi

echo "== 5. 起服 + 健康检查 + 接口 =="
# 敏感 env 由验收侧注入（真实部署由运维提供，不随镜像发出）；缺了 launch.sh 会拒绝起服。
ENV_ARGS=()
for kv in ${VERIFY_ENV:-}; do ENV_ARGS+=(-e "$kv"); done
docker run -d --name "$CNAME" ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} -p "$PORT:${EXPOSE_PORT:-8000}" "$TAG" >/dev/null
for i in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 1
done
if curl -fsS "http://127.0.0.1:$PORT/healthz" | grep -q ok; then ok "/healthz 正常"; else bad "/healthz 不通"; docker logs "$CNAME" | tail -20; fi
V="$(curl -fsS "http://127.0.0.1:$PORT/version" 2>/dev/null)"; echo "    version: $V"
echo "$V" | grep -q "\"version\":\"$VERSION\"" && ok "版本指纹正确" || bad "版本指纹不对"
R="$(curl -fsS -X POST "http://127.0.0.1:$PORT/infer" -H 'content-type: application/json' -d '{"prompt":"hello world"}' 2>/dev/null)"
echo "    infer: $R"
echo "$R" | grep -q '"score"' && ok "/infer 走通受保护逻辑" || bad "/infer 失败"

echo "== 6. 运维入口 =="
docker logs "$CNAME" 2>&1 | tail -3 | sed 's/^/    log: /'
sleep 1
ST="$(docker inspect -f '{{.State.Health.Status}}' "$CNAME" 2>/dev/null || echo none)"; echo "    health: $ST"
# 取 PROTECT_GLOBS 的第一个受保护文件做“容器内 cat 不到明文”探针——不写死具体文件名。
FIRST_PROT="$(echo $PROTECT_GLOBS | awk '{print $1}')"
if [ -n "$FIRST_PROT" ]; then
  if docker exec "$CNAME" /bin/sh -c "cat /app/${FIRST_PROT}" >/dev/null 2>&1; then
    bad "容器内 cat 到了源码: /app/${FIRST_PROT}"
  else
    ok "容器内 cat 源码失败（符合预期）: /app/${FIRST_PROT}"
  fi
fi

echo
[ "$FAIL" -eq 0 ] && echo "验收通过" || { echo "验收失败"; exit 1; }
