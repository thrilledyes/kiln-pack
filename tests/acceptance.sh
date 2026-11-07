#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# kiln-pack 端到端验收：真的打镜像、起容器，覆盖「该通过的通过、该失败的失败」。
# 用法: bash tests/acceptance.sh [场景名...]     不带参数跑全部，场景名见文件末尾。
# 需要 Docker、rsync、perl、openssl。镜像都以 kiln-acc- 开头，跑完自动清掉；构建缓存留着。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
LOG="${WORK}/out.log"
KILN_CONFIG_KEY="$(openssl rand -base64 32)"
export KILN_CONFIG_KEY
PASSED=0
FAILED=0
SCENARIO=""
PACK_RC=0

cleanup() {
  local images
  docker ps -aq --filter 'name=^kiln-acc-' | xargs docker rm -fv >/dev/null 2>&1
  images="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^kiln-acc-')"
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
  grep -E '\[FAIL\]|!!|ERROR' "$LOG" 2>/dev/null | LC_ALL=C cut -c1-200 | tail -8 | sed 's/^/      /'
}
check_rc() { if [[ "$PACK_RC" -eq "$1" ]]; then passed "退出码 $1"; else failed "退出码是 ${PACK_RC}，期望 $1"; fi; }
check_log() { if grep -qF -e "$1" "$LOG"; then passed "日志有: $1"; else failed "日志里没有: $1"; fi; }
check_nolog() { if grep -qF -e "$1" "$LOG"; then failed "日志里不该有: $1"; else passed "日志没有: $1"; fi; }

# new_project <名字> <tests 下的模板>：复制模板，改成带 kiln-acc- 前缀的镜像名。
new_project() {
  local name="$1" template="$2"
  cp -R "${ROOT}/tests/${template}" "${WORK}/${name}"
  printf '\nAPP_NAME="kiln-acc-%s"\n' "$name" >> "${WORK}/${name}/pack.conf"
}

# new_service <名字>：不依赖 demo 接口约定的最小服务，接口是 /health 和 /v1/completions，只用标准库。
new_service() {
  local dir="${WORK}/$1"
  mkdir -p "${dir}/svc"
  : > "${dir}/svc/__init__.py"
  cat > "${dir}/svc/logic.py" <<'EOF'
def complete(prompt):
    return prompt[::-1]
EOF
  cat > "${dir}/server.py" <<'EOF'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

from svc.logic import complete


class Handler(BaseHTTPRequestHandler):
    def _send(self, body):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_GET(self):
        self._send({"status": "up"})

    def do_POST(self):
        self._send({"choices": [{"text": complete("abc")}]})


HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
EOF
  cat > "${dir}/pack.conf" <<EOF
PROFILE="serve"
APP_NAME="kiln-acc-$1"
VERSION="1.0.0"
RUNTIME_BASE="python:3.11-slim-bookworm"
BUILDER_BASE="python:3.11-slim-bookworm"
SRC_DIR="."
PROTECT_GLOBS="svc/logic.py"
START_CMD="python server.py"
EXPOSE_PORT="8000"
HEALTHCHECK_CMD="python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)\""
EOF
}

pack() {
  echo "    打包 $1"
  bash "${ROOT}/engine/pack.sh" "${WORK}/$1" > "$LOG" 2>&1
  PACK_RC=$?
}

# pack_with_key <密钥> <项目名>：用指定的密钥打包，空字符串表示没有密钥。
pack_with_key() {
  local saved="$KILN_CONFIG_KEY"
  KILN_CONFIG_KEY="$1"
  pack "$2"
  KILN_CONFIG_KEY="$saved"
}

# expect_rejected <描述> <期望的报错片段>：打包前就要拒绝，退出码 2，而且没有开始构建。
expect_rejected() {
  if [[ "$PACK_RC" -eq 2 ]] && grep -qF -e "$2" "$LOG" && ! grep -qF 'docker build（两阶段' "$LOG"; then
    passed "拒绝: $1"
  else
    failed "$1 没有被正确拒绝（码 ${PACK_RC}）"
  fi
}

# pin_hashes <requirements 路径>：换成带完整哈希的版本。网络慢时 torch 这串依赖可能很久，限时 15 分钟。
# 失败要明确报出来：拿空文件往下走，打包只会报不相干的错。
pin_hashes() {
  local file="$1" name="kiln-acc-pin-$$" guard rc
  ( sleep 900; docker rm -f "$name" ) >/dev/null 2>&1 &
  guard=$!
  docker run -i --rm --name "$name" python:3.11-slim-bookworm sh -c 'pip install -q --root-user-action=ignore pip-tools >/dev/null 2>&1; cat > /tmp/r.in; cd /tmp; pip-compile -q --generate-hashes --allow-unsafe --no-header --no-annotate --output-file=- r.in' \
    < "$file" > "${file}.new" 2> "${file}.err"
  rc=$?
  kill "$guard" 2>/dev/null
  if [[ "$rc" -ne 0 ]] || ! grep -q -- '--hash=' "${file}.new"; then
    failed "生成哈希失败（码 ${rc}）: $(tail -1 "${file}.err" | cut -c1-160)"
    return 1
  fi
  mv "${file}.new" "$file"
  rm -f "${file}.err"
}

# fetch_wheel <目录>：下载一个 wheel 到目录，模拟提前下载好的私有依赖。
fetch_wheel() {
  mkdir -p "$1"
  docker run --rm python:3.11-slim-bookworm sh -c 'pip download -q --no-deps -d /w six==1.16.0 >/dev/null 2>&1; tar -C /w -cf - .' | tar -xf - -C "$1"
}

verify() {
  bash "${ROOT}/profiles/$2/verify.sh" "${WORK}/$1" > "$LOG" 2>&1
  PACK_RC=$?
}

# ---------- serve：接口探针 ----------
scenario_serve_demo() {
  new_project serve-demo demo-fastapi
  pack serve-demo
  check_rc 0
  check_log '接口探针通过'
  check_log 'docker stop 后服务正常退出'
  check_log '控制样本扫到了'
}

