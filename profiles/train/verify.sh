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

# 产物挂载目录、作业日志和镜像层解包目录都是临时文件，脚本中途失败也要清掉（踩过：日志漏在 $TMPDIR）。
HOST_OUT=""; RUN_LOG=""; SCAN_DIR=""
cleanup() { rm -rf "${HOST_OUT:-/nonexistent-kiln}" "${RUN_LOG:-/nonexistent-kiln}" "${SCAN_DIR:-/nonexistent-kiln}"; }
trap cleanup EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

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
# 配置密钥只按名字传给 docker，不写进命令行。
KEY_ARGS=()
[ "${CONFIG_ENCRYPT:-off}" = on ] && KEY_ARGS=(-e KILN_CONFIG_KEY)
# 产物挂载到宿主临时目录；非 root 容器（uid 10001）要能写，放开 others 写位。
HOST_OUT="$(mktemp -d)"; chmod 777 "$HOST_OUT"
echo "    产物挂载: $HOST_OUT -> $OUTPUT_DIR"
RUN_LOG="$(mktemp)"
docker run --rm ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} -v "$HOST_OUT:$OUTPUT_DIR" "$TAG" 2>&1 | tee "$RUN_LOG"
RC="${PIPESTATUS[0]}"
echo "    作业退出码: $RC"
if [ "$RC" -eq 0 ]; then ok "训练作业正常退出（码 0）"; else bad "训练作业异常退出（码 ${RC}）"; fi
# 可选：日志里必须出现的内容。比如 world_size=2，防止启动器悄悄退回单进程，作业照样跑通、验收照样过。
if [[ -n "${VERIFY_LOG_CONTAINS:-}" ]]; then
  if grep -qF -e "$VERIFY_LOG_CONTAINS" "$RUN_LOG"; then ok "日志里有 ${VERIFY_LOG_CONTAINS}"; else bad "日志里没有 ${VERIFY_LOG_CONTAINS}"; fi
fi

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

echo "== 6. 配置加密：无明文 + 能解密 + 没密钥起不了训 + 逐层扫描无泄漏 =="
if [ "${CONFIG_ENCRYPT:-off}" != on ]; then
  echo "  [i] CONFIG_ENCRYPT=off，配置按明文随镜像发出，跳过。"
elif [ -z "$(printenv KILN_CONFIG_KEY 2>/dev/null)" ]; then
  bad "CONFIG_ENCRYPT=on 但没有 export KILN_CONFIG_KEY，无法验收"
else
  CONFIG_LIST="$(docker run --rm --entrypoint /bin/sh "$TAG" -c 'cat /app/.kiln/config.list 2>/dev/null')"
  [ -n "$CONFIG_LIST" ] || bad "镜像里没有 /app/.kiln/config.list"
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    if echo "$LISTING" | grep -qxF "/app/${rel}"; then bad "配置明文仍在: /app/${rel}"; else ok "无配置明文: ${rel}"; fi
    if echo "$LISTING" | grep -qxF "/app/${rel}.enc"; then ok "有密文: ${rel}.enc"; else bad "缺密文: ${rel}.enc"; fi
    # 解出来的内容必须和打包机上的明文一字不差。
    GOT_SHA="$(docker run --rm -e KILN_CONFIG_KEY --entrypoint python "$TAG" -c \
      'import hashlib,sys,kiln_config; sys.stdout.write(hashlib.sha256(kiln_config.load(sys.argv[1])).hexdigest())' "$rel" 2>&1)"
    if [ "$GOT_SHA" = "$(sha256_of "${PROJECT_DIR}/${SRC_DIR:-.}/${rel}")" ]; then
      ok "解密结果与明文一致: ${rel}"
    else
      bad "解密结果与明文不一致: ${rel}（${GOT_SHA}）"
    fi
  done <<KILN_CONFIG_EOF
