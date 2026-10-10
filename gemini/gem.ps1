<#
.SYNOPSIS
  gem2: drive Gemini (and the Claude/GPT models on the same plan) headlessly through
  the Antigravity CLI `agy`, built from the measured token economics of the
  2026-10-05 overnight lane. Sits beside gem.ps1; same call shape, same exit codes.

.DESCRIPTION
  What changed against gem.ps1, each item with its evidence
  (wiki/resources/gemini-bridge-v2.md):

  1. -Mode singleshot|tools. Five tool-driven jobs spent 25 to 40 turns exploring
     files and wrote nothing; two single-shot jobs (all inputs inline, no tools)
     delivered in 81 s and 165 s. Singleshot runs the toolless `gem-oneshot` agent
     (first turn 1.2k tokens against 13.5k to 16.4k for the default agent), answer
     lands in <brief>.log. Tools mode runs the DEFAULT agent (a lean custom agent was
     tested and rejected: it cannot invoke subagents and gets no prompt caching, so
     it saved no quota per turn) and forces "write the deliverable skeleton first,
     rewrite after every item".
  2. Skill pack. The ponytail core, no-em-dash and verify-by-opening-sources rules.
     Singleshot: native, inside ~/.gemini/config/agents/gem-oneshot/agent.md (agy's
     custom-agent mechanism, selected with --agent; not a global rule, so gem.ps1
     runs are untouched). Tools mode: gem2-pack.md prepended to the stdin primer
     (about 470 tokens). Keep the two texts in step.
  3. Routing table (-Task): task type to model, mode and turn cap.
  4. UTF-8 everywhere (brief in, stdin file out, event stream in, answer out; no BOM).
     gem.ps1 read the event stream with the ANSI default and would mangle non-ASCII.
  5. Turn counter counts real model turns: one `agent_response` step in state DONE
     is one turn. The final `result` event ALSO carries a usage object (an aggregate),
     so counting every "usage": line (gem.ps1) over-counts by one and double-counts
     tokens. result.num_turns counts user prompts (always 1), not model turns.
  6. Quota is readable for free: `agy -p "/quota"` answers with zero model turns and
     zero quota. gem2 reads it before the run (exit 4 below the floor) and after it
     (prints the debit). The pools are separate: "Gemini Models" (Flash + Pro) and
     "Claude and GPT models".
  7. Money gate, unchanged in spirit and tightened: API-key env vars are cleared for
     the child, the agy log must say authMethod=consumer on the plan account, and any
     AI-credits setting that is on aborts the run.

  Exit codes (unchanged from gem.ps1, plus 6): 0 ok, 2 timeout, 3 account/auth/credits
  mismatch, 4 quota exhausted or below floor, 5 turn cap hit (partial output),
  6 agy itself reported an error (agy uses 3 for that; remapped to avoid the clash).
  7 research/sourcing run opened no pages (read_url_content=0): snippet-grade, not research (2026-10-09).

.PARAMETER BriefFile   File holding the prompt. Always a file.
.PARAMETER Task        Routing key. See $Routes below. -Model/-Mode/-MaxTurns override it.
.PARAMETER Mode        singleshot (no tools, answer in <brief>.log) or tools.
.PARAMETER Include     Files to append to the brief as inline excerpts (singleshot input).
.PARAMETER Deliverable Path of the file a tools-mode run must create first (checked after).
.PARAMETER ReadOnly    Prepend a do-not-modify instruction (prompt level, not a sandbox).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BriefFile,
  [string]$WorkDir = (Get-Location).Path,
  [string]$OutFile,
  [ValidateSet("research","sourcing","extract","draft","review","critique","visual","audit","longcontext","write","code")][string]$Task = "research",
  [ValidateSet("singleshot","tools")][string]$Mode,
  [string]$Model,
  [string]$Effort,
  [int]$MaxTurns,
  [string[]]$Include,
  [int]$IncludeMaxKB = 150,
  [string]$Deliverable,
  [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Conversation,
  [switch]$ReadOnly,
  [switch]$NoAgent,
  [switch]$DryRun,
  [switch]$IgnoreQuota,
  [double]$QuotaFloor = 0.04,
  [int]$TimeoutMinutes = 30
)

