# studio

The tooling behind how I build. One person, three models, one standard.

Claude Code plans and reviews. Codex and Gemini build and second-source. Each agent owns its own files, a different model reviews every diff, and nothing counts as done until I re-run the result myself.

These scripts are the plumbing that makes that cheap enough to run every day.

| Folder | What it does |
|---|---|
| `gemini/` | `gem.ps1` drives Gemini headlessly through the Antigravity CLI: single-shot or tool mode, a turn cap, a deliverable check, and exit codes that say why a run failed instead of pretending it worked. `gem2-pack.md` is the brief preamble it injects. |
| `codex/` | `cx.sh` wraps `codex exec` with a timeout and refuses the most expensive model and effort settings unless asked. `codex-lean.sh` holds the lean flags, `codex-run.sh` runs one brief, `codex-skills-prune.mjs` keeps Codex's skill list from bloating every call. |
| `quota/` | `ai-usage.ps1` reads Codex's own session logs and reports what quota is left, so the planner can decide whether to delegate without asking. |
| `routing/` | `partner-wait.sh` sleeps until a rate-limited model comes back, then wakes the planner. `or-free.py` calls OpenRouter's free models only, and refuses anything paid. `idle-guard.ps1` keeps long unattended runs honest. |
| `atlas/` | `inventory.py` builds an index of every installed skill, plugin and CLI, so the planner picks a tool from a list instead of from memory. |

## Rules the scripts enforce

- A run that exits 0 is a finished turn, not a result. Read the output.
- Set the model and effort on every call. Defaults are the expensive ones.
- No paid API. Free tiers and flat subscriptions only.

Windows first (PowerShell and Git Bash), because that's the machine. Paths use `$HOME`; set `GEM_PLAN_ACCOUNT` if you want `gem.ps1` to check which account is signed in.

MIT licensed.
