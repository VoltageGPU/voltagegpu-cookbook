# vLLM inside a Confidential VM (the server runs, the generated text is not correct)

Goal: serve a small model with vLLM's OpenAI-compatible server **inside** the Intel TDX guest, bound to
`127.0.0.1:8000`, and query it from inside the guest with curl and the openai SDK. The VM is the one
rented by `../deploy-confidential-vm-api/deploy_and_attest.py`; `in-vm-vllm.sh` is passed to it with
`--script`, or run by hand:

```bash
ssh -p <port> ubuntu@<ip> 'BUDGET_SECONDS=720 bash -s' < in-vm-vllm.sh
```

What the script does: waits for the venv prepared by `../deploy-confidential-vm-api/in-vm-prepare.sh`
(`uv venv ~/vllm-venv && uv pip install vllm openai`) and for gcc and the Python headers (Triton
compiles a small C launcher at first use; the VM image ships neither), runs a PyTorch and Triton smoke
test on the GPU, starts `vllm serve Qwen/Qwen2.5-0.5B-Instruct --host 127.0.0.1 --port 8000
--max-model-len 4096 --gpu-memory-utilization 0.60 --enforce-eager`, prints the whole server log if
it fails (and retries with settings chosen from that log), then calls `/v1/models`,
`/v1/chat/completions` (plain and streaming) and the openai SDK.

## Status on 2026-10-23

**The server starts and answers the OpenAI-compatible API, but in both runs that reached a running
server the generated text was degenerate: 40 spaces (second run), then 40 em dashes and
"editor editor editor ..." (third run). That is not a correct answer from this model, so this is not
a working recipe yet.** The cause is not known; nothing here says whether it comes from the
confidential-computing mode, from a kernel on this GPU generation (compute capability 12.0) or from
this vLLM version. The PyTorch and Triton smoke test before it gave correct results both times.

### Third run (13:47 to 13:52 UTC), unedited log in [`output-2026-10-23-run3.txt`](output-2026-10-23-run3.txt)

Same model, `--gpu-memory-utilization 0.30 --max-model-len 2048 --enforce-eager`. Started in parallel
with the dstack and SkyPilot scripts, which stopped within 20 seconds (see their READMEs), so vLLM had
the VM to itself.

| Step | Status | Evidence |
|---|---|---|
| vLLM venv, gcc, smoke test | executed | same versions as the second run; fp16 matmul ok, pinned host to device 256 MiB ok, Triton kernel `sum = 2048.0` |
| `vllm serve` | executed, answering after 222 s | `FLASH_ATTN` (FlashAttention 2), FlashInfer sampler, `Available KV cache memory: 26.3 GiB` |
| `GET /v1/models` | executed | `[('Qwen/Qwen2.5-0.5B-Instruct', 2048)]` |
| `POST /v1/chat/completions` (curl, `temperature: 0`) | executed, **wrong output** | `"content":"————————————————————————————————————————"` (40 em dashes), `finish_reason: length`, 39 prompt and 40 completion tokens, answer after 47 s |
| Streaming | executed, **wrong output** | chunks `"content":"editor"` |
| openai SDK | executed, **wrong output** | `editor` repeated 30 times, `usage: 37 prompt + 30 completion tokens` |
| GPU memory while serving | executed | `29910 MiB, 97887 MiB` |
| Second model, `TinyLlama/TinyLlama-1.1B-Chat-v1.0 --dtype float16` | **not executed** | the script switched models only on a *blank* answer, and the dashes were not blank; and 206 s of budget remained, less than one vLLM start measured that day (191 s, 222 s) |

### Second run (13:26 to 13:31 UTC), unedited log in [`output-2026-10-23-run2.txt`](output-2026-10-23-run2.txt)

| Step | Status | Evidence |
|---|---|---|
| vLLM venv, gcc, Python headers | executed | `vllm 0.32.0`, `torch 2.13.0`, `triton 3.7.1`, `flashinfer-python 0.7.0.post1`, `gcc 13.3.0` |
| PyTorch and Triton smoke test on the GPU | executed | `capability (12, 0)`, fp16 matmul ok, pinned host to device 256 MiB ok (5.8 GB/s, first transfer, not a benchmark), Triton kernel ok (`sum = 2048.0`, the expected value) |
| `vllm serve` | executed, answering after 191 s | `Using FLASH_ATTN attention backend`, `Using FlashAttention version 2`, `Using FlashInfer for top-p & top-k sampling`, weights 0.93 GiB in 11 s, `Available KV cache memory: 54.76 GiB`, `Starting vLLM server on http://127.0.0.1:8000` |
| `GET /v1/models` | executed | `[('Qwen/Qwen2.5-0.5B-Instruct', 4096)]` |
| `POST /v1/chat/completions` (curl, `temperature: 0`) | executed, **wrong output** | HTTP answer in 46 s, `"content":"                                        "` (40 spaces), `finish_reason: length`, `completion_tokens: 40` |
| Streaming | executed, **wrong output** | chunks with `"content":" "` |
| openai SDK | executed, **wrong output** | empty text after `strip()`, `usage: 37 prompt + 30 completion tokens` |
| GPU memory while serving | executed | `59048 MiB, 97887 MiB` |

```text
[13:30:20] == POST /v1/chat/completions with curl
{"id":"chatcmpl-ac35c190f0c3d47e","object":"chat.completion","created":1792762220,"model":"Qwen/Qwen2.5-0.5B-Instruct","choices":[{"index":0,"message":{"role":"assistant","content":"                                        ","refusal":null,...},"finish_reason":"length",...}],...,"usage":{"prompt_tokens":39,"total_tokens":79,"completion_tokens":40,...}}
[13:31:06] == POST /v1/chat/completions with stream: true (first chunks)
data: {...,"choices":[{"index":0,"delta":{"role":"assistant","content":""},...}]}
data: {...,"choices":[{"index":0,"delta":{"content":" "},...}]}
data: {...,"choices":[{"index":0,"delta":{"content":" "},...}]}
[13:31:07] == the openai SDK against the local server

usage: 37 prompt + 30 completion tokens
```

### First run (11:57 to 12:12 UTC), log in [`output-2026-10-23.txt`](output-2026-10-23.txt)

Same install, but without gcc on the VM: `vllm serve` failed with `RuntimeError: Engine core
initialization failed`, and the script kept only the last 30 lines of the server log, so the root
cause was not captured. With gcc and the Python headers installed, the second run started; the missing
compiler is therefore the likely cause of the first failure, not a proven one.

### Next run (prepared, not executed)

`in-vm-vllm.sh` now flags a *degenerate* answer (blank, or one or two words or characters repeated;
checked locally on the three outputs above), then restarts once with
`TinyLlama/TinyLlama-1.1B-Chat-v1.0 --dtype float16`, and if that is degenerate too, once more with
`VLLM_USE_FLASHINFER_SAMPLER=0 VLLM_ATTENTION_BACKEND=TRITON_ATTN`. That needs about ten minutes of VM
for the three starts. Comparing with the same model on a GPU outside confidential-computing mode would
separate the remaining explanations. None of this has been run.
