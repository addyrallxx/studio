#!/usr/bin/env bash
# Run one Codex brief to completion without hanging on processes Codex leaves running.
# Usage: codex-run.sh <brief.md> <workdir> [effort=medium] [model=gpt-6.1-sol]
# Log: <brief>.log next to the brief. Completion is read from the log ("tokens used"), never from
# `wait`: a dev server Codex starts keeps the process tree alive (2026-10-01, cost an idle hour).
# Only Codex's own line-start "ERROR: You.ve hit your usage limit" counts: Codex echoes files
# that quote that text, and a loose match once started a duplicate run (2026-10-01).
# If the regular pool is out, it re-runs the same brief once on the
# Luna Reserve (`gpt-reserve`), which only has room after the regular pool is empty.
set -u
brief="$1"; dir="$2"; effort="${3:-medium}"; model="${4:-gpt-6.1-sol}"
log="${brief%.md}.log"
export PATH="$HOME/AppData/Roaming/npm:/c/Program Files/nodejs:$PATH"
. "$(dirname "${BASH_SOURCE[0]}")/codex-lean.sh"

run() { # $1 model, $2 effort, $3 log
  : > "$3"
  (cd "$dir" && nohup codex exec -m "$1" -c model_reasoning_effort="$2" "${CODEX_LEAN[@]}" --skip-git-repo-check \
    --dangerously-bypass-approvals-and-sandbox < "$brief" >> "$3" 2>&1 &)
  until grep -q "^tokens used" "$3" 2>/dev/null || grep -Eq "^ERROR: You.{1,3}ve hit your usage limit" "$3" 2>/dev/null; do sleep 20; done
  sleep 5
}

run "$model" "$effort" "$log"
if grep -Eq "^ERROR: You.{1,3}ve hit your usage limit" "$log" && [ "$model" != "gpt-reserve" ]; then
  echo "== regular pool out, re-running on gpt-reserve"
  mv "$log" "${log%.log}.regular.log"
  run gpt-reserve "$effort" "$log"
fi
echo "== $(basename "$brief") ($(grep -m1 -o 'model: [^ ]*' "$log" 2>/dev/null))"
tail -c 1500 "$log"
