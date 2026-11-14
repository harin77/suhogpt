#!/usr/bin/env bash
# One-time setup on the rented GPU. Run from the project folder.
set -euo pipefail

nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv

export HF_HOME="$PWD/hf_cache"   # keep model downloads on the persistent volume

if command -v apt-get >/dev/null; then
  SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO=sudo
  $SUDO apt-get update -y && $SUDO apt-get install -y build-essential cmake curl libcurl4-openssl-dev git tmux
fi

pip install --upgrade pip
pip install unsloth
pip install datasets openai

python - <<'EOF'
import torch
print("torch", torch.__version__, "| CUDA:", torch.cuda.is_available(), "|", torch.cuda.get_device_name(0))
import unsloth; print("unsloth OK")
EOF
echo "✅ Setup done"
