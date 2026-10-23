# vLLM inside a Confidential VM (partially executed)

Goal: serve a small model with vLLM's OpenAI-compatible server **inside** the Intel TDX guest, bound to
`127.0.0.1:8000`, and query it from inside the guest with curl and the openai SDK. The VM is the one
rented by `../deploy-confidential-vm-api/deploy_and_attest.py`; `in-vm-vllm.sh` is passed to it with
`--script`, or run by hand:

```bash
ssh -p <port> ubuntu@<ip> 'BUDGET_SECONDS=900 bash -s' < in-vm-vllm.sh
```

The script waits for the venv prepared by `../deploy-confidential-vm-api/in-vm-prepare.sh`
(`uv venv ~/vllm-venv && uv pip install vllm openai`), prints the GPU as the guest sees it, starts
`vllm serve Qwen/Qwen2.5-0.5B-Instruct --host 127.0.0.1 --port 8000 --max-model-len 4096
--gpu-memory-utilization 0.60 --enforce-eager`, then calls `/v1/models` and `/v1/chat/completions`.

## Executed on 2026-10-23, and what was not

VM: `rtx6000b-small`, Ubuntu 24.04.4, driver 595.71.05, CUDA 13.2 (driver side). Unedited log in
[`output-2026-10-23.txt`](output-2026-10-23.txt) (times UTC).

| Step | Status | Evidence |
|---|---|---|
| `uv pip install vllm openai` in a fresh venv | **executed**, finished in under 51 s (started 11:56:34, done before 11:57:25) | `vllm-install exit 0` |
| GPU seen from the guest | **executed** | `NVIDIA RTX PRO 6000 Blackwell Server Edition, 595.71.05, 97887 MiB`, `CC State: ON`, `CC GPUs Ready State: Ready` |
| Import and device check | **executed** | `vllm 0.32.0 \| torch 2.13.0+cu130 \| cuda 13.0 \| NVIDIA RTX PRO 6000 Blackwell Server Edition` |
| `vllm serve Qwen/Qwen2.5-0.5B-Instruct ...` | **failed**: `RuntimeError: Engine core initialization failed. See root cause above. Failed core proc(s): {}` | tail of `vllm-serve.log`, below |
| `GET /v1/models`, `POST /v1/chat/completions` (curl), openai SDK against the local server | **not executed** (server never answered) | |

```text
[11:57:25] == GPU as seen from the guest
name, driver_version, memory.total [MiB], memory.used [MiB]
NVIDIA RTX PRO 6000 Blackwell Server Edition, 595.71.05, 97887 MiB, 0 MiB
    CC State                   : ON
    Multi-GPU Mode             : None
    CC GPUs Ready State        : Ready
[11:57:25] == waiting for the vLLM install (vllm-install.done)
[11:57:25] vLLM install exit 0 after 0 s of waiting here
vllm 0.32.0 | torch 2.13.0+cu130 | cuda 13.0 | NVIDIA RTX PRO 6000 Blackwell Server Edition
[11:57:41] == vllm serve Qwen/Qwen2.5-0.5B-Instruct (model download, then startup)
[12:12:27] vLLM did not come up within the budget: the queries below were NOT EXECUTED
  ...
  File ".../vllm/v1/engine/utils.py", line 1431, in wait_for_engine_startup
    raise RuntimeError(
RuntimeError: Engine core initialization failed. See root cause above. Failed core proc(s): {}
```

**The root cause is not known.** The script of that day kept only the last 30 lines of
`vllm-serve.log`, and the "root cause above" was not among them; the VM was released before the full
log could be read. Nothing here says whether the failure is specific to the confidential-computing
mode of the GPU, to this driver and CUDA 13.0 wheel pairing, or to the model; that is unverified.
The script was changed afterwards so that the next run (a) exits as soon as the `vllm serve` process
dies instead of waiting for the budget, and (b) prints the whole server log. Until that run exists,
this example documents an attempt, not a working recipe.