scenario_serve_custom_api() {
  new_service serve-api
  cat >> "${WORK}/serve-api/pack.conf" <<'EOF'
SECRET_MARKER="ACC_MARKER_NOT_IN_IMAGE_91bd"
VERIFY_CMD='
R="$(curl -fsS --max-time 10 -X POST "$VERIFY_BASE_URL/v1/completions" -d "{}")"
echo "completion: $R"
grep -q cba <<<"$R"
'
EOF
  pack serve-api
  check_rc 0
  check_log '接口探针通过'
  check_log 'completion:'
  check_log '文本文件无标记'
  check_log 'docker stop 后服务正常退出'
}

scenario_serve_no_probe() {
  new_service serve-noprobe
  pack serve-noprobe
  check_rc 0
  check_log '没设 VERIFY_CMD'
}

scenario_serve_probe_fails() {
  new_service serve-probefail
  cat >> "${WORK}/serve-probefail/pack.conf" <<'EOF'
VERIFY_CMD='echo probe-ran; exit 3'
EOF
  pack serve-probefail
  check_rc 1
  check_log 'probe-ran'
  check_log '接口探针失败（码 3）'
}

scenario_serve_probe_pipe_fails() {
  # 管道前半段失败也要算失败，否则 curl 失败会被 grep 的结果盖住。
  new_service serve-pipefail
  cat >> "${WORK}/serve-pipefail/pack.conf" <<'EOF'
VERIFY_CMD='false | true'
EOF
  pack serve-pipefail
  check_rc 1
  check_log '接口探针失败'
}

scenario_serve_health_timeout() {
  new_service serve-unhealthy
  cat >> "${WORK}/serve-unhealthy/pack.conf" <<'EOF'
HEALTHCHECK_CMD="false"
VERIFY_TIMEOUT="3"
VERIFY_CMD='echo probe-should-not-run'
EOF
  pack serve-unhealthy
  check_rc 1
  check_log '3 秒内健康检查没有通过'
  check_nolog 'probe-should-not-run'
}

scenario_serve_exits_early() {
  new_service serve-early
  cat >> "${WORK}/serve-early/pack.conf" <<'EOF'
START_CMD='python -c "raise SystemExit(3)"'
EOF
  pack serve-early
  check_rc 1
  check_log '服务提前退出（码 3）'
}

# ---------- serve：扫描不能假通过 ----------
scenario_marker_unset() {
  new_service marker-unset
  pack marker-unset
  check_rc 0
  check_log '没设 SECRET_MARKER'
  check_nolog '文本文件无标记'
  check_nolog '文本文件里发现标记'
}

scenario_marker_empty() {
  new_service marker-empty
  printf 'SECRET_MARKER=""\n' >> "${WORK}/marker-empty/pack.conf"
  pack marker-empty
  check_rc 0
  check_log '没设 SECRET_MARKER'
  check_nolog '文本文件里发现标记'
}

scenario_marker_leak() {
  new_service marker-leak
  printf 'ACC_LEAKED_MARKER_55aa\n' > "${WORK}/marker-leak/notes.txt"
  printf 'SECRET_MARKER="ACC_LEAKED_MARKER_55aa"\n' >> "${WORK}/marker-leak/pack.conf"
  pack marker-leak
  check_rc 1
  check_log '文本文件里发现标记'
}

scenario_export_fails() {
  local shim real
  new_service export-fail
  printf 'SECRET_MARKER="ACC_MARKER_NOT_IN_IMAGE_91bd"\n' >> "${WORK}/export-fail/pack.conf"
  pack export-fail
  check_rc 0
  real="$(command -v docker)"
  shim="${WORK}/shim"
  mkdir -p "$shim"
  cat > "${shim}/docker" <<EOF
#!/bin/sh
if [ "\$1" = export ]; then exit 1; fi
exec "${real}" "\$@"
EOF
  chmod +x "${shim}/docker"
  PATH="${shim}:${PATH}" verify export-fail serve
  check_rc 1
  check_log 'docker export 失败'
  check_nolog '文本文件无标记'
}

# ---------- 敏感文件 ----------
scenario_sensitive_excluded() {
  local dir="${WORK}/sensitive" files
  new_service sensitive
  mkdir -p "${dir}/sub" "${dir}/certs" "${dir}/.aws" "${dir}/.ssh"
  for f in .env sub/.env prod.env tls.key sub/server.pem id_rsa .pypirc .aws/credentials .ssh/config certs/ca.pem certs/other.pem; do
    printf 'x\n' > "${dir}/${f}"
  done
  printf 'PACK_KEEP="certs/ca.pem"\n' >> "${dir}/pack.conf"
  pack sensitive
  check_rc 0
  check_log '敏感文件不会进镜像（确实要带上就写进 PACK_KEEP）: .env'
  check_log 'PACK_KEEP 放行，这个敏感文件会进镜像: certs/ca.pem'
  check_log '无敏感文件'
  files="$(docker run --rm --entrypoint /bin/sh kiln-acc-sensitive:1.0.0 -c 'find /app -type f | sort')"
  for f in .env sub/.env prod.env tls.key sub/server.pem id_rsa .pypirc .aws/credentials .ssh/config certs/other.pem; do
    if printf '%s\n' "$files" | grep -qxF "/app/${f}"; then failed "镜像里有 ${f}"; else passed "镜像里没有 ${f}"; fi
  done
  if printf '%s\n' "$files" | grep -qxF /app/certs/ca.pem; then passed "放行的 certs/ca.pem 在镜像里"; else failed "放行的 certs/ca.pem 不在镜像里"; fi

  # 排除规则漏了也要拦得住：往镜像里塞一个，验收必须判失败。
  printf 'FROM kiln-acc-sensitive:1.0.0\nUSER root\nRUN touch /app/.env\nUSER appuser\n' \
    | docker build -q -t kiln-acc-sensitive:1.0.0 - >/dev/null
  verify sensitive serve
  check_rc 1
  check_log '镜像里有敏感文件'
}

