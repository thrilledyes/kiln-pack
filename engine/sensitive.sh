# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
# 敏感文件规则：打包时默认不进构建上下文，验收时在镜像里发现就判失败。两边共用这一份。
# 确实要随镜像发出的文件（比如公开的 CA 证书）写进 pack.conf 的 PACK_KEEP。

KILN_SENSITIVE_NAMES=(
  '*.env' '.env.*' '.envrc'
  '*.pem' '*.key' '*.p12' '*.pfx' '*.jks' '*.keystore'
  'id_rsa' 'id_dsa' 'id_ecdsa' 'id_ed25519'
  '.netrc' '.pypirc' '.npmrc' '.git-credentials'
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