$CONFIG_LIST
KILN_CONFIG_EOF

  # 缺密钥：launch.sh 应在起训前拒绝。
  NOKEY_LOG="$(docker run --rm ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} "$TAG" 2>&1)"; NOKEY_RC=$?
  if [ "$NOKEY_RC" -ne 0 ] && echo "$NOKEY_LOG" | grep -qF '缺少必需环境变量: KILN_CONFIG_KEY'; then
    ok "没有密钥时拒绝起训（码 ${NOKEY_RC}）"
  else
    bad "没有密钥时没有被拒绝（码 ${NOKEY_RC}）"
  fi
  # 错密钥：作业必须解密失败。如果还能跑通，说明作业根本没读加密配置。
  WRONG_KEY="$(head -c 32 /dev/urandom | base64)"
  WRONG_LOG="$(docker run --rm ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} -e "KILN_CONFIG_KEY=${WRONG_KEY}" "$TAG" 2>&1)"; WRONG_RC=$?
  if [ "$WRONG_RC" -ne 0 ] && echo "$WRONG_LOG" | grep -qF '解密失败'; then
    ok "错误密钥时解密失败，作业中止（码 ${WRONG_RC}）"
  elif [ "$WRONG_RC" -eq 0 ]; then
    bad "错误密钥时作业仍然跑通：START_CMD 没有读取加密配置"
  else
    bad "错误密钥时作业失败了，但不是解密失败（码 ${WRONG_RC}）"
  fi

  # 明文特征和密钥不能出现在元数据、作业日志和产物里。密钥不进命令行，用 printenv 喂给 grep。
  if grep -qF -f <(printenv KILN_CONFIG_KEY) <<<"$META"; then bad "镜像元数据里有配置密钥"; else ok "镜像元数据里无配置密钥"; fi
  if [ -n "${CONFIG_MARKER:-}" ]; then
    if grep -qF -e "$CONFIG_MARKER" <<<"$META"; then bad "镜像元数据里有配置明文"; else ok "镜像元数据里无配置明文"; fi
    if grep -qaF -e "$CONFIG_MARKER" "$RUN_LOG"; then bad "作业日志里有配置明文"; else ok "作业日志里无配置明文"; fi
    if grep -rlaF -e "$CONFIG_MARKER" "$HOST_OUT" >/dev/null 2>&1; then bad "产物目录里有配置明文"; else ok "产物目录里无配置明文"; fi
  else
    echo "  [WARN] 没设 CONFIG_MARKER，下面的扫描只查密钥，查不了配置明文。"
  fi

  # 逐层扫描 docker save 的全部内容：被后续层删掉的文件，/app 里看不到，但层里还在。
  # 密文和助手脚本里都有 KILNCFG1，它当控制样本：扫不到它就说明解压或搜索没生效，不能算通过。
  SCAN_DIR="$(mktemp -d)"
  FOUND="${SCAN_DIR}/.found"
  : > "$FOUND"
  SCAN_FAILED=0
  if docker save "$TAG" | tar -xf - -C "$SCAN_DIR"; then
    while IFS= read -r blob; do
      case "$(od -An -tx1 -N4 "$blob" | tr -d ' \n')" in
        1f8b*) DECODE=(gzip -dc) ;;
        28b52ffd)
          if ! command -v zstd >/dev/null 2>&1; then SCAN_FAILED=1; continue; fi
          DECODE=(zstd -dc)
          ;;
        *) DECODE=(cat) ;;
      esac
      # grep -a -o 把命中写进 FOUND，只在本目录内比对，不打印。LC_ALL=C 防止非 UTF-8 字节让 grep 提前放弃。
      "${DECODE[@]}" "$blob" 2>/dev/null \
        | LC_ALL=C grep -a -o -F -f <(printenv KILN_CONFIG_KEY; echo KILNCFG1; [ -z "${CONFIG_MARKER:-}" ] || printf '%s\n' "$CONFIG_MARKER") \
        >> "$FOUND"
    done < <(find "$SCAN_DIR" -type f ! -name '.found')
  else
    SCAN_FAILED=1
  fi
  if [ "$SCAN_FAILED" -ne 0 ]; then
    bad "镜像层扫描没做完（docker save 失败，或层是 zstd 压缩而本机没有 zstd）"
  elif ! grep -qx KILNCFG1 "$FOUND"; then
    bad "控制样本 KILNCFG1 没被扫到，扫描本身不可信"
  else
    ok "控制样本扫到了，镜像层扫描有效"
    if grep -qxF -f <(printenv KILN_CONFIG_KEY) "$FOUND"; then bad "镜像层里有配置密钥"; else ok "所有镜像层里无配置密钥"; fi
    if [ -n "${CONFIG_MARKER:-}" ]; then
      if grep -qxF -e "$CONFIG_MARKER" "$FOUND"; then bad "镜像层里有配置明文"; else ok "所有镜像层里无配置明文"; fi
    fi
  fi
  rm -rf "$SCAN_DIR"; SCAN_DIR=""
fi

echo "== 7. 运维入口 + 容器内 cat 不到源码 =="
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