scenario_keep_rejected() {
  local bad
  new_service keep-bad
  mkdir -p "${WORK}/keep-bad/.aws"
  printf 'x\n' > "${WORK}/keep-bad/.aws/my.pem"
  for bad in no-such.pem server.py .aws/my.pem '*.pem' ../x.pem /etc/x.pem; do
    cp "${WORK}/keep-bad/pack.conf" "${WORK}/keep-bad/pack.conf.orig"
    printf 'PACK_KEEP="%s"\n' "$bad" >> "${WORK}/keep-bad/pack.conf"
    pack keep-bad
    if [[ "$PACK_RC" -eq 2 ]]; then passed "拒绝 PACK_KEEP=${bad}"; else failed "PACK_KEEP=${bad} 退出码 ${PACK_RC}，期望 2"; fi
    mv "${WORK}/keep-bad/pack.conf.orig" "${WORK}/keep-bad/pack.conf"
  done
}

scenario_train_sensitive() {
  new_project train-sensitive demo-train
  printf 'x\n' > "${WORK}/train-sensitive/.env"
  printf 'x\n' > "${WORK}/train-sensitive/tls.key"
  pack train-sensitive
  check_rc 0
  check_log '敏感文件不会进镜像（确实要带上就写进 PACK_KEEP）: .env'
  check_log '无敏感文件'
}

# ---------- train：回归和退出码 ----------
scenario_train_demo() {
  new_project train-demo demo-train
  pack train-demo
  check_rc 0
  check_log 'docker stop 后作业正常退出'
  check_log '所有镜像层里无配置明文'
}

scenario_train_exit_code() {
  new_project train-exit demo-train
  cat >> "${WORK}/train-exit/pack.conf" <<'EOF'
START_CMD='python -c "raise SystemExit(7)"'
EOF
  pack train-exit
  check_rc 1
  check_log '作业退出码: 7'
}

scenario_train_compound_cmd() {
  new_project train-compound demo-train
  cat >> "${WORK}/train-compound/pack.conf" <<'EOF'
START_CMD='export KILN_STEPS=30; python -m trainer.train'
EOF
  pack train-compound
  check_rc 0
  check_log 'steps=30'
}

# ---------- train：停止信号要到得了 worker ----------
# 给 demo 加一个 SIGTERM 处理函数和原地等待，模拟训练被抢占时存 checkpoint。
add_signal_hook() {
  local dir="${WORK}/$1"
  cat > "${dir}/trainer/sig_hook.py" <<'EOF'
import os
import signal
import time

got = []


def install():
    def on_term(*_):
        got.append(1)
        print(f"[sig] rank={os.environ.get('RANK', '0')} 收到 SIGTERM 第 {len(got)} 次", flush=True)

    signal.signal(signal.SIGTERM, on_term)


def hold():
    if not os.environ.get("KILN_HOLD"):
        return
    print(f"[sig] rank={os.environ.get('RANK', '0')} 等待信号", flush=True)
    while not got:
        time.sleep(0.2)
    time.sleep(3)
    print(f"[sig] rank={os.environ.get('RANK', '0')} checkpoint 已保存", flush=True)
EOF
  perl -0pi -e 's/def main\(\):\n/def main():\n    from trainer.sig_hook import hold, install\n    install()\n/; s/    if rank == 0:\n        ckpt_path/    hold()\n    if rank == 0:\n        ckpt_path/' "${dir}/trainer/train.py"
}

# stop_held_job <项目名> <worker 数>：作业等在原地，docker stop 后看每个 worker 是否收到信号并存完。
stop_held_job() {
  local name="kiln-acc-stop-$1" image="kiln-acc-$1:1.0.0" workers="$2" i rc saved
  docker run -d --name "$name" -e KILN_HOLD=1 -e KILN_CONFIG_KEY \
    -e KILN_SECRET_MARKER=TRAIN_SECRET_DO_NOT_LEAK_a1b2c3 "$image" >/dev/null
  for i in $(seq 1 90); do
    docker logs "$name" > "$LOG" 2>&1
    if [[ "$(grep -c '等待信号' "$LOG")" -ge "$workers" ]]; then break; fi
    sleep 1
  done
  docker stop -t 30 "$name" >/dev/null
  rc="$(docker inspect -f '{{.State.ExitCode}}' "$name")"
  docker logs "$name" > "$LOG" 2>&1
  docker rm -fv "$name" >/dev/null
  echo "    退出码 ${rc}"; grep '\[sig\]' "$LOG" | sed 's/^/    /'
  if [[ "$rc" != 137 ]]; then passed "没有被强杀（码 ${rc}）"; else failed "被强杀（码 137）"; fi
  # demo 自己也会打印「checkpoint 已保存」，所以只数 [sig] 这句。多进程的输出可能挤在一行，按匹配次数数，不按行数。
  saved="$(grep -oE '\[sig\] rank=[0-9]+ checkpoint 已保存' "$LOG" | wc -l | tr -d ' ')"
  if [[ "$saved" -eq "$workers" ]]; then
    passed "${workers} 个 worker 都收到信号并存完"
  else
    failed "存完的 worker 数是 ${saved}，期望 ${workers}"
  fi
}

scenario_signal_single() {
  new_project sig-single demo-train
  add_signal_hook sig-single
  pack sig-single
  check_rc 0
  stop_held_job sig-single 1
}

scenario_signal_torchrun() {
  new_project sig-torchrun demo-train
  add_signal_hook sig-torchrun
  cat >> "${WORK}/sig-torchrun/pack.conf" <<'EOF'
LAUNCHER="torchrun"
NPROC_PER_NODE="2"
VERIFY_LOG_CONTAINS="world_size=2"
EOF
  pack sig-torchrun
  check_rc 0
  stop_held_job sig-torchrun 2
}

