#!/usr/bin/env bash
# vLLM inside the Confidential VM: serve a small model on vLLM's OpenAI-compatible API, bound to
# 127.0.0.1, and query it from inside the guest with curl (plain and streaming) and with the openai SDK.
# Run over SSH from your machine:  ssh -p <port> ubuntu@<ip> 'BUDGET_SECONDS=720 bash -s' < in-vm-vllm.sh
# Expects the vLLM venv prepared by deploy-confidential-vm-api/in-vm-prepare.sh (vllm-install.done);
# without it, the install runs here. BUDGET_SECONDS bounds every wait.
#
# 2026-10-23, first run: `vllm serve` failed at engine start and only the last 30 lines of its log were
# kept, so the root cause was lost. Since then: a PyTorch/Triton smoke test runs first, the WHOLE
# server log is printed on any failure, the script stops waiting as soon as the server process dies,
# and up to two more attempts run with settings chosen from what the log says.
set -uo pipefail
cd "$HOME"
export PATH="$HOME/.local/bin:$PATH"
BUDGET=${BUDGET_SECONDS:-720}
START=$(date +%s)
left() { echo $(( BUDGET - ($(date +%s) - START) )); }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
MODEL=Qwen/Qwen2.5-0.5B-Instruct
PORT=8000

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
while [ ! -f vllm-install.done ] && [ "$(left)" -gt 240 ]; do sleep 5; done
if [ ! -f vllm-install.done ]; then
  log "NOT EXECUTED: the vLLM install was still running when the budget ran out"
  tail -5 vllm-install.log 2>/dev/null
  exit 2
fi
log "vLLM install exit $(cat vllm-install.done)"
[ "$(cat vllm-install.done)" = 0 ] || { tail -20 vllm-install.log; exit 1; }

# Triton compiles a small C launcher the first time it runs a kernel: it needs gcc and Python headers,
# which the VM image does not ship. in-vm-prepare.sh installs them (cc.done); this is the fallback.
log "== C compiler for Triton's JIT"
while [ ! -f cc.done ] && [ "$(left)" -gt 300 ]; do sleep 5; done
command -v gcc >/dev/null || sudo apt-get -o DPkg::Lock::Timeout=180 install -y -qq build-essential python3-dev
gcc --version | head -1

# shellcheck disable=SC1091
. "$HOME/vllm-venv/bin/activate"
uv pip list --python "$HOME/vllm-venv/bin/python" 2>/dev/null | grep -iE "^(vllm|torch|triton|flashinfer[a-z-]*|transformers|openai) "

log "== smoke test: PyTorch and Triton on the GPU (allocation, fp16 matmul, pinned host memory, a Triton kernel)"
cat > smoke.py <<'PY'
import time
import torch
import triton
import triton.language as tl

print("torch", torch.__version__, "| cuda", torch.version.cuda, "|", torch.cuda.get_device_name(0),
      "| capability", torch.cuda.get_device_capability(0))
x = torch.randn(4096, 4096, device="cuda", dtype=torch.float16)
torch.cuda.synchronize(); t = time.time(); y = x @ x; torch.cuda.synchronize()
print("fp16 matmul 4096x4096: ok, %.1f ms" % ((time.time() - t) * 1000))
p = torch.empty(256 * 1024 * 1024, dtype=torch.uint8, pin_memory=True)
torch.cuda.synchronize(); t = time.time(); g = p.to("cuda", non_blocking=True); torch.cuda.synchronize()
dt = time.time() - t
print("pinned host -> device, 256 MiB: ok, %.1f ms (%.1f GB/s)" % (dt * 1000, 0.268 / dt))

@triton.jit
def add(x_ptr, y_ptr, o_ptr, n, BLOCK: tl.constexpr):
    i = tl.program_id(0) * BLOCK + tl.arange(0, BLOCK)
    m = i < n
    tl.store(o_ptr + i, tl.load(x_ptr + i, mask=m) + tl.load(y_ptr + i, mask=m), mask=m)

a = torch.ones(1024, device="cuda"); b = torch.ones(1024, device="cuda"); o = torch.empty_like(a)
add[(4,)](a, b, o, 1024, BLOCK=256); torch.cuda.synchronize()
print("triton", triton.__version__, "kernel: ok, sum =", float(o.sum()))
PY
python smoke.py 2>&1 | tail -15

