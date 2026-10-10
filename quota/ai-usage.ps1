#Requires -Version 5.1
<#
.SYNOPSIS
  Reports remaining Codex and Gemini/Antigravity quota so Claude Code can
  decide whether to delegate to them, without asking the user.

.DESCRIPTION
  Codex: reads the newest rate_limits entry out of Codex CLI's own session
  rollout JSONL files under ~\.codex\sessions. Entries with
  limit_id "premium" (primary/secondary both null) carry no usage data and
  are skipped. "Newest" is decided by file last-write-time first, then by
  position within that file (last matching line wins).

  Gemini/Antigravity: no numeric quota file has ever been found on this
  machine (searched under ~\.gemini). Reported instead as
  "running" (language_server.exe with --app_data_dir antigravity on its
  command line) or "not running". Do not invent a percentage for it.

.PARAMETER Json
  Emit one JSON object to stdout instead of the human block.

.PARAMETER SessionsRoot
  Override the Codex sessions directory for fixture checks.
#>
param(
    [switch]$Json,
    [string]$SessionsRoot = (Join-Path $env:USERPROFILE '.codex\sessions')
)

$ErrorActionPreference = 'Stop'

function Get-CodexUsage {
    $sessionsRoot = $SessionsRoot
    if (-not (Test-Path $sessionsRoot)) {
        return @{ available = $false; detail = "no .codex\sessions directory found at $sessionsRoot" }
    }

    $files = Get-ChildItem -Path $sessionsRoot -Filter 'rollout-*.jsonl' -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if ($null -eq $files -or $files.Count -eq 0) {
        return @{ available = $false; detail = "no rollout-*.jsonl files found under $sessionsRoot" }
    }

    # Stop once both pools are found. A pool may be absent from recent files.
    $candidateFiles = @($files)

    $best = $null
    $reserve = $null
    $bestFile = $null
    $bestFileWriteTime = $null

    foreach ($f in $candidateFiles) {
        $lines = @(Get-Content -Path $f.FullName -ErrorAction SilentlyContinue)
        if ($null -eq $lines) { continue }

        $reserveModel = $false
        foreach ($line in $lines) {
            if ($line -notmatch '"turn_context"') { continue }
            try { $context = $line | ConvertFrom-Json } catch { continue }
            if ($context.payload.model -eq 'gpt-reserve') { $reserveModel = $true }
        }

        # File write time ranks files; last matching line wins within each pool.
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = $lines[$i]
            if ($line -notmatch '"rate_limits"') { continue }

            $obj = $null
            try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }

            $rl = $null
            if ($null -ne $obj.payload) { $rl = $obj.payload.rate_limits }
            if ($null -eq $rl) { continue }
            if ($null -eq $rl.primary) { continue }
            if ($rl.limit_id -eq 'premium') { continue }

            if (($rl.primary.window_minutes -eq 10080 -and $null -eq $rl.secondary) -or $reserveModel) {
                if ($null -eq $reserve) {
                    $epoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
                    $reset = $epoch.AddSeconds([double]$rl.primary.resets_at)
                    $reserve = @{
                        used_percent = [double]$rl.primary.used_percent
                        resets_at = $reset.ToLocalTime().ToString('yyyy-MM-ddTHH:mm:sszzz')
                        reading_age_minutes = [math]::Max(0, [math]::Round(([datetime]::UtcNow - $f.LastWriteTime.ToUniversalTime()).TotalMinutes))
                    }
                }
                continue
            }
            if ($rl.primary.window_minutes -ne 300 -or ($null -ne $rl.secondary -and $rl.secondary.window_minutes -ne 10080)) { continue }

            # Candidate found for this file. File LastWriteTime ranks files;
            # within the winning file we already picked the last matching line.
            if ($null -eq $best -or $f.LastWriteTime -gt $bestFileWriteTime) {
                $best = $rl
                $bestFile = $f.FullName
                $bestFileWriteTime = $f.LastWriteTime
            }
        }
        if ($null -ne $best -and $null -ne $reserve) { break }
    }

    if ($null -eq $best) {
        return @{ available = $false; reserve = $reserve; detail = "no regular pool rate_limits found in $($candidateFiles.Count) rollout files" }
    }

    $nowUtc = [DateTime]::UtcNow
    $epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)

    $primaryUsed = [double]$best.primary.used_percent
    $primaryLeft = 100.0 - $primaryUsed
    $primaryResetsAtUtc = $epoch.AddSeconds([double]$best.primary.resets_at)
    $primaryResetsInMin = [math]::Round(($primaryResetsAtUtc - $nowUtc).TotalMinutes)

    $secondaryUsed = $null
    $secondaryLeft = $null
    $secondaryResetsAtUtc = $null
    $secondaryResetsInMin = $null
    if ($null -ne $best.secondary) {
        $secondaryUsed = [double]$best.secondary.used_percent
        $secondaryLeft = 100.0 - $secondaryUsed
        $secondaryResetsAtUtc = $epoch.AddSeconds([double]$best.secondary.resets_at)
        $secondaryResetsInMin = [math]::Round(($secondaryResetsAtUtc - $nowUtc).TotalMinutes)
    }

    $plan = $best.plan_type
    if ($null -eq $plan) { $plan = 'unknown' }

    $readingAgeMin = [math]::Round(($nowUtc - $bestFileWriteTime.ToUniversalTime()).TotalMinutes)
    if ($readingAgeMin -lt 0) { $readingAgeMin = 0 }

    return @{
        reserve      = $reserve
        available    = $true
        five_hour    = @{
            used_percent      = $primaryUsed
            left_percent      = $primaryLeft
            resets_at_iso     = $primaryResetsAtUtc.ToLocalTime().ToString('yyyy-MM-ddTHH:mm:sszzz')
            resets_at_local   = $primaryResetsAtUtc.ToLocalTime()
            resets_in_minutes = $primaryResetsInMin
        }
        weekly       = @{
            used_percent      = $secondaryUsed
            left_percent      = $secondaryLeft
            resets_at_iso     = $(if ($null -ne $secondaryResetsAtUtc) { $secondaryResetsAtUtc.ToLocalTime().ToString('yyyy-MM-ddTHH:mm:sszzz') } else { $null })
            resets_at_local   = $(if ($null -ne $secondaryResetsAtUtc) { $secondaryResetsAtUtc.ToLocalTime() } else { $null })
            resets_in_minutes = $secondaryResetsInMin
        }
        plan                 = $plan
        reading_age_minutes  = $readingAgeMin
        source_file          = $bestFile
    }
}

