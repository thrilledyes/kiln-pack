#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# kiln-pack 训练作业验收：确认镜像“源码看不见 + 能正常训 + 产物可取 + 可运维”同时成立。
# 用法: verify.sh <项目目录>
# 与 serve 版的差异集中在“怎么证明它能跑”：serve 起常驻服务打接口，train 跑一个
# 短冒烟作业，断言「正常退出 + 落下 checkpoint + loss 有限且下降」。源码保护检查两边一致。
# 本脚本只认 pack.conf，不含任何具体项目/demo 的硬编码。
set -uo pipefail

PROJECT_DIR="$(cd "${1:?用法: verify.sh <项目目录>}" && pwd)"
# shellcheck disable=SC1090
source "$PROJECT_DIR/pack.conf"
TAG="${APP_NAME}:${VERSION}"
ORIGIN_MARKERS="${ORIGIN_MARKERS:-}"
# 训练验收相关项（可在 pack.conf 覆盖）
OUTPUT_DIR="${OUTPUT_DIR:-/workspace/output}"   # 容器内产物目录
CKPT_GLOB="${CKPT_GLOB:-*.pt}"                   # 验收期望落下的 checkpoint（相对 OUTPUT_DIR）
LOSS_TAG="${LOSS_TAG:-loss=}"                    # 训练日志里 loss 的前缀标记，供解析下降趋势
FAIL=0

ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }

HOST_OUT=""; EXPORT_DIR=""
cleanup() { [ -n "$HOST_OUT" ] && rm -rf "$HOST_OUT"; [ -n "$EXPORT_DIR" ] && rm -rf "$EXPORT_DIR"; }
trap cleanup EXIT

echo "== 1. 镜像里的文件 =="
LISTING="$(docker run --rm --entrypoint /bin/sh "$TAG" -c 'find /app -type f | sort')"
echo "$LISTING" | sed 's/^/    /'

echo "== 2. 受保护的 .py 不在镜像里（清单取自打包阶段写入的 .kiln/protected.list）=="
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

echo "== 3. 应用层扫描机密标记 =="
# 聚焦 /app（受保护代码、.so、.kiln、产物）：机密只可能从项目代码/交付物泄漏，
# 训练底座的框架库（torch 等，常达数 GB）不含项目机密，整镜像 export 扫描既慢又无意义。
APP_FILES="$(docker run --rm --entrypoint /bin/sh "$TAG" -c 'tar -cf - -C / app 2>/dev/null' | tar -tf - 2>/dev/null | wc -l | tr -d ' ')"
echo "    /app 文件数: ${APP_FILES}"
if [ -n "${SECRET_MARKER:-}" ]; then
  HITS="$(docker run --rm --entrypoint /bin/sh "$TAG" -c "grep -rIl -e '$SECRET_MARKER' /app 2>/dev/null" || true)"
  if [ -n "$HITS" ]; then bad "文本文件里发现标记:"; echo "$HITS" | sed 's/^/    /'; else ok "/app 文本文件无标记"; fi
  BHITS="$(docker run --rm --entrypoint /bin/sh "$TAG" -c "grep -rl -a -e '$SECRET_MARKER' /app 2>/dev/null" || true)"
  if [ -n "$BHITS" ]; then
    echo "  [WARN] 二进制里仍能 strings 出该值，说明还有硬编码未外置（见教程“密钥外置”）:"; echo "$BHITS" | sed 's/^/    /'
  else ok "静态交付物中无此敏感值——已外置为运行时注入"; fi
  echo "  [i] 边界：作业运行后该值会驻留进程内存，dump /proc/<pid>/mem 仍可取回；env 外置只保证不随镜像发出。"
else
  echo "  [i] 未设 SECRET_MARKER，跳过机密扫描。"
fi
if echo "$LISTING" | grep -q '/app/.git'; then bad "镜像里有 .git"; else ok "无 .git"; fi