# ---------- train：启动器回归（launch.sh 的启动方式改过，都要重新跑通） ----------
scenario_launcher_accelerate() {
  new_project launcher-accelerate demo-train
  printf 'accelerate\nnumpy\n' >> "${WORK}/launcher-accelerate/requirements.txt"
  cat >> "${WORK}/launcher-accelerate/pack.conf" <<'EOF'
LAUNCHER="accelerate"
NPROC_PER_NODE="2"
ACCELERATE_ARGS="--multi_gpu"
VERIFY_LOG_CONTAINS="world_size=2"
EOF
  pack launcher-accelerate
  check_rc 0
  check_log 'docker stop 后作业正常退出'
}

scenario_launcher_deepspeed() {
  new_project launcher-deepspeed demo-train
  printf 'deepspeed\nnumpy\n' >> "${WORK}/launcher-deepspeed/requirements.txt"
  printf 'localhost slots=2\n' > "${WORK}/launcher-deepspeed/hostfile"
  cat >> "${WORK}/launcher-deepspeed/pack.conf" <<'EOF'
LAUNCHER="deepspeed"
NPROC_PER_NODE="2"
DEEPSPEED_ARGS="--hostfile=hostfile --no_ssh_check --master_addr=127.0.0.1 --no_local_rank"
VERIFY_LOG_CONTAINS="world_size=2"
EOF
  pack launcher-deepspeed
  check_rc 0
  check_log 'docker stop 后作业正常退出'
}

scenario_config_materialize() {
  local dir="${WORK}/materialize"
  new_project materialize demo-train
  cat >> "${dir}/pack.conf" <<'EOF'
LAUNCHER="torchrun"
NPROC_PER_NODE="2"
VERIFY_LOG_CONTAINS="world_size=2"
CONFIG_MATERIALIZE="configs/recipe.yaml"
START_CMD='python -m trainer.train --steps 50 --config-path ${KILN_CONFIG_DIR}/configs/recipe.yaml'
EOF
  perl -pi -e 's/^(\s*)ap\.add_argument\("--config", default="configs\/recipe\.yaml"\)$/$1ap.add_argument("--config-path", required=True)/; s/^(\s*)cfg = load_yaml\(args\.config\)$/$1import yaml\n$1cfg = yaml.safe_load(open(args.config_path))/' "${dir}/trainer/train.py"
  pack materialize
  check_rc 0
  check_log '配置已解密到内存盘'
}

# ---------- train：配置加密的拒绝场景和假通过拦截 ----------
scenario_config_rejected() {
  new_project cfg-reject demo-train
  pack_with_key "" cfg-reject
  expect_rejected "没有密钥" '必须 export KILN_CONFIG_KEY'
  rm -rf "${WORK}/cfg-reject"

  local conf
  while IFS='|' read -r conf want; do
    new_project cfg-reject demo-train
    printf '%s\n' "$conf" >> "${WORK}/cfg-reject/pack.conf"
    pack cfg-reject
    expect_rejected "$conf" "$want"
    rm -rf "${WORK}/cfg-reject"
  done <<'EOF'
CONFIG_GLOBS=""|必须设置 CONFIG_GLOBS
CONFIG_GLOBS="nope/*.yaml"|没有匹配到文件
CONFIG_GLOBS="configs/**/*.yaml"|不支持 **
CONFIG_GLOBS="../x.yaml"|相对路径
CONFIG_ENCRYPT="maybe"|未知 CONFIG_ENCRYPT
CONFIG_MATERIALIZE="configs/none.yaml"|不在 CONFIG_GLOBS
EOF

  new_project cfg-serve demo-fastapi
  printf 'CONFIG_ENCRYPT="on"\nCONFIG_GLOBS="x"\n' >> "${WORK}/cfg-serve/pack.conf"
  pack cfg-serve
  expect_rejected "serve 不支持加密" '只支持 PROFILE=train'
}

scenario_config_bad_key() {
  new_project cfg-badkey demo-train
  pack_with_key 'not base64!!' cfg-badkey
  check_rc 1
  check_log '不是合法的 base64'
}

scenario_config_not_covered() {
  new_project cfg-leak demo-train
  printf 'CONFIG_GLOBS="configs/other.yaml"\n' >> "${WORK}/cfg-leak/pack.conf"
  printf 'a: 1\n' > "${WORK}/cfg-leak/configs/other.yaml"
  pack cfg-leak
  check_rc 1
  check_log '这些配置不在 CONFIG_GLOBS 里'
  check_log '镜像层里有配置明文'
}

scenario_job_leaks_config() {
  local train="${WORK}/job-leak/trainer/train.py"
  new_project job-leak demo-train
  perl -pi -e 's/^(\s*)cfg = load_yaml\(args\.config\)$/$1cfg = load_yaml(args.config)\n$1print("tag", cfg["recipe_tag"], flush=True)/' "$train"
  perl -pi -e 's/^(\s*)"steps": args\.steps,$/$1"steps": args.steps,\n$1"cfg": cfg,/' "$train"
  pack job-leak
  check_rc 1
  check_log '作业日志里有配置明文'
  check_log '产物目录里有配置明文'
}

scenario_job_ignores_config() {
  new_project job-ignore demo-train
  perl -pi -e 's/^(\s*)cfg = load_yaml\(args\.config\)$/$1cfg = {"model":{"dim":16,"hidden":64},"train":{"batch":64,"base_lr":0.1,"warmup_ratio":0.1},"loss":{"huber_delta":1.0}}/' "${WORK}/job-ignore/trainer/train.py"
  pack job-ignore
  check_rc 1
  check_log '错误密钥时作业仍然跑通'
}

scenario_encrypt_off() {
  local found
  new_project enc-off demo-train
  printf 'CONFIG_ENCRYPT="off"\n' >> "${WORK}/enc-off/pack.conf"
  pack_with_key "" enc-off
  check_rc 0
  found="$(docker run --rm --entrypoint python kiln-acc-enc-off:1.0.0 -c 'import importlib.util as u; print(u.find_spec("cryptography") is not None)')"
  if [[ "$found" == False ]]; then passed "关闭加密时镜像里没有 cryptography"; else failed "cryptography 已安装: ${found}"; fi
}

