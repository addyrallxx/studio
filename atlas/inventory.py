"""Mechanical capability inventory. Run with the uv python 3.12.
Writes inventory.json next to this file. Read-only on everything it scans."""
import json, os, re, sys, glob
from pathlib import Path

HOME = Path(os.path.expanduser("~"))
HERE = Path(__file__).parent
CLAUDE = HOME / ".claude"
APPDATA = HOME / "AppData" / "Roaming" / "Claude" / "local-agent-mode-sessions"


def parse_fm(path):
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        return None
    text = text.lstrip("﻿")
    m = re.match(r"^---\s*\r?\n(.*?)\r?\n---", text, re.S)
    if not m:
        return {}
    fm, key, mode = {}, None, None
    for line in m.group(1).splitlines():
        km = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if km and not line.startswith((" ", "\t")):
            key, val = km.group(1), km.group(2).strip()
            if val in (">", "|", ">-", "|-", ">+", "|+"):
                fm[key], mode = "", "block"
            else:
                fm[key], mode = val, "plain"
        elif key is not None and (line.startswith((" ", "\t")) or not line.strip()):
            fm[key] = (fm[key] + " " + line.strip()).strip()
    for k, v in list(fm.items()):
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        fm[k] = re.sub(r"\s+", " ", v)
    return fm


records = []


def add(group, source, kind, name, desc, enabled, path, plugin=None):
    desc = desc or ""
    records.append(dict(group=group, source=source, kind=kind, name=name, desc=desc,
                        enabled=enabled, path=str(path), plugin=plugin,
                        chars=len(name) + len(desc)))


# --- A. user skills, source attributed through the skill lock ---
lock = json.loads((HOME / ".agents" / ".skill-lock.json").read_text(encoding="utf-8"))["skills"]
for sk in sorted((CLAUDE / "skills").iterdir()):
    f = sk / "SKILL.md"
    if not f.exists():
        continue
    fm = parse_fm(f) or {}
    name = fm.get("name") or sk.name
    src = lock.get(sk.name, {}).get("source") or lock.get(name, {}).get("source") or "unlocked (hand-installed or forked)"
    add("user-skill", src, "skill", name, fm.get("description", ""), True, f)

# --- B. CLI plugins (claude plugin list) ---
cache = CLAUDE / "plugins" / "cache"
cli_plugins = [
    ("21st", "21st/21st/0.4.0", True, ["skills/*/SKILL.md"], ["commands/*.md"], ["agents/*.md"]),
    ("codex", "openai-codex/codex/1.0.6", True, ["skills/*/SKILL.md"], ["commands/*.md"], ["agents/*.md"]),
    ("humanizer", "humanizer/humanizer/2.9.1", True, ["SKILL.md"], [], ["agents/*.md"]),
    ("impeccable", "impeccable/impeccable/4.0.2", True, ["skills/*/SKILL.md"], [], ["agents/*.md"]),
    ("ponytail", "ponytail/ponytail/4.8.4", True, ["skills/*/SKILL.md"], ["commands/*.md"], []),
    ("ui-ux-pro-max", "ui-ux-pro-max-skill/ui-ux-pro-max/2.6.2", True, [".claude/skills/*/SKILL.md"], [], []),
    ("claude-seo", "agricidaniel-claude-seo/claude-seo/2.2.4", False, ["skills/*/SKILL.md"], [], ["agents/*.md"]),
    ("ecc", "ecc/ecc/2.1.0", False, ["skills/*/SKILL.md"], ["commands/*.md"], ["agents/*.md"]),
]
for pname, rel, enabled, skglobs, cmdglobs, aggl in cli_plugins:
    root = cache / rel
    for kind, globs in (("skill", skglobs), ("command", cmdglobs), ("agent", aggl)):
        for g in globs:
            for f in sorted(root.glob(g)):
                fm = parse_fm(f) or {}
                nm = fm.get("name") or (f.parent.name if f.name == "SKILL.md" else f.stem)
                if pname == "humanizer" and kind == "skill":
                    nm = fm.get("name") or "humanizer"
                add("cli-plugin", pname, kind, nm, fm.get("description", ""), enabled, f, plugin=pname)

