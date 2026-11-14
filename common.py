"""
Shared config + helpers for the Tanglish Linux / Coding / Cybersecurity 3B model.

Edit the CONFIG section to change the model name, persona, or data sources.
"""
import hashlib
import json
import re
from pathlib import Path

# ============================================================================
# CONFIG
# ============================================================================

# Your assistant's name (used in identity answers + system prompt)
ASSISTANT_NAME = "Suho"
CREATOR_NAME = "Harin"

# Base model to fine-tune (3B class). Good options:
#   "unsloth/Qwen2.5-3B-Instruct"        -> best all-round default (chat + code + multilingual)
#   "unsloth/Qwen2.5-Coder-3B-Instruct"  -> stronger at code, a bit weaker at chat
#   "unsloth/Llama-3.2-3B-Instruct"      -> good chat, big ecosystem
BASE_MODEL = "unsloth/Qwen2.5-3B-Instruct"

SYSTEM_PROMPT = (
    f"You are {ASSISTANT_NAME}, a personal AI assistant created by {CREATOR_NAME}. "
    "Your personality is like a movie-style AI butler: calm, confident, loyal, quick-witted, with dry humour, "
    f"and always one step ahead. You call your user 'boss' now and then. If asked who made you, say {CREATOR_NAME} "
    "built you. Keep the wit light and never let it get in the way of a correct answer. "
    "You are an expert in Linux, programming and cybersecurity. "
    "Match the user's language style: if the user writes in Tanglish (Tamil words written in English "
    "letters, mixed with English), reply in Tanglish; if the user writes in English, reply in English. "
    "Never use Tamil script. Keep commands, code, file paths and technical terms in English. "
    "Give correct, practical answers with working commands and short explanations. "
    "When teaching Linux, explain every command with a short # comment. "
    "For security topics, help with learning, defense, CTFs and authorized testing only."
)

DATA_DIR = Path(__file__).parent / "data"
ENGLISH_POOL = DATA_DIR / "english_pool.jsonl"
TANGLISH_GENERATED = DATA_DIR / "tanglish_generated.jsonl"
TRAIN_FILE = DATA_DIR / "train.jsonl"
VALID_FILE = DATA_DIR / "valid.jsonl"

# Public English datasets used for knowledge + as raw material for Tanglish conversion.
# "max" = how many rows to take from each. Any source that fails to load is skipped.
SOURCES = [
    # --- Linux / Bash ---
    {"name": "aelhalili/bash-commands-dataset", "split": "train", "max": 1000, "topic": "linux"},
    {"name": "Frost2o24/bash-instruct-II-55k", "split": "train", "max": 2500, "topic": "linux"},
    # --- Cybersecurity ---
    {"name": "Mohabahmed03/Alpaca_Dataset_CyberSecurity_Smaller_2.0", "split": "train", "max": 5000, "topic": "security"},
    {"name": "ansulev/trendyol-cybersecurity-instruction", "split": "train", "max": 4000, "topic": "security"},
    # --- Coding ---
    {"name": "sahil2801/CodeAlpaca-20k", "split": "train", "max": 4000, "topic": "coding"},
    {"name": "iamtarun/python_code_instructions_18k_alpaca", "split": "train", "max": 3000, "topic": "coding"},
    # --- General chat (keeps the model well-rounded) ---
    {"name": "yahma/alpaca-cleaned", "split": "train", "max": 3000, "topic": "general"},
]

# ============================================================================
# HELPERS
# ============================================================================

TAMIL_SCRIPT_RE = re.compile(r"[஀-௿]")

