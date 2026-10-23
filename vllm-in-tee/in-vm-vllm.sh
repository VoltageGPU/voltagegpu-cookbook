#!/usr/bin/env bash
# vLLM inside the Confidential VM: serve a small model on vLLM's OpenAI-compatible API, bound to
# 127.0.0.1, and query it from inside the guest with curl and with the openai SDK.
# Run over SSH from your machine:  ssh -p <port> ubuntu@<ip> 'BUDGET_SECONDS=900 bash -s' < in-vm-vllm.sh
# Expects the vLLM venv prepared by deploy-confidential-vm-api/in-vm-prepare.sh (vllm-install.done);
# without it, the install runs here (several minutes). BUDGET_SECONDS bounds every wait.
set -uo pipefail
cd "$HOME"
export PATH="$HOME/.local/bin:$PATH"
BUDGET=${BUDGET_SECONDS:-900}
START=$(date +%s)
left() { echo $(( BUDGET - ($(date +%s) - START) )); }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
MODEL=Qwen/Qwen2.5-0.5B-Instruct

log "== GPU as seen from the guest"
nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used --format=csv
nvidia-smi conf-compute -q | grep -E "CC State|Multi-GPU|Ready State"

if [ ! -f vllm-install.done ] && [ ! -d "$HOME/vllm-venv" ]; then
  log "== no prepared venv: installing vLLM now"
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
  uv venv -q "$HOME/vllm-venv" && uv pip install -q --python "$HOME/vllm-venv/bin/python" vllm openai
  echo $? > vllm-install.done
fi
log "== waiting for the vLLM install (vllm-install.done)"
while [ ! -f vllm-install.done ] && [ "$(left)" -gt 240 ]; do sleep 10; done
if [ ! -f vllm-install.done ]; then
  log "vLLM install still running after the budget: the rest of this script was NOT EXECUTED"
  tail -5 vllm-install.log 2>/dev/null
  exit 2
fi
log "vLLM install exit $(cat vllm-install.done) after $(( $(date +%s) - START )) s of waiting here"
[ "$(cat vllm-install.done)" = 0 ] || { tail -20 vllm-install.log; exit 1; }
# shellcheck disable=SC1091
. "$HOME/vllm-venv/bin/activate"
python -c "import vllm, torch; print('vllm', vllm.__version__, '| torch', torch.__version__, '| cuda', torch.version.cuda, '|', torch.cuda.get_device_name(0))"

log "== vllm serve $MODEL (model download, then startup)"
nohup vllm serve "$MODEL" --host 127.0.0.1 --port 8000 --max-model-len 4096 \
  --gpu-memory-utilization 0.60 --enforce-eager > vllm-serve.log 2>&1 </dev/null &
VLLM_PID=$!
until curl -sf http://127.0.0.1:8000/v1/models >/dev/null 2>&1; do
  if ! kill -0 "$VLLM_PID" 2>/dev/null; then
    log "vllm serve exited before answering: the queries below were NOT EXECUTED. Full server log:"
    cat vllm-serve.log
    exit 1
  fi
  if [ "$(left)" -le 60 ]; then
    log "vLLM did not come up within the budget: the queries below were NOT EXECUTED. Full server log:"
    cat vllm-serve.log
    pkill -f "vllm serve"
    exit 2
  fi
  sleep 5
done
log "== server up after $(( $(date +%s) - START )) s. GET /v1/models"
curl -s http://127.0.0.1:8000/v1/models | python -c 'import sys,json; print([m["id"] for m in json.load(sys.stdin)["data"]])'

log "== POST /v1/chat/completions with curl"
curl -s http://127.0.0.1:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello from a confidential VM in one sentence.\"}],\"max_tokens\":40,\"temperature\":0}"
echo

log "== the openai SDK against the local server"
python - <<PY
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:8000/v1", api_key="unused-locally")
r = client.chat.completions.create(model="$MODEL", messages=[{"role": "user", "content": "Count from one to five in words."}], max_tokens=30, temperature=0)
print(r.choices[0].message.content.strip())
print("usage:", r.usage.prompt_tokens, "prompt +", r.usage.completion_tokens, "completion tokens")
PY

log "== GPU memory while serving"
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
pkill -f "vllm serve"
sleep 3
log "== vLLM stopped after $(( $(date +%s) - START )) s"
