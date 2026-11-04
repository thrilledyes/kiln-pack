#!/bin/sh
# 统一启动入口。真正的起服命令写死在镜像里（build 时注入），
# 这样 docker run 不需要带命令，运维侧只管 up/down/日志。
set -eu
echo "[kiln] app=${KILN_APP} version=${KILN_VERSION} build_id=${KILN_BUILD_ID} built_at=${KILN_BUILT_AT}"

# 校验运行必需的环境变量（敏感常量外置后，缺了就拒绝起服，避免用空值裸奔）。
REQ_LIST=/app/.kiln/required_env.list
if [ -f "$REQ_LIST" ]; then
  _missing=0
  while IFS= read -r _name; do
    [ -z "$_name" ] && continue
    if [ -z "$(printenv "$_name" 2>/dev/null)" ]; then
      echo "[kiln] 缺少必需环境变量: $_name" >&2
      _missing=1
    fi
  done < "$REQ_LIST"
  if [ "$_missing" = 1 ]; then
    echo "[kiln] 启动中止：请用 docker run -e 注入上述变量后重试。" >&2
    exit 1
  fi
fi

exec /bin/sh /app/.kiln/start_cmd.sh
