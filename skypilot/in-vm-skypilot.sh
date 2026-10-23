#!/usr/bin/env bash
# SkyPilot SSH Node Pool with a VoltageGPU Confidential VM as the node.
#
# In your setup SkyPilot runs on your laptop (or its API server host) and ~/.sky/ssh_node_pools.yaml
# lists the VM, with the SSH port given through an alias in ~/.ssh/config (the API returns IP and port
# in ssh_command). For this test SkyPilot runs inside the VM itself and the pool points at 127.0.0.1:
# same mechanism (`sky ssh up` reaches the node over SSH, installs k3s, labels the GPU, runs tasks as
# pods), one machine fewer to rent.
#
# Expects the Docker + NVIDIA Container Toolkit install, kubectl and the SkyPilot venv prepared by
# deploy-confidential-vm-api/in-vm-prepare.sh. BUDGET_SECONDS bounds every wait; a step that does not
# fit is printed as NOT EXECUTED with the reason.
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
  timeout "$t" "$@"; local rc=$?
  [ $rc -eq 124 ] && log "$name: stopped by the budget after $t s"
  log "$name: exit $rc"
  return $rc
}

log "== waiting for the host install (host-install.done) and the SkyPilot venv (tools-install.done)"
while { [ ! -f host-install.done ] || [ ! -f tools-install.done ]; } && [ "$(left)" -gt 300 ]; do sleep 5; done
if [ ! -f host-install.done ] || [ ! -f tools-install.done ]; then
  log "NOT EXECUTED: everything below (installs still running when the budget ran out)"
  exit 2
fi
[ "$(cat host-install.done)" = 0 ] && [ "$(cat tools-install.done)" = 0 ] || { log "an install failed"; tail -10 host-install.log tools-install.log; exit 1; }

# shellcheck disable=SC1091
. "$HOME/sky-venv/bin/activate"
sky --version
kubectl version --client 2>/dev/null | head -1

log "== an SSH key SkyPilot uses to reach the node (here: this VM, through 127.0.0.1)"
# Written in $HOME, not ~/.ssh: on 2026-10-23 ssh-keygen got "Permission denied" writing into ~/.ssh as
# ubuntu on this image (~/.ssh is root:root 755, seen on the second run). authorized_keys is appended with sudo.
[ -f "$HOME/fleet_ed25519" ] || ssh-keygen -t ed25519 -N "" -f "$HOME/fleet_ed25519" -q
PUB=$(cut -d' ' -f2 "$HOME/fleet_ed25519.pub")
# 2026-10-23, second run: the key appended with `sudo tee -a` was refused ("Permission denied (publickey)").
# Most probable cause, not verified: the provider writes authorized_keys without a final newline, so the
# appended key was glued to the last line. A newline is now added first when it is missing.
if ! sudo grep -qF "$PUB" "$HOME/.ssh/authorized_keys"; then
  if [ -s "$HOME/.ssh/authorized_keys" ] && [ -n "$(sudo tail -c1 "$HOME/.ssh/authorized_keys")" ]; then
    log "authorized_keys does not end with a newline: adding one before the key"
    echo | sudo tee -a "$HOME/.ssh/authorized_keys" >/dev/null
  fi
  sudo tee -a "$HOME/.ssh/authorized_keys" < "$HOME/fleet_ed25519.pub" >/dev/null
fi
if ssh -i "$HOME/fleet_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/known_hosts_local" ubuntu@127.0.0.1 true; then
  log "ssh ubuntu@127.0.0.1 with the new key: OK"
else
  log "ssh ubuntu@127.0.0.1 with the new key: FAILED. NOT EXECUTED: sky ssh up and sky launch"
  exit 1
fi

mkdir -p "$HOME/.sky"
cat > "$HOME/.sky/ssh_node_pools.yaml" <<'YML'
voltagegpu-vm:
  user: ubuntu
  identity_file: ~/fleet_ed25519
  hosts:
    # Your laptop as the SkyPilot host: put an ~/.ssh/config alias here that carries the VM's
    # public IP and SSH port (both in ssh_command from GET /api/volt/pods).
    - 127.0.0.1
YML
cat "$HOME/.sky/ssh_node_pools.yaml"

if ! step "sky ssh up (installs k3s on the node, labels its GPU, registers the pool)" 150 sky ssh up; then
  log "NOT EXECUTED: sky launch (the node pool was not set up, see the output of sky ssh up above)"
  sky check ssh 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | tail -6
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
step "sky launch --infra ssh/voltagegpu-vm --gpus $GPU:1 (a pod on the node: nvidia-smi in the TEE)" 25 \
  sky launch --infra ssh/voltagegpu-vm --gpus "$GPU:1" -c tee-test -y -- \
  'nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader; nvidia-smi conf-compute -q 2>/dev/null | grep -E "CC State|Ready State" || true'
log "== sky status"
sky status 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | tail -6
log "== done after $(( $(date +%s) - START )) s"
