# LiteLLM proxy in front of VoltageGPU

[LiteLLM](https://docs.litellm.ai/) is an OpenAI-compatible gateway: your applications call one local
endpoint with short aliases, and the proxy forwards to the providers listed in its config. VoltageGPU
is declared as an `openai/` provider with a custom `api_base`, so no VoltageGPU-specific plugin is
needed. The VoltageGPU key stays on the proxy host; clients only hold the proxy's master key.

## Files

* `config.yaml`: three aliases (`gemma-4-tee`, `qwen3-32b-tee`, `deepseek-v3.2-tee`) mapped to
  `openai/<VoltageGPU model id>` with `api_base: https://api.voltagegpu.com/v1`. Keys are read from
  environment variables (`os.environ/...`), nothing secret is in the file.
* `run.sh`: starts the proxy on `127.0.0.1:4000`, waits for `/health/readiness`, queries it with curl
  and with `query.py`, stops it.
* `query.py`: the openai SDK against the proxy (model list, one completion with LiteLLM's response
  headers, one streamed completion).

## Run

```bash
pip install "litellm[proxy]" openai
export VOLTAGEGPU_API_KEY=vgpu_...                  # AI Inference key, https://voltagegpu.com/api-keys
export LITELLM_MASTER_KEY="sk-$(openssl rand -hex 16)"   # what your apps use to reach the proxy
bash run.sh
# or by hand:
litellm --config config.yaml --port 4000 --host 127.0.0.1
```

Then any OpenAI client works with `base_url=http://127.0.0.1:4000` and `api_key=$LITELLM_MASTER_KEY`,
and `model="gemma-4-tee"`.

Notes:

* `drop_params: true` makes the proxy drop OpenAI-only request parameters instead of failing.
* VoltageGPU's own headers (`X-VoltageGPU-Model`, `X-VoltageGPU-Cost-USD`) are on the upstream answer
  and are not forwarded by LiteLLM; the proxy adds its own (`x-litellm-model-id`,
  `x-litellm-model-api-base`). Its `x-litellm-response-cost` needs a price entry for the model in
  LiteLLM's table, which VoltageGPU models do not have, so it is absent here. Read `GET /v1/models` on
  VoltageGPU for the prices actually charged.
* On Windows the proxy needs `PYTHONUTF8=1` (its startup banner is Unicode); `run.sh` sets it.

## Executed on 2026-10-23

Environment: Windows 11, Python 3.12.4, litellm 1.106.2, openai 2.54.0. Unedited output, also in
[`output-2026-10-23.txt`](output-2026-10-23.txt).

```text
### bash run.sh  (litellm 1.106.2, openai 2.54.0, Python 3.12.4, Windows 11, 2026-10-23T12:02Z)
== litellm 1.106.2
== GET /health/readiness
{"status":"healthy","db":"Not connected"}

== GET /v1/models (the aliases of config.yaml)
['deepseek-v3.2-tee', 'gemma-4-tee', 'qwen3-32b-tee']

== POST /v1/chat/completions through the proxy (curl)
gemma-4-tee | Hello, how are you today? | 27 tokens

== python query.py (openai SDK against the proxy)
== models the proxy exposes
['deepseek-v3.2-tee', 'gemma-4-tee', 'qwen3-32b-tee']

== chat.completions.create (alias gemma-4-tee)
answer: Remote attestation is a process where a device provides a cryptographically signed proof of its current hardware and software configuration to a remote party to verify that the system is trusted and has not been compromised.
model reported by the upstream: gemma-4-tee
usage: 23 prompt + 40 completion tokens
x-litellm-model-id: 74be382119b0b914845b07ce988a8fcabd7e428882c545e230f25e11abe637a2
x-litellm-model-api-base: https://api.voltagegpu.com/v1

== streaming (alias gemma-4-tee)
One, two, three, four, five.

== proxy stopped; last log lines (no key is ever printed by the proxy at this log level):
INFO:     127.0.0.1:59402 - "GET /models HTTP/1.1" 200 OK
INFO:     127.0.0.1:59402 - "POST /chat/completions HTTP/1.1" 200 OK
INFO:     127.0.0.1:59402 - "POST /chat/completions HTTP/1.1" 200 OK
exit 0
```

`"db": "Not connected"` is expected: this configuration runs the proxy without its optional database
(virtual keys, spend tracking), which is a separate setup in LiteLLM's documentation.
