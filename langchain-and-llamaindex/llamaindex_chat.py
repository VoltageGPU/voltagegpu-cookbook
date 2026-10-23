"""LlamaIndex against VoltageGPU's OpenAI-compatible endpoint: OpenAILike with a custom api_base.

OpenAILike (llama-index-llms-openai-like) is the class for any OpenAI-compatible server whose model
ids are not in OpenAI's catalogue; it does not guess the context window or chat support, so set them.

  export VOLTAGEGPU_API_KEY=vgpu_...   # AI Inference key, https://voltagegpu.com/api-keys
  python llamaindex_chat.py [model]
"""
import os
import sys

from llama_index.core.llms import ChatMessage
from llama_index.llms.openai_like import OpenAILike

BASE_URL = "https://api.voltagegpu.com/v1"
MODEL = sys.argv[1] if len(sys.argv) > 1 else "google/gemma-4-31B-turbo-TEE"

llm = OpenAILike(
    model=MODEL,
    api_base=BASE_URL,
    api_key=os.environ["VOLTAGEGPU_API_KEY"],
    is_chat_model=True,
    is_function_calling_model=False,
    context_window=131072,  # GET /models reports context_length per model
    max_tokens=80,
    temperature=0.2,
)

print("== chat")
response = llm.chat([
    ChatMessage(role="system", content="You answer in one short sentence."),
    ChatMessage(role="user", content="Why does a confidential VM matter for an inference API?"),
])
print(response.message.content.strip())
usage = getattr(response.raw, "usage", None)
print("usage:", usage.prompt_tokens, "prompt +", usage.completion_tokens, "completion tokens") if usage else None

print("\n== stream_chat")
for chunk in llm.stream_chat([ChatMessage(role="user", content="Count from one to five in words, then stop.")]):
    print(chunk.delta, end="", flush=True)
print()