# --- C. Cowork / org plugins in the desktop app (rpm) ---
rpm_roots = list(APPDATA.glob("*/*/rpm"))
mcp_by_plugin = {}
org_meta = []
for rpm in rpm_roots:
    for pd in sorted(rpm.glob("plugin_*")):
        pj = pd / ".claude-plugin" / "plugin.json"
        if not pj.exists():
            continue
        meta = json.loads(pj.read_text(encoding="utf-8-sig"))
        pname = meta.get("name", pd.name)
        org_meta.append(dict(name=pname, version=meta.get("version", ""), desc=meta.get("description", "")))
        for f in sorted(pd.glob("skills/*/SKILL.md")):
            fm = parse_fm(f) or {}
            add("org-plugin", pname, "skill", f"{pname}:{fm.get('name') or f.parent.name}", fm.get("description", ""), True, f, plugin=pname)
        for f in sorted(pd.glob("commands/*.md")):
            fm = parse_fm(f) or {}
            add("org-plugin", pname, "command", f"{pname}:{f.stem}", fm.get("description", ""), True, f, plugin=pname)
        for f in sorted(pd.glob("agents/*.md")):
            fm = parse_fm(f) or {}
            add("org-plugin", pname, "agent", f"{pname}:{fm.get('name') or f.stem}", fm.get("description", ""), True, f, plugin=pname)
        mj = pd / ".mcp.json"
        if mj.exists():
            try:
                servers = json.loads(mj.read_text(encoding="utf-8-sig"))
                servers = servers.get("mcpServers", servers)
                mcp_by_plugin[pname] = sorted(servers.keys())
            except Exception:
                mcp_by_plugin[pname] = ["(unparsed .mcp.json)"]
        mj2 = pd / ".claude-plugin" / ".mcp.json"
        if mj2.exists() and pname not in mcp_by_plugin:
            try:
                servers = json.loads(mj2.read_text(encoding="utf-8-sig"))
                servers = servers.get("mcpServers", servers)
                mcp_by_plugin[pname] = sorted(servers.keys())
            except Exception:
                pass

# --- D. anthropic-skills (desktop app built-in) ---
for man in APPDATA.glob("skills-plugin/*/*/manifest.json"):
    for s in json.loads(man.read_text(encoding="utf-8-sig")).get("skills", []):
        add("anthropic-skills", "anthropic-skills (desktop app)", "skill", f"anthropic-skills:{s['name']}", s.get("description", ""), bool(s.get("enabled", True)), man)

# --- E. Claude Code bundled skills, descriptions copied from the live skill listing ---
sup = HERE / "bundled.json"
if sup.exists():
    for s in json.loads(sup.read_text(encoding="utf-8")):
        add("bundled", "Claude Code bundled", "skill", s["name"], s["desc"], True, sup)

# --- F. MCP configured via CLI, plus the needs-auth cache ---
needs = {}
try:
    needs = json.loads((CLAUDE / "mcp-needs-auth-cache.json").read_text(encoding="utf-8"))
except Exception:
    pass

import re as _re
cli_meta = []
txt = (HERE / "plugins.txt").read_text(encoding="utf-8-sig", errors="replace")
for blk in _re.split(r"\n\s*> ", txt)[1:]:
    nm = blk.splitlines()[0].strip()
    ver = _re.search(r"Version:\s*(\S+)", blk)
    en = "disabled" not in blk.split("Status:")[1]
    cli_meta.append(dict(name=nm, version=ver.group(1) if ver else "", enabled=en))
out = dict(cli_meta=cli_meta, org_meta=org_meta, records=records, mcp_by_plugin=mcp_by_plugin, needs_auth=sorted(needs.keys()),
           skills_dir_count=len([d for d in (CLAUDE / "skills").iterdir() if (d / "SKILL.md").exists()]))
(HERE / "inventory.json").write_text(json.dumps(out, indent=1), encoding="utf-8")

from collections import Counter, defaultdict
tot = defaultdict(int)
cnt = Counter()
for r in records:
    cnt[(r["group"], r["source"], r["kind"], r["enabled"])] += 1
for k, v in sorted(cnt.items()):
    print(k, v)
print("records", len(records), "skills dir", out["skills_dir_count"])
print("org plugin mcp:", {k: v for k, v in mcp_by_plugin.items()})
print("needs-auth cache keys:", len(needs))
