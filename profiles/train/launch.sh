#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# 训练作业统一启动入口（镜像内 /bin/sh 执行）。
# 真正的训练命令写死在镜像里（build 时由 START_CMD 渲染进 .kiln/start_cmd.sh），
# docker run 不需要带命令；运维侧只管挂数据/产物卷、注入 env、看退出码。
set -eu

# 启动器等运行期配置（pack.sh 写入）
. /app/.kiln/profile.conf

echo "[kiln] app=${KILN_APP} version=${KILN_VERSION} build_id=${KILN_BUILD_ID} built_at=${KILN_BUILT_AT}"
echo "[kiln] profile=train launcher=${LAUNCHER} nproc=${NPROC_PER_NODE} output=${OUTPUT_DIR} config_encrypt=${CONFIG_ENCRYPT}"

# 校验运行必需的环境变量（敏感常量外置后，缺了就拒绝起训，避免用空值裸跑浪费算力）。
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
    echo "[kiln] 起训中止：请用 docker run -e 注入上述变量后重试。" >&2
    exit 1
  fi
fi

# 产物目录必须可写（checkpoint/日志往这里落）。挂宿主卷时属主要对得上容器内用户，
# 否则非 root 写不进——这里只做明确报错，不强行 chown（非 root 无权改挂载卷属主）。
mkdir -p "${OUTPUT_DIR}" 2>/dev/null || true
if [ ! -w "${OUTPUT_DIR}" ]; then
  echo "[kiln] 产物目录不可写: ${OUTPUT_DIR}" >&2
  echo "[kiln] 挂卷时请确保属主可被容器内用户(uid 10001)写入，例如先 chmod 777 宿主目录，或用具名卷。" >&2
  exit 1
fi

# 训练命令（渲染自 pack.conf 的 START_CMD），例如: python -m trainer.train --steps 50
START_CMD="$(cat /app/.kiln/start_cmd.sh)"

case "${LAUNCHER}" in
  single)
    echo "[kiln] 起训: ${START_CMD}"
    exec /bin/sh -c "${START_CMD}"
    ;;
  torchrun)
    # torchrun 本身就是启动器，内部会拉起 python；去掉 START_CMD 开头的 python/python3，
    # 把剩下的「-m 模块 ...」或「脚本 ...」交给它。单机多卡用 --standalone 自带 rendezvous。
    CMD_BODY="$(printf '%s\n' "${START_CMD}" | sed -E 's/^[[:space:]]*python3?[[:space:]]+//')"
    echo "[kiln] 起训: torchrun --standalone --nproc_per_node=${NPROC_PER_NODE} ${TORCHRUN_ARGS} ${CMD_BODY}"
    # shellcheck disable=SC2086
    exec torchrun --standalone --nproc_per_node="${NPROC_PER_NODE}" ${TORCHRUN_ARGS} ${CMD_BODY}
    ;;
  deepspeed|accelerate)
    echo "[kiln] LAUNCHER='${LAUNCHER}' 在 v1 尚未实装（预留）。当前支持: single | torchrun。" >&2
    exit 2
    ;;
  *)
    echo "[kiln] 未知 LAUNCHER='${LAUNCHER}'。支持: single | torchrun（deepspeed/accelerate 预留）。" >&2
    exit 2
    ;;
esac
