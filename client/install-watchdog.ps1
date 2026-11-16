# Install or remove the herdr watchdog scheduled task.
#
# Usage:
#   powershell -File install-watchdog.ps1            [-IntervalMinutes 2]
#   powershell -File install-watchdog.ps1 -Uninstall
#
# The task runs in the interactive session so it can relaunch the TUI.

param(
    [int]$IntervalMinutes = 2,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$TaskName = "HerdrWatchdog"
$Script = Join-Path $PSScriptRoot "watchdog.ps1"
# wscript.exe has no console window, so the 2-minute task does not flash a
# terminal window. It starts powershell.exe with a hidden window.
$Vbs = Join-Path $PSScriptRoot "watchdog-hidden.vbs"
$WscriptExe = Join-Path $env:SystemRoot "System32\wscript.exe"

if ($Uninstall) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output "Removed task $TaskName"
    } else {
        Write-Output "Task $TaskName not present"
    }
    $launch = Get-ScheduledTask -TaskName "HerdrWatchdogLaunch" -ErrorAction SilentlyContinue
    if ($launch) { Unregister-ScheduledTask -TaskName "HerdrWatchdogLaunch" -Confirm:$false }
    exit 0
}

if (-not (Test-Path $Script)) { Write-Output "watchdog.ps1 not found"; exit 2 }
if (-not (Test-Path $Vbs)) { Write-Output "watchdog-hidden.vbs not found"; exit 2 }
if (-not (Test-Path $WscriptExe)) { Write-Output "wscript.exe not found"; exit 2 }

$action = New-ScheduledTaskAction -Execute $WscriptExe `
    -Argument "`"$Vbs`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Output "Installed task $TaskName (every $IntervalMinutes min, interactive session, hidden via wscript)"
Write-Output "Log: $env:LOCALAPPDATA\HerdrSetup\logs\watchdog.log"
Write-Output "Test: powershell -File `"$Script`" -DryRun"