$ErrorActionPreference = "Stop"
$agy = Join-Path $env:LOCALAPPDATA "agy\bin\agy.exe"
$planAccount = $env:GEM_PLAN_ACCOUNT  # set to the Google account email the plan belongs to; unset skips the account check
$utf8 = New-Object System.Text.UTF8Encoding $false

if (-not (Test-Path $agy)) { throw "agy not found at $agy" }
if (-not (Test-Path $BriefFile)) { throw "brief not found at $BriefFile" }
if (-not (Test-Path $WorkDir)) { throw "work dir not found at $WorkDir" }
if (-not $OutFile) { $OutFile = [System.IO.Path]::ChangeExtension($BriefFile, ".log") }

# ---- Routing table: task type -> model, mode, turn cap, reason -------------------
# Flash and Pro share ONE quota pool; Claude and GPT models are a SEPARATE pool that
# burns about 1 percent of its weekly allowance per tiny call, so use it for short
# single-shot judgement or prose only, never for tool loops.
$Routes = @{
  research    = @{ Model = "gemini-3.8-flash-medium"; Mode = "tools";      Turns = 30; Why = "verified web research; tools verified working at flash" }
  sourcing    = @{ Model = "gemini-3.8-flash-medium"; Mode = "tools";      Turns = 40; Why = "list-shaped fetch and extract; batch per command; fan out on Model flash only if the brief says" }
  extract     = @{ Model = "gemini-3.8-flash-medium"; Mode = "singleshot"; Turns = 2;  Why = "pre-fetched text to structured data; no tools needed" }
  draft       = @{ Model = "gemini-3.8-flash-medium"; Mode = "singleshot"; Turns = 2;  Why = "bulk prose and drafts from inline material" }
  review      = @{ Model = "gemini-3.8-flash-high";   Mode = "singleshot"; Turns = 2;  Why = "diff or doc review with the diff inline; judgement earns high effort (thinking is priced as output)" }
  critique    = @{ Model = "gemini-3.8-flash-high";   Mode = "singleshot"; Turns = 2;  Why = "adversarial critique of inline material" }
  visual      = @{ Model = "gemini-3.8-flash-high";   Mode = "tools";      Turns = 12; Why = "multimodal critique: needs view_file to open PNGs" }
  audit       = @{ Model = "gemini-3.1-pro-high";     Mode = "singleshot"; Turns = 2;  Why = "long-context audit; measured 79k tokens in, 8.5k out, 70 s, delivered" }
  longcontext = @{ Model = "gemini-3.1-pro-high";     Mode = "singleshot"; Turns = 2;  Why = "1M-token reading with everything inline" }
  write       = @{ Model = "claude-sonnet-5-5-medium"; Mode = "singleshot"; Turns = 2; Why = "Claude-quality prose off the Claude Code limit; separate pool, short outputs only" }
  code        = @{ Model = "gemini-3.8-flash-medium"; Mode = "tools";      Turns = 20; Why = "last resort builder (Codex is better); one small item per run, owned files named" }
}
$route = $Routes[$Task]
if (-not $Model)    { $Model = $route.Model }
if (-not $Mode)     { $Mode = $route.Mode }
if (-not $MaxTurns) { $MaxTurns = if ($Mode -ne $route.Mode) { if ($Mode -eq "singleshot") { 2 } else { 30 } } else { $route.Turns } }
$agentName = if ($Mode -eq "singleshot") { "gem-oneshot" } else { "" }
$pool = if ($Model -like "gemini-*") { "Gemini Models" } else { "Claude and GPT models" }

# ---- Money gate (absolute) -------------------------------------------------------
# agy switches to API billing semantics when these variables exist. Clear them for
# the child process; restore afterwards.
$savedEnv = @{}
foreach ($n in "GEMINI_API_KEY","GOOGLE_API_KEY","GOOGLE_GENAI_USE_VERTEXAI","GOOGLE_CLOUD_PROJECT","GOOGLE_APPLICATION_CREDENTIALS") {
  $v = [Environment]::GetEnvironmentVariable($n, "Process")
  if ($v) { $savedEnv[$n] = $v; [Environment]::SetEnvironmentVariable($n, $null, "Process") }
}
foreach ($cfg in (Join-Path $HOME ".gemini\config\config.json"), (Join-Path $HOME ".gemini\antigravity-cli\settings.json")) {
  if (Test-Path $cfg) {
    $raw = [System.IO.File]::ReadAllText($cfg, $utf8)
    if ($raw -match '(?i)"(useG1Credits|useAiCredits|UseG1Credits)"\s*:\s*true') {
      Write-Output "MONEY GATE: AI credits are switched on in $cfg. Credits can be paid. Turn it off, then rerun."
      exit 3
    }
  }
}

