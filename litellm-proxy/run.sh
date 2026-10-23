#!/usr/bin/env bash
# Starts the LiteLLM proxy on port 4000 with config.yaml, queries it with curl and with query.py,
# then stops it. Needs: pip install "litellm[proxy]" openai, VOLTAGEGPU_API_KEY (vgpu_...) and
# LITELLM_MASTER_KEY (any secret you choose, e.g. sk-$(openssl rand -hex 16)) in the environment.
set -uo pipefail
cd "$(dirname "$0")"
LITELLM="${LITELLM:-litellm}"
PYTHON="${PYTHON:-python3}"
PORT=4000
export PYTHONUTF8=1   # the proxy prints a Unicode banner; Windows consoles default to a legacy code page

echo "== litellm $("$PYTHON" -c "import importlib.metadata as m; print(m.version('litellm'))")"
"$LITELLM" --config config.yaml --port $PORT --host 127.0.0.1 > litellm-proxy.log 2>&1 &
PROXY_PID=$!
for _ in $(seq 1 60); do
  curl -sf "http://127.0.0.1:$PORT/health/readiness" >/dev/null 2>&1 && break
  sleep 2
done
echo "== GET /health/readiness"
curl -s "http://127.0.0.1:$PORT/health/readiness"; echo

echo; echo "== GET /v1/models (the aliases of config.yaml)"
curl -s "http://127.0.0.1:$PORT/v1/models" -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  | "$PYTHON" -c 'import sys,json; print(sorted(m["id"] for m in json.load(sys.stdin)["data"]))'

echo; echo "== POST /v1/chat/completions through the proxy (curl)"
curl -s "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"model":"gemma-4-tee","messages":[{"role":"user","content":"Say hello in five words."}],"max_tokens":20}' \
  | "$PYTHON" -c 'import sys,json; d=json.load(sys.stdin); print(d["model"], "|", d["choices"][0]["message"]["content"].strip(), "|", d["usage"]["total_tokens"], "tokens")'

echo; echo "== python query.py (openai SDK against the proxy)"
"$PYTHON" query.py

kill $PROXY_PID 2>/dev/null
wait $PROXY_PID 2>/dev/null
echo; echo "== proxy stopped; last log lines (no key is ever printed by the proxy at this log level):"
grep -v "^$" litellm-proxy.log | tail -3
