# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
# 两个 profile 的验收脚本共用的检查。调用方要先定义 ok / bad。

# 检查镜像元数据有没有来源痕迹。只查本次构建写入的内容：底座自带的 label 和构建历史
# 不是这个项目留下的，框架的官方底座大多带着 github.com，查它们只会误报。
# Dockerfile 在 runtime 阶段开头打了 kiln.runtime.begin 标记，构建历史里它之后的都是本次写入的；
# ENV 和 LABEL 也都记在历史里，所以不用再看 docker inspect。
kiln_check_origin() {
  local tag="$1" markers="$2" history own pat marker
  pat='github\.com'
  for marker in $markers; do pat="${pat}|${marker}"; done
  history="$(docker history --no-trunc --format '{{.CreatedBy}}' "$tag")"
  if own="$(printf '%s\n' "$history" | awk '/kiln\.runtime\.begin/ { found = 1 } !found { print } END { exit found ? 0 : 3 }')"; then
    echo "  [i] 只查本次构建写入的内容，底座自带的不算。"
  else
    echo "  [WARN] 镜像里没有构建起点标记（请用新版引擎重新打包），只能查全部历史，底座的内容可能造成误报。"
    own="$history"
  fi
  if printf '%s\n%s\n' "$tag" "$own" | grep -qiE "$pat"; then
    bad "元数据里有来源痕迹（匹配 /${pat}/）"
  else
    ok "元数据无来源痕迹"
  fi
}
