#!/bin/bash
set -euo pipefail

base_url="${OLLAMA_PROXY_URL:-http://127.0.0.1:11435}"
model="${1:-llama3.2}"
runs="${2:-5}"
prompt="${BENCHMARK_PROMPT:-Explain why the sky is blue in approximately 150 words.}"
label="${BENCHMARK_LABEL:-standard-150-word}"

echo "Benchmarking $model: $runs runs through $base_url"
for ((run = 1; run <= runs; run++)); do
    curl --fail --silent --show-error "$base_url/api/generate" \
        -H 'Content-Type: application/json' \
        -H "X-Ollama-Benchmark-Label: $label" \
        -d "$(MODEL="$model" PROMPT="$prompt" python3 -c 'import json,os; print(json.dumps({"model":os.environ["MODEL"],"prompt":os.environ["PROMPT"],"stream":True,"options":{"temperature":0,"seed":42}}))')" \
        >/dev/null
    echo "  completed $run/$runs"
done

echo
curl --fail --silent --show-error "$base_url/benchmarks"
echo
