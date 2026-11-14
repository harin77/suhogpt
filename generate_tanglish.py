"""
Create Tanglish training data with a bigger "teacher" model.

Works with ANY OpenAI-compatible endpoint:
  * Local vLLM on the same 3090 (free, see serve_teacher.sh)   -> default
  * A cloud API: set TEACHER_BASE_URL, TEACHER_API_KEY, TEACHER_MODEL

Three modes (run all for the best mix):
  python generate_tanglish.py translate --n 2500   # rewrite English pool examples into Tanglish
  python generate_tanglish.py linux --n 2500       # Linux course: ~180 commands, every command explained with # comments
  python generate_tanglish.py fresh --n 800        # brand-new Tanglish Q&A on coding + security topics

Output is appended to data/tanglish_generated.jsonl (safe to stop & resume).
Every example is checked: no Tamil script, real Tanglish words present, code blocks kept.
"""
import argparse
import json
import os
import random
import re
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed

from common import (
    ENGLISH_POOL, TANGLISH_GENERATED, ASSISTANT_NAME, CREATOR_NAME, count_code_blocks, has_tamil_script,
    is_tanglish, read_jsonl, text_hash,
)

BASE_URL = os.environ.get("TEACHER_BASE_URL", "http://localhost:8000/v1")
API_KEY = os.environ.get("TEACHER_API_KEY", "local")
MODEL = os.environ.get("TEACHER_MODEL", "Qwen/Qwen2.5-14B-Instruct-AWQ")

STYLE_RULES = f"""You write training data for "{ASSISTANT_NAME}", a personal Linux / coding / cybersecurity AI assistant created by {CREATOR_NAME}. Personality: calm, loyal, witty movie-style AI butler who sometimes calls the user "boss". It speaks TANGLISH.

TANGLISH RULES (very important):
- Tanglish = Tamil words written ONLY in English/Latin letters, mixed naturally with English, like Chennai techies chat.
- NEVER use Tamil script characters. Not even one. Tamil words are ALWAYS spelled with English letters (e.g. "romba", "epdi").
- Keep ALL commands, code, code blocks, file paths, flags, tool names and technical terms exactly in English.
- Use natural spoken Tamil words: enna, epdi, panna, pannunga, irukku, illa, venum, mudiyum, theriyum, konjam, romba,
  idhu, adhu, inga, unga, namma, appo, apram, mattum, thaan, kooda, aagum, varum, paarunga, sollunga, seri, aana.
- Friendly, clear, respectful tone ("pannunga" style). Short sentences. Explanations accurate and practical.
- Use markdown: code blocks with language tags, bullet points, bold for key terms.
- COVER ALL LINUX DISTROS, not only Ubuntu: Arch/CachyOS/Manjaro, Debian/Ubuntu/Mint/Kali, Fedora/RHEL, openSUSE, Alpine.
  When the user names a distro, answer for THAT distro.
- TEACH LIKE A GOOD LINUX TEACHER: inside every bash code block, put a short `# comment` (in Tanglish) next to or
  above EACH command explaining what it does. Explain important flags. Show the expected output when it helps.
  Warn about dangerous commands (rm -rf, dd, chmod 777, etc.).
- Security answers: educational/defensive; mention authorization for offensive tools.

EXAMPLES OF THE STYLE:
"""


def build_fewshot(k=3):
    from seed_data import SEED
    picks = random.sample([s for s in SEED if len(s) == 2 and any(w in s[0] for w in
                          ("epdi", "enna", "pannanum", "sollu", "na enna"))], k)
    return "\n\n---\n\n".join(f"USER: {u}\nASSISTANT: {a.replace('{NAME}', ASSISTANT_NAME).replace('{CREATOR}', CREATOR_NAME)}" for u, a in picks)


