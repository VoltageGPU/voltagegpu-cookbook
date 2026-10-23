# Use VoltageGPU with dstack: an SSH fleet (partially executed)

[dstack](https://dstack.ai/docs/concepts/fleets/) runs dev environments, tasks and services on a
*fleet*. An **SSH fleet** is a fleet made of machines you already have and can reach over SSH: the
dstack server connects to each host, installs its shim and schedules jobs in Docker containers there.
A VoltageGPU Confidential VM is such a machine, so no dstack backend is needed: list its IP and SSH
port.

## The recipe, host by host

**Your machine (dstack server and CLI)**

```bash
pip install "dstack[all]" -U
dstack server            # prints the admin token, configures ~/.dstack/config.yml for this CLI
```

**The VM (from <https://voltagegpu.com/confidential-vm/deploy> or `POST /api/volt/pods`, see
`../deploy-confidential-vm-api`)**: dstack's host requirements for SSH fleets are Linux, Docker, the
NVIDIA Container Toolkit (CUDA 12.1 or later on the host side), passwordless `sudo` for the SSH user,
`AllowTcpForwarding yes` in sshd. On the VoltageGPU image (Ubuntu 24.04, driver 595.71.05), Docker and
the toolkit are not preinstalled; `../deploy-confidential-vm-api/in-vm-prepare.sh` installs them:

```bash
curl -fsSL https://get.docker.com | sudo sh
# NVIDIA Container Toolkit apt repository, then:
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
sudo docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi    # the GPU from a container
```

**Fleet file** (`fleet.dstack.yml`), with the values `GET /api/volt/pods` returns in `ssh_command`
(`ssh -p <port> ubuntu@<ip>`):

```yaml
type: fleet
name: voltagegpu-vm
ssh_config:
  user: ubuntu
  identity_file: ~/.ssh/id_ed25519      # the key registered on your VoltageGPU account
  hosts:
    - hostname: <vm public ip>
      port: <ssh port>
```

```bash
dstack apply -f fleet.dstack.yml      # connects, installs the shim, registers the host
dstack fleet                          # the VM appears with its GPU
```

**A task on it** (`task.dstack.yml`):

```yaml
type: task
name: nvidia-smi-in-tee
image: nvidia/cuda:12.4.1-base-ubuntu22.04
commands:
  - nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
resources:
  gpu: 1
```

```bash
dstack apply -f task.dstack.yml
```

The VM keeps billing while it exists: release it through the API or the dashboard when the fleet is no
longer needed (`dstack fleet delete` only removes dstack's record).

## Executed on 2026-10-23, step by step

To stay within one rented VM, the test ran the dstack server *inside* the VM and pointed the fleet at
`127.0.0.1:22` (same mechanism, one machine fewer). `in-vm-dstack.sh` was started detached by
`deploy_and_attest.py`. Versions: dstack 0.22.5, Docker 29.9.2, NVIDIA Container Toolkit 1.20.1.
Unedited log in [`output-2026-10-23.txt`](output-2026-10-23.txt).

| Step | Status | Evidence |
|---|---|---|
| Docker + NVIDIA Container Toolkit install (apt) | **executed** (about 75 s) | `host-install exit 0`, `Docker version 29.9.2`, `NVIDIA Container Toolkit CLI version 1.20.1` |
| GPU visible from a container | **executed** | `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi ...` printed `NVIDIA RTX PRO 6000 Blackwell Server Edition, 595.71.05` |
| `pip install "dstack[all]"` (via uv) | **executed** | `0.22.5` |
| `dstack server` | **executed** | `Configured the main project in ~/.dstack/config.yml`, `The admin token is <admin token>`, `The dstack server 0.22.5 is running at http://127.0.0.1:3000` |
| SSH key for the fleet | **failed**: `ssh-keygen` answered `Saving key "/home/ubuntu/.ssh/fleet_ed25519" failed: Permission denied` | script bug, not dstack's: the key was written into `~/.ssh`, which the `ubuntu` user could not write to on this image |
| `dstack apply -f fleet.dstack.yml` | **not executed** (refused: `Unable to read the SSH key at ~/.ssh/fleet_ed25519`) | `dstack fleet` listed no fleet |
| `dstack apply -f task.dstack.yml` | **not executed** (`The project has no fleets`) | `dstack ps -a`: `nvidia-smi-in-tee ... no fleets` |

So the host side is proven (the VM meets dstack's requirements once Docker and the toolkit are
installed, and the server runs), the fleet registration and the job are not. `in-vm-dstack.sh` now
writes the key in `$HOME`, appends `authorized_keys` with `sudo` and checks `ssh ubuntu@127.0.0.1`
before `dstack apply`; that version has not been run yet.
