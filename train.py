"""
Fine-tune a 3B model on data/train.jsonl with Unsloth (LoRA, bf16) on an RTX 3090 (24 GB).

  python train.py                       # defaults: Qwen2.5-3B-Instruct, 2 epochs
  python train.py --epochs 3 --rank 128
  python train.py --export-only         # just re-export an already-trained model

Outputs (in ./outputs):
  lora/         small LoRA adapter
  merged/       full 16-bit merged model (Hugging Face format)
  gguf/         *.gguf files (Q4_K_M + Q8_0) + Ollama Modelfile
"""
import argparse
import glob
import inspect
import os
import shutil

from common import ASSISTANT_NAME, BASE_MODEL, SYSTEM_PROMPT, TRAIN_FILE, VALID_FILE

OUT = "outputs"

TURN_MARKERS = {
    "qwen": ("<|im_start|>user\n", "<|im_start|>assistant\n", "qwen-2.5"),
    "llama": ("<|start_header_id|>user<|end_header_id|>\n\n",
              "<|start_header_id|>assistant<|end_header_id|>\n\n", "llama-3.1"),
}

OLLAMA_TEMPLATES = {
    "qwen": ('''TEMPLATE """{{ if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}{{ if .Prompt }}<|im_start|>user
{{ .Prompt }}<|im_end|>
{{ end }}<|im_start|>assistant
{{ .Response }}<|im_end|>
"""
PARAMETER stop "<|im_end|>"
PARAMETER stop "<|im_start|>"'''),
    "llama": ('''TEMPLATE """{{ if .System }}<|start_header_id|>system<|end_header_id|>

{{ .System }}<|eot_id|>{{ end }}{{ if .Prompt }}<|start_header_id|>user<|end_header_id|>

{{ .Prompt }}<|eot_id|>{{ end }}<|start_header_id|>assistant<|end_header_id|>

{{ .Response }}<|eot_id|>"""
PARAMETER stop "<|eot_id|>"'''),
}


def family(model_name):
    n = model_name.lower()
    if "qwen" in n:
        return "qwen"
    if "llama" in n:
        return "llama"
    return None


