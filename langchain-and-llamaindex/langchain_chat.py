"""LangChain against VoltageGPU's OpenAI-compatible endpoint: ChatOpenAI with a custom base_url.

  export VOLTAGEGPU_API_KEY=vgpu_...   # AI Inference key, https://voltagegpu.com/api-keys
  python langchain_chat.py [model]
"""
import os
import sys

from langchain_openai import ChatOpenAI

BASE_URL = "https://api.voltagegpu.com/v1"
MODEL = sys.argv[1] if len(sys.argv) > 1 else "google/gemma-4-31B-turbo-TEE"

llm = ChatOpenAI(
    model=MODEL,
    base_url=BASE_URL,
    api_key=os.environ["VOLTAGEGPU_API_KEY"],
    temperature=0.2,
    max_tokens=80,
)

print("== invoke")
answer = llm.invoke([
    ("system", "You answer in one short sentence."),
    ("human", "Why does a confidential VM matter for an inference API?"),
])
print(answer.content.strip())
meta = answer.response_metadata
print("model:", meta.get("model_name"), "| usage:", meta.get("token_usage"))

print("\n== stream")
for chunk in llm.stream("Count from one to five in words, then stop."):
    print(chunk.content, end="", flush=True)
print()