TRANSLATE_TASK = """Rewrite the following English Q&A into Tanglish.
- The user question should sound like a real Tamil person typing casually in Tanglish.
- The answer must contain the SAME technical content, commands and code blocks (copy code exactly; you may add # comments to bash lines).
- If the original answer is very short (e.g. just a command), add 1-3 short Tanglish lines explaining it.
- If the original is wrong or unsafe, fix it.

ORIGINAL QUESTION:
{q}

ORIGINAL ANSWER:
{a}

Return ONLY valid JSON: {{"user": "...", "assistant": "..."}}"""

FRESH_TASK = """Create ONE new, realistic Tanglish conversation about: {topic}
Difficulty: {level}. Make the question specific (a real situation, error, or task), not generic.
The answer must be technically correct, practical, with working commands/code where useful.

Return ONLY valid JSON: {{"user": "...", "assistant": "..."}}"""

TOPICS = [
    "Linux file permissions and chown", "systemd services and journalctl", "bash scripting loops and conditions",
    "find, grep, awk, sed text processing", "Linux networking: ip, ss, ping, traceroute, dig", "disk partitions, mount, fstab",
    "SSH config, keys and tunnels", "cron and systemd timers", "package management apt/dnf/pacman",
    "Docker basics and debugging", "nginx reverse proxy and TLS with certbot",
    "Python basics and common errors", "Python file handling and JSON", "Python requests and APIs",
    "Python OOP classes", "Python virtualenv and pip problems", "Git branching, merge conflicts, rebase",
    "JavaScript async/await and fetch", "Node.js Express API basics", "SQL queries and joins",
    "regex in Python", "debugging techniques", "writing CLI tools with argparse", "C pointers basics", "Go basics",
    "OWASP Top 10 web vulnerabilities", "SQL injection prevention", "XSS and CSP", "CSRF and SameSite cookies",
    "nmap scanning in a lab", "Wireshark analysis", "Burp Suite basics for authorized testing", "password hashing and salting",
    "TLS/HTTPS how it works", "Linux server hardening", "fail2ban and SSH protection", "log analysis for incident response",
    "phishing detection", "malware analysis lab setup (safe, isolated)", "CTF beginner tips (web, crypto, forensics)",
    "privilege escalation concepts and defenses on Linux", "firewalls ufw/iptables/nftables", "VPN and WireGuard setup",
    "SIEM, Wazuh, and alerting basics", "secure coding in Python", "JWT and session security", "MITRE ATT&CK basics",
    "cryptography basics: AES, RSA, hashing", "OSINT basics and privacy protection", "Active Directory security concepts",
    "differences between Linux distro families (package managers, init, config paths)",
    "Arch / CachyOS maintenance: updates, AUR safety, pacnew files, kernels",
    "Fedora / RHEL: dnf, SELinux, firewalld troubleshooting", "Kali Linux setup for a legal pentest lab",
    "hardening Arch-based vs Debian-based servers", "cloud security basics (IAM, S3 buckets)", "vulnerability management and CVEs", "SOC analyst daily tasks",
]
LEVELS = ["beginner", "beginner", "intermediate", "intermediate", "advanced"]

