#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# 真实 GPU 环境的端到端验收：真实卡、真实模型、真实框架。CPU 上的验收见 tests/acceptance.sh。
# 用法:
#   KILN_GPU_BASE=<带 CUDA torch 的底座> KILN_GPU_MODEL=<模型目录> KILN_GPU_IDS=2,3 \
#     bash tests/acceptance_gpu.sh [场景名...]
# 必填:
#   KILN_GPU_BASE     运行底座，要有 CUDA 版 torch、accelerate、transformers、fastapi、uvicorn
#   KILN_GPU_MODEL    宿主机上的模型目录，只读挂载，单卡放得下（比如 7B 量级）
# 可选:
#   KILN_GPU_BUILDER  builder 底座，默认和运行底座相同；离线环境要预装 Cython
#   KILN_GPU_IDS      用哪两张卡，默认 0,1。卡上有别的进程时拒绝开始
#   KILN_GPU_SGLANG_BASE  装好 SGLang 的运行底座，设了才跑 sglang 场景
#   KILN_GPU_SGLANG_BUILDER  SGLang 的 builder 底座，默认和运行底座相同，要预装 Cython
# 镜像都以 kiln-gpuacc- 开头，跑完自动清掉。需要 lora 场景时底座要有 llamafactory-cli。
set -uo pipefail

: "${KILN_GPU_BASE:?要设置 KILN_GPU_BASE}"
: "${KILN_GPU_MODEL:?要设置 KILN_GPU_MODEL}"
BUILDER="${KILN_GPU_BUILDER:-$KILN_GPU_BASE}"
IDS="${KILN_GPU_IDS:-0,1}"
GPU_ONE="${IDS%%,*}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
LOG="${WORK}/out.log"
KILN_CONFIG_KEY="$(openssl rand -base64 32)"
export KILN_CONFIG_KEY
PASSED=0
FAILED=0
SCENARIO=""
PACK_RC=0
# 模型目录的属主，容器用它运行才读得到权限严的目录。
MODEL_UID="$(stat -c %u "$KILN_GPU_MODEL")"
MODEL_GID="$(stat -c %g "$KILN_GPU_MODEL")"

