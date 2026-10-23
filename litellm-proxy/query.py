"""Talk to the LiteLLM proxy (which forwards to VoltageGPU) with the openai SDK.

The application only knows the proxy's address and the proxy's master key; the VoltageGPU key
stays on the proxy host.

  export LITELLM_MASTER_KEY=sk-...        # the same value the proxy was started with
  python query.py [alias]                 # default alias: gemma-4-tee
"""
import os
import sys

from openai import OpenAI

PROXY = os.environ.get("LITELLM_PROXY_URL", "http://127.0.0.1:4000")
ALIAS = sys.argv[1] if len(sys.argv) > 1 else "gemma-4-tee"

client = OpenAI(base_url=PROXY, api_key=os.environ["LITELLM_MASTER_KEY"])

print("== models the proxy exposes")
print(sorted(m.id for m in client.models.list().data))

print(f"\n== chat.completions.create (alias {ALIAS})")
raw = client.chat.completions.with_raw_response.create(
    model=ALIAS,
    messages=[{"role": "user", "content": "In one sentence, what is remote attestation?"}],
    max_tokens=80,
    temperature=0.2,
)
completion = raw.parse()
print("answer:", completion.choices[0].message.content.strip())
print("model reported by the upstream:", completion.model)
print("usage:", completion.usage.prompt_tokens, "prompt +", completion.usage.completion_tokens, "completion tokens")
# LiteLLM adds its own headers: the deployment it picked and the cost it computed from its price table
# (VoltageGPU's own cost is in x-voltagegpu-cost-usd on the upstream answer, not forwarded here).
for header in ("x-litellm-model-id", "x-litellm-response-cost", "x-litellm-model-api-base"):
    if raw.headers.get(header):
        print(f"{header}: {raw.headers.get(header)}")

print(f"\n== streaming (alias {ALIAS})")
for chunk in client.chat.completions.create(
    model=ALIAS,
    messages=[{"role": "user", "content": "Count from one to five in words, then stop."}],
    max_tokens=40,
    stream=True,
):
    if chunk.choices and chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
print()
