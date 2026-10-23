# VoltageGPU Cookbook

Runnable examples for [VoltageGPU](https://voltagegpu.com), the confidential AI infrastructure:
confidential inference through an OpenAI-compatible API (models with the `-TEE` suffix run in Intel
TDX guests with confidential-computing NVIDIA GPUs), and Confidential VMs you rent by the second and
can attest yourself with Intel's and NVIDIA's hardware evidence.

Every example in this repository was **executed for real**, and each folder keeps the unedited output
of that run with its date and tool versions (`output-<date>.txt`). When a step did not run, the README
of the folder says so, step by step, instead of showing an expected output.

| Folder | What it shows | Status on 2026-10-23 |
|---|---|---|
| [`openai-sdk-tee-chat/`](openai-sdk-tee-chat/) | The openai SDK and curl against `https://api.voltagegpu.com/v1`: model list with live status and prices, a completion with the `X-VoltageGPU-*` headers, streaming | executed, output in the README |
| [`litellm-proxy/`](litellm-proxy/) | LiteLLM proxy with VoltageGPU declared as an `openai/` provider, queried with curl and the SDK | executed |
| [`langchain-and-llamaindex/`](langchain-and-llamaindex/) | `ChatOpenAI(base_url=...)` and `OpenAILike(api_base=...)`, invoke and stream | executed |
| [`verify-attestation-notebook/`](verify-attestation-notebook/) | Jupyter notebook: download a published evidence bundle, verify it offline with voltage-verify 0.2.3, read every check, break it on purpose, what it does not prove | executed, outputs inside the notebook |
| [`deploy-confidential-vm-api/`](deploy-confidential-vm-api/) | One Confidential VM through the public API (`rtx6000b-small`), SSH, `nvidia-smi`, the two proofs on a challenge drawn locally, stop in a `finally`, billing read back, offline verification | executed three times (1134 s for 1.18 $, 489 s for 0.50 $, 516 s for 0.53 $ net), `RESULT: VERIFIED` on both attested runs; the first bundle is in `evidence-2026-10-23/` |
| [`vllm-in-tee/`](vllm-in-tee/) | vLLM serving a small model inside the VM, queried on the OpenAI-compatible port | the server runs and answers `/v1/models`, chat completions, streaming and the openai SDK, but the generated text is degenerate (spaces, then dashes and a repeated word); cause not known; a second model was not tried |
| [`dstack-ssh-fleet/`](dstack-ssh-fleet/) | The VM as a host of a dstack SSH fleet | partial: Docker, NVIDIA Container Toolkit, the GPU from a container, the dstack server, and SSH into the VM with passwordless sudo all work; fleet and task not executed because of a bug in the test script (fixed, not rerun) |
| [`skypilot/`](skypilot/) | The VM as a node of a SkyPilot SSH Node Pool | partial: install and node prerequisites ok; `sky ssh up` and `sky launch` not executed, same test-script bug |

## Before you start

Two kinds of API keys exist, both created at <https://voltagegpu.com/api-keys>:

| Key | Prefix | Header | Used by |
|---|---|---|---|
| AI Inference | `vgpu_` | `Authorization: Bearer` on `https://api.voltagegpu.com/v1/...` | examples 1 to 3 |
| GPU Pods | `volt_` | `X-API-Key` on `https://api.voltagegpu.com/api/volt/...` and `/api/confidential/...` | example 5 (and the three that run on its VM) |

The examples read them from the environment (`VOLTAGEGPU_API_KEY`, `VOLTAGEGPU_VOLT_API_KEY`) and
never write them anywhere. Inference is billed per token (prices per model in `GET /v1/models`; the
calls in this repository cost well under a cent). A Confidential VM is billed per second from a prepaid
hour (3.80 $/h for `rtx6000b-small` on 2026-10-23); the deploy example stops its VM in a `finally`
block, with a watchdog and the API's own hard stop behind it.

```bash
python -m venv .venv && . .venv/bin/activate       # Windows: .venv\Scripts\activate
pip install openai "litellm[proxy]" langchain-openai llama-index-llms-openai-like jupyter "voltage-verify==0.2.3"
export VOLTAGEGPU_API_KEY=vgpu_...
export VOLTAGEGPU_VOLT_API_KEY=volt_...
```

Reference: the OpenAPI document <https://voltagegpu.com/openapi-voltagegpu.yaml>, the docs at
<https://docs.voltagegpu.com>, the verifier <https://github.com/VoltageGPU/voltage-verify>.

## What the attestation examples do and do not show

A verified bundle shows that an Intel TDX quote and NVIDIA GPU attestation tokens were produced for
the manifest you wrote, after the challenge you drew, by genuine Intel and NVIDIA hardware at a TCB
level Intel accepts. It does not show that the GPU executed a given image or model, nor anything about
the guest's software beyond the printed `MRTD` and `RTMR` values; see
`verify-attestation-notebook/` (section 7) which quotes voltage-verify's `WHAT_IT_PROVES.md`. For the
inference API, `GET /v1/attestation` returns the evidence of a model's running instances bound to your
nonce; it does not prove which instance served a given response.

## License

MIT, see [`LICENSE`](LICENSE). The evidence bundles are public data from the runs described.