cleanup() {
  local images
  docker ps -aq --filter 'name=^kiln-gpuacc-' | xargs -r docker rm -fv >/dev/null 2>&1
  images="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^kiln-gpuacc-')"
  if [[ -n "$images" ]]; then
    printf '%s\n' "$images" | xargs docker rmi -f >/dev/null 2>&1
  fi
  docker rmi kiln-config-tool:local >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT
# 被中途结束时也要清理：bash 收到信号默认直接退出，不走 EXIT。
trap 'exit 143' TERM INT

passed() { PASSED=$((PASSED + 1)); echo "  [符合预期] $*"; }
failed() {
  FAILED=$((FAILED + 1))
  echo "  [不符合预期] ${SCENARIO}: $*"
  grep -E '\[FAIL\]|!!|ERROR|Traceback|Error:' "$LOG" 2>/dev/null | cut -c1-220 | tail -8 | sed 's/^/      /'
}
check_rc() { if [[ "$PACK_RC" -eq "$1" ]]; then passed "退出码 $1"; else failed "退出码是 ${PACK_RC}，期望 $1"; fi; }
check_log() { if grep -qF -e "$1" "$LOG"; then passed "日志有: $1"; else failed "日志里没有: $1"; fi; }
check_nolog() { if grep -qF -e "$1" "$LOG"; then failed "日志里不该有: $1"; else passed "日志没有: $1"; fi; }

pack() {
  echo "    打包 $1"
  bash "${ROOT}/engine/pack.sh" "${WORK}/$1" > "$LOG" 2>&1
  PACK_RC=$?
  grep -E 'loss first|开始训练|\[svc\]|等了' "$LOG" | cut -c1-150 | sed 's/^/    /'
}

common_conf() {
  cat <<EOF
APP_NAME="kiln-gpuacc-$1"
VERSION="1.0.0"
RUNTIME_BASE="${KILN_GPU_BASE}"
BUILDER_BASE="${BUILDER}"
SRC_DIR="."
PIP_REQUIREMENTS=""
SECRET_MARKER="KILN_GPU_SECRET_b71e"
REQUIRED_ENV="KILN_SECRET_MARKER"
VERIFY_ENV="KILN_SECRET_MARKER=KILN_GPU_SECRET_b71e"
EOF
}

simple_recipe() {
  cat > "$1/proj/recipe.py" <<'PY'
import torch


def build_model():
    return torch.nn.Sequential(torch.nn.Linear(16, 64), torch.nn.ReLU(), torch.nn.Linear(64, 1))


def batch(step, device):
    g = torch.Generator().manual_seed(step)
    x = torch.randn(64, 16, generator=g).to(device)
    return x, x.sum(dim=1, keepdim=True)
PY
}

# ---------- 训练：多卡 ----------
scenario_torchrun_two_gpus() {
  local p="${WORK}/ddp"
  cp -R "${ROOT}/tests/demo-train" "$p"
  perl -pi -e 's/init_process_group\(backend="gloo"\)/init_process_group(backend="nccl")/; s/device = torch\.device\("cpu"\)/local = int(os.environ.get("LOCAL_RANK", "0")); torch.cuda.set_device(local); device = torch.device("cuda", local)/; s/DistributedDataParallel\(model\)/DistributedDataParallel(model, device_ids=[local])/; s/device=\{device\}", flush=True\)/device={device} card={torch.cuda.get_device_name(local)}", flush=True)/' "${p}/trainer/train.py"
  common_conf ddp >> "${p}/pack.conf"
  cat >> "${p}/pack.conf" <<EOF
LAUNCHER="torchrun"
NPROC_PER_NODE="2"
VERIFY_LOG_CONTAINS="world_size=2"
VERIFY_DOCKER_ARGS='--gpus "device=${IDS}"'
EOF
  pack ddp
  check_rc 0
  check_log 'device=cuda'
  check_log '所有镜像层里无配置明文'
  check_log 'docker stop 后作业正常退出'
}

scenario_accelerator_two_gpus() {
  local p="${WORK}/accel"
  mkdir -p "${p}/proj"; : > "${p}/proj/__init__.py"
  simple_recipe "$p"
  cat > "${p}/proj/train.py" <<'PY'
import os

import torch
from accelerate import Accelerator

from proj import recipe


def main():
    acc = Accelerator()
    model = recipe.build_model()
    opt = torch.optim.Adam(model.parameters(), lr=1e-2)
    model, opt = acc.prepare(model, opt)
    acc.print(f"[train] 开始训练 world_size={acc.num_processes} device={acc.device} mixed={acc.mixed_precision}")
    for step in range(1, 51):
        x, y = recipe.batch(step, acc.device)
        loss = torch.nn.functional.mse_loss(model(x), y)
        opt.zero_grad()
        acc.backward(loss)
        opt.step()
        acc.print(f"[train] step={step} loss={loss.item():.6f}")
    acc.wait_for_everyone()
    acc.save(acc.unwrap_model(model).state_dict(), os.path.join(os.environ["KILN_OUTPUT_DIR"], "ckpt.pt"))


if __name__ == "__main__":
    main()
PY
  { printf 'PROFILE="train"\n'; common_conf accel; cat <<EOF
PROTECT_GLOBS="proj/recipe.py"
LAUNCHER="accelerate"
NPROC_PER_NODE="2"
ACCELERATE_ARGS="--multi_gpu --mixed_precision=fp16"
VERIFY_LOG_CONTAINS="world_size=2"
START_CMD="python -m proj.train"
VERIFY_DOCKER_ARGS='--gpus "device=${IDS}"'
EOF
  } > "${p}/pack.conf"
  pack accel
  check_rc 0
  check_log 'mixed=fp16'
  check_log 'device=cuda'
}

# ---------- 推理：真实模型 + 受保护的 FastAPI 路由 ----------
write_model_service() {
  local p="$1"
  mkdir -p "${p}/app"; : > "${p}/app/__init__.py"
  cat > "${p}/app/logic.py" <<'PY'
import torch


def generate(model, tok, prompt, max_new_tokens):
    ids = tok(prompt, return_tensors="pt").to(model.device)
    with torch.no_grad():
        out = model.generate(**ids, max_new_tokens=max_new_tokens, do_sample=False)
    return tok.decode(out[0][ids["input_ids"].shape[1]:], skip_special_tokens=True)
PY
  cat > "${p}/app/routes.py" <<'PY'
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.logic import generate

router = APIRouter()
state = {}


class GenerateRequest(BaseModel):
    prompt: str
    max_new_tokens: int = 16


@router.get("/health")
def health():
    if "model" not in state:
        raise HTTPException(status_code=503, detail="loading")
    return {"status": "up"}


@router.post("/v1/generate")
def do_generate(req: GenerateRequest):
    text = generate(state["model"], state["tok"], req.prompt, req.max_new_tokens)
    return {"text": text, "device": str(state["model"].device)}
PY
  cat > "${p}/server.py" <<'PY'
import threading
import time

import torch
from fastapi import FastAPI
from transformers import AutoModelForCausalLM, AutoTokenizer

from app.routes import router, state

app = FastAPI()
app.include_router(router)


def load():
    start = time.time()
    tok = AutoTokenizer.from_pretrained("/models/m")
    model = AutoModelForCausalLM.from_pretrained("/models/m", dtype=torch.float16).to("cuda").eval()
    state.update(tok=tok, model=model)
    print(f"[svc] 模型加载完成 {time.time() - start:.1f} 秒 {torch.cuda.get_device_name(0)}", flush=True)


threading.Thread(target=load, daemon=True).start()
PY
  { printf 'PROFILE="serve"\n'; common_conf "$2"; cat <<EOF
PROTECT_GLOBS="app/logic.py app/routes.py"
START_CMD="python -m uvicorn server:app --host 0.0.0.0 --port 8000"
EXPOSE_PORT="8000"
HEALTH_START_PERIOD="10m"
VERIFY_TIMEOUT="300"
HEALTHCHECK_CMD="python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)\""
VERIFY_DOCKER_ARGS='--gpus "device=${GPU_ONE}" -v ${KILN_GPU_MODEL}:/models/m:ro'
VERIFY_CMD='
R="\$(curl -fsS --max-time 120 -X POST "\$VERIFY_BASE_URL/v1/generate" -H "content-type: application/json" -d "{\"prompt\":\"1+1=\",\"max_new_tokens\":12}")"
echo "generate: \$R"
grep -q cuda <<<"\$R"
'
EOF
  } > "${p}/pack.conf"
}

scenario_serve_real_model() {
  write_model_service "${WORK}/svc" svc
  printf 'RUNTIME_UID="%s"\nRUNTIME_GID="%s"\n' "$MODEL_UID" "$MODEL_GID" >> "${WORK}/svc/pack.conf"
  pack svc
  check_rc 0
  check_log '接口探针通过'
  check_log 'docker stop 后服务正常退出'
  check_log '无敏感文件'
}

scenario_serve_model_unreadable() {
  # 只在模型目录对 others 不可读时有意义：默认 uid 读不了，验收要失败，而且看得到真正的原因。
  if [[ "$(stat -c %A "$KILN_GPU_MODEL" | cut -c8-10)" != '---' ]]; then
    echo "    模型目录对 others 可读，跳过"
    return
  fi
  write_model_service "${WORK}/svc-noread" svc-noread
  printf 'VERIFY_TIMEOUT="40"\n' >> "${WORK}/svc-noread/pack.conf"
  pack svc-noread
  check_rc 1
  check_log 'Permission denied'
}

# ---------- 真实推理框架：SGLang（要设 KILN_GPU_SGLANG_BASE）----------
# 受保护模块调用 SGLang 的启动 API，入口留明文。SGLang 用 spawn 起子进程，子进程也要能加载 .so。
write_sglang_service() {
  local p="$1" name="$2" extra_args="$3" gpus="$4"
  mkdir -p "${p}/proj"; : > "${p}/proj/__init__.py"
  cat > "${p}/proj/launcher.py" <<'PY'
import sys

from sglang.srt.entrypoints.http_server import launch_server
from sglang.srt.server_args import prepare_server_args


def main():
    print("[proj] 受保护模块接管启动", flush=True)
    launch_server(prepare_server_args(sys.argv[1:]))
PY
  cat > "${p}/serve.py" <<'PY'
from proj.launcher import main

if __name__ == "__main__":
    main()
PY
  { printf 'PROFILE="serve"\n'; common_conf "$name"; cat <<EOF
RUNTIME_BASE="${KILN_GPU_SGLANG_BASE}"
BUILDER_BASE="${KILN_GPU_SGLANG_BUILDER:-$KILN_GPU_SGLANG_BASE}"
PROTECT_GLOBS="proj/launcher.py"
RUNTIME_UID="${MODEL_UID}"
RUNTIME_GID="${MODEL_GID}"
START_CMD="python serve.py --model-path /models/m --host 0.0.0.0 --port 8000 --mem-fraction-static 0.8 --disable-cuda-graph ${extra_args}"
EXPOSE_PORT="8000"
HEALTH_START_PERIOD="10m"
VERIFY_TIMEOUT="400"
VERIFY_STOP_TIMEOUT="60"
HEALTHCHECK_CMD="python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)\""
VERIFY_DOCKER_ARGS='--gpus "device=${gpus}" --shm-size=4g -v ${KILN_GPU_MODEL}:/models/m:ro'
VERIFY_CMD='
R="\$(curl -fsS --max-time 600 -X POST "\$VERIFY_BASE_URL/v1/chat/completions" -H "content-type: application/json" -d "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"1+1=\"}],\"max_tokens\":16,\"temperature\":0}")"
echo "chat: \$R" | cut -c1-300
grep -q "\"content\"" <<<"\$R"
docker logs "\$VERIFY_CONTAINER" 2>&1 | grep -F "[proj] 受保护模块接管启动"
'
EOF
  } > "${p}/pack.conf"
}

