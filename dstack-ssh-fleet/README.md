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

## Executed on 2026-10-23: two runs, fleet and task not executed

To stay within one rented VM per run, the test ran the dstack server *inside* the VM and pointed the
fleet at `127.0.0.1:22` (same mechanism, one machine fewer). Versions: dstack 0.22.5, Docker 29.9.2,
NVIDIA Container Toolkit 1.20.1. Unedited logs: [`output-2026-10-23.txt`](output-2026-10-23.txt)
(first run) and [`output-2026-10-23-run2.txt`](output-2026-10-23-run2.txt) (second run).

| Step | Status | Evidence |
|---|---|---|
| Docker + NVIDIA Container Toolkit install (apt) | **executed**, both runs | `host-install exit 0`, `Docker version 29.9.2`, `NVIDIA Container Toolkit CLI version 1.20.1` |
| sshd allows TCP forwarding | **checked** (run 2) | `#AllowTcpForwarding yes` (commented: the default, yes) |
| GPU visible from a container | **executed**, both runs | `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi ...` printed `NVIDIA RTX PRO 6000 Blackwell Server Edition, 595.71.05` |
| `pip install "dstack[all]"` (via uv) | **executed** | `0.22.5` |
| `dstack server` | **executed** (run 1) | `The dstack server 0.22.5 is running at http://127.0.0.1:3000` |
| SSH key the server uses to reach the host | **failed** in both runs | run 1: `ssh-keygen` could not write into `~/.ssh` (`Permission denied`); run 2 showed why, `drwxr-xr-x 2 root root /home/ubuntu/.ssh`. Run 2 wrote the key in `$HOME`, appended it to `authorized_keys` with `sudo`, then `ssh ubuntu@127.0.0.1` with that key answered `Permission denied (publickey)` |
| `dstack apply -f fleet.dstack.yml` | **not executed** | run 1: `Unable to read the SSH key at ~/.ssh/fleet_ed25519`; run 2: stopped before it, the host was not reachable with the key |
| `dstack apply -f task.dstack.yml` | **not executed** | run 1: `The project has no fleets`; run 2: stopped before it |

What is proven: the VM meets dstack's host requirements once Docker and the toolkit are installed (a
container sees the GPU) and the server runs. What is not: the fleet registration and a job. The cause
of the last refusal is not verified. The most probable one is that `authorized_keys`, written by the
platform, does not end with a newline, so the appended key was glued to the last line.
`in-vm-dstack.sh` now adds the missing newline first and says so in its output; that version has not
been run. In the normal setup (dstack server on your machine, your registered key, the VM's public
address) this self-loop key is not needed at all.
