"""
Build the training data.

  python build_dataset.py pool     # 1) download English sources -> data/english_pool.jsonl
  python build_dataset.py final    # 2) mix seed + generated Tanglish + English -> data/train.jsonl, data/valid.jsonl
"""
import argparse
import random
import sys

from common import (
    ENGLISH_POOL, SOURCES, TANGLISH_GENERATED, TRAIN_FILE, VALID_FILE, ASSISTANT_NAME, CREATOR_NAME,
    has_tamil_script, is_tanglish, normalize_record, read_jsonl, text_hash, with_system, write_jsonl,
)

MAX_CHARS = 7000  # skip very long examples (≈ 2k tokens)


def seed_conversations():
    from seed_data import SEED
    convs = []
    for turns in SEED:
        assert len(turns) % 2 == 0, f"Seed conversation must alternate user/assistant: {turns[0][:60]}"
        convs.append([{"role": "user" if i % 2 == 0 else "assistant",
                       "content": t.replace("{NAME}", ASSISTANT_NAME).replace("{CREATOR}", CREATOR_NAME).strip()} for i, t in enumerate(turns)])
    return convs


def conv_ok(msgs):
    total = sum(len(m["content"]) for m in msgs)
    if total > MAX_CHARS or total < 10:
        return False
    return not any(has_tamil_script(m["content"]) for m in msgs)


def build_pool(args):
    try:
        from datasets import load_dataset
    except ImportError:
        sys.exit("pip install datasets")

    rng = random.Random(42)
    pool, seen = [], set()
    for src in SOURCES:
        name = src["name"]
        print(f"→ {name} ...", flush=True)
        try:
            ds = load_dataset(name, split=src.get("split", "train"))
        except Exception as e:
            print(f"   ⚠️  skipped ({type(e).__name__}: {str(e)[:150]})")
            continue
        idx = list(range(len(ds)))
        rng.shuffle(idx)
        kept = 0
        for i in idx:
            if kept >= src["max"]:
                break
            rec = dict(ds[i])
            rec["_topic"] = src["topic"]
            msgs = normalize_record(rec)
            if not msgs or not conv_ok(msgs):
                continue
            h = text_hash(msgs[0]["content"])
            if h in seen:
                continue
            seen.add(h)
            pool.append({"messages": msgs, "topic": src["topic"], "source": name})
            kept += 1
        print(f"   kept {kept}")
    write_jsonl(ENGLISH_POOL, pool)
    print(f"\n✅ English pool: {len(pool)} examples → {ENGLISH_POOL}")


def build_final(args):
    rng = random.Random(42)

    seed = seed_conversations()
    bad = [c[0]["content"][:50] for c in seed if any(has_tamil_script(m["content"]) for m in c)]
    if bad:
        sys.exit(f"❌ Tamil script found in seed examples: {bad}")

    gen = []
    for r in read_jsonl(TANGLISH_GENERATED):
        msgs = r.get("messages")
        if msgs and conv_ok(msgs) and is_tanglish(msgs[-1]["content"]):
            gen.append(msgs)

    eng = [r["messages"] for r in read_jsonl(ENGLISH_POOL) if conv_ok(r["messages"])]

    tanglish = [c for c in seed for _ in range(args.seed_repeat)] + gen
    n_tanglish = len(tanglish)
    if args.tanglish_ratio > 0 and n_tanglish:
        n_eng = int(n_tanglish * (1 - args.tanglish_ratio) / args.tanglish_ratio)
    else:
        n_eng = len(eng)
    rng.shuffle(eng)
    eng = eng[:n_eng]

    allc = tanglish + eng
    rng.shuffle(allc)
    allc = allc[: args.max_total]
    rows = [{"messages": with_system(m)} for m in allc]

    seed_hashes = {text_hash(c[0]["content"]) for c in seed}
    n_valid = max(20, int(len(rows) * 0.03))
    valid, train = [], []
    for r in rows:
        is_seed = text_hash(r["messages"][1]["content"]) in seed_hashes
        if len(valid) < n_valid and not is_seed:
            valid.append(r)
        else:
            train.append(r)

    write_jsonl(TRAIN_FILE, train)
    write_jsonl(VALID_FILE, valid)

    print("📊 Dataset summary")
    print(f"   seed conversations     : {len(seed)} (×{args.seed_repeat})")
    print(f"   generated Tanglish     : {len(gen)}")
    print(f"   English examples used  : {len(eng)}")
    print(f"   Tanglish share         : {n_tanglish / max(1, n_tanglish + len(eng)):.0%}")
    print(f"   train / valid          : {len(train)} / {len(valid)}")
    print(f"✅ wrote {TRAIN_FILE} and {VALID_FILE}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("stage", choices=["pool", "final"])
    p.add_argument("--tanglish-ratio", type=float, default=0.45)
    p.add_argument("--seed-repeat", type=int, default=4)
    p.add_argument("--max-total", type=int, default=40000)
    a = p.parse_args()
    build_pool(a) if a.stage == "pool" else build_final(a)
