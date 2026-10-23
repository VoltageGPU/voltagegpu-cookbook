#!/usr/bin/env bash
# dstack SSH fleet with a VoltageGPU Confidential VM as the host.
#
# In your setup the dstack server runs on your laptop or a small box and the fleet file lists the
# VM's public IP and SSH port (the API returns them in ssh_command). For this test the server runs
# inside the VM itself and the fleet points at 127.0.0.1: same mechanism (the server reaches the
# host over SSH, installs its shim, runs jobs in Docker), one machine fewer to rent.
#
# Expects deploy-confidential-vm-api/in-vm-prepare.sh (Docker + NVIDIA Container Toolkit, dstack venv)
# and in-vm-selfssh.sh (selfssh.env: the port and key that let the VM reach itself over SSH).
# BUDGET_SECONDS bounds every wait; a step that does not fit is printed as NOT EXECUTED with the
# reason. Writes dstack.finished on exit, which the SkyPilot script waits for.
set -uo pipefail
cd "$HOME"
trap 'touch "$HOME/dstack.finished"' EXIT
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
  timeout "$t" "$@" </dev/null; local rc=$?
  [ $rc -eq 124 ] && log "$name: stopped by the budget after $t s"
  log "$name: exit $rc"
  return $rc
}
waitfor() {  # waitfor <marker> <seconds kept>: waits for <marker>.done, prints its exit code
  while [ ! -f "$1.done" ] && [ "$(left)" -gt "$2" ]; do sleep 3; done
  [ -f "$1.done" ] || { log "NOT EXECUTED: everything below ($1 still running when the budget ran out)"; tail -3 "$1.log" 2>/dev/null; exit 2; }
  log "$1 exit $(cat "$1.done")"
  [ "$(cat "$1.done")" = 0 ] || { tail -20 "$1.log"; exit 1; }
}

# shellcheck disable=SC1091
[ -f selfssh.env ] && . ./selfssh.env
if [ -z "${SELF_SSH_PORT:-}" ]; then
  log "NOT EXECUTED: fleet and task (the VM could not reach itself over SSH, see in-vm-selfssh.log)"
  exit 1
fi
log "self-loop SSH from in-vm-selfssh.sh: port $SELF_SSH_PORT, key $SELF_SSH_KEY"

log "== waiting for the dstack venv"
waitfor dstack-install 200
# shellcheck disable=SC1091
. "$HOME/dstack-venv/bin/activate"
dstack --version 2>/dev/null || dstack version

log "== dstack server (local, SQLite state), started while Docker installs"
nohup dstack server --host 127.0.0.1 --port 3000 > dstack-server.log 2>&1 </dev/null &
until grep -qiE "running at" dstack-server.log 2>/dev/null; do
  [ "$(left)" -le 150 ] && { log "NOT EXECUTED: fleet and task (dstack server not up within the budget)"; cat dstack-server.log; exit 2; }
  sleep 2
done
grep -iE "running at|admin token" dstack-server.log | sed -E 's/[0-9a-f]{8}-[0-9a-f-]{27}/<admin token>/g'

log "== waiting for Docker + NVIDIA Container Toolkit"
waitfor host-install 150
sudo docker --version
nvidia-ctk --version | head -1
step "host requirement check: the GPU from a container" 140 \
  sudo docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi --query-gpu=name,driver_version --format=csv,noheader

cat > fleet.dstack.yml <<YML
type: fleet
name: voltagegpu-vm
ssh_config:
  user: ubuntu
  identity_file: $SELF_SSH_KEY
  hosts:
    # Your laptop as the server: the VM's public IP and SSH port (ssh_command in GET /api/volt/pods).
    - hostname: 127.0.0.1
      port: $SELF_SSH_PORT
YML
cat fleet.dstack.yml
step "dstack apply -f fleet.dstack.yml (connects over SSH, installs the shim, registers the host)" 90 \
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
step "dstack apply -f task.dstack.yml (a job on the fleet: nvidia-smi in a container, in the TEE)" 15 \
  dstack apply -f task.dstack.yml -y
log "== dstack ps -a"
dstack ps -a 2>/dev/null | head -5
pkill -f "dstack server"
log "== done after $(( $(date +%s) - START )) s"