# ---- Free quota read: agy -p "/quota" is answered locally, no model turn ----------
function Get-Quota {
  try {
    $raw = (& $agy -p "/quota" --output-format json 2>$null | Out-String)
    $j = $raw | ConvertFrom-Json
    $q = @{}
    foreach ($g in $j.command.data.groups) {
      foreach ($b in $g.buckets) { $q["$($g.name)|$($b.window)"] = [double]$b.remaining_fraction; $q["$($g.name)|$($b.window)|reset"] = $b.reset_time }
    }
    return $q
  } catch { return $null }
}
function Fmt($q, $g) {
  if ($null -eq $q) { return "unreadable" }
  "5h={0:P1} wk={1:P1}" -f $q["$g|5h"], $q["$g|weekly"]
}
$q0 = Get-Quota
if ($q0) {
  Write-Output ("quota before: gemini {0} | claude+gpt {1}" -f (Fmt $q0 "Gemini Models"), (Fmt $q0 "Claude and GPT models"))
  $r5 = $q0["$pool|5h"]; $rw = $q0["$pool|weekly"]
  if (-not $IgnoreQuota -and $null -ne $r5 -and $null -ne $rw -and ($r5 -lt $QuotaFloor -or $rw -lt $QuotaFloor)) {
    $resets = if ($r5 -lt $QuotaFloor) { $q0["$pool|5h|reset"] } else { $q0["$pool|weekly|reset"] }
    Write-Output "QUOTA EXHAUSTED: pool '$pool' is below the $([int]($QuotaFloor*100)) percent floor. Resets at $resets (UTC). Launch partner-wait.sh gemini and requeue this brief, or pass -IgnoreQuota."
    exit 4
  }
}