scenario_protected_imports_kiln_config() {
  local recipe="${WORK}/protected-cfg/trainer/recipe.py"
  new_project protected-cfg demo-train
  { echo 'import kiln_config'; cat "$recipe"; } > "${recipe}.new"
  mv "${recipe}.new" "$recipe"
  cat >> "${WORK}/protected-cfg/pack.conf" <<'EOF'
LAUNCHER="torchrun"
NPROC_PER_NODE="2"
VERIFY_LOG_CONTAINS="world_size=2"
EOF
  pack protected-cfg
  check_rc 0
}

# ---------- train：启动器的失败路径 ----------
scenario_accelerate_cpu_detected() {
  # accelerate --cpu 会忽略进程数，悄悄退回单进程，VERIFY_LOG_CONTAINS 要抓得到。
  new_project accel-cpu demo-train
  printf 'accelerate\nnumpy\n' >> "${WORK}/accel-cpu/requirements.txt"
  cat >> "${WORK}/accel-cpu/pack.conf" <<'EOF'
LAUNCHER="accelerate"
NPROC_PER_NODE="2"
ACCELERATE_ARGS="--cpu"
VERIFY_LOG_CONTAINS="world_size=2"
EOF
  pack accel-cpu
  check_rc 1
  check_log '日志里没有 world_size=2'
}

scenario_launcher_not_installed() {
  new_project launcher-missing demo-train
  printf 'LAUNCHER="deepspeed"\n' >> "${WORK}/launcher-missing/pack.conf"
  pack launcher-missing
  check_rc 1
  check_log '需要命令 deepspeed'
}

scenario_launcher_unknown() {
  new_project launcher-unknown demo-train
  printf 'LAUNCHER="mpirun"\n' >> "${WORK}/launcher-unknown/pack.conf"
  pack launcher-unknown
  check_rc 1
  check_log '未知 LAUNCHER'
  # 作业失败时验收要走完全部检查，不能中途退出。
  check_log '验收失败'
  check_nolog 'unbound variable'
}

scenario_start_cmd_interpreter_path() {
  local cmd
  for cmd in 'python3.11 -m trainer.train --steps 50' '/usr/local/bin/python -m trainer.train --steps 50'; do
    rm -rf "${WORK}/interp"
    new_project interp demo-train
    cat >> "${WORK}/interp/pack.conf" <<EOF
LAUNCHER="torchrun"
NPROC_PER_NODE="2"
VERIFY_LOG_CONTAINS="world_size=2"
START_CMD="${cmd}"
EOF
    pack interp
    check_rc 0
    check_log 'world_size=2'
  done
}

scenario_launcher_args_with_quotes() {
  new_project launcher-quotes demo-train
  cat >> "${WORK}/launcher-quotes/pack.conf" <<'EOF'
LAUNCHER="torchrun"
NPROC_PER_NODE="2"
TORCHRUN_ARGS="--master_port='29555'"
VERIFY_LOG_CONTAINS="world_size=2"
EOF
  pack launcher-quotes
  check_rc 0
  check_log "--master_port='29555'"
}

# ---------- 依赖安装 ----------
scenario_deps_cache_reuse() {
  new_project cache demo-train
  pack cache
  check_rc 0
  pack cache
  check_rc 0
  if grep -qF 'Downloading torch-' "$LOG"; then failed "什么都没改，又下载了 torch"; else passed "什么都没改时不下载 torch"; fi
  echo '# 只改一行代码注释' >> "${WORK}/cache/trainer/train.py"
  pack cache
  check_rc 0
  if grep -qF 'Downloading torch-' "$LOG"; then failed "只改代码，又下载了 torch"; else passed "只改代码时不下载 torch"; fi
}

scenario_deps_relative_requirements() {
  local dir="${WORK}/deps-rel"
  new_project deps-rel demo-train
  cp "${dir}/requirements.txt" "${dir}/base.txt"
  printf -- '-r base.txt\n' > "${dir}/requirements.txt"
  pack deps-rel
  check_rc 0
}

scenario_deps_in_base() {
  printf 'FROM python:3.11-slim-bookworm\nRUN pip install --no-cache-dir torch==2.5.1 pyyaml==6.0.2\n' \
    | docker build -q -t kiln-acc-torch-base:1 - >/dev/null
  new_project deps-base demo-train
  cat >> "${WORK}/deps-base/pack.conf" <<'EOF'
PIP_REQUIREMENTS=""
RUNTIME_BASE="kiln-acc-torch-base:1"
BUILDER_BASE="kiln-acc-torch-base:1"
EOF
  pack deps-base
  check_rc 0
}

scenario_pip_only_binary() {
  new_project pip-bin demo-train
  printf 'PIP_INSTALL_ARGS="--only-binary :all:"\n' >> "${WORK}/pip-bin/pack.conf"
  pack pip-bin
  check_rc 0
  check_log 'pip install --no-cache-dir --only-binary :all: -r'
}

scenario_pip_hashes_missing() {
  new_project pip-nohash demo-train
  printf 'PIP_INSTALL_ARGS="--require-hashes"\n' >> "${WORK}/pip-nohash/pack.conf"
  pack pip-nohash
  check_rc 1
  check_log 'Hashes are required'
}

scenario_pip_sdist_only() {
  new_project pip-sdist demo-train
  printf 'PIP_INSTALL_ARGS="--only-binary :all:"\n' >> "${WORK}/pip-sdist/pack.conf"
  printf 'pycrypto==2.6.1\n' >> "${WORK}/pip-sdist/requirements.txt"
  pack pip-sdist
  check_rc 1
  check_log 'No matching distribution'
}

