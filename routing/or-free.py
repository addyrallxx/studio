"""Free worker lane: one prompt to an OpenRouter `:free` model. Zero dollars (no card on the account).

Usage:  uv run --no-project --python 3.12 ~/.claude/tools/or-free.py [-m MODEL] [-f FILE ...] < prompt.txt
Key:    OPENROUTER_API_KEY user env var (setx). Never in the vault or a repo.
Limits: 50 requests/day, 20/minute without credits. Free providers may log or train on prompts:
        PUBLIC DATA ONLY. Never code, design, review, plans, client data, secrets or private notes.
        Fit for: summaries of public text, format/link checks, counting, schema-shaped bulk extraction.
"""
import argparse, json, os, sys, urllib.request

DEFAULT = "nvidia/nemotron-3-super-120b-a12b:free"  # ponytail: picked by size/context on 2026-10-09, re-check `or-free.py --list` monthly

ap = argparse.ArgumentParser()
ap.add_argument("-m", "--model", default=DEFAULT)
ap.add_argument("-f", "--file", action="append", default=[], help="append file contents to the prompt")
ap.add_argument("--list", action="store_true", help="list current :free models")
a = ap.parse_args()

if a.list:
    data = json.load(urllib.request.urlopen("https://openrouter.ai/api/v1/models"))["data"]
    for m in sorted((m for m in data if m["id"].endswith(":free")), key=lambda m: -m.get("context_length", 0)):
        print(m["id"], m.get("context_length"))
    sys.exit()

if not a.model.endswith(":free"):
    sys.exit("refusing: model must end in :free (zero-dollar rule)")
key = os.environ.get("OPENROUTER_API_KEY") or sys.exit("OPENROUTER_API_KEY not set (setx it, then open a new shell)")
prompt = sys.stdin.read() + "".join(f"\n\n--- {p} ---\n" + open(p, encoding="utf-8").read() for p in a.file)

req = urllib.request.Request(
    "https://openrouter.ai/api/v1/chat/completions",
    data=json.dumps({"model": a.model, "messages": [{"role": "user", "content": prompt}]}).encode(),
    headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json", "X-Title": "or-free"},
)
try:
    r = json.load(urllib.request.urlopen(req, timeout=300))
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code}: {e.read().decode()[:500]}")  # 429 = daily free cap hit
print(r["choices"][0]["message"]["content"])
print(f"[or-free] model={r.get('model')} tokens={r.get('usage', {}).get('total_tokens')}", file=sys.stderr)