# ---- Build the stdin file: primer + brief (+ inline files) ------------------------
$stdinFile = [System.IO.Path]::ChangeExtension($BriefFile, ".in.txt")
$moneyGate = "- MONEY GATE (absolute): never call a paid API. Never use any API key or token from the environment or from files (including any GOOGLE_API_KEY). Never call generativelanguage.googleapis.com, aiplatform.googleapis.com, Vertex AI, Veo, Imagen, Nano Banana or any image or video generation API. Never install or configure anything that asks for a Gemini or Google API key. Never switch on AI credits. Your own built-in tools are free; stay inside them."
if ($Mode -eq "singleshot") {
  $primer = @(
    "RUN NOTES (from the orchestrator):",
    "- SINGLE-SHOT: you have no tools and one turn. Everything you need is in this message. Do not ask to look anything up. If something is missing, say exactly what and mark the dependent claim UNVERIFIED.",
    "- Put the COMPLETE deliverable in your final message, in the format the brief asks for. It is saved verbatim as the output file.",
    $moneyGate,
    ""
  ) -join "`n"
} else {
  $deliv = if ($Deliverable) { "Your deliverable file is $Deliverable." } else { "Your deliverable is the output file your brief names." }
  $packFile = Join-Path (Split-Path -Parent $PSCommandPath) "gem2-pack.md"
  $pack = if (Test-Path $packFile) { [System.IO.File]::ReadAllText($packFile, $utf8) } else { "" }
  $primer = @(
    $pack,
    "RUN NOTES (from the orchestrator):",
    "- TOOLS MODE. Windows PowerShell via run_command (use curl.exe, not curl); also view_file, write_to_file, replace_file_content, search_web, read_url_content.",
    "- FIRST ACTION, before any exploration: write the deliverable skeleton (headings with PENDING markers). $deliv Then rewrite it after EVERY finished item. A stop at the cap must lose one item, never the job.",
    "- BUDGET (absolute): finish within $MaxTurns model turns; the run is killed at that cap. Do not explore directories. Open only files and URLs the brief names. Never view_file a file over 30 KB.",
    "- SUBAGENTS: none unless the brief says so. If it does: invoke_subagent with TypeName research and Model flash (the cheap tier, verified to run gemini-3.8-flash-tiered even under a Pro parent). A subagent starts with NO context, so its Prompt must carry the task, the sources and the exact return format. Subagents are ASYNC: after invoking, call the wait tool until each reports idle and read its reply before you answer; ending your turn early loses their results. Never invent a subagent's reply.",
    "- WRITE SCOPE (absolute): create or change only the files your brief names as yours. Never edit any other existing file; never run git commands that change state (stash, checkout, restore, reset, clean, commit, push). Helper scripts go in a gemini-scratch folder in the working directory, deleted when you finish.",
    $(if ($Task -in @("research","sourcing")) { "- VERIFY BY OPENING (absolute): search_web only FINDS pages; its snippets are not sources. Every fact, number, cap, date or rule you write must come from a page you opened with read_url_content (or curl.exe) in this run, cited with that exact URL. Anything you only saw in a snippet goes under an 'Unverified' heading at the end. Budget: one search, then open the one or two best primary pages (the company's own page, the government page, the statute); never open more than three pages per item. The orchestrator counts read_url_content calls and fails a run that opened none." } else { "" }),
    $moneyGate,
    ""
  ) -join "`n"
}
$preamble = ""
if ($ReadOnly) {
  $preamble = @(
    "READ ONLY TASK. Do not create, edit, move or delete any file, anywhere.",
    "You may read files and run read only commands such as git diff and git log.",
    "Your entire output is a report. If you believe a file must change, describe the change instead of making it.",
    ""
  ) -join "`n"
}
$body = [System.IO.File]::ReadAllText($BriefFile, $utf8)
if ($Include) {
  $inc = New-Object System.Text.StringBuilder
  foreach ($p in $Include) {
    if (-not (Test-Path $p)) { throw "-Include file not found: $p" }
    $t = [System.IO.File]::ReadAllText($p, $utf8)
    $cap = $IncludeMaxKB * 1024
    if ($t.Length -gt $cap) { $t = $t.Substring(0, $cap) + "`n[TRUNCATED at $IncludeMaxKB KB by gem2]" }
    [void]$inc.Append("`n`n=== FILE: $p ===`n$t`n=== END FILE ===`n")
  }
  $body += $inc.ToString()
}
$stdinText = $primer + $preamble + $body
[System.IO.File]::WriteAllText($stdinFile, $stdinText, $utf8)
$approxTokens = [int]($stdinText.Length / 4)
if ($Mode -eq "singleshot" -and $stdinText.Length -gt 600KB) { Write-Output "WARNING: singleshot input is about $approxTokens tokens. Trim it or use gemini-3.1-pro-high." }
$jsonl = [System.IO.Path]::ChangeExtension($OutFile, ".jsonl")
$agyLog = [System.IO.Path]::ChangeExtension($OutFile, ".agy.log")
if ($DryRun) {
  foreach ($k in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k], "Process") }
  Write-Output "DRY RUN: mode=$Mode task=$Task model=$Model agent=$(if ($agentName -and -not $NoAgent) { $agentName } else { 'default' }) maxturns=$MaxTurns pool='$pool' stdin=$stdinFile chars=$($stdinText.Length) approx-tokens=$approxTokens (no model call made)"
  exit 0
}

$agyArgs = @(
  "--model", $Model,
  "--add-dir", "`"$WorkDir`"",
  "--dangerously-skip-permissions",
  "--print-timeout", "$($TimeoutMinutes)m",
  "--output-format", "stream-json",
  "--log-file", "`"$agyLog`""
)
if ($agentName -and -not $NoAgent) { $agyArgs += @("--agent", $agentName) }
if ($Conversation) { $agyArgs += @("--conversation", $Conversation) } else { $agyArgs += "--new-project" }
if ($Effort) { $agyArgs += @("--effort", $Effort) }

