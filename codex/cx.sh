#!/usr/bin/env bash
# Launch one Codex run from brief files on stdin (never inline prompts).
# Usage: bash ~/.claude/tools/cx.sh <workdir> <model> <effort> <log> <brief> [more briefs...]
# Prints one status line (status, tokens, seconds) then the log tail. Always read the tail.
# Exit: 0 ok, 3 usage limit (exit 0 from codex itself still means "maybe limited"), 124 timeout, 2 bad args,
# otherwise codex's own code.
# Env: CX_TIMEOUT seconds (default 3600), CX_EXTRA extra codex args, CX_ALLOW_EXPENSIVE=1 to permit
# ultra or astra above medium (standing rule: never by default), CX_CODEX binary (default codex).
# Completion is read from the log ("tokens used"), never from process exit: a dev server Codex starts
# keeps the process tree alive (2026-10-01 idle hour). The timeout reaps anything left.
set -u
export PATH="/c/Program Files/nodejs:$HOME/AppData/Roaming/npm:$PATH"
. "$(dirname "${BASH_SOURCE[0]}")/codex-lean.sh"

[ $# -ge 5 ] || { echo "usage: cx.sh <workdir> <model> <effort> <log> <brief>..." >&2; exit 2; }
workdir=$1; model=$2; effort=$3; log=$4; shift 4
[ -d "$workdir" ] || { echo "cx: workdir not found: $workdir" >&2; exit 2; }
for b in "$@"; do [ -s "$b" ] || { echo "cx: brief missing or empty: $b" >&2; exit 2; }; done
case $effort in low|medium|high|xhigh|max|ultra) ;; *) echo "cx: bad effort '$effort'" >&2; exit 2;; esac
case "$model:$effort" in
  *:ultra|*astra*:high|*astra*:xhigh|*astra*:max)
    [ "${CX_ALLOW_EXPENSIVE:-}" = 1 ] || { echo "cx: refusing $model at $effort (no ultra, no astra above medium). CX_ALLOW_EXPENSIVE=1 overrides." >&2; exit 2; };;
esac

limit="^ERROR: You.{1,3}ve hit your usage limit"
start=$(date +%s)
: > "$log"
# shellcheck disable=SC2086
cat "$@" | timeout -k 20 "${CX_TIMEOUT:-3600}" "${CX_CODEX:-codex}" exec -m "$model" \
  -c model_reasoning_effort="$effort" "${CODEX_LEAN[@]}" --skip-git-repo-check \
  --dangerously-bypass-approvals-and-sandbox -C "$workdir" ${CX_EXTRA:-} >> "$log" 2>&1 &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
  grep -q '^tokens used' "$log" && break
  grep -Eq "$limit" "$log" && break
  sleep 3
done
sleep 2
if kill -0 "$pid" 2>/dev/null; then rc=0; alive=1; else wait "$pid"; rc=$?; alive=0; fi

if grep -Eq "$limit" "$log"; then status=usage-limit; rc=3
elif [ "$rc" = 124 ] || [ "$rc" = 137 ]; then status=timeout
elif grep -q '^tokens used' "$log"; then status=ok
else status="failed(rc=$rc)"; [ "$rc" = 0 ] && rc=1
fi
tok=$(grep -A1 '^tokens used' "$log" | tail -1)
echo "cx: status=$status model=$model effort=$effort tokens=${tok:-?} seconds=$(( $(date +%s) - start )) log=$log"
[ "$alive" = 1 ] && [ "$status" = ok ] && echo "cx: note: codex pid $pid still alive after finishing (a dev server it started?); the timeout reaps it."
[ "$status" = usage-limit ] && echo "cx: usage limit. Reset time is in the log tail. Run partner-wait.sh codex $log in the background, then re-run."
tail -20 "$log" | grep -v '^hook\|tokens used'
exit "$rc"
