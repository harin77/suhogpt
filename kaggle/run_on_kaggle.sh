#!/usr/bin/env bash
# Full pipeline tuned for Kaggle's free 2× Tesla T4 (16 GB each). Runs inside the Kaggle kernel.
#   - teacher: Qwen2.5-14B-Instruct-AWQ on both T4s (vLLM 0.8.5, tensor parallel 2, fp16)
#   - student: Qwen2.5-3B-Instruct, QLoRA on one T4
# Heavy files live in /tmp; only the final model + logs go to /kaggle/working (kept as kernel output).
set -uo pipefail
cd "$(dirname "$0")"
export HF_HOME=/tmp/hf_cache
export TOKENIZERS_PARALLELISM=false
OUT=/kaggle/working
TRANSLATE_N="${TRANSLATE_N:-3000}"
LINUX_N="${LINUX_N:-3500}"
FRESH_N="${FRESH_N:-1500}"
GEN_MINUTES="${GEN_MINUTES:-260}"     # hard time budget for the whole data-generation stage
T0=$(date +%s)
log() { echo "[$(( ($(date +%s)-T0)/60 )) min] $*"; }

nvidia-smi --query-gpu=index,name,memory.total --format=csv

log "1/7 install student libs"
pip install -q unsloth datasets openai 2>&1 | tail -2
python -c "import torch,unsloth;print('torch',torch.__version__,'gpus',torch.cuda.device_count())" || exit 1

log "2/7 download English datasets"
python build_dataset.py pool || exit 1

log "3/7 install + start teacher (vLLM in its own venv)"
pip install -q uv 2>&1 | tail -1
# vLLM 0.8.5 (last version with good T4 support) ships wheels only up to Python 3.12 -> give it its own 3.12.
# env -u PYTHONPATH keeps Kaggle's sitecustomize hooks out of the teacher's Python.
uv python install 3.12 2>&1 | tail -1
env -u PYTHONPATH uv venv -q --seed --python 3.12 /tmp/vllm-env || { log "uv venv failed"; exit 1; }
env -u PYTHONPATH uv pip install -q --python /tmp/vllm-env/bin/python "vllm==0.8.5.post1" "transformers==4.51.3" 2>&1 | tail -5
env -u PYTHONPATH /tmp/vllm-env/bin/python -c "import vllm; print('vllm', vllm.__version__)" || { log "❌ vllm import failed"; exit 1; }
# Teacher: biggest model that fits 2x T4 first (best Tanglish), smaller one as fallback.
TP=""
for TEACHER in Qwen/Qwen2.5-32B-Instruct-AWQ Qwen/Qwen2.5-14B-Instruct-AWQ; do
  log "starting teacher $TEACHER"
  env -u PYTHONPATH VLLM_USE_V1=0 /tmp/vllm-env/bin/vllm serve "$TEACHER" \
    --tensor-parallel-size 2 --dtype half --quantization awq \
    --max-model-len 4096 --gpu-memory-utilization 0.93 --max-num-seqs 24 --port 8000 \
    > /tmp/teacher.log 2>&1 &
  TP=$!
  for i in $(seq 1 150); do
    curl -s localhost:8000/v1/models >/dev/null && break
    kill -0 $TP 2>/dev/null || break
    sleep 10
  done
  if curl -s localhost:8000/v1/models >/dev/null; then export TEACHER_MODEL="$TEACHER"; log "✅ teacher ready: $TEACHER"; break; fi
  log "teacher $TEACHER failed to load:"; tail -25 /tmp/teacher.log; cp /tmp/teacher.log $OUT/teacher_$(basename $TEACHER).log
  kill $TP 2>/dev/null; pkill -f "vllm serve"; sleep 15
done

if curl -s localhost:8000/v1/models >/dev/null; then
  log "4/7 generate Tanglish data (budget ${GEN_MINUTES} min)"
  END=$(( $(date +%s) + GEN_MINUTES*60 ))
  left() { echo $(( (END-$(date +%s))/60 )); }
  timeout $(( $(left)*60 * 35/100 ))s python generate_tanglish.py linux --n "$LINUX_N" --workers 24
  timeout $(( $(left)*60 * 75/100 ))s python generate_tanglish.py translate --n "$TRANSLATE_N" --workers 24
  [ "$(left)" -gt 3 ] && timeout $(( $(left)*60 ))s python generate_tanglish.py fresh --n "$FRESH_N" --workers 24
  log "generated: $(wc -l < data/tanglish_generated.jsonl 2>/dev/null || echo 0) examples"
else
  log "❌ teacher unavailable – stopping instead of training a weak model"; tail -60 /tmp/teacher.log; cp /tmp/teacher.log $OUT/ 2>/dev/null; exit 1
fi
kill $TP 2>/dev/null; pkill -f "vllm serve" ; sleep 20
cp data/tanglish_generated.jsonl $OUT/ 2>/dev/null

log "5/7 build final dataset"
python build_dataset.py final || exit 1

log "6/7 train (QLoRA, T4 = fp16) + export GGUF"
CUDA_VISIBLE_DEVICES=0 python train.py --load-4bit --batch 2 --grad-accum 8 --epochs 2 || exit 1

log "7/7 eval"
CUDA_VISIBLE_DEVICES=0 timeout 20m python chat.py --eval > $OUT/eval.log 2>&1

mkdir -p $OUT/model
cp outputs/gguf/*.gguf outputs/gguf/Modelfile $OUT/model/ 2>/dev/null
tar -czf $OUT/lora.tar.gz -C outputs lora
ls -lh $OUT/model
log "✅ ALL DONE"