scenario_pip_full_hashes() {
  new_project pip-hash-serve demo-fastapi
  printf 'PIP_INSTALL_ARGS="--require-hashes --only-binary :all:"\n' >> "${WORK}/pip-hash-serve/pack.conf"
  pin_hashes "${WORK}/pip-hash-serve/requirements.txt" || return
  pack pip-hash-serve
  check_rc 0
  # train 这边 torch 预装在底座里：这里要验证的是每个 pip 步骤都带上参数，现场解析 torch 的全部依赖要很久。
  printf 'FROM python:3.11-slim-bookworm\nRUN pip install --no-cache-dir torch==2.5.1 pyyaml==6.0.2\n' \
    | docker build -q -t kiln-acc-torch-base:1 - >/dev/null
  new_project pip-hash-train demo-train
  cat >> "${WORK}/pip-hash-train/pack.conf" <<'EOF'
PIP_INSTALL_ARGS="--require-hashes --only-binary :all:"
RUNTIME_BASE="kiln-acc-torch-base:1"
BUILDER_BASE="kiln-acc-torch-base:1"
EOF
  printf 'six==1.16.0\n' > "${WORK}/pip-hash-train/requirements.txt"
  pin_hashes "${WORK}/pip-hash-train/requirements.txt" || return
  pack pip-hash-train
  check_rc 0
  check_log 'pip install --no-cache-dir --require-hashes --only-binary :all: -r /tmp/kiln-requirements.txt'
  check_log 'pip install --no-cache-dir --require-hashes --only-binary :all: -r /app/requirements.txt'
}

scenario_pip_args_credentials() {
  new_service pip-cred
  printf 'PIP_INSTALL_ARGS="--index-url https://user:acc-secret-pw@pypi.example.com/simple"\n' >> "${WORK}/pip-cred/pack.conf"
  pack pip-cred
  expect_rejected "PIP_INSTALL_ARGS 带账号密码" '不能带账号密码'
  check_nolog 'acc-secret-pw'
}

scenario_requirements_credentials() {
  local dir="${WORK}/req-cred"
  new_service req-cred
  printf 'PIP_REQUIREMENTS="requirements.txt"\n' >> "${dir}/pack.conf"
  printf 'six==1.16.0\n--extra-index-url https://user:acc-secret-pw@pypi.example.com/simple\n' > "${dir}/requirements.txt"
  pack req-cred
  expect_rejected "requirements 带账号密码" 'requirements.txt:2'
  check_nolog 'acc-secret-pw'
  mkdir -p "${dir}/deps"
  printf -- '-r deps/base.txt\n' > "${dir}/requirements.txt"
  printf 'pkg @ git+https://x-access-token:acc-secret-pw@git.example.com/o/r.git\n' > "${dir}/deps/base.txt"
  pack req-cred
  expect_rejected "-r 引用的文件带令牌" 'deps/base.txt:1'
  check_nolog 'acc-secret-pw'
}

scenario_private_wheels() {
  local dir="${WORK}/wheels-serve" found
  new_service wheels-serve
  fetch_wheel "${dir}/wheels"
  printf 'PIP_REQUIREMENTS="requirements.txt"\n' >> "${dir}/pack.conf"
  printf -- '--no-index\n--find-links wheels\nsix==1.16.0\n' > "${dir}/requirements.txt"
  pack wheels-serve
  check_rc 0
  found="$(docker run --rm --entrypoint python kiln-acc-wheels-serve:1.0.0 -c 'import six; print(six.__version__)')"
  if [[ "$found" == 1.16.0 ]]; then passed "服务镜像里装上了提前下载的 wheel"; else failed "six 版本: ${found}"; fi

  dir="${WORK}/wheels-train"
  new_project wheels-train demo-train
  fetch_wheel "${dir}/wheels"
  printf -- '--find-links wheels\nsix==1.16.0\n' >> "${dir}/requirements.txt"
  pack wheels-train
  check_rc 0
  found="$(docker run --rm --entrypoint python kiln-acc-wheels-train:1.0.0 -c 'import six; print(six.__version__)')"
  if [[ "$found" == 1.16.0 ]]; then passed "训练镜像里装上了提前下载的 wheel"; else failed "six 版本: ${found}"; fi
}

# ---------- 来源痕迹：底座自带的不算，本次构建写入的要抓到 ----------
scenario_origin_base_ignored() {
  printf 'FROM python:3.11-slim-bookworm\nLABEL org.opencontainers.image.source=https://github.com/example/base\nRUN echo cloned https://github.com/example/base && mkdir -p /opt/framework/.git\nENV FRAMEWORK_URL=https://github.com/example/base\n' \
    | docker build -q -t kiln-acc-github-base:1 - >/dev/null
  new_service origin-serve
  cat >> "${WORK}/origin-serve/pack.conf" <<'EOF'
RUNTIME_BASE="kiln-acc-github-base:1"
BUILDER_BASE="kiln-acc-github-base:1"
EOF
  pack origin-serve
  check_rc 0
  check_log '元数据无来源痕迹'
  check_log '无 .git'

  printf 'FROM kiln-acc-github-base:1\nRUN pip install --no-cache-dir torch==2.5.1 pyyaml==6.0.2\n' \
    | docker build -q -t kiln-acc-github-torch:1 - >/dev/null
  new_project origin-train demo-train
  cat >> "${WORK}/origin-train/pack.conf" <<'EOF'
PIP_REQUIREMENTS=""
RUNTIME_BASE="kiln-acc-github-torch:1"
BUILDER_BASE="kiln-acc-github-torch:1"
EOF
  pack origin-train
  check_rc 0
  check_log '元数据无来源痕迹'
}

scenario_origin_own_detected() {
  new_service origin-own
  printf 'PIP_INSTALL_ARGS="--find-links https://github.com/example/wheels"\n' >> "${WORK}/origin-own/pack.conf"
  pack origin-own
  check_rc 1
  check_log '元数据里有来源痕迹'
}

scenario_origin_project_marker() {
  new_service origin-marker
  cat >> "${WORK}/origin-marker/pack.conf" <<'EOF'
PIP_INSTALL_ARGS="--find-links https://acc-private-org.example.com/wheels"
ORIGIN_MARKERS="acc-private-org"
EOF
  pack origin-marker
  check_rc 1
  check_log '元数据里有来源痕迹'
}