def kwargs_for(cls, **kw):
    """Pass only the kwargs this library version supports (TRL/transformers rename things often)."""
    for c in cls.__mro__:
        init = c.__dict__.get("__init__")
        if init is None:
            continue
        params = inspect.signature(init).parameters
        named = [p for p in params.values() if p.kind not in (p.VAR_POSITIONAL, p.VAR_KEYWORD)]
        if len(named) <= 1:
            continue
        return {k: v for k, v in kw.items() if k in params}
    return kw


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", default=BASE_MODEL)
    p.add_argument("--epochs", type=float, default=2)
    p.add_argument("--lr", type=float, default=1e-4)
    p.add_argument("--rank", type=int, default=64)
    p.add_argument("--max-seq", type=int, default=2048)
    p.add_argument("--batch", type=int, default=4)
    p.add_argument("--grad-accum", type=int, default=4)
    p.add_argument("--load-4bit", action="store_true", help="QLoRA (less VRAM, slightly lower quality)")
    p.add_argument("--export-only", action="store_true")
    p.add_argument("--no-gguf", action="store_true")
    a = p.parse_args()

    from unsloth import FastLanguageModel  # import first: it patches transformers/trl
    from unsloth.chat_templates import get_chat_template, train_on_responses_only
    import torch
    from datasets import load_dataset

    fam = family(a.model)

    if a.export_only:
        model, tokenizer = FastLanguageModel.from_pretrained(
            model_name=f"{OUT}/lora", max_seq_length=a.max_seq, dtype=None, load_in_4bit=False)
    else:
        model, tokenizer = FastLanguageModel.from_pretrained(
            model_name=a.model, max_seq_length=a.max_seq, dtype=None, load_in_4bit=a.load_4bit)

        model = FastLanguageModel.get_peft_model(
            model, r=a.rank, lora_alpha=a.rank, lora_dropout=0, bias="none",
            target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
            use_gradient_checkpointing="unsloth", random_state=3407,
        )

        if fam:
            tokenizer = get_chat_template(tokenizer, chat_template=TURN_MARKERS[fam][2])

        def fmt(batch):
            return {"text": [tokenizer.apply_chat_template(m, tokenize=False, add_generation_prompt=False)
                             for m in batch["messages"]]}

        ds = load_dataset("json", data_files={"train": str(TRAIN_FILE), "valid": str(VALID_FILE)})
        train_ds = ds["train"].map(fmt, batched=True, remove_columns=ds["train"].column_names)
        valid_ds = ds["valid"].map(fmt, batched=True, remove_columns=ds["valid"].column_names)
        print(f"Train: {len(train_ds)}  Valid: {len(valid_ds)}")
        print("Sample:\n" + train_ds[0]["text"][:800])

        from trl import SFTConfig, SFTTrainer

        bf16 = torch.cuda.is_bf16_supported()
        cfg = SFTConfig(**kwargs_for(
            SFTConfig,
            output_dir=f"{OUT}/checkpoints", dataset_text_field="text",
            max_seq_length=a.max_seq, max_length=a.max_seq, packing=False,
            per_device_train_batch_size=a.batch, per_device_eval_batch_size=a.batch,
            gradient_accumulation_steps=a.grad_accum, num_train_epochs=a.epochs,
            learning_rate=a.lr, lr_scheduler_type="cosine", warmup_ratio=0.03, weight_decay=0.01,
            optim="adamw_8bit", bf16=bf16, fp16=not bf16, logging_steps=10,
            eval_strategy="steps", evaluation_strategy="steps", eval_steps=200,
            save_strategy="steps", save_steps=200, save_total_limit=2,
            report_to="none", seed=3407, dataset_num_proc=4,
        ))

        common_kw = dict(model=model, train_dataset=train_ds, eval_dataset=valid_ds, args=cfg)
        try:
            trainer = SFTTrainer(processing_class=tokenizer, **common_kw)   # newer TRL
        except TypeError:
            trainer = SFTTrainer(tokenizer=tokenizer, **common_kw)          # older TRL

        if fam:  # learn only from the assistant's answers
            user_m, asst_m, _ = TURN_MARKERS[fam]
            trainer = train_on_responses_only(trainer, instruction_part=user_m, response_part=asst_m)

        resume = bool(glob.glob(f"{OUT}/checkpoints/checkpoint-*"))
        if resume:
            print("Resuming from last checkpoint ...")
        print(trainer.train(resume_from_checkpoint=resume or None))

        model.save_pretrained(f"{OUT}/lora")
        tokenizer.save_pretrained(f"{OUT}/lora")
        print(f"✅ LoRA adapter saved to {OUT}/lora")

    print("Saving merged 16-bit model ...")
    model.save_pretrained_merged(f"{OUT}/merged", tokenizer, save_method="merged_16bit")

    if a.no_gguf:
        return
    print("Exporting GGUF ...")
    os.makedirs(f"{OUT}/gguf", exist_ok=True)
    try:
        model.save_pretrained_gguf(f"{OUT}/gguf", tokenizer, quantization_method=["q4_k_m", "q8_0"])
    except TypeError:
        for q in ("q4_k_m", "q8_0"):
            model.save_pretrained_gguf(f"{OUT}/gguf", tokenizer, quantization_method=q)

    for f in glob.glob(f"{OUT}/**/*.gguf", recursive=True) + glob.glob("*.gguf"):
        if os.path.dirname(f) != f"{OUT}/gguf":
            shutil.move(f, f"{OUT}/gguf/{os.path.basename(f)}")

    ggufs = sorted(glob.glob(f"{OUT}/gguf/*.gguf"))
    q4 = next((g for g in ggufs if "q4_k_m" in g.lower()), ggufs[0] if ggufs else None)
    if not q4:
        print("⚠️ No GGUF produced – see README 'Manual GGUF export'.")
        return

    sys_prompt = SYSTEM_PROMPT.replace('"', '\\"')
    with open(f"{OUT}/gguf/Modelfile", "w") as f:
        f.write(f'''FROM ./{os.path.basename(q4)}
{OLLAMA_TEMPLATES.get(fam, "")}
SYSTEM """{sys_prompt}"""
PARAMETER temperature 0.4
PARAMETER top_p 0.9
PARAMETER repeat_penalty 1.1
PARAMETER num_ctx 4096
''')
    print("\n✅ GGUF files:")
    for g in ggufs:
        print(f"   {g}  ({os.path.getsize(g) / 1e9:.2f} GB)")


if __name__ == "__main__":
    main()