# ---- "linux" mode: a full Linux course, command by command -----------------
LINUX_COMMANDS = [
    "pwd", "cd", "ls", "tree", "mkdir", "rmdir", "touch", "cp", "mv", "rm", "ln", "file", "stat", "basename/dirname",
    "realpath", "find", "locate", "which/whereis/type",
    "cat", "less", "more", "head", "tail", "wc", "sort", "uniq", "cut", "paste", "tr", "tee", "diff", "comm",
    "grep", "egrep / grep -E", "sed", "awk", "xargs", "column", "nl", "rev", "split", "jq",
    "nano", "vim basics",
    "chmod", "chown", "chgrp", "umask", "sudo", "su", "id", "whoami", "groups", "useradd/adduser", "usermod",
    "passwd", "userdel", "visudo", "getfacl/setfacl", "lsattr/chattr",
    "ps", "top", "htop", "kill", "pkill", "killall", "jobs/fg/bg", "nohup", "nice/renice", "pgrep", "lsof",
    "strace", "time", "watch", "timeout",
    "uname", "hostnamectl", "uptime", "free", "df", "du", "lsblk", "blkid", "lscpu", "lspci", "lsusb", "dmesg",
    "vmstat", "iostat", "date/timedatectl", "env/export", "alias", "history",
    "mount/umount", "fdisk", "parted", "mkfs", "fsck", "/etc/fstab", "swapon/mkswap", "dd (carefully)",
    "apt", "dpkg", "dnf/yum", "rpm", "pacman", "snap", "flatpak", "pip in venv",
    "systemctl", "journalctl", "service", "crontab", "systemd timers", "logrotate", "/var/log files",
    "ip addr / ip route", "ping", "traceroute/tracepath", "ss", "netstat", "dig", "nslookup", "host", "curl", "wget",
    "nc (netcat)", "nmap (own network)", "tcpdump", "iptables", "nftables", "ufw", "hostname", "/etc/hosts",
    "nmcli", "resolvectl", "ethtool", "mtr",
    "ssh", "ssh-keygen", "ssh-copy-id", "~/.ssh/config", "scp", "rsync", "sftp", "tmux", "screen",
    "tar", "gzip/gunzip", "zip/unzip", "xz", "7z",
    "bash variables", "bash if/else", "bash for/while loops", "bash functions", "bash arrays", "exit codes and $?",
    "pipes and redirection > >> 2>&1", "here documents", "set -euo pipefail", "shebang and chmod +x", "read input",
    "case statements", "command substitution $( )", "globbing and wildcards", "brace expansion",
    "sha256sum/md5sum", "gpg", "openssl", "fail2ban-client", "auditctl/ausearch", "last/lastb/who/w",
    "find SUID files", "lynis", "chkrootkit/rkhunter", "sudo -l",
    "docker run/ps/logs/exec", "docker compose", "git basics", "make",
    # distro-specific tools
    "pacman -Syu / -Qdt / -Rns", "paru / yay (AUR helpers)", "makepkg and PKGBUILD", "pacman-mirrors / reflector",
    "mkinitcpio", "CachyOS kernels and repos", "arch-audit", "apt-mark hold", "apt vs apt-get vs dpkg",
    "dnf history / dnf groupinstall", "rpm -qa / rpm -qf", "zypper (openSUSE)", "apk (Alpine)",
    "firewalld / firewall-cmd", "SELinux: getenforce, setenforce, restorecon, audit2why", "AppArmor: aa-status",
    "update-grub vs grub-mkconfig vs grub2-mkconfig", "dracut vs mkinitcpio vs update-initramfs", "systemd-boot / bootctl",
    "btrfs subvolumes and snapper snapshots", "timeshift", "NetworkManager / nmcli / nmtui", "flatpak vs snap vs AUR",
    "Kali Linux tools and metapackages", "NixOS: nix-env / configuration.nix basics", "WSL Linux basics",
]

