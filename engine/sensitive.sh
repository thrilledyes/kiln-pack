# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
# 敏感文件规则：打包时默认不进构建上下文，验收时在镜像里发现就判失败。两边共用这一份。
# 确实要随镜像发出的文件（比如公开的 CA 证书）写进 pack.conf 的 PACK_KEEP。

KILN_SENSITIVE_NAMES=(
  '*.env' '.env.*' '.envrc'
  '*.pem' '*.key' '*.p12' '*.pfx' '*.jks' '*.keystore'
  'id_rsa' 'id_dsa' 'id_ecdsa' 'id_ed25519'
  '.netrc' '.pypirc' '.npmrc' 'pip.conf' '.git-credentials'
  'credentials.json' 'service-account*.json'
)
KILN_SENSITIVE_DIRS=('.ssh' '.aws' '.gnupg')

# 给 rsync 用的排除参数和给 find 用的匹配条件，都由上面两张表生成。
KILN_SENSITIVE_RSYNC_ARGS=()
KILN_SENSITIVE_FIND_ARGS=()
for _kiln_item in "${KILN_SENSITIVE_NAMES[@]}"; do
  KILN_SENSITIVE_RSYNC_ARGS+=("--exclude=${_kiln_item}")
  KILN_SENSITIVE_FIND_ARGS+=(-name "${_kiln_item}" -o)
done
for _kiln_item in "${KILN_SENSITIVE_DIRS[@]}"; do
  KILN_SENSITIVE_RSYNC_ARGS+=("--exclude=${_kiln_item}" "--exclude=${_kiln_item}/***")
  KILN_SENSITIVE_FIND_ARGS+=(-path "*/${_kiln_item}/*" -o)
done
unset '_kiln_item'
# 去掉末尾多余的 -o（bash 3.2 不支持负下标）。
unset "KILN_SENSITIVE_FIND_ARGS[$(( ${#KILN_SENSITIVE_FIND_ARGS[@]} - 1 ))]"

kiln_sensitive_in_dir() {
  local rel="$1" dir
  for dir in "${KILN_SENSITIVE_DIRS[@]}"; do
    case "/${rel}" in
      */"${dir}"/*) return 0 ;;
      *) ;;
    esac
  done
  return 1
}

# 相对路径命中敏感规则时返回 0。.enc 是加密后的配置，不算。
kiln_sensitive_match() {
  local rel="$1" name pat
  name="${rel##*/}"
  case "$name" in
    *.enc) return 1 ;;
    *) ;;
  esac
  for pat in "${KILN_SENSITIVE_NAMES[@]}"; do
    # shellcheck disable=SC2254
    case "$name" in
      $pat) return 0 ;;
      *) ;;
    esac
  done
  kiln_sensitive_in_dir "$rel"
}

# 从 find /app 的文件清单里挑出命中规则、又没写进 PACK_KEEP 的文件，每行一个。
kiln_sensitive_in_listing() {
  local listing="$1" keep path rel
  keep=" $(printf '%s' "$2" | tr '\n\t' '  ') "
  while IFS= read -r path; do
    rel="${path#/app/}"
    [[ -n "$rel" ]] || continue
    kiln_sensitive_match "$rel" || continue
    case "$keep" in
      *" ${rel} "*) continue ;;
      *) ;;
    esac
    printf '%s\n' "$path"
  done <<<"$listing"
}

# 从标准输入读文本，打印带账号密码或令牌的地址所在的行号。只给行号，不把凭据打印出来。
# 不算凭据的：ssh://git@host 这种只有用户名的；${VAR} 占位符，它们在文本里没有真实的值。
kiln_lines_with_url_credentials() {
  grep -nE '[a-zA-Z][a-zA-Z0-9+.-]*://[^/@:[:space:]]+:[^/@[:space:]]+@|https?://[^/@[:space:]]+@' \
    | grep -vE '^[0-9]+:[^@]*://\$\{[^}]+\}(:\$\{[^}]+\})?@' \
    | cut -d: -f1
}

# 打印 requirements 及其 -r / -c 引用的文件里带凭据的位置（路径:行号）。这些文件都会随镜像发出。
KILN_REQ_SEEN=""
kiln_requirements_credentials() {
  local file="$1" dir line ref number
  [[ -f "$file" ]] || return 0
  # 用规范化的绝对路径判重：requirements 可能经 ../ 互相引用，直接拼路径会越拼越长，死循环。
  dir="$(cd "$(dirname "$file")" && pwd)"
  file="${dir}/$(basename "$file")"
  case "${KILN_REQ_SEEN}" in
    *"|${file}|"*) return 0 ;;
    *) ;;
  esac
  KILN_REQ_SEEN="${KILN_REQ_SEEN}|${file}|"
  while IFS= read -r number; do
    printf '%s:%s\n' "${file#"${PWD}/"}" "$number"
  done < <(kiln_lines_with_url_credentials < "$file" || true)
  while IFS= read -r line; do
    ref="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*(-r|-c|--requirement|--constraint)[=[:space:]]+//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//')"
    case "$ref" in
      *://*) ;;
      /*) kiln_requirements_credentials "$ref" ;;
      *) kiln_requirements_credentials "${dir}/${ref}" ;;
    esac
  done < <(grep -E '^[[:space:]]*(-r|-c|--requirement|--constraint)[=[:space:]]' "$file" || true)
}
