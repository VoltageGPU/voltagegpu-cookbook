#!/usr/bin/env bash
# SkyPilot SSH Node Pool with a VoltageGPU Confidential VM as the node.
#
# In your setup SkyPilot runs on your laptop (or its API server host) and ~/.sky/ssh_node_pools.yaml
# lists the VM's public IP, with the SSH port given through an alias in ~/.ssh/config (the API returns
# both in ssh_command). For this test SkyPilot runs inside the VM itself and the pool points at
# 127.0.0.1: same mechanism (`sky ssh up` reaches the node over SSH, installs k3s, labels the GPU,
# runs tasks as pods), one machine fewer to rent.
#
# Expects the Docker + NVIDIA Container Toolkit install, kubectl and the SkyPilot venv prepared by
# deploy-confidential-vm-api/in-vm-prepare.sh. BUDGET_SECONDS bounds every wait.
set -uo pipefail
cd "$HOME"
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
BUDGET=${BUDGET_SECONDS:-600}
START=$(date +%s)
left() { echo $(( BUDGET - ($(date +%s) - START) )); }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

log "== waiting for the host install (host-install.done) and the SkyPilot venv (tools-install.done)"
while { [ ! -f host-install.done ] || [ ! -f tools-install.done ]; } && [ "$(left)" -gt 300 ]; do sleep 10; done
if [ ! -f host-install.done ] || [ ! -f tools-install.done ]; then
  log "installs not finished within the budget: the rest of this script was NOT EXECUTED"
  exit 2
fi
[ "$(cat host-install.done)" = 0 ] && [ "$(cat tools-install.done)" = 0 ] || { log "an install failed"; tail -10 host-install.log tools-install.log; exit 1; }

# shellcheck disable=SC1091
. "$HOME/sky-venv/bin/activate"
sky --version
kubectl version --client 2>/dev/null | head -1

log "== an SSH key SkyPilot uses to reach the node (here: this VM, through 127.0.0.1)"
# Written in $HOME, not ~/.ssh: on 2026-10-23 ssh-keygen got "Permission denied" writing into ~/.ssh as
# ubuntu on this image, and the step below failed silently. authorized_keys is appended with sudo.
[ -f "$HOME/fleet_ed25519" ] || ssh-keygen -t ed25519 -N "" -f "$HOME/fleet_ed25519" -q
PUB=$(cut -d' ' -f2 "$HOME/fleet_ed25519.pub")
sudo grep -qF "$PUB" "$HOME/.ssh/authorized_keys" || sudo tee -a "$HOME/.ssh/authorized_keys" < "$HOME/fleet_ed25519.pub" >/dev/null
ssh -i "$HOME/fleet_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/known_hosts_local" ubuntu@127.0.0.1 true && log "ssh ubuntu@127.0.0.1 with the new key: OK" || log "ssh ubuntu@127.0.0.1 with the new key: FAILED"

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

log "== sky ssh up  (installs k3s on the node, labels its GPU, registers the pool)"
timeout $(( $(left) - 200 )) sky ssh up
log "== sky check ssh"
sky check ssh 2>&1 | tail -8
log "== GPUs the pool offers"
sky gpus list --infra ssh 2>/dev/null || sky show-gpus --infra ssh 2>/dev/null || true
GPU=$(sky gpus list --infra ssh/voltagegpu-vm 2>/dev/null | awk '/^GPU/{h=1; next} h && NF && $1 != "" {print $1; exit}')
log "GPU name as SkyPilot sees it: ${GPU:-<not detected>}"

log "== sky launch --infra ssh/voltagegpu-vm  (a task as a pod on the node: nvidia-smi inside the TEE)"
timeout $(( $(left) - 30 )) sky launch --infra ssh/voltagegpu-vm ${GPU:+--gpus "$GPU:1"} -c tee-test -y -- \
  'nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || echo "no GPU in this pod"; nvidia-smi conf-compute -q 2>/dev/null | grep -E "CC State|Ready State" || true'
log "== sky status"
sky status 2>&1 | tail -6
sky down -y tee-test >/dev/null 2>&1 || true
log "== done after $(( $(date +%s) - START )) s"