DISTROS = [
    "Arch Linux", "CachyOS", "Manjaro", "EndeavourOS",
    "Ubuntu", "Debian", "Linux Mint", "Kali Linux",
    "Fedora", "RHEL / Rocky Linux / AlmaLinux",
    "openSUSE", "Alpine Linux",
]
# which distro a distro-specific command belongs to (others pick a random distro)
DISTRO_HINTS = {
    "pacman": ["Arch Linux", "CachyOS", "Manjaro", "EndeavourOS"], "paru": ["Arch Linux", "CachyOS", "EndeavourOS"],
    "makepkg": ["Arch Linux", "CachyOS"], "mkinitcpio": ["Arch Linux", "CachyOS", "Manjaro"], "CachyOS": ["CachyOS"],
    "arch-audit": ["Arch Linux", "CachyOS"], "reflector": ["Arch Linux", "EndeavourOS"],
    "apt": ["Ubuntu", "Debian", "Linux Mint", "Kali Linux"], "dpkg": ["Ubuntu", "Debian"], "Kali": ["Kali Linux"],
    "dnf": ["Fedora", "RHEL / Rocky Linux / AlmaLinux"], "rpm": ["Fedora", "RHEL / Rocky Linux / AlmaLinux"],
    "firewalld": ["Fedora", "RHEL / Rocky Linux / AlmaLinux"], "SELinux": ["Fedora", "RHEL / Rocky Linux / AlmaLinux"],
    "zypper": ["openSUSE"], "apk": ["Alpine Linux"], "AppArmor": ["Ubuntu", "Debian", "openSUSE"],
    "NixOS": ["NixOS"], "snapper": ["openSUSE", "CachyOS", "Arch Linux"], "WSL": ["Ubuntu"],
}


def pick_distro(cmd):
    for key, ds in DISTRO_HINTS.items():
        if cmd.lower().startswith(key.lower()) or key in cmd:
            return random.choice(ds)
    return random.choice(DISTROS)
LINUX_ANGLES = [
    "Teach the `{c}` command from zero: what it does, syntax, the 5-8 most useful options/examples, each with a # comment.",
    "Give a real-world task that needs `{c}` (sysadmin / developer / security situation) and solve it step by step with commented commands.",
    "Explain a common mistake or error message people get with `{c}` and how to fix it, with commented commands.",
    "Make a quick cheat sheet for `{c}` as a commented bash block, then 2-3 practical tips.",
    "Compare `{c}` with a similar/alternative command, when to use which, with commented examples.",
    "Give a small practice exercise using `{c}` (like a mini lab), then the solution with commented commands.",
]

LINUX_TASK = """Create ONE Tanglish conversation for a Linux learning dataset.
Task: {angle}
Level: {level}.
- The user question is a real Tanglish question a learner would type (e.g. "{c} command epdi use pannradhu?").
- In the answer, EVERY command inside bash code blocks must have a short Tanglish # comment explaining it.
- Target distro for this example: {distro}. The user mentions this distro in the question, and the answer uses its real
  package manager, service tools, config paths and defaults.
- If the command or its package name differs between distro families, add a short "Other distros" block with the
  equivalent for the other families: Debian/Ubuntu/Mint/Kali (apt), Fedora/RHEL/Rocky/Alma (dnf), Arch/CachyOS/Manjaro/
  EndeavourOS (pacman, AUR via paru/yay), openSUSE (zypper), Alpine (apk). Each line with a Tanglish # comment.
- Be 100% technically correct for that distro. Never invent commands, flags or package names.

Return ONLY valid JSON: {{"user": "...", "assistant": "..."}}"""

_lock = threading.Lock()


def parse_json(text):
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return None
    try:
        obj = json.loads(m.group(0))
    except json.JSONDecodeError:
        return None
    u, a = obj.get("user"), obj.get("assistant")
    if isinstance(u, str) and isinstance(a, str) and u.strip() and a.strip():
        return u.strip(), a.strip()
    return None


def call_teacher(client, prompt):
    resp = client.chat.completions.create(
        model=MODEL,
        messages=[{"role": "system", "content": STYLE_RULES + build_fewshot()},
                  {"role": "user", "content": prompt}],
        temperature=0.7,
        max_tokens=2048,
    )
    return resp.choices[0].message.content or ""


def bash_blocks_commented(text):
    """True if there is at least one bash/sh code block and every such block has # comments."""
    blocks = re.findall(r"```(?:bash|sh|shell|console)\n(.*?)```", text, re.S)
    return bool(blocks) and all("#" in b for b in blocks)


