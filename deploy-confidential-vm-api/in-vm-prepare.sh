#!/usr/bin/env bash
# Runs first, right after SSH is up, and returns at once: it starts the long installs in the
# background so they overlap with the attestation step. Each job writes <name>.done with its exit
# code when it finishes; the later scripts (vllm-in-tee, dstack-ssh-fleet, skypilot) wait on those.
#
#   vllm-install   uv venv + vLLM wheels (the biggest download)
#   host-install   gcc + Python headers (cc.done, Triton's JIT needs them), then
#                  Docker + NVIDIA Container Toolkit (dstack SSH fleets and SkyPilot node pools both
#                  run workloads in containers with GPU access), socat and netcat for SkyPilot
#   dstack-install dstack CLI and server in its own venv
#   sky-install    SkyPilot CLI in its own venv, kubectl (SkyPilot needs it)
set -uo pipefail
cd "$HOME"
exec > >(tee -a prepare.log) 2>&1
echo "[$(date -u +%H:%M:%S)] prepare: $(lsb_release -ds 2>/dev/null), $(nproc) vCPU, $(free -g | awk '/Mem/{print $2}') GB RAM, disk $(df -h / | awk 'NR==2{print $4}') free"
echo "[$(date -u +%H:%M:%S)] uv (fast installer for the venvs below)"
curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
export PATH="$HOME/.local/bin:$PATH"
uv --version

{ ( set -e
    uv venv -q "$HOME/vllm-venv"
    uv pip install -q --python "$HOME/vllm-venv/bin/python" vllm openai
    echo 0 > vllm-install.done ) > vllm-install.log 2>&1 || echo 1 > vllm-install.done; } </dev/null >/dev/null 2>&1 &

{ ( set -e
    # gcc and Python headers first (Triton JIT, used by vLLM), marked by cc.done
    sudo apt-get update -qq
    sudo apt-get install -y -qq build-essential python3-dev && echo 0 > cc.done || echo 1 > cc.done
    curl -fsSL https://get.docker.com | sudo sh
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq nvidia-container-toolkit socat netcat-openbsd
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    sudo usermod -aG docker ubuntu
    echo 0 > host-install.done ) > host-install.log 2>&1 || echo 1 > host-install.done; } </dev/null >/dev/null 2>&1 &

{ ( set -e
    uv venv -q "$HOME/dstack-venv"
    uv pip install -q --python "$HOME/dstack-venv/bin/python" "dstack[all]"
    echo 0 > dstack-install.done ) > dstack-install.log 2>&1 || echo 1 > dstack-install.done; } </dev/null >/dev/null 2>&1 &

{ ( set -e
    uv venv -q "$HOME/sky-venv"
    uv pip install -q --python "$HOME/sky-venv/bin/python" "skypilot[kubernetes]"
    curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -m 0755 kubectl /usr/local/bin/kubectl
    echo 0 > sky-install.done ) > sky-install.log 2>&1 || echo 1 > sky-install.done; } </dev/null >/dev/null 2>&1 &

disown -a
echo "[$(date -u +%H:%M:%S)] background jobs started: vllm-install, host-install, dstack-install, sky-install (logs: *-install.log)"
