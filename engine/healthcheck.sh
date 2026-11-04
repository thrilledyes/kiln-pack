#!/bin/sh
# 实际的检查命令由 pack.sh 渲染进 .kiln/health_cmd.sh，这里只是统一入口。
set -eu
exec /bin/sh /app/.kiln/health_cmd.sh