def validate(user, assistant, src_answer=None, kind=None):
    if has_tamil_script(user) or has_tamil_script(assistant):
        return "tamil-script"
    if kind == "linux" and not bash_blocks_commented(assistant):
        return "no-comments"
    if not is_tanglish(assistant, 3):
        return "not-tanglish"
    if len(assistant) < 40:
        return "too-short"
    if src_answer is not None and count_code_blocks(assistant) < count_code_blocks(src_answer):
        return "lost-code-block"
    return None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["translate", "fresh", "linux"])
    p.add_argument("--n", type=int, default=3000, help="how many NEW examples to create")
    p.add_argument("--workers", type=int, default=24)
    a = p.parse_args()

    from openai import OpenAI
    client = OpenAI(base_url=BASE_URL, api_key=API_KEY)
    print(f"Teacher: {MODEL} @ {BASE_URL}")

    done = read_jsonl(TANGLISH_GENERATED)
    done_src = {r.get("src_hash") for r in done}
    done_by_mode = sum(1 for r in done if r.get("mode") == a.mode)
    print(f"Already have {len(done)} generated examples ({done_by_mode} in mode {a.mode}).")
    want = max(0, a.n - done_by_mode)   # resume-friendly: only make what's missing

    jobs = []
    if a.mode == "translate":
        pool = read_jsonl(ENGLISH_POOL)
        if not pool:
            raise SystemExit("No English pool. Run: python build_dataset.py pool")
        random.shuffle(pool)
        for r in pool:
            if len(jobs) >= want:
                break
            msgs = r["messages"]
            if len(msgs) != 2:
                continue
            h = text_hash(msgs[0]["content"])
            if h in done_src:
                continue
            jobs.append(("translate", h, msgs[0]["content"], msgs[1]["content"], r.get("topic")))
    elif a.mode == "linux":
        combos = [(c, ang) for c in LINUX_COMMANDS for ang in LINUX_ANGLES]
        random.shuffle(combos)
        while len(jobs) < want:
            for c, ang in combos:
                if len(jobs) >= want:
                    break
                jobs.append(("linux", f"linux-{random.getrandbits(48)}", c, ang, "linux"))
    else:
        for _ in range(want):
            jobs.append(("fresh", f"fresh-{random.getrandbits(48)}", random.choice(TOPICS), random.choice(LEVELS), None))

    stats = {"ok": 0}
    out = open(TANGLISH_GENERATED, "a", encoding="utf-8")

    def work(job):
        kind, h, x, y, topic = job
        if kind == "translate":
            prompt = TRANSLATE_TASK.format(q=x, a=y)
        elif kind == "linux":
            prompt = LINUX_TASK.format(angle=y.format(c=x), level=random.choice(LEVELS), c=x, distro=pick_distro(x))
        else:
            prompt = FRESH_TASK.format(topic=x, level=y)
        for _attempt in range(2):
            try:
                parsed = parse_json(call_teacher(client, prompt))
            except Exception as e:
                return f"api-error:{type(e).__name__}"
            if not parsed:
                continue
            u, ans = parsed
            if validate(u, ans, y if kind == "translate" else None, kind):
                continue
            row = {"messages": [{"role": "user", "content": u}, {"role": "assistant", "content": ans}],
                   "src_hash": h, "mode": kind, "topic": topic or x}
            with _lock:
                out.write(json.dumps(row, ensure_ascii=False) + "\n")
                out.flush()
            return "ok"
        return "rejected"

    with ThreadPoolExecutor(max_workers=a.workers) as ex:
        futs = [ex.submit(work, j) for j in jobs]
        for i, f in enumerate(as_completed(futs), 1):
            r = f.result()
            stats[r] = stats.get(r, 0) + 1
            if i % 50 == 0 or i == len(futs):
                print(f"  {i}/{len(futs)}  {stats}", flush=True)
    out.close()
    print(f"\n✅ Done. {stats.get('ok', 0)} new Tanglish examples → {TANGLISH_GENERATED}")


if __name__ == "__main__":
    main()
