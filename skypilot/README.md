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

## Executed on 2026-10-23: three runs, node pool and task not executed

To stay within one rented VM per run, SkyPilot ran *inside* the VM and the pool pointed at
`127.0.0.1`. Versions: skypilot 0.14.1, kubectl v1.37.1. Unedited logs:
[`output-2026-10-23.txt`](output-2026-10-23.txt) (first run) and
[`output-2026-10-23-run2.txt`](output-2026-10-23-run2.txt) (second run).

| Step | Status | Evidence |
|---|---|---|
| `pip install "skypilot[kubernetes]"` (via uv), kubectl | **executed**, both runs | `skypilot, version 0.14.1`, `Client Version: v1.37.1` |
| Docker + NVIDIA Container Toolkit on the node | **executed** (shared with the dstack example) | see `../dstack-ssh-fleet/README.md` |
| `~/.sky/ssh_node_pools.yaml` written, local API server | **executed** (run 1) | `SkyPilot API server started`, `Found 1 Node Pool: voltagegpu-vm` |
| SSH key SkyPilot uses to reach the node | **failed** in both runs | run 1: `ssh-keygen` could not write into `~/.ssh` (root-owned on this image); run 2: key in `$HOME`, appended to `authorized_keys` with `sudo`, then `ssh ubuntu@127.0.0.1` answered `Permission denied (publickey)` |
| `sky ssh up` (k3s install, GPU labelling) | **not executed** | run 1: `SSH Identity File Missing: /home/ubuntu/.ssh/fleet_ed25519`; run 2: stopped before it, the node was not reachable with the key |
| `sky check ssh`, `sky gpus list --infra ssh` | ran in run 1, **no pool enabled** | `No infra to check/enabled`, `SSH Node Pools are not enabled` |
| `sky launch --infra ssh/voltagegpu-vm ...` | **not executed** | run 1: `SSH Node Pool 'voltagegpu-vm' is not set up`; run 2: stopped before it |

### Third run (13:47 UTC): the self-loop SSH works, then a bug in the test script

Log: [`output-2026-10-23-run3.txt`](output-2026-10-23-run3.txt). `../deploy-confidential-vm-api/in-vm-selfssh.sh`
ran first, with diagnostics:

```text
drwxr-xr-x 2 root   root   4096 Oct 23 13:45 /home/ubuntu/.ssh
-rw------- 1 ubuntu ubuntu  387 Oct 23 13:45 /home/ubuntu/.ssh/authorized_keys
authorized_keys: 3 line(s), last byte:   3
   authorizedkeyscommand none
   authorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2
[13:47:13] == 1. ~/.ssh owned by ubuntu (700), authorized_keys owned by ubuntu (600), content kept
[13:47:13] /home/ubuntu/.ssh/authorized_keys does not end with a newline: adding one first
[13:47:13] key appended to /home/ubuntu/.ssh/authorized_keys
   connected
   passwordless-sudo
[13:47:13] ssh -o BatchMode=yes -i fleet_ed25519 ubuntu@127.0.0.1 (port 22, ~/.ssh/authorized_keys): OK
```

So the refusal of the second run is explained: `authorized_keys` on this image ends without a newline
(its last byte is the end of a key comment), and a key appended with `cat >>` or `tee -a` is glued to
the last line. With a newline added first, `ssh ubuntu@127.0.0.1` and passwordless `sudo` work.

Then the script stopped right after that OK line, without writing `selfssh.env`. The cause is mine:
the script was fed to `bash -s` over stdin, and the `ssh` of the test, run without `-n`, read the rest
of the script from that same stdin. The tests below it saw no `selfssh.env` and stopped
(`NOT EXECUTED: ... the VM could not reach itself over SSH`). Fixed since (`ssh -n ... </dev/null`
everywhere), not rerun: this was the last VM of the budget.

**Status.** Proven: SkyPilot and kubectl install, the pool definition is read, the node meets the
prerequisites listed above, and the VM can be reached over SSH as `ubuntu` with passwordless `sudo`
once a key is added correctly. Not executed: `sky ssh up` and `sky launch` (k3s on the node, GPU labelling, a
task), because of the test-script bug above; the time they take on this VM is unknown. In the normal
setup (SkyPilot on your machine, your registered key, the VM's public address) the self-loop key is not
needed.