function Get-CodexBlock {
    # The used_percent field lags badly. Verified 2026-09-01: it read 68 percent
    # while Codex was in fact hard blocked at 100 percent. The authoritative
    # signal is a task_complete event carrying codex_error_info
    # "usage_limit_exceeded". Trust that over any percentage.
    param([datetime]$WindowStartUtc)

    $result = @{ blocked = $false; at_utc = $null; retry_text = $null }

    $sessionsRoot = $SessionsRoot
    if (-not (Test-Path $sessionsRoot)) { return $result }

    $files = Get-ChildItem -Path $sessionsRoot -Filter 'rollout-*.jsonl' -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 8
    if ($null -eq $files) { return $result }

    foreach ($f in $files) {
        $hits = Select-String -Path $f.FullName -Pattern 'usage_limit_exceeded' -SimpleMatch -ErrorAction SilentlyContinue
        if ($null -eq $hits) { continue }
        foreach ($hit in $hits) {
            $obj = $null
            try { $obj = $hit.Line | ConvertFrom-Json } catch { continue }
            # Only a real task_complete error counts. A brief or message that merely quotes the
            # string (2026-10-01: an AIU brief did) must not read as a block.
            if ($obj.payload.type -ne 'task_complete' -or $obj.payload.error.codex_error_info -ne 'usage_limit_exceeded') { continue }
            if ($null -eq $obj.timestamp) { continue }
            $ts = $null
            try { $ts = ([datetime]$obj.timestamp).ToUniversalTime() } catch { continue }
            # Only count a block inside the current 5 hour window. An older one
            # has already been cleared by a reset.
            if ($ts -lt $WindowStartUtc) { continue }
            if ($null -eq $result.at_utc -or $ts -gt $result.at_utc) {
                $result.blocked = $true
                $result.at_utc = $ts
                $m = [regex]::Match($hit.Line, 'try again at ([0-9]{1,2}:[0-9]{2}\s?[AP]M)')
                if ($m.Success) { $result.retry_text = $m.Groups[1].Value }
            }
        }
    }
    return $result
}

