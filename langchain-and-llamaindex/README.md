# LangChain and LlamaIndex on VoltageGPU's OpenAI-compatible endpoint

Both frameworks have an OpenAI client that accepts a custom base URL. Point it at
`https://api.voltagegpu.com/v1`, pass an **AI Inference** key (`vgpu_...`, from
<https://voltagegpu.com/api-keys>) and a `-TEE` model id from `GET /v1/models`. Nothing else changes.

| Framework | Class | Where the base URL goes |
|---|---|---|
| LangChain (`langchain-openai`) | `ChatOpenAI` | `base_url=` |
| LlamaIndex (`llama-index-llms-openai-like`) | `OpenAILike` | `api_base=`; also set `is_chat_model=True` and `context_window` (the class makes no assumption about a non-OpenAI model id) |

The examples use `google/gemma-4-31B-turbo-TEE`, which answers directly. Thinking models such as
`Qwen/Qwen3-32B-TEE` return their reasoning in `reasoning_content`, which these two clients expose
through `additional_kwargs` / `raw` rather than in the visible content.

## Files

* `langchain_chat.py`: `invoke` with a system and a human message, then `stream`.
* `llamaindex_chat.py`: `chat` with `ChatMessage`s, then `stream_chat`.

## Run

```bash
pip install langchain-openai llama-index-llms-openai-like
export VOLTAGEGPU_API_KEY=vgpu_...
python langchain_chat.py
python llamaindex_chat.py
```

## Executed on 2026-10-23

Environment: Windows 11, Python 3.12.4, langchain-openai 1.7.2, langchain-core 1.7.0,
llama-index-core 0.14.25, llama-index-llms-openai-like 0.8.1. Unedited output, also in
[`output-2026-10-23.txt`](output-2026-10-23.txt). The LangChain call cost 0.000023 $
(`estimated_cost` in the usage block).

```text
### python langchain_chat.py  (langchain-openai 1.7.2, langchain-core 1.7.0, Python 3.12.4, 2026-10-23T11:38Z)
== invoke
It ensures that sensitive model weights and user data remain encrypted and inaccessible to the cloud provider or unauthorized administrators.
model: google/gemma-4-31B-turbo-TEE | usage: {'completion_tokens': 22, 'prompt_tokens': 36, 'total_tokens': 58, 'completion_tokens_details': None, 'prompt_tokens_details': {'audio_tokens': None, 'cache_write_tokens': None, 'cached_tokens': 5}, 'reasoning_tokens': 0, 'estimated_cost': 2.3e-05}

== stream
One, two, three, four, five.
exit 0

### python llamaindex_chat.py  (llama-index-core 0.14.25, llama-index-llms-openai-like 0.8.1, 2026-10-23T11:39Z)
== chat
It ensures that the model weights and user data remain encrypted and inaccessible to the cloud provider during processing.
usage: 36 prompt + 21 completion tokens

== stream_chat
One, two, three, four, five.
exit 0
```

The sentences above are the model's answers, not VoltageGPU's claims. What the platform itself
states about confidential inference, and its limits, is in the OpenAPI description
(<https://voltagegpu.com/openapi-voltagegpu.yaml>, section "Inference reliability and verification").