echo "== 4. 镜像元数据不含来源痕迹 =="
META="$(docker inspect "$TAG"; docker history --no-trunc "$TAG")"
ORIGIN_PAT='github\.com'
for m in $ORIGIN_MARKERS; do ORIGIN_PAT="${ORIGIN_PAT}|${m}"; done
if echo "$META" | grep -qiE "$ORIGIN_PAT"; then bad "元数据里有来源痕迹（匹配 /$ORIGIN_PAT/）"; else ok "元数据无来源痕迹"; fi

echo "== 5. 冒烟训练：正常退出 + 落下 checkpoint + loss 有限且下降 =="
# 敏感 env 由验收侧注入（真实部署由运维提供，不随镜像发出）；缺了 launch.sh 会拒绝起训。
ENV_ARGS=()
for kv in ${VERIFY_ENV:-}; do ENV_ARGS+=(-e "$kv"); done
# 产物挂载到宿主临时目录；非 root 容器（uid 10001）要能写，放开 others 写位。
HOST_OUT="$(mktemp -d)"; chmod 777 "$HOST_OUT"
echo "    产物挂载: $HOST_OUT -> $OUTPUT_DIR"
RUN_LOG="$(mktemp)"
set +e
docker run --rm ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} -v "$HOST_OUT:$OUTPUT_DIR" "$TAG" 2>&1 | tee "$RUN_LOG"
RC="${PIPESTATUS[0]}"
set -e
echo "    作业退出码: $RC"
if [ "$RC" -eq 0 ]; then ok "训练作业正常退出（码 0）"; else bad "训练作业异常退出（码 $RC）"; fi

# checkpoint 是否落盘
CKPTS="$(cd "$HOST_OUT" 2>/dev/null && ls -1 $CKPT_GLOB 2>/dev/null)"
if [ -n "$CKPTS" ]; then ok "产物目录落下 checkpoint: $(echo "$CKPTS" | tr '\n' ' ')"; else bad "产物目录没有匹配 '$CKPT_GLOB' 的 checkpoint"; fi

# loss 趋势：抓日志里所有 loss=数值，判首末有限且不升
LOSSES="$(grep -oE "${LOSS_TAG}[-+0-9.eEnafiNAFI]+" "$RUN_LOG" | sed "s/${LOSS_TAG}//" )"
if [ -n "$LOSSES" ]; then
  FIRST_L="$(echo "$LOSSES" | head -n1)"; LAST_L="$(echo "$LOSSES" | tail -n1)"
  echo "    loss first=${FIRST_L} last=${LAST_L}"
  # 变量一律用 ${} 包：避免后面紧贴多字节字符时被某些 bash 吞进变量名（踩过）。
  awk -v a="${FIRST_L}" -v b="${LAST_L}" 'BEGIN{
    if (b+0!=b+0 || b=="inf" || b=="-inf" || b=="nan") exit 2;   # 非有限
    if (b+0 <= a+0) exit 0; else exit 3;                          # 不升为通过
  }'
  case $? in
    0) ok "loss 有限且不升: ${FIRST_L} -> ${LAST_L}";;
    2) bad "末尾 loss 非有限(nan/inf)，训练发散";;
    *) bad "loss 未下降: ${FIRST_L} -> ${LAST_L}";;
  esac
else
  bad "日志里没抓到 '${LOSS_TAG}' 开头的 loss，无法判断收敛（demo 需按此格式打印）"
fi

echo "== 6. 运维入口 + 容器内 cat 不到源码 =="
tail -n 3 "$RUN_LOG" | sed 's/^/    log: /'
rm -f "$RUN_LOG"
# 批作业跑完即退出，用一次性 run 验证“容器内 cat 受保护源码失败”。
FIRST_PROT="$(echo "$PROT_LIST" | head -n1)"
if [ -n "$FIRST_PROT" ]; then
  if docker run --rm --entrypoint /bin/sh "$TAG" -c "cat /app/${FIRST_PROT}" >/dev/null 2>&1; then
    bad "容器内 cat 到了源码: /app/${FIRST_PROT}"
  else
    ok "容器内 cat 源码失败（符合预期）: /app/${FIRST_PROT}"
  fi
fi

echo
[ "$FAIL" -eq 0 ] && echo "验收通过" || { echo "验收失败"; exit 1; }
