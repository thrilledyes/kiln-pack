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

# 框架只接受配置文件路径时，把 CONFIG_MATERIALIZE 列的配置解密到内存盘，START_CMD 用
# ${KILN_CONFIG_DIR}/<相对路径> 引用。在启动器之前做，多进程读的是同一份；文件随容器一起消失。
if [ -n "${CONFIG_MATERIALIZE}" ]; then
  # shellcheck disable=SC2086
  KILN_CONFIG_DIR="$(python -m kiln_config materialize ${CONFIG_MATERIALIZE})"
  export KILN_CONFIG_DIR
  echo "[kiln] 配置已解密到内存盘: ${KILN_CONFIG_DIR}（作业期间能进容器的人可以读到明文）"
fi

# 训练命令（渲染自 pack.conf 的 START_CMD），例如: python -m trainer.train --steps 50
START_CMD="$(cat /app/.kiln/start_cmd.sh)"

# 启动器自己会拉起 python：去掉 START_CMD 开头的解释器（python、python3.11、/opt/conda/bin/python 等），
# 把剩下的「-m 模块 ...」或「脚本 ...」交给它。
strip_python() {
  printf '%s\n' "${START_CMD}" | sed -E 's#^[[:space:]]*(/[^[:space:]]*/)?python[0-9.]*[[:space:]]+##'
}

# 启动器由项目在 requirements 里安装，没装时给出明确报错。
require_launcher() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[kiln] LAUNCHER='${LAUNCHER}' 需要命令 $1，请把 $2 加进项目的 requirements。" >&2
    exit 2
  fi
}

# 启动命令都交给 sh -c，这样 START_CMD 里的引号和 ${KILN_CONFIG_DIR} 在各个启动器下行为一致。
case "${LAUNCHER}" in
  single)
    RUN_CMD="${START_CMD}"
    ;;
  torchrun)
    # 单机多卡用 --standalone 自带 rendezvous。
    require_launcher torchrun torch
    RUN_CMD="torchrun --standalone --nproc_per_node=${NPROC_PER_NODE} ${TORCHRUN_ARGS} $(strip_python)"
    ;;
  deepspeed)
    # deepspeed 用 --module 而不是 -m。它默认按 GPU 数起进程，没有 GPU 时要在 DEEPSPEED_ARGS 里给 --hostfile。
    require_launcher deepspeed deepspeed
    RUN_CMD="deepspeed --num_gpus=${NPROC_PER_NODE} ${DEEPSPEED_ARGS} $(strip_python | sed -E 's/^-m[[:space:]]+/--module /')"
    ;;
  accelerate)
    require_launcher accelerate accelerate
    RUN_CMD="accelerate launch --num_processes=${NPROC_PER_NODE} ${ACCELERATE_ARGS} $(strip_python)"
    ;;
  *)
    echo "[kiln] 未知 LAUNCHER='${LAUNCHER}'。支持: single | torchrun | deepspeed | accelerate。" >&2
    exit 2
    ;;
esac

echo "[kiln] 起训: ${RUN_CMD}"
# kiln_init 当 PID 1，被抢占或 docker stop 时作业才收得到 SIGTERM，有机会存 checkpoint。详见 kiln_init.py。
KILN_PY="$(command -v python || command -v python3 || true)"
if [ -z "${KILN_PY}" ]; then
  echo "[kiln] 找不到 python，无法转发停止信号，docker stop 时作业可能被强杀。" >&2
  exec /bin/sh -c "${RUN_CMD}"
fi
exec "${KILN_PY}" -I -S /app/.kiln/kiln_init.py /bin/sh -c "${RUN_CMD}"