# ---------- serve：镜像元数据 ----------
scenario_serve_image_config() {
  local image=kiln-acc-serve-config:1.0.0
  new_service serve-config
  pack serve-config
  check_rc 0
  if [[ "$(docker inspect -f '{{.Config.Healthcheck.StartPeriod}}' "$image")" == 20s ]]; then passed "默认 start-period 是 20s"; else failed "默认 start-period 不对"; fi
  cat >> "${WORK}/serve-config/pack.conf" <<'EOF'
HEALTH_START_PERIOD="10m"
EOF
  pack serve-config
  check_rc 0
  if [[ "$(docker inspect -f '{{.Config.Healthcheck.StartPeriod}}' "$image")" == 10m0s ]]; then passed "HEALTH_START_PERIOD 生效"; else failed "HEALTH_START_PERIOD 没生效"; fi
  if [[ "$(docker inspect -f '{{json .Config.ExposedPorts}}' "$image")" == *'8000/tcp'* ]]; then passed "镜像 EXPOSE 了 8000"; else failed "镜像没有 EXPOSE 8000"; fi
}

scenario_serve_bad_values() {
  local conf
  while IFS='|' read -r conf want; do
    rm -rf "${WORK}/serve-badval"
    new_service serve-badval
    printf '%s\n' "$conf" >> "${WORK}/serve-badval/pack.conf"
    pack serve-badval
    expect_rejected "$conf" "$want"
  done <<'EOF'
EXPOSE_PORT="abc"|EXPOSE_PORT 必须是端口号
HEALTH_START_PERIOD="soon"|HEALTH_START_PERIOD 要写成
HEALTH_START_PERIOD="10m/;s/x/"|HEALTH_START_PERIOD 要写成
EOF
}

# ---------- 真实环境：非 root 底座、离线构建、权限和缓存 ----------
# 框架镜像常见的样子：自带编译器和 Cython，默认用户不是 root，缓存变量指向底座用户的目录。
build_framework_base() {
  docker build -q -t "$1" - >/dev/null <<'EOF'
FROM python:3.11-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev binutils && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir Cython
RUN useradd -u 1000 -m trainer && mkdir -p /workspace/runtime && chown trainer /workspace/runtime
ENV HF_DATASETS_CACHE=/opt/not-writable/datasets MODELSCOPE_CACHE=/opt/not-writable/modelscope HF_HUB_CACHE=/tmp/kiln-acc-writable-hub
USER trainer
EOF
}

scenario_nonroot_base_offline() {
  build_framework_base kiln-acc-fw-base:1
  new_service fw-offline
  cat >> "${WORK}/fw-offline/pack.conf" <<'EOF'
RUNTIME_BASE="kiln-acc-fw-base:1"
BUILDER_BASE="kiln-acc-fw-base:1"
EOF
  echo "    打包 fw-offline（构建时断网）"
  bash "${ROOT}/engine/pack.sh" "${WORK}/fw-offline" --network none > "$LOG" 2>&1
  PACK_RC=$?
  check_rc 0
  if [[ "$(docker inspect -f '{{.Config.User}}' kiln-acc-fw-offline:1.0.0)" == appuser ]]; then passed "最终用户是 appuser"; else failed "最终用户不对"; fi
}

scenario_cache_env_repointed() {
  build_framework_base kiln-acc-fw-base:1
  new_service fw-cache
  cat >> "${WORK}/fw-cache/pack.conf" <<'EOF'
RUNTIME_BASE="kiln-acc-fw-base:1"
BUILDER_BASE="kiln-acc-fw-base:1"
VERIFY_CMD='
docker logs "$VERIFY_CONTAINER" 2>&1 | grep -F "HF_DATASETS_CACHE=/opt/not-writable/datasets 不可写"
docker logs "$VERIFY_CONTAINER" 2>&1 | grep -F "MODELSCOPE_CACHE=/opt/not-writable/modelscope 不可写"
if docker logs "$VERIFY_CONTAINER" 2>&1 | grep -F "HF_HUB_CACHE="; then exit 7; fi
'
EOF
  pack fw-cache
  check_rc 0
  check_log '接口探针通过'

  cat >> "${WORK}/fw-cache/pack.conf" <<'EOF'
VERIFY_DOCKER_ARGS="-e KILN_KEEP_CACHE_ENV=1"
VERIFY_CMD='if docker logs "$VERIFY_CONTAINER" 2>&1 | grep -F "不可写"; then exit 7; fi'
EOF
  pack fw-cache
  check_rc 0
  check_log '接口探针通过'
}

scenario_verify_docker_args() {
  new_service docker-args
  cat >> "${WORK}/docker-args/pack.conf" <<'EOF'
VERIFY_DOCKER_ARGS="-e ACC_PROBE=hello-from-args"
VERIFY_CMD='docker exec "$VERIFY_CONTAINER" printenv ACC_PROBE'
EOF
  pack docker-args
  check_rc 0
  check_log 'hello-from-args'
}

scenario_runtime_uid() {
  local image=kiln-acc-run-uid:1.0.0 got
  new_service run-uid
  printf 'RUNTIME_UID="1234"\nRUNTIME_GID="2345"\n' >> "${WORK}/run-uid/pack.conf"
  pack run-uid
  check_rc 0
  got="$(docker run --rm --entrypoint /bin/sh "$image" -c 'id -u; id -g; id -un' | tr '\n' ' ')"
  if [[ "$got" == '1234 2345 appuser ' ]]; then passed "运行用户是 1234:2345"; else failed "运行用户是 ${got}"; fi
  new_project train-uid demo-train
  printf 'RUNTIME_UID="1234"\n' >> "${WORK}/train-uid/pack.conf"
  pack train-uid
  check_rc 0
}

scenario_runtime_uid_rejected() {
  local conf
  while IFS='|' read -r conf want; do
    rm -rf "${WORK}/uid-bad"
    new_service uid-bad
    printf '%s\n' "$conf" >> "${WORK}/uid-bad/pack.conf"
    pack uid-bad
    expect_rejected "$conf" "$want"
  done <<'EOF'
RUNTIME_UID="0"|不能用 root
RUNTIME_UID="abc"|不能用 root
RUNTIME_GID="-1"|不能用 root
EOF
}

