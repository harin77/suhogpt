#!/usr/bin/env bash
# Run a bigger "teacher" model on the same 3090 to generate Tanglish data (free, no API key).
# Uses a SEPARATE virtualenv so vLLM's torch version can't break Unsloth.
set -euo pipefail
export HF_HOME="$PWD/hf_cache"

TEACHER="${TEACHER_MODEL:-Qwen/Qwen2.5-14B-Instruct-AWQ}"

if [ ! -x vllm-env/bin/vllm ]; then
  echo "== Installing vLLM in ./vllm-env (one time) =="
  python -m venv vllm-env
  vllm-env/bin/pip install --upgrade pip
  vllm-env/bin/pip install vllm
fi

echo "== Serving $TEACHER on :8000 =="
exec vllm-env/bin/vllm serve "$TEACHER" \
  --max-model-len 4096 \
  --gpu-memory-utilization 0.92 \
  --max-num-seqs 32 \
  --port 8000