VLLM_PID=""
serve() {  # serve <attempt> [VAR=value ...]
  local n=$1; shift
  log "== attempt $n: vllm serve $MODEL ${*:+with $*}"
  env "$@" nohup vllm serve "$MODEL" --host 127.0.0.1 --port $PORT --max-model-len 4096 \
    --gpu-memory-utilization 0.60 --enforce-eager > "vllm-serve-$n.log" 2>&1 </dev/null &
  VLLM_PID=$!
  until curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; do
    if ! kill -0 "$VLLM_PID" 2>/dev/null; then
      log "attempt $n: vllm serve exited before answering. Full server log:"
      cat "vllm-serve-$n.log"
      return 1
    fi
    if [ "$(left)" -le 90 ]; then
      log "attempt $n: no answer before the budget ran out. Full server log:"
      cat "vllm-serve-$n.log"
      pkill -f "vllm serve"; sleep 3
      return 2
    fi
    sleep 5
  done
  log "attempt $n: server answering after $(( $(date +%s) - START )) s of this script"
  return 0
}

UP=""
COMBINED="VLLM_ENABLE_V1_MULTIPROCESSING=0 VLLM_USE_FLASHINFER_SAMPLER=0 VLLM_ATTENTION_BACKEND=TRITON_ATTN"
if serve 1; then UP=1; else
  # Second attempt: what the log points at. Third: every fallback at once.
  if grep -qiE "nvcc|CUDA_HOME|flashinfer" vllm-serve-1.log; then ENV2="VLLM_USE_FLASHINFER_SAMPLER=0 VLLM_ATTENTION_BACKEND=TRITON_ATTN"
  elif grep -qiE "C compiler|Python\.h|gcc" vllm-serve-1.log; then ENV2=""
  else ENV2="VLLM_ENABLE_V1_MULTIPROCESSING=0"; fi
  if [ "$(left)" -gt 180 ]; then
    # shellcheck disable=SC2086
    if serve 2 $ENV2; then UP=2
    elif [ "$(left)" -gt 180 ] && [ "$ENV2" != "$COMBINED" ]; then
      # shellcheck disable=SC2086
      serve 3 $COMBINED && UP=3
    fi
  fi
fi
if [ -z "$UP" ]; then
  log "NOT EXECUTED: GET /v1/models, POST /v1/chat/completions and the openai SDK call (no attempt answered)"
  exit 1
fi

log "== startup facts from the server log (attempt $UP)"
grep -E "Loading|loading took|weights|KV cache|backend|Using|Maximum concurrency|Starting vLLM|device" "vllm-serve-$UP.log" \
  | sed -E 's/^\(APIServer pid=[0-9]+\) //' | cut -c1-220 | head -25

log "== GET /v1/models"
curl -s "http://127.0.0.1:$PORT/v1/models" | python -c 'import sys,json; print([(m["id"], m.get("max_model_len")) for m in json.load(sys.stdin)["data"]])'

ask() {  # one chat completion with curl; prints the answer, returns 1 when the generated text is blank
  local body
  body=$(curl -s "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello from a confidential VM in one sentence.\"}],\"max_tokens\":40,\"temperature\":0}")
  echo "$body"
  echo "$body" | python -c 'import sys,json; c=json.load(sys.stdin)["choices"][0]["message"]["content"] or ""; sys.exit(0 if c.strip() else 1)'
}
log "== POST /v1/chat/completions with curl"
if ! ask; then
  # 2026-10-23, second run: the server answered with 40 spaces (greedy decoding), which is not a correct
  # generation for this model; the cause was not verified. Next time, one restart without the FlashInfer
  # sampler and with the Triton attention backend tells whether those kernels are involved.
  log "BLANK ANSWER: the server ran but generated only whitespace, which is not a correct answer"
  if [ "$(left)" -gt 240 ]; then
    pkill -f "vllm serve"; sleep 5
    if serve 4 VLLM_USE_FLASHINFER_SAMPLER=0 VLLM_ATTENTION_BACKEND=TRITON_ATTN; then
      UP=4
      log "== POST /v1/chat/completions with curl (attempt 4)"
      ask || log "BLANK ANSWER again with VLLM_USE_FLASHINFER_SAMPLER=0 VLLM_ATTENTION_BACKEND=TRITON_ATTN"
    fi
  else
    log "NOT EXECUTED: restart with other kernels ($(left) s left)"
  fi
fi
echo

log "== POST /v1/chat/completions with stream: true (first chunks)"
curl -s -N "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Count from one to five in words.\"}],\"max_tokens\":30,\"temperature\":0,\"stream\":true}" \
  | head -n 6 || true

log "== the openai SDK against the local server"
python - <<PY
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:$PORT/v1", api_key="unused-locally")
r = client.chat.completions.create(model="$MODEL", messages=[{"role": "user", "content": "Count from one to five in words."}], max_tokens=30, temperature=0)
print(r.choices[0].message.content.strip())
print("usage:", r.usage.prompt_tokens, "prompt +", r.usage.completion_tokens, "completion tokens")
PY

log "== GPU memory while serving"
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
pkill -f "vllm serve"
sleep 5
log "== vLLM stopped after $(( $(date +%s) - START )) s"