scenario_custom_user_at_runtime() {
  # 用 --user 指定镜像里不存在的 uid（K8s 上常见）。解密失败和停止信号的检查不能因此误判。
  new_project custom-user demo-train
  printf 'VERIFY_DOCKER_ARGS="--user 1234:1234"\n' >> "${WORK}/custom-user/pack.conf"
  pack custom-user
  check_rc 0
  check_log '错误密钥时解密失败'
  check_log 'docker stop 后作业正常退出'
  check_log 'HOME 不可写'
  check_nolog '作业没有起来'
}

scenario_protected_entry_rejected() {
  new_service entry-module
  printf 'START_CMD="python -m svc.logic"\n' >> "${WORK}/entry-module/pack.conf"
  pack entry-module
  if [[ "$PACK_RC" -ne 0 ]]; then passed "打包失败（码 ${PACK_RC}）"; else failed "打包居然成功了"; fi
  check_log 'START_CMD 不能直接启动受保护的模块: python -m svc.logic'

  new_service entry-script
  printf 'PROTECT_GLOBS="svc/logic.py server.py"\n' >> "${WORK}/entry-script/pack.conf"
  pack entry-script
  if [[ "$PACK_RC" -ne 0 ]]; then passed "打包失败（码 ${PACK_RC}）"; else failed "打包居然成功了"; fi
  check_log 'START_CMD 不能直接启动受保护的模块: python server.py'
}

scenario_failure_log_shows_root_cause() {
  # 真正的报错在最前面，后面被健康检查的访问日志淹没。
  new_service root-cause
  cat > "${WORK}/root-cause/server.py" <<'EOF'
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer


def load():
    raise RuntimeError("ACC_ROOT_CAUSE_7d21")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(503)
        self.end_headers()


threading.Thread(target=load, daemon=True).start()
HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
EOF
  : > "${WORK}/root-cause/svc/logic.py"
  printf 'VERIFY_TIMEOUT="30"\n' >> "${WORK}/root-cause/pack.conf"
  pack root-cause
  check_rc 1
  check_log '30 秒内健康检查没有通过'
  check_log 'ACC_ROOT_CAUSE_7d21'
}

scenario_verify_start_cmd() {
  local rc
  new_project smoke demo-train
  cat >> "${WORK}/smoke/pack.conf" <<'EOF'
START_CMD='python -c "raise SystemExit(9)"'
VERIFY_START_CMD="python -m trainer.train --steps 20"
EOF
  pack smoke
  check_rc 0
  check_log 'steps=20'
  # 短任务只在验收时用，镜像自己的启动命令不变。
  docker run --rm -e KILN_SECRET_MARKER=x -e KILN_CONFIG_KEY kiln-acc-smoke:1.0.0 >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 9 ]]; then passed "镜像的启动命令没变（码 9）"; else failed "镜像的退出码是 ${rc}，期望 9"; fi
  if docker history --no-trunc kiln-acc-smoke:1.0.0 | grep -qF 'steps 20'; then failed "短任务写进了镜像历史"; else passed "短任务没有写进镜像"; fi
}

scenario_verify_loss_off() {
  new_project loss-off demo-train
  printf 'LOSS_TAG="no-such-tag="\nVERIFY_LOSS="off"\n' >> "${WORK}/loss-off/pack.conf"
  pack loss-off
  check_rc 0
  check_log 'VERIFY_LOSS=off'

  new_project loss-bad demo-train
  printf 'VERIFY_LOSS="maybe"\n' >> "${WORK}/loss-bad/pack.conf"
  pack loss-bad
  expect_rejected "未知 VERIFY_LOSS" '未知 VERIFY_LOSS'
}

scenario_loss_with_quotes() {
  # transformers 5 打印的是 {'loss': '1.23'}，数值带引号。
  new_project loss-quote demo-train
  perl -pi -e "s/ loss=\{loss:\.6f\}/ {{'loss': '{loss:.6f}'}}/" "${WORK}/loss-quote/trainer/train.py"
  cat >> "${WORK}/loss-quote/pack.conf" <<'EOF'
LOSS_TAG="'loss': "
EOF
  pack loss-quote
  check_rc 0
  check_log 'loss first=1.872699 last=1.183935'
}

scenario_stop_check_job_not_started() {
  new_project stop-nostart demo-train
  printf 'VERIFY_ENV=""\n' >> "${WORK}/stop-nostart/pack.conf"
  pack stop-nostart
  check_rc 1
  check_log '作业没有起来，无法验证停止信号'
  check_log '缺少必需环境变量'
}

ALL_SCENARIOS="
nonroot_base_offline cache_env_repointed verify_docker_args runtime_uid runtime_uid_rejected custom_user_at_runtime
protected_entry_rejected failure_log_shows_root_cause verify_start_cmd verify_loss_off loss_with_quotes stop_check_job_not_started
serve_demo serve_custom_api serve_no_probe serve_probe_fails serve_probe_pipe_fails
serve_health_timeout serve_exits_early serve_image_config serve_bad_values
marker_unset marker_empty marker_leak export_fails
sensitive_excluded keep_rejected train_sensitive
origin_base_ignored origin_own_detected origin_project_marker
train_demo train_exit_code train_compound_cmd
config_rejected config_bad_key config_not_covered job_leaks_config job_ignores_config encrypt_off protected_imports_kiln_config
signal_single signal_torchrun
launcher_accelerate launcher_deepspeed config_materialize
accelerate_cpu_detected launcher_not_installed launcher_unknown start_cmd_interpreter_path launcher_args_with_quotes
deps_cache_reuse deps_relative_requirements deps_in_base
pip_only_binary pip_hashes_missing pip_sdist_only pip_full_hashes pip_args_credentials
requirements_credentials private_wheels
"

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
