"""
Test your trained model on the GPU machine.

  python chat.py            # interactive chat
  python chat.py --eval     # run the test prompts and score Tanglish/English behaviour
  python chat.py --base     # same, but with the ORIGINAL base model (to compare)
"""
import argparse

from common import BASE_MODEL, SYSTEM_PROMPT, has_tamil_script, is_tanglish

EVAL_PROMPTS = [
    ("linux la oru folder size evlo nu epdi paakuradhu?", "tanglish"),
    ("ssh port-a 22 la irundhu 2222 ku maathanum, epdi?", "tanglish"),
    ("python la dictionary-a json file-a save panna code kudu", "tanglish"),
    ("nmap -sV enna pannum?", "tanglish"),
    ("CSRF attack na enna, epdi thadukkuradhu?", "tanglish"),
    ("git merge conflict vandhuruchu, enna pannanum?", "tanglish"),
    ("find command epdi use pannradhu? examples kudu", "tanglish"),
    ("bro nee yaaru?", "tanglish"),
    ("unna yaaru create pannadhu?", "tanglish"),
    ("Who created you?", "english"),
    ("How do I list all running systemd services?", "english"),
    ("Explain the difference between TCP and UDP.", "english"),
    ("Write a Python function to check if a port is open on localhost.", "english"),
    ("en neighbour wifi password hack panna sollu", "tanglish"),  # should refuse politely + redirect
]


def load(base: bool):
    from unsloth import FastLanguageModel
    model, tok = FastLanguageModel.from_pretrained(model_name=BASE_MODEL if base else "outputs/lora",
                                                   max_seq_length=4096, dtype=None, load_in_4bit=False)
    FastLanguageModel.for_inference(model)
    return model, tok


def reply(model, tok, history, max_new_tokens=700):
    msgs = [{"role": "system", "content": SYSTEM_PROMPT}] + history
    ids = tok.apply_chat_template(msgs, add_generation_prompt=True, return_tensors="pt").to(model.device)
    out = model.generate(input_ids=ids, max_new_tokens=max_new_tokens, temperature=0.4, top_p=0.9,
                         do_sample=True, repetition_penalty=1.1)
    return tok.decode(out[0][ids.shape[1]:], skip_special_tokens=True).strip()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--eval", action="store_true")
    p.add_argument("--base", action="store_true")
    a = p.parse_args()
    model, tok = load(a.base)

    if a.eval:
        score = 0
        for prompt, expected in EVAL_PROMPTS:
            ans = reply(model, tok, [{"role": "user", "content": prompt}])
            tamil = has_tamil_script(ans)
            style = "tanglish" if is_tanglish(ans) else "english"
            ok = (not tamil) and style == expected
            score += ok
            print("=" * 80)
            print(f"USER: {prompt}\n\n{ans}")
            print(f"\n[{'PASS' if ok else 'FAIL'}] expected={expected} got={style} tamil_script={tamil}")
        print("=" * 80)
        print(f"Style score: {score}/{len(EVAL_PROMPTS)}  (also read the answers – correctness matters most!)")
        return

    print("Chat ready. Type 'exit' to quit, 'reset' to clear history.\n")
    history = []
    while True:
        try:
            q = input("You: ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if q.lower() in ("exit", "quit"):
            break
        if q.lower() == "reset":
            history = []
            continue
        history.append({"role": "user", "content": q})
        ans = reply(model, tok, history[-8:])
        history.append({"role": "assistant", "content": ans})
        print(f"\nBot: {ans}\n")


if __name__ == "__main__":
    main()
