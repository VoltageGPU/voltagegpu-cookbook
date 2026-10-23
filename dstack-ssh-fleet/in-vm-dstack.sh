#!/usr/bin/env bash
# dstack SSH fleet with a VoltageGPU Confidential VM as the host.
#
# In your setup the dstack server runs on your laptop or a small box and the fleet file lists the
# VM's public IP and SSH port (the API returns them in ssh_command). For this test the server runs
# inside the VM itself and the fleet points at 127.0.0.1: same mechanism (the server reaches the
# host over SSH, installs its shim, runs jobs in Docker), one machine fewer to rent.
#
# Expects the Docker + NVIDIA Container Toolkit install and the dstack venv prepared by
# deploy-confidential-vm-api/in-vm-prepare.sh. BUDGET_SECONDS bounds every wait; a step that does not
# fit is printed as NOT EXECUTED with the reason.
set -uo pipefail
cd "$HOME"
export PATH="$HOME/.local/bin:$PATH"
BUDGET=${BUDGET_SECONDS:-480}
START=$(date +%s)
left() { echo $(( BUDGET - ($(date +%s) - START) )); }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
# step <name> <seconds kept for later steps> <command...>: runs the command with what remains, or says why not
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

log "== waiting for Docker + NVIDIA Container Toolkit (host-install.done) and the dstack venv (tools-install.done)"
while { [ ! -f host-install.done ] || [ ! -f tools-install.done ]; } && [ "$(left)" -gt 240 ]; do sleep 5; done
if [ ! -f host-install.done ] || [ ! -f tools-install.done ]; then
  log "NOT EXECUTED: everything below (installs still running when the budget ran out)"
  tail -3 host-install.log tools-install.log 2>/dev/null
  exit 2
fi
log "host-install exit $(cat host-install.done), tools-install exit $(cat tools-install.done)"
[ "$(cat host-install.done)" = 0 ] || { tail -20 host-install.log; exit 1; }
[ "$(cat tools-install.done)" = 0 ] || { tail -20 tools-install.log; exit 1; }
sudo docker --version
nvidia-ctk --version | head -1
grep -E "^ *#? *AllowTcpForwarding" /etc/ssh/sshd_config || echo "AllowTcpForwarding not set in sshd_config (default: yes)"

step "host requirement check: the GPU from a container" 200 \
  sudo docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi --query-gpu=name,driver_version --format=csv,noheader

# shellcheck disable=SC1091
. "$HOME/dstack-venv/bin/activate"
dstack --version 2>/dev/null || dstack version

log "== an SSH key the server uses to reach the host (here: this VM, through 127.0.0.1)"
# Written in $HOME, not ~/.ssh: on 2026-10-23 ssh-keygen got "Permission denied" writing into ~/.ssh as
# ubuntu on this image (~/.ssh is root:root 755, seen on the second run). authorized_keys is appended with sudo.
ls -ld "$HOME/.ssh" "$HOME/.ssh/authorized_keys" 2>&1
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
  log "ssh ubuntu@127.0.0.1 with the new key: FAILED. NOT EXECUTED: fleet and task (dstack cannot reach the host)"
  exit 1
fi

log "== dstack server (local, SQLite state)"
nohup dstack server --host 127.0.0.1 --port 3000 > dstack-server.log 2>&1 </dev/null &
until grep -qiE "running at" dstack-server.log 2>/dev/null; do
  [ "$(left)" -le 150 ] && { log "NOT EXECUTED: fleet and task (dstack server not up within the budget)"; cat dstack-server.log; exit 2; }
  sleep 2
done
sleep 2
grep -iE "running at|admin token|project" dstack-server.log | sed -E 's/[0-9a-f]{8}-[0-9a-f-]{27}/<admin token>/g'

cat > fleet.dstack.yml <<'YML'
type: fleet
name: voltagegpu-vm
ssh_config:
  user: ubuntu
  identity_file: ~/fleet_ed25519
  hosts:
    # Your laptop as the server: put the VM's public IP here and its SSH port below
    # (both are in ssh_command from GET /api/volt/pods).
    - hostname: 127.0.0.1
      port: 22
YML
cat fleet.dstack.yml
step "dstack apply -f fleet.dstack.yml (connects over SSH, installs the shim, registers the host)" 120 \
  dstack apply -f fleet.dstack.yml -y
log "== dstack fleet"
dstack fleet

cat > task.dstack.yml <<'YML'
type: task
name: nvidia-smi-in-tee
image: nvidia/cuda:12.4.1-base-ubuntu22.04
commands:
  - nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
  - nvidia-smi conf-compute -q | grep -E "CC State|Ready State" || true
resources:
  gpu: 1
YML
cat task.dstack.yml
step "dstack apply -f task.dstack.yml (a job on the fleet: nvidia-smi in a container, in the TEE)" 20 \
  dstack apply -f task.dstack.yml -y
log "== dstack ps -a"
dstack ps -a 2>/dev/null | head -5
pkill -f "dstack server"
log "== done after $(( $(date +%s) - START )) s"