# ---- Run, with a real model-turn cap ---------------------------------------------
function Count-Turns($path) {
  try { return @(Select-String -Path $path -Pattern '"step_type":"agent_response"' -SimpleMatch -ErrorAction Stop | Where-Object { $_.Line.Contains('"state":"DONE"') }).Count } catch { return 0 }
}
$startedAt = Get-Date
$capped = $false
Push-Location $WorkDir
try {
  $proc = Start-Process -FilePath $agy -ArgumentList $agyArgs `
    -RedirectStandardInput $stdinFile -RedirectStandardOutput $jsonl -RedirectStandardError "$OutFile.err" `
    -NoNewWindow -PassThru
  $null = $proc.Handle  # PS 5.1: cache the handle or ExitCode comes back null
  $deadline = $startedAt.AddMinutes($TimeoutMinutes)
  while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if ((Count-Turns $jsonl) -ge $MaxTurns) {
      # Let the turn that just finished flush, then stop the tree (our own child only).
      Start-Process -FilePath "taskkill.exe" -ArgumentList @("/PID", "$($proc.Id)", "/T", "/F") -NoNewWindow -Wait -ErrorAction SilentlyContinue
      $capped = $true; break
    }
  }
  if (-not $capped -and -not $proc.WaitForExit(1000)) {
    Start-Process -FilePath "taskkill.exe" -ArgumentList @("/PID", "$($proc.Id)", "/T", "/F") -NoNewWindow -Wait -ErrorAction SilentlyContinue
    Write-Output "TIMEOUT after $TimeoutMinutes min. Quota may be the cause: read it with agy -p /quota, then route elsewhere rather than retrying blind."
    exit 2
  }
  $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
  $exitCode = if ($capped -or $null -eq $proc.ExitCode) { 0 } else { [int]$proc.ExitCode }
}
finally {
  Pop-Location
  foreach ($k in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k], "Process") }
}

