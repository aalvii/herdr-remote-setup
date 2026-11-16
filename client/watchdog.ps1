# Herdr remote watchdog.
# Detects the known "surface revocation" stall (herdr issue #3842) and
# restarts only the local client. The local server, panes, and the remote
# server are left untouched.
#
# Usage:
#   powershell -File watchdog.ps1 [-DryRun] [-StaleMinutes 3] [-Quiet]
#
# Exit codes:
#   0  healthy, nothing to do
#   10 client restarted
#   11 dry run: restart needed
#   2  cannot evaluate (missing files)

param(
    [switch]$DryRun,
    [int]$StaleMinutes = 3,
    [switch]$Quiet,
    [string]$ClientLog
)

$ErrorActionPreference = "Continue"

if (-not $ClientLog) { $ClientLog = Join-Path $env:APPDATA "herdr\herdr-client.log" }
$LogDir = Join-Path $env:LOCALAPPDATA "HerdrSetup\logs"
$WatchdogLog = Join-Path $LogDir "watchdog.log"
$LaunchTask = "HerdrWatchdogLaunch"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $Message
    try { Add-Content -LiteralPath $WatchdogLog -Value $line -Encoding UTF8 } catch { }
    if (-not $Quiet) { Write-Host $line }
}

if (-not (Test-Path $ClientLog)) {
    Log "no client log at $ClientLog"
    exit 2
}

$lines = Get-Content -LiteralPath $ClientLog -Tail 120 -ErrorAction SilentlyContinue
if (-not $lines) { Log "client log is empty"; exit 0 }

$state = "unknown"
$lastLine = ""
foreach ($line in $lines) {
    if ($line -match "handshake succeeded") { $state = "ok"; $lastLine = $line }
    elseif ($line -match "did not acknowledge surface revocation|endpoint health check timed out") {
        $state = "stuck"; $lastLine = $line
    }
    elseif ($line -match "endpoint transport failed|connection was lost") {
        $state = "fail"; $lastLine = $line
    }
}

$age = (Get-Date) - (Get-Item -LiteralPath $ClientLog).LastWriteTime
Log ("state={0} logAge={1:n1}min last={2}" -f $state, $age.TotalMinutes, $lastLine.Trim())

if ($state -eq "ok") { exit 0 }
if ($age.TotalMinutes -lt $StaleMinutes) {
    Log "recent activity; waiting"
    exit 0
}

# Find the TUI client (not the server).
$clients = @()
try {
    $clients = Get-CimInstance Win32_Process -Filter "Name='herdr.exe'" |
        Where-Object { $_.CommandLine -notmatch '\sserver\b' }
} catch { }

if (-not $clients -or $clients.Count -eq 0) {
    Log "no local client process; nothing to restart"
    exit 0
}

if ($DryRun) {
    Log ("DRY RUN: would stop {0} and relaunch" -f (($clients | ForEach-Object { $_.ProcessId }) -join ','))
    exit 11
}

foreach ($c in $clients) {
    Log ("stopping client pid={0}" -f $c.ProcessId)
    try { Stop-Process -Id $c.ProcessId -Force -ErrorAction Stop } catch { Log ("stop failed: " + $_.Exception.Message) }
}

Start-Sleep -Seconds 3

# Relaunch through a scheduled task: a TUI needs an interactive console, and
# Start-Process from a non-console context exits immediately.
try {
    $herdrExe = $null
    $cmd = Get-Command herdr -ErrorAction SilentlyContinue
    if ($cmd) { $herdrExe = $cmd.Source }
    if (-not $herdrExe) {
        $candidate = Get-ChildItem "$env:USERPROFILE\.herdr\packages\standalone\release*\herdr.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($candidate) { $herdrExe = $candidate.FullName }
    }
    if (-not $herdrExe) { Log "herdr.exe not found"; exit 2 }

    $task = Get-ScheduledTask -TaskName $LaunchTask -ErrorAction SilentlyContinue
    if (-not $task) {
        $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c start `"`" `"$herdrExe`""
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $LaunchTask -Action $action -Principal $principal -Force | Out-Null
        Log "registered launch task"
    }
    Start-ScheduledTask -TaskName $LaunchTask
    Log "relaunch requested"
    exit 10
} catch {
    Log ("relaunch failed: " + $_.Exception.Message)
    exit 2
}