function Get-GeminiUsage {
    # ponytail: no numeric Antigravity/Gemini quota artifact exists on this
    # machine as of 2026-09-01 (searched under ~\.gemini). Wire
    # in a real one here if a future Antigravity version writes one.
    $running = $false
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'language_server.exe'" -ErrorAction SilentlyContinue
        if ($null -ne $procs) {
            foreach ($p in $procs) {
                if ($p.CommandLine -match '--app_data_dir\s+antigravity' -or $p.CommandLine -match 'antigravity') {
                    $running = $true
                    break
                }
            }
        }
    } catch {
        # Process query failed (permissions, WMI unavailable). Treat as unknown-not-running.
    }

    # What actually decides whether Gemini can be delegated to is whether the agy
    # CLI is on disk and authenticated, not whether the IDE happens to be open.
    # Deliberately not probing agy live: a probe on every session start would
    # spend the very quota this is meant to protect.
    $agyPath = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
    $agyInstalled = Test-Path $agyPath

    if ($agyInstalled) {
        $detail = "agy CLI ready, delegate with: agy --model gemini-3.1-pro-high --new-project --print='...'"
        if (-not $running) { $detail = "$detail (IDE closed, CLI still works)" }
        return @{ available = $true; detail = $detail; agy = $agyPath }
    }

    if ($running) {
        return @{ available = $false; detail = "IDE running but agy CLI not installed, see antigravity.google/cli/install.ps1" }
    }
    return @{ available = $false; detail = "not running, agy CLI not installed" }
}

function Format-MinutesAsHM {
    param([int]$Minutes)
    if ($Minutes -lt 0) { $Minutes = 0 }
    $h = [math]::Floor($Minutes / 60)
    $m = $Minutes % 60
    return "$($h)h$($m)m"
}

$codex = Get-CodexUsage
$gemini = Get-GeminiUsage
$generatedAt = Get-Date

# Build advice
$codexBlock = @{ blocked = $false; retry_text = $null }
$advice = $null
if ($codex.available) {
    $leftPct = $codex.five_hour.left_percent
    $resetLocal = $codex.five_hour.resets_at_local
    $resetTimeStr = $resetLocal.ToString('HH:mm')

    if ($leftPct -ge 40) {
        $advice = "Codex: safe to delegate heavy work."
    } elseif ($leftPct -ge 15) {
        $advice = "Codex: light tasks only, reserve for adversarial review."
    } else {
        $advice = "Codex: do not delegate, wait for reset at $resetTimeStr."
    }

    # Weekly is informational only: the owner applies weekly resets manually when it runs out
    # (2026-10-01), so a low week never throttles Sol. When everything is out, use gpt-reserve.
    if ($null -ne $codex.weekly.left_percent -and $codex.weekly.left_percent -lt 25) {
        $advice = "$advice Week $([math]::Round($codex.weekly.left_percent))% left (owner resets it; keep using Sol)."
    }

    if ($codex.reading_age_minutes -gt 120) {
        $advice = "STALE READING, verify before relying: $advice"
    }

    # Authoritative override. A recorded usage_limit_exceeded beats any percentage.
    $windowStartUtc = $resetLocal.ToUniversalTime().AddMinutes(-300)
    $codexBlock = Get-CodexBlock -WindowStartUtc $windowStartUtc
    if ($codexBlock.blocked) {
        $retryStr = $codexBlock.retry_text
        if ($null -eq $retryStr) { $retryStr = $resetTimeStr }
        $advice = "Codex: BLOCKED, usage limit hit. Do not delegate until $retryStr."
        if ($null -ne $codex.reserve -and $codex.reserve.used_percent -lt 100) {
            $advice = 'Codex: BLOCKED, usage limit hit. Route mechanical work to codex exec -m gpt-reserve -c model_reasoning_effort=low (prompt on stdin).'
            if ($codex.reserve.reading_age_minutes -gt 120) {
                $advice = "STALE RESERVE READING, verify before relying: $advice"
            }
        }
    }
} else {
    $advice = "Codex: usage unknown ($($codex.detail)), verify before delegating."
}

