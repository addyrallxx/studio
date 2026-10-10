#!/usr/bin/env bash
# Wait for a partner model to come back from a usage limit, then exit so the
# orchestrator (Claude Code, launched with run_in_background) is woken and
# re-dispatches work. 2026-10-03: partners are probed automatically and
# kept busy whenever available.
#
#   partner-wait.sh codex  <codex-log>   # reads "try again at HH:MM [AM|PM]" from the log tail
#   partner-wait.sh gemini               # no reset time is published: probes every 20 min
#
# Prints "BACK <partner> <time>" and exits 0, or "GAVE UP" and exits 1 after 8 h.
set -u
export PATH="/c/Program Files/nodejs:$HOME/AppData/Roaming/npm:$PATH"
. "$(dirname "${BASH_SOURCE[0]}")/../codex/codex-lean.sh"
partner="${1:?codex|gemini}"
deadline=$(( $(date +%s) + 8*3600 ))

probe_codex() {
  out=$(echo "Reply with the single word OK." | codex exec -m gpt-6.1-sol -c model_reasoning_effort=low "${CODEX_LEAN[@]}" \
        --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox 2>&1 | tail -5)
  echo "$out" | grep -q "usage limit" && return 1
  echo "$out" | grep -qw "OK"
}
probe_gemini() {
  out=$(echo "Reply with the single word OK." | "$LOCALAPPDATA/agy/bin/agy.exe" \
        --model gemini-3.8-flash-low --new-project --print-timeout 3m --output-format stream-json 2>/dev/null)
  echo "$out" | grep -q '"status":"SUCCESS"'
}

if [ "$partner" = codex ] && [ -n "${2:-}" ]; then
  when=$(tail -c 4000 "$2" | grep -oE "try again at [0-9]{1,2}:[0-9]{2}( ?[AP]M)?" | tail -1 | sed 's/try again at //')
  if [ -n "$when" ]; then
    target=$(date -d "$when" +%s 2>/dev/null || echo 0)
    [ "$target" -gt 0 ] && [ "$target" -le "$(date +%s)" ] && target=$(( target + 86400 ))
    [ "$target" -gt 0 ] && { echo "codex resets at $when, sleeping $(( target - $(date +%s) + 60 ))s"; sleep $(( target - $(date +%s) + 60 )); }
  fi
fi

interval=$([ "$partner" = codex ] && echo 600 || echo 1200)
while [ "$(date +%s)" -lt "$deadline" ]; do
  if "probe_$partner"; then echo "BACK $partner $(date '+%H:%M')"; exit 0; fi
  echo "$partner still limited at $(date '+%H:%M'), next probe in ${interval}s"
  sleep "$interval"
done
echo "GAVE UP $partner after 8 h"; exit 1