scenario_sglang_one_gpu() {
  write_sglang_service "${WORK}/sg1" sg1 "" "$GPU_ONE"
  pack sg1
  check_rc 0
  check_log '接口探针通过'
  check_log 'docker stop 后服务正常退出'
  check_log '无明文: proj/launcher.py'
  grep -E 'chat:|健康检查通过' "$LOG" | cut -c1-200 | sed 's/^/    /'
}

scenario_sglang_two_gpus() {
  write_sglang_service "${WORK}/sg2" sg2 "--tp-size 2" "$IDS"
  pack sg2
  check_rc 0
  check_log '接口探针通过'
  check_log 'docker stop 后服务正常退出'
  grep -E 'chat:|健康检查通过' "$LOG" | cut -c1-200 | sed 's/^/    /'
}

# ---------- 真实框架：只认配置路径、loss 带引号、短任务验收 ----------
scenario_llamafactory_config_path() {
  local p="${WORK}/lora"
  mkdir -p "${p}/proj" "${p}/configs"; : > "${p}/proj/__init__.py"
  cat > "${p}/proj/prepare.py" <<'PY'
import json
import os


def main():
    os.makedirs("/tmp/kiln-data", exist_ok=True)
    rows = [{"instruction": f"计算 {i}+{i}", "input": "", "output": str(i + i)} for i in range(40)]
    with open("/tmp/kiln-data/demo.json", "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False)
    with open("/tmp/kiln-data/dataset_info.json", "w", encoding="utf-8") as f:
        json.dump({"kiln_demo": {"file_name": "demo.json"}}, f)
PY
  for name in full smoke; do
    cat > "${p}/configs/${name}.yaml" <<YAML
# CONFIG_SECRET_LORA_77ab
model_name_or_path: /models/m
stage: sft
do_train: true
finetuning_type: lora
lora_target: all
dataset: kiln_demo
dataset_dir: /tmp/kiln-data
template: qwen
output_dir: /workspace/output/lora
overwrite_output_dir: true
per_device_train_batch_size: 2
max_steps: $([[ "$name" == full ]] && echo 100000 || echo 30)
learning_rate: 0.001
logging_steps: 1
save_strategy: "no"
fp16: true
report_to: none
YAML
  done
  { printf 'PROFILE="train"\n'; common_conf lora; cat <<EOF
PROTECT_GLOBS="proj/prepare.py"
RUNTIME_UID="${MODEL_UID}"
RUNTIME_GID="${MODEL_GID}"
OUTPUT_DIR="/workspace/output"
CKPT_GLOB="lora/adapter_model.safetensors"
LOSS_TAG="'loss': "
START_CMD='python -c "from proj.prepare import main; main()" && llamafactory-cli train \${KILN_CONFIG_DIR}/configs/full.yaml'
VERIFY_START_CMD='python -c "from proj.prepare import main; main()" && llamafactory-cli train \${KILN_CONFIG_DIR}/configs/smoke.yaml'
CONFIG_ENCRYPT="on"
CONFIG_GLOBS="configs/*.yaml"
CONFIG_MATERIALIZE="configs/full.yaml configs/smoke.yaml"
CONFIG_MARKER="CONFIG_SECRET_LORA_77ab"
VERIFY_DOCKER_ARGS='--gpus "device=${GPU_ONE}" -v ${KILN_GPU_MODEL}:/models/m:ro'
VERIFY_STOP_TIMEOUT="60"
EOF
  } > "${p}/pack.conf"
  pack lora
  check_rc 0
  check_log 'HF_DATASETS_CACHE='
  check_log '错误密钥时解密失败'
  check_log 'docker stop 后作业正常退出'
  check_log 'lora/adapter_model.safetensors'
  check_log '所有镜像层里无配置明文'
  check_nolog '开头的 loss'
}

ALL_SCENARIOS="
torchrun_two_gpus accelerator_two_gpus serve_real_model serve_model_unreadable llamafactory_config_path
"
if [[ -n "${KILN_GPU_SGLANG_BASE:-}" ]]; then
  ALL_SCENARIOS="${ALL_SCENARIOS} sglang_one_gpu sglang_two_gpus"
fi

BUSY="$(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits | awk -F', *' -v ids=",${IDS}," 'index(ids, "," $1 ",") && $2 > 100 { print $1 }')"
if [[ -n "$BUSY" ]]; then
  echo "这些卡上有别的进程在用，不开始: $(echo "$BUSY" | tr '\n' ' ')"
  exit 3
fi

for SCENARIO in ${*:-$ALL_SCENARIOS}; do
  echo
  echo "######## ${SCENARIO}"
  STARTED="$(date +%s)"
  "scenario_${SCENARIO}"
  echo "    耗时 $(( $(date +%s) - STARTED )) 秒"
done

echo
echo "符合预期 ${PASSED} 项，不符合预期 ${FAILED} 项"
[[ "$FAILED" -eq 0 ]]
