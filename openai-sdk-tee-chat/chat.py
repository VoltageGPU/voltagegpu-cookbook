"""Chat with a confidential (-TEE) model on VoltageGPU through the official openai SDK.

The API is OpenAI-compatible: only the base URL and the key change.
  export VOLTAGEGPU_API_KEY=vgpu_...   # an AI Inference key from https://voltagegpu.com/api-keys
  python chat.py [model]              # default: google/gemma-4-31B-turbo-TEE
"""
import os
import sys

from openai import OpenAI

BASE_URL = "https://api.voltagegpu.com/v1"
MODEL = sys.argv[1] if len(sys.argv) > 1 else "google/gemma-4-31B-turbo-TEE"

client = OpenAI(base_url=BASE_URL, api_key=os.environ["VOLTAGEGPU_API_KEY"])

# 1. The catalogue: every id ends in -TEE and carries a live status and a price per million tokens.
print("== models")
for m in client.models.list().data:
    d = m.to_dict()
    status = d.get("status", {}).get("state", "?")
    price = d.get("pricing", {})
    print(f"{d['id']:45} {status:12} ${price.get('prompt')}/M in, ${price.get('completion')}/M out")

# 2. One completion. with_raw_response exposes the headers VoltageGPU adds to every answer:
#    the model that actually ran (and was billed), the retries, the cost of this call.
print(f"\n== chat.completions.create (model {MODEL})")
raw = client.chat.completions.with_raw_response.create(
    model=MODEL,
    messages=[
        {"role": "system", "content": "You answer in one short sentence."},
        {"role": "user", "content": "What does a TEE protect, in plain words?"},
    ],
    max_tokens=80,
    temperature=0.2,
    # Optional: other confidential models to try, in order, if this one is saturated (429/503 upstream).
    extra_body={"fallback_models": ["Qwen/Qwen3.8-27B-TEE"]},
)
completion = raw.parse()
for header in ("x-voltagegpu-model", "x-voltagegpu-confidential", "x-voltagegpu-retries", "x-voltagegpu-cost-usd"):
    print(f"{header}: {raw.headers.get(header)}")
print("answer:", completion.choices[0].message.content.strip())
print("usage:", completion.usage.prompt_tokens, "prompt +", completion.usage.completion_tokens, "completion tokens")

# 3. Streaming: the same call with stream=True yields chunks as the model produces them.
print(f"\n== streaming (model {MODEL})")
stream = client.chat.completions.create(
    model=MODEL,
    messages=[{"role": "user", "content": "Count from one to five in words, then stop."}],
    max_tokens=40,
    stream=True,
)
for chunk in stream:
    if chunk.choices and chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
print()
