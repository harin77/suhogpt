#!/usr/bin/env bash
# Full pipeline in one go (≈ 3 h on an RTX 3090). Run inside tmux or with nohup:
#   nohup bash run_all.sh > run.log 2>&1 &
# Every step is resumable: re-running skips work that's already done.
set -euo pipefail
export HF_HOME="$PWD/hf_cache"
TRANSLATE_N="${TRANSLATE_N:-2500}"
LINUX_N="${LINUX_N:-2500}"
FRESH_N="${FRESH_N:-800}"
GEN_MINUTES="${GEN_MINUTES:-100}"   # hard time budget for data generation (booking ends at 05:00)

echo "[0/6] Setup  $(date)"
[ -f .setup_done ] || { bash setup.sh && touch .setup_done; }

echo "[1/6] Download English datasets  $(date)"
[ -s data/english_pool.jsonl ] || python build_dataset.py pool

if [ ! -f .gen_done ]; then
  if [ -z "${TEACHER_BASE_URL:-}" ]; then
    echo "[2/6] Start local teacher model  $(date)"
    bash serve_teacher.sh > teacher.log 2>&1 &
    TEACHER_PID=$!
    echo -n "waiting for teacher to load"
    until curl -s localhost:8000/v1/models >/dev/null; do
      if ! kill -0 $TEACHER_PID 2>/dev/null; then echo; echo "❌ teacher failed, see teacher.log"; tail -30 teacher.log; exit 1; fi
      echo -n "."; sleep 10
    done; echo " ready"
  fi

  echo "[3/6] Generate Tanglish data  $(date)"
  END=$(( $(date +%s) + GEN_MINUTES*60 ))
  left() { echo $(( END - $(date +%s) )); }
  timeout $(( $(left) * 40/100 ))s python generate_tanglish.py linux --n "$LINUX_N" || true
  timeout $(( $(left) * 80/100 ))s python generate_tanglish.py translate --n "$TRANSLATE_N" || true
  [ "$(left)" -gt 120 ] && { timeout "$(left)"s python generate_tanglish.py fresh --n "$FRESH_N" || true; }
  echo "generated: $(wc -l < data/tanglish_generated.jsonl) examples"
  touch .gen_done

  if [ -n "${TEACHER_PID:-}" ]; then
    echo "Stopping teacher to free the GPU"
    pkill -f "vllm serve" || true; sleep 20
  fi
fi

echo "[4/6] Build final dataset  $(date)"
python build_dataset.py final

echo "[5/6] Train + export  $(date)"
if [ -f outputs/lora/adapter_config.json ]; then python train.py --export-only; else python train.py; fi

echo "[6/6] Quick evaluation  $(date)"
python chat.py --eval | tee eval.log || true

echo "✅ ALL DONE $(date)"
ls -lh outputs/gguf/
touch .all_done
