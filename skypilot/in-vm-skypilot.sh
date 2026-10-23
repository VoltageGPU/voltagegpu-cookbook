#!/usr/bin/env bash
# SkyPilot SSH Node Pool with a VoltageGPU Confidential VM as the node.
#
# In your setup SkyPilot runs on your laptop (or its API server host) and ~/.sky/ssh_node_pools.yaml
# lists the VM, with the SSH port given through an alias in ~/.ssh/config (the API returns IP and port
# in ssh_command). For this test SkyPilot runs inside the VM itself and the pool points at the VM
# through a loopback alias: same mechanism (`sky ssh up` reaches the node over SSH, installs k3s,
# labels the GPU, runs tasks as pods), one machine fewer to rent.
#
# Expects deploy-confidential-vm-api/in-vm-prepare.sh (Docker + NVIDIA Container Toolkit, SkyPilot venv,
# kubectl) and in-vm-selfssh.sh (selfssh.env). Prepares in parallel with the dstack test, then waits
# for dstack.finished before changing the host, so the two never install at the same time.
# BUDGET_SECONDS bounds every wait; a step that does not fit is printed as NOT EXECUTED with the reason.
set -uo pipefail
cd "$HOME"
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
BUDGET=${BUDGET_SECONDS:-600}
START=$(date +%s)
left() { echo $(( BUDGET - ($(date +%s) - START) )); }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
step() {
  local name=$1 keep=$2; shift 2
  local t=$(( $(left) - keep ))
  if [ "$t" -lt 30 ]; then log "NOT EXECUTED: $name ($(left) s left in the budget)"; return 124; fi
  log "== $name (up to $t s)"
  timeout "$t" "$@" </dev/null; local rc=$?
  [ $rc -eq 124 ] && log "$name: stopped by the budget after $t s"
  log "$name: exit $rc"
  return $rc
}
nocolor() { sed -E 's/\x1b\[[0-9;]*m//g'; }

# shellcheck disable=SC1091
[ -f selfssh.env ] && . ./selfssh.env
if [ -z "${SELF_SSH_PORT:-}" ]; then
  log "NOT EXECUTED: sky ssh up and sky launch (the VM could not reach itself over SSH, see in-vm-selfssh.log)"
  exit 1
fi

log "== waiting for the SkyPilot venv and kubectl (sky-install.done)"
while [ ! -f sky-install.done ] && [ "$(left)" -gt 300 ]; do sleep 3; done
[ -f sky-install.done ] && [ "$(cat sky-install.done)" = 0 ] || { log "NOT EXECUTED: everything below (SkyPilot install not finished or failed)"; tail -5 sky-install.log 2>/dev/null; exit 1; }
# shellcheck disable=SC1091
. "$HOME/sky-venv/bin/activate"
sky --version
kubectl version --client 2>/dev/null | head -1

log "== the node as an ~/.ssh/config alias (the port of the self-loop SSH is $SELF_SSH_PORT)"
touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"
grep -q "^Host selfnode$" "$HOME/.ssh/config" || cat >> "$HOME/.ssh/config" <<CFG
Host selfnode
  HostName 127.0.0.1
  Port $SELF_SSH_PORT
  User ubuntu
  IdentityFile $SELF_SSH_KEY
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $HOME/known_hosts_self
CFG
ssh -n -o BatchMode=yes selfnode 'echo "ssh selfnode: OK"' </dev/null || log "ssh selfnode: FAILED"
mkdir -p "$HOME/.sky"
cat > "$HOME/.sky/ssh_node_pools.yaml" <<YML
voltagegpu-vm:
  user: ubuntu
  identity_file: $SELF_SSH_KEY
  hosts:
    # Your laptop as the SkyPilot host: an ~/.ssh/config alias carrying the VM's public IP and SSH port.
    - selfnode
YML
cat "$HOME/.sky/ssh_node_pools.yaml"
# No pipe after a sky command anywhere below: one that starts the API server daemon would keep the pipe
# open and hang the script. Output goes straight to the log; colors are stripped when it is published.
step "sky api start (local API server, while dstack runs)" 330 sky api start

log "== waiting for the dstack test to finish (dstack.finished) before changing the host"
while [ ! -f dstack.finished ] && [ "$(left)" -gt 330 ]; do sleep 3; done
[ -f dstack.finished ] && log "dstack finished, going on" || log "dstack still running with $(left) s left: going on anyway"
[ -f host-install.done ] && [ "$(cat host-install.done)" = 0 ] || { log "NOT EXECUTED: sky ssh up (Docker + NVIDIA Container Toolkit not installed)"; exit 1; }

if ! step "sky ssh up (installs k3s on the node, labels its GPU, registers the pool)" 150 sky ssh up; then
  log "NOT EXECUTED: sky launch (the node pool was not set up). Newest SkyPilot log:"
  newest=$(ls -t "$HOME"/sky_logs/*/*.log "$HOME"/sky_logs/*.log 2>/dev/null | head -1)
  [ -n "$newest" ] && { echo "   $newest"; tail -25 "$newest" | nocolor | cut -c1-220 | sed 's/^/   /'; }
  exit 1
fi
step "sky check ssh" 140 sky check ssh
log "== the node as Kubernetes sees it (labels and allocatable GPUs)"
for ctx in $(kubectl config get-contexts -o name 2>/dev/null); do
  echo "context: $ctx"
  kubectl --context "$ctx" get nodes -o json 2>/dev/null | python -c '
import sys, json
for n in json.load(sys.stdin)["items"]:
    labels = n["metadata"]["labels"]
    print(" node", n["metadata"]["name"], "| gpu labels", {k: v for k, v in labels.items() if "gpu" in k or "accelerator" in k},
          "| allocatable nvidia.com/gpu", n["status"]["allocatable"].get("nvidia.com/gpu"))'
done
GPU=$(for ctx in $(kubectl config get-contexts -o name 2>/dev/null); do kubectl --context "$ctx" get nodes -o jsonpath='{.items[0].metadata.labels.skypilot\.co/accelerator}' 2>/dev/null; done | head -1)
step "sky gpus list --infra ssh" 130 sky gpus list --infra ssh
log "GPU name for --gpus: ${GPU:-<no skypilot.co/accelerator label>}"
if [ -z "$GPU" ]; then
  log "NOT EXECUTED: sky launch with a GPU (the node carries no skypilot.co/accelerator label)"
  exit 1
fi
step "sky launch --infra ssh/voltagegpu-vm --gpus $GPU:1 (a pod on the node: nvidia-smi in the TEE)" 20 \
  sky launch --infra ssh/voltagegpu-vm --gpus "$GPU:1" -c tee-test -y -- \
  'nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader; nvidia-smi conf-compute -q 2>/dev/null | grep -E "CC State|Ready State" || true'
log "== sky status"
sky status > sky-status.txt 2>&1 </dev/null; nocolor < sky-status.txt | tail -6
log "== done after $(( $(date +%s) - START )) s"
