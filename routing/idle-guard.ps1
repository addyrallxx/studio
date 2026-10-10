# Keep partner and automation processes at Idle priority so a game in the foreground keeps its frames.
# Never touches the user's own Chrome (only headless or remote-debugging instances) or Discord.
# Usage (PowerShell tool, run_in_background): powershell -NoProfile -File $HOME\.claude\tools\idle-guard.ps1 [-Minutes 115]
param([int]$Minutes = 115)
$names = 'codex','agy','ffmpeg','ffprobe','python','uv','esbuild','chrome-headless-shell'
$auto = '--headless|--remote-debugging|puppeteer|playwright|remotion|ms-playwright'
$end = (Get-Date).AddMinutes($Minutes)
function Set-Idle($p) { try { if ($p.PriorityClass -ne 'Idle') { $p.PriorityClass = 'Idle' } } catch {} }
while ((Get-Date) -lt $end) {
  Get-Process -Name $names -ErrorAction SilentlyContinue | ForEach-Object { Set-Idle $_ }
  Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'node.exe' -or $_.CommandLine -match $auto } |
    ForEach-Object { $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue; if ($p) { Set-Idle $p } }
  Start-Sleep -Seconds 15
}
