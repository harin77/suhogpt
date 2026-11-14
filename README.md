# SuhoGPT

**Suho** is a personal AI assistant for **Linux, coding and cybersecurity**. It replies in **Tanglish** (Tamil words written in English letters, never Tamil script) or **English**, matching how you write. It runs fully offline on your own PC.

- Model: Qwen2.5-3B-Instruct, fine-tuned with LoRA (Unsloth) on hand-written and generated Tanglish data
- Desktop app: Flutter, with a ChatGPT-style interface, for Windows and Linux
- Engine: [llama.cpp](https://github.com/ggml-org/llama.cpp). It uses NVIDIA, AMD or Intel GPUs through Vulkan or CUDA and falls back to the CPU. Works on 8 GB RAM PCs.

## Download

Get the latest version from [**Releases**](../../releases):

| OS | File | How |
|---|---|---|
| Windows 10/11 x64 | `SuhoGPT-windows-x64.zip` | Unzip, put the model `.gguf` in `models\`, run `suho_ai.exe` |
| Linux x64 (any distro) | `SuhoGPT-linux-x64.tar.gz` | Extract, then run `./install_linux.sh path/to/model.gguf` |

On first start, the app:
1. checks your CPU, RAM and GPU and tells you whether Suho will run on the GPU, a GPU + CPU split, or the CPU only
2. downloads llama.cpp (~40 MB), or uses one already installed on your system if it has GPU support
3. picks the best settings, including Low-RAM mode on 8 GB machines

**Terminal mode (CLI):** click the terminal icon next to the chat box. Suho's command blocks get a ▶ **Run** button (bash on Linux, PowerShell on Windows), and the output goes back to Suho, who explains it. Safety rules:
- nothing runs until you review it, and you can edit the command first
- every command gets a safety check with comments (Safe / Caution / Dangerous / Blocked)
- disk wipes, `rm -rf /`, fork bombs, formatting drives and deleting Windows system folders are **blocked**
- commands run in **your real terminal** (Ptyxis, Konsole, kitty, Alacritty… 35+ Linux terminals, or PowerShell on Windows), where you see everything and type sudo passwords yourself; the output is captured and sent back to Suho. You can pick the terminal in ⚙ Performance
- commands run in your home folder with a 2-minute limit and a Stop button, and every command is logged to `command_history.log`

**Performance panel:** Auto / GPU / CPU / Split (how many of the 37 layers go on the GPU), CPU threads, chat memory, Low-RAM mode, and live GPU / VRAM / RAM meters.

## Repository layout

| Path | What |
|---|---|
| `suho_app/` | Flutter desktop app (Windows + Linux) |
| `seed_data.py` | Hand-written Tanglish "gold" examples |
| `generate_tanglish.py` | Generates Tanglish training data with a bigger teacher LLM |
| `build_dataset.py` | Mixes the seed data, generated Tanglish and English datasets |
| `train.py` | LoRA fine-tune with Unsloth, then exports GGUF |
| `chat.py`, `bench.py` | Test and benchmark the model |
| `kaggle/` | Run the whole training pipeline on Kaggle's free T4 GPUs |

## Build the app yourself

```bash
cd suho_app
flutter pub get
flutter build linux --release      # or: flutter build windows --release (on Windows)
```

To publish a release, push a tag. GitHub Actions then builds Windows and Linux and attaches both:
```bash
git tag v1.0.0 && git push origin v1.0.0
```

## Note

Suho is a small 3B model and can make mistakes. Double-check important commands. Security help is for learning, defense, CTFs and authorized testing only.
