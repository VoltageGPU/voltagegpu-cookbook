# Use VoltageGPU with SkyPilot: an SSH Node Pool (partially executed)

[SkyPilot](https://docs.skypilot.co/en/latest/reservations/existing-machines.html) turns machines you
already have into an *SSH Node Pool*: `sky ssh up` connects to each host over SSH, installs a
lightweight Kubernetes (k3s) on it, labels its GPUs, and from then on `sky launch --infra ssh/<pool>`
runs tasks there like on any cloud. A VoltageGPU Confidential VM is such a machine.

## The recipe, host by host

**Your machine (SkyPilot client and local API server)**

```bash
pip install "skypilot[kubernetes]"       # SSH Node Pools are built on Kubernetes
# kubectl must be on the PATH; socat and netcat are used for port-forwarding
```

**The VM** (from <https://voltagegpu.com/confidential-vm/deploy> or `POST /api/volt/pods`, see
`../deploy-confidential-vm-api`). SkyPilot's prerequisites for the remote machines: Debian-based OS,
SSH access from the SkyPilot host, GPU drivers installed (check with `nvidia-smi`), not already part of
a Kubernetes cluster. The VoltageGPU image satisfies them at boot (Ubuntu 24.04, driver 595.71.05).
For GPU pods, k3s also needs the NVIDIA Container Toolkit on the host (installed by
`../deploy-confidential-vm-api/in-vm-prepare.sh`).

**Pool file**, `~/.sky/ssh_node_pools.yaml`. The VM's SSH port is not 22, so give it through an alias
in `~/.ssh/config` and list the alias:

```text
# ~/.ssh/config
Host voltagegpu-vm
  HostName <vm public ip>        # from ssh_command in GET /api/volt/pods
  Port <ssh port>
  User ubuntu
  IdentityFile ~/.ssh/id_ed25519
```

```yaml
# ~/.sky/ssh_node_pools.yaml
voltagegpu-vm:
  hosts:
    - voltagegpu-vm
```

```bash
sky ssh up                 # installs k3s on the node, registers the pool
sky check ssh              # the pool appears under "Enabled infra"
sky gpus list --infra ssh  # the GPU name as SkyPilot sees it
sky launch --infra ssh/voltagegpu-vm --gpus <name>:1 -y -- nvidia-smi
sky ssh down               # removes the SkyPilot runtime from the node
```

The VM keeps billing while it exists: release it through the API or the dashboard when done.

## Executed on 2026-10-23, step by step

To stay within one rented VM, SkyPilot ran *inside* the VM and the pool pointed at `127.0.0.1`.
`in-vm-skypilot.sh` was started detached by `deploy_and_attest.py`. Versions: skypilot 0.14.1,
kubectl v1.37.1. Unedited log in [`output-2026-10-23.txt`](output-2026-10-23.txt).

| Step | Status | Evidence |
|---|---|---|
| `pip install "skypilot[kubernetes]"` (via uv), kubectl | **executed** | `skypilot, version 0.14.1`, `Client Version: v1.37.1` |
| Docker + NVIDIA Container Toolkit on the node | **executed** (shared with the dstack example) | see `../dstack-ssh-fleet/README.md` |
| `~/.sky/ssh_node_pools.yaml` written | **executed** | printed in the log |
| Local SkyPilot API server | **executed** | `SkyPilot API server started`, `Found 1 Node Pool: voltagegpu-vm` |
| SSH key for the pool | **failed**: `ssh-keygen` answered `Saving key "/home/ubuntu/.ssh/fleet_ed25519" failed: Permission denied` | script bug, not SkyPilot's: the key was written into `~/.ssh`, which the `ubuntu` user could not write to on this image |
| `sky ssh up` (k3s install, GPU labelling) | **not executed**: `Failed to deploy 1 cluster(s): voltagegpu-vm: SSH Identity File Missing: /home/ubuntu/.ssh/fleet_ed25519` | |
| `sky check ssh` | ran, **no pool enabled** (`No infra to check/enabled`) | |
| `sky gpus list --infra ssh` | ran, `SSH Node Pools are not enabled` | |
| `sky launch --infra ssh/voltagegpu-vm ...` | **not executed**: `SSH Node Pool 'voltagegpu-vm' is not set up` | |

So SkyPilot is installed and sees the pool definition, but the node was never set up and no task ran.
`in-vm-skypilot.sh` now writes the key in `$HOME`, appends `authorized_keys` with `sudo` and checks
`ssh ubuntu@127.0.0.1` before `sky ssh up`; that version has not been run yet. The time `sky ssh up`
and the first `sky launch` take on this VM is therefore unknown.
