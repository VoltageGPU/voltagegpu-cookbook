#!/usr/bin/env bash
# Same calls with curl. VOLTAGEGPU_API_KEY holds an AI Inference key (vgpu_...).
# PYTHON overrides the interpreter used to pretty-print the model list (default python3).
set -euo pipefail
BASE_URL="https://api.voltagegpu.com/v1"
MODEL="${1:-google/gemma-4-31B-turbo-TEE}"

echo "== GET /models (public): ids, live status"
curl -s "$BASE_URL/models" | "${PYTHON:-python3}" -c 'import sys,json; [print(m["id"], m["status"]["state"]) for m in json.load(sys.stdin)["data"]]'

echo; echo "== POST /chat/completions, with the VoltageGPU response headers"
curl -s -i "$BASE_URL/chat/completions" \
  -H "Authorization: Bearer $VOLTAGEGPU_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"What does a TEE protect, in plain words? One sentence.\"}],\"max_tokens\":80,\"temperature\":0.2}" \
  | tr -d '\r' | grep -iE '^(HTTP/|x-voltagegpu-|\{)'

echo; echo "== POST /chat/completions with stream: true (server-sent events, first chunks)"
curl -s -N "$BASE_URL/chat/completions" \
  -H "Authorization: Bearer $VOLTAGEGPU_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Count from one to five in words, then stop.\"}],\"max_tokens\":40,\"stream\":true}" \
  | head -n 6 || true   # head closes the pipe early, curl then reports 23: expected