# ---- Parse the event stream (UTF-8), one pass ------------------------------------
$status = "NO_RESULT"; $tools = @{}; $conversationId = "unknown"; $initModel = ""; $initTools = 0
$answer = ""; $err = ""
$turnsByConv = @{}; $fresh = 0; $cached = 0; $outTok = 0; $think = 0; $turns = 0
if (Test-Path $jsonl) {
  foreach ($line in [System.IO.File]::ReadLines($jsonl, $utf8)) {
    if (-not $line.StartsWith("{")) { continue }
    $isDone = $line.Contains('"state":"DONE"'); $isInit = $line.Contains('"event":"init"'); $isResult = $line.Contains('"event":"result"')
    if (-not ($isDone -or $isInit -or $isResult)) { continue }
    try { $ev = $line | ConvertFrom-Json } catch { continue }
    if ($ev.event -eq "init") {
      $conversationId = $ev.conversation_id; $initModel = $ev.init.model; $initTools = @($ev.init.tools).Count
    } elseif ($ev.event -eq "result") {
      $status = $ev.result.status
      if ($ev.result.response) { $answer = [string]$ev.result.response }
      if ($ev.result.error) { $err = [string]$ev.result.error }
    } elseif ($ev.event -eq "step_update") {
      $s = $ev.step_update
      if ($s.step_type -eq "agent_response" -and $s.state -eq "DONE" -and $s.usage) {
        $turns++; $fresh += [int64]$s.usage.input_tokens; $cached += [int64]$s.usage.cache_read_tokens
        $outTok += [int64]$s.usage.output_tokens; $think += [int64]$s.usage.thinking_tokens
        $c = "$($s.conversation_id)".Substring(0, [Math]::Min(8, "$($s.conversation_id)".Length)); $turnsByConv[$c] = 1 + [int]$turnsByConv[$c]
      } elseif (($s.step_type -eq "tool" -or $s.step_type -eq "subagent") -and $s.tool_name) {
        $tools[$s.tool_name] = 1 + [int]$tools[$s.tool_name]
      }
    }
  }
}
if ($capped) { $status = "TURN_CAP" }
$text = $answer; if ($err) { $text += "`nERROR: $err" }
[System.IO.File]::WriteAllText($OutFile, $text, $utf8)
$size = (Get-Item $OutFile).Length
$toolLine = ($tools.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join " "
$costEq = ($fresh * 0.75 + $cached * 0.075 + $outTok * 3.75) / 1e6

Write-Output "exit=$exitCode status=$status mode=$Mode task=$Task seconds=$elapsed bytes=$size log=$OutFile events=$jsonl"
Write-Output "conversation=$conversationId agent=$(if ($agentName -and -not $NoAgent) { $agentName } else { 'default' }) model=$Model (init: $initModel, $initTools tools registered) route-why: $($route.Why)"
$convLine = ($turnsByConv.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " "
Write-Output "usage: turns=$turns/$MaxTurns [$convLine] fresh=$fresh cached=$cached out=$outTok think=$think approx-cost=`$$([Math]::Round($costEq,3)) flash-list-price-equivalent$(if ($capped) { ' STOPPED AT TURN CAP: output is partial' })"
$expect = if ($Mode -eq "singleshot") { if ($toolLine) { "tools: UNEXPECTED in singleshot: $toolLine" } else { "tools: none (as intended for singleshot)" } } else { if ($toolLine) { "tools: $toolLine" } else { "tools: NONE (answered from memory: treat external facts as unverified)" } }
Write-Output $expect

if ($Deliverable) {
  if (Test-Path $Deliverable) { Write-Output "deliverable: $Deliverable bytes=$((Get-Item $Deliverable).Length)" } else { Write-Output "deliverable: MISSING $Deliverable" }
}

# ---- Quota after, and quota exhaustion mid-run -----------------------------------
$q1 = Get-Quota
if ($q0 -and $q1) {
  $dg5 = ($q0["Gemini Models|5h"] - $q1["Gemini Models|5h"]) * 100; $dgw = ($q0["Gemini Models|weekly"] - $q1["Gemini Models|weekly"]) * 100
  $dc5 = ($q0["Claude and GPT models|5h"] - $q1["Claude and GPT models|5h"]) * 100; $dcw = ($q0["Claude and GPT models|weekly"] - $q1["Claude and GPT models|weekly"]) * 100
  Write-Output ("quota after:  gemini {0} | claude+gpt {1}" -f (Fmt $q1 "Gemini Models"), (Fmt $q1 "Claude and GPT models"))
  Write-Output ("quota debit:  gemini 5h {0:N2}pp wk {1:N2}pp | claude+gpt 5h {2:N2}pp wk {3:N2}pp (includes any other agy run active meanwhile)" -f $dg5, $dgw, $dc5, $dcw)
}
$quota = @(Get-Content $jsonl, "$OutFile.err" -ErrorAction SilentlyContinue | Select-String -Pattern "Individual quota reached|RESOURCE_EXHAUSTED|credits balance is too low" | Select-Object -Last 1)
if ($quota.Count -gt 0) {
  $resets = [regex]::Match($quota[0].Line, "Resets in [0-9hms]+").Value
  Write-Output "QUOTA EXHAUSTED: $resets. Output is partial. Launch partner-wait.sh gemini and requeue this brief."
  exit 4
}

# ---- Account and auth method ------------------------------------------------------
$acct = ""; $auth = ""
if (Test-Path $agyLog) {
  $m = Select-String -Path $agyLog -Pattern "applyAuthResult: email=([^,\s]+), authMethod=(\w+)" | Select-Object -Last 1
  if ($m) { $acct = $m.Matches.Groups[1].Value; $auth = $m.Matches.Groups[2].Value }
}
if ($planAccount -and (($acct -and $acct -ne $planAccount) -or ($auth -and $auth -ne "consumer"))) {
  Write-Output "ACCOUNT MISMATCH: agy ran as $acct via authMethod=$auth, not the plan account $planAccount via consumer login. Re-login agy (open Antigravity, sign in with the plan account) before trusting quota or cost."
  exit 3
}
Write-Output "account: $(if ($acct) { "$acct authMethod=$auth" } else { 'unknown (no auth line in agy log)' })"

# ---- Failure signatures ------------------------------------------------------------
if ($size -lt 200 -and $status -ne "SUCCESS" -and -not $capped) {
  Write-Output "WARNING: log is nearly empty and status=$status. Check $OutFile.err for an auto-denied tool permission or a bad --agent name."
  if (Test-Path "$OutFile.err") { Get-Content -Tail 5 "$OutFile.err" | ForEach-Object { Write-Output "  err: $_" } }
}
if ($Task -in @("research","sourcing") -and -not $capped) {
  if ([int]$tools["read_url_content"] -eq 0) {
    Write-Output "UNVERIFIED RESEARCH: $Task run opened no pages with read_url_content (run_command=$([int]$tools['run_command'])). Treat every external fact as snippet-grade; do not count this as research. Requeue with named primary URLs instead of retrying blind."
    exit 7
  }
}
if ($capped) { Write-Output "TURN CAP: stopped at $MaxTurns turns. Read the partial deliverable; requeue only what is left, with a tighter brief."; exit 5 }
if ($exitCode -ne 0) { Write-Output "AGY ERROR: agy exited $exitCode (see $OutFile.err)."; exit 6 }
exit 0
