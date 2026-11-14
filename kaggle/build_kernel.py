"""
Pack the project into a single Kaggle script kernel and write kernel-metadata.json.

  python kaggle/build_kernel.py <kaggle_username>
  kaggle kernels push -p kaggle/kernel
"""
import base64
import io
import json
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILES = ["common.py", "seed_data.py", "build_dataset.py", "generate_tanglish.py", "train.py", "chat.py",
         "kaggle/run_on_kaggle.sh"]

user = sys.argv[1]
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:gz") as tar:
    for f in FILES:
        tar.add(ROOT / f, arcname=Path(f).name)
payload = base64.b64encode(buf.getvalue()).decode()

script = f'''# Suho 3B Tanglish model – auto-generated Kaggle kernel. Do not edit by hand.
import base64, io, os, subprocess, sys, tarfile
PROJ = "/tmp/proj"
os.makedirs(PROJ, exist_ok=True)
tarfile.open(fileobj=io.BytesIO(base64.b64decode("{payload}")), mode="r:gz").extractall(PROJ)
p = subprocess.Popen(["bash", "run_on_kaggle.sh"], cwd=PROJ, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
with open("/kaggle/working/run.log", "w") as log:
    for line in p.stdout:
        sys.stdout.write(line); sys.stdout.flush(); log.write(line); log.flush()
sys.exit(p.wait())
'''

out = ROOT / "kaggle" / "kernel"
out.mkdir(parents=True, exist_ok=True)
(out / "suho_train.py").write_text(script)
(out / "kernel-metadata.json").write_text(json.dumps({
    "id": f"{user}/suho-tanglish-3b",
    "title": "suho-tanglish-3b",
    "code_file": "suho_train.py",
    "language": "python",
    "kernel_type": "script",
    "is_private": True,
    "enable_gpu": True,
    "enable_internet": True,
    "machine_shape": "NvidiaTeslaT4",
    "dataset_sources": [], "competition_sources": [], "kernel_sources": [], "model_sources": [],
}, indent=2))
print(f"kernel written to {out}  ({len(script)//1024} KB)")