# Common Tanglish words – used to check that generated text really is Tanglish.
TANGLISH_MARKERS = {
    "enna", "epdi", "eppadi", "panna", "pannunga", "pannu", "pannalam", "pannanum", "pannum",
    "irukku", "iruku", "irukum", "irundha", "illa", "illai", "venum", "vendam", "mudiyum",
    "mudiyadhu", "theriyum", "theriyadhu", "sollu", "sollunga", "konjam", "seri", "sari",
    "aana", "adhu", "idhu", "romba", "inga", "anga", "namma", "unga", "ungaloda", "naan",
    "nee", "neenga", "appo", "apram", "paarunga", "paaru", "kudukkum", "kudunga", "varum",
    "aagum", "aaguthu", "ellam", "ellaam", "mattum", "thaan", "dhaan", "kooda", "enga",
    "yen", "edhuku", "nalla", "vachu", "podunga", "podu", "pola", "maari", "mathiri",
    "vandha", "vandhu", "pogum", "edhu", "yaaru", "evlo", "evvalavu", "solren", "solla",
    "kekkum", "kelunga", "aagidum", "pannradhu", "paakalam", "kaatum", "pannina",
    "pannitu", "paaka", "edukkum", "podhum", "aayidum", "ulla", "kulla",
    "check", "da", "bro", "machi", "nga", "la", "ku", "oda",
}


def has_tamil_script(text: str) -> bool:
    return bool(TAMIL_SCRIPT_RE.search(text or ""))


def tanglish_score(text: str) -> int:
    """Number of distinct Tanglish marker words found (ignores very short generic ones)."""
    words = set(re.findall(r"[a-zA-Z]+", (text or "").lower()))
    strong = TANGLISH_MARKERS - {"check", "da", "bro", "la", "ku", "oda", "nga"}
    return len(words & strong)


def is_tanglish(text: str, min_markers: int = 3) -> bool:
    return (not has_tamil_script(text)) and tanglish_score(text) >= min_markers


def count_code_blocks(text: str) -> int:
    return (text or "").count("```") // 2


def text_hash(text: str) -> str:
    return hashlib.md5(re.sub(r"\s+", " ", (text or "").strip().lower()).encode()).hexdigest()


def read_jsonl(path):
    path = Path(path)
    if not path.exists():
        return []
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return rows


def write_jsonl(path, rows):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


def _clean(s):
    return s.strip() if isinstance(s, str) else ""


def normalize_record(rec: dict):
    """
    Convert a row from (almost) any common dataset schema into a list of
    chat messages [{"role": "user"|"assistant", "content": str}, ...].
    Source system prompts are dropped (we add our own). Returns None if unusable.
    """
    msgs = None

    if isinstance(rec.get("messages"), list):
        msgs = [{"role": m.get("role"), "content": _clean(m.get("content"))} for m in rec["messages"]
                if isinstance(m, dict)]

    elif isinstance(rec.get("conversations"), list):
        role_map = {"human": "user", "user": "user", "gpt": "assistant", "assistant": "assistant",
                    "system": "system", "model": "assistant"}
        msgs = []
        for m in rec["conversations"]:
            if not isinstance(m, dict):
                continue
            role = role_map.get(m.get("from") or m.get("role"))
            if role:
                msgs.append({"role": role, "content": _clean(m.get("value") or m.get("content"))})

    else:
        pairs = [
            ("instruction", "output"), ("prompt", "response"), ("question", "answer"),
            ("nl_command", "bash_code"), ("nl", "bash"), ("input", "output"),
            ("query", "response"), ("user", "assistant"), ("prompt", "completion"),
        ]
        for q_key, a_key in pairs:
            q, a = _clean(rec.get(q_key)), _clean(rec.get(a_key))
            if q and a:
                if q_key == "instruction" and _clean(rec.get("input")):
                    q = f"{q}\n\n{_clean(rec.get('input'))}"
                if a_key in ("bash_code", "bash") or (q_key == "prompt" and "\n" not in a and len(a) < 200
                                                       and rec.get("_topic") == "linux"):
                    a = f"```bash\n{a}\n```"
                msgs = [{"role": "user", "content": q}, {"role": "assistant", "content": a}]
                break

    if not msgs:
        return None
    msgs = [m for m in msgs if m["role"] in ("user", "assistant") and m["content"]]
    while msgs and msgs[0]["role"] != "user":
        msgs.pop(0)
    while msgs and msgs[-1]["role"] != "assistant":
        msgs.pop()
    if len(msgs) < 2:
        return None
    for i, m in enumerate(msgs):
        if m["role"] != ("user" if i % 2 == 0 else "assistant"):
            return None
    return msgs


def with_system(msgs):
    return [{"role": "system", "content": SYSTEM_PROMPT}] + msgs