if ($Json) {
    $codexJson = $null
    if ($codex.available) {
        $codexJson = [ordered]@{
            available            = $true
            blocked              = [bool]$codexBlock.blocked
            blocked_until        = $codexBlock.retry_text
            five_hour            = [ordered]@{
                used_percent      = $codex.five_hour.used_percent
                left_percent      = $codex.five_hour.left_percent
                resets_at_iso     = $codex.five_hour.resets_at_iso
                resets_in_minutes = $codex.five_hour.resets_in_minutes
            }
            weekly               = [ordered]@{
                used_percent      = $codex.weekly.used_percent
                left_percent      = $codex.weekly.left_percent
                resets_at_iso     = $codex.weekly.resets_at_iso
                resets_in_minutes = $codex.weekly.resets_in_minutes
            }
            plan                 = $codex.plan
            reading_age_minutes  = $codex.reading_age_minutes
            source_file          = $codex.source_file
        }
    } else {
        $codexJson = [ordered]@{
            available = $false
            detail    = $codex.detail
        }
    }

    $codexJson['reserve'] = $codex.reserve

    $geminiJson = [ordered]@{
        available = [bool]$gemini.available
        detail    = $gemini.detail
    }

    $out = [ordered]@{
        generated_at = $generatedAt.ToString('yyyy-MM-ddTHH:mm:sszzz')
        codex        = $codexJson
        gemini       = $geminiJson
        advice       = $advice
    }

    $out | ConvertTo-Json -Depth 6
    exit 0
}

# Human readable block, at most 4 lines.
$lines = New-Object System.Collections.Generic.List[string]

if ($codex.available) {
    $fiveH = $codex.five_hour
    $week = $codex.weekly
    $resetTimeStr = $fiveH.resets_at_local.ToString('HH:mm')
    $resetInStr = Format-MinutesAsHM -Minutes $fiveH.resets_in_minutes

    $weekResetStr = 'unknown'
    if ($null -ne $week.resets_at_local) {
        $weekResetStr = $week.resets_at_local.ToString('MMM d HH:mm')
    }
    $weekUsedStr = 'unknown'
    if ($null -ne $week.used_percent) {
        $weekUsedStr = "$([math]::Round($week.used_percent))%"
    }

    $blockTag = ''
    if ($codexBlock.blocked) { $blockTag = ' | BLOCKED' }

    $line1 = "CODEX   5h  $([math]::Round($fiveH.used_percent))% used / $([math]::Round($fiveH.left_percent))% left, resets $resetTimeStr (in $resetInStr) | week $weekUsedStr used, resets $weekResetStr | plan $($codex.plan) | reading $($codex.reading_age_minutes)m old$blockTag"
    $lines.Add($line1)
} else {
    $lines.Add("CODEX   unavailable: $($codex.detail)")
}

if ($null -ne $codex.reserve) {
    $minutes = [math]::Max(0, [math]::Round(([datetime]$codex.reserve.resets_at - (Get-Date)).TotalMinutes))
    $days = [math]::Floor($minutes / 1440)
    $hours = [math]::Floor(($minutes % 1440) / 60)
    $lines.Add("Codex reserve (gpt-reserve): $($codex.reserve.used_percent)% used, resets in $($days)d $($hours)h | reading $($codex.reserve.reading_age_minutes)m old")
} else {
    $lines.Add('Codex reserve: no reading yet')
}
$lines.Add("GEMINI  $($gemini.detail)")
$lines.Add($advice)

$lines -join "`n"
