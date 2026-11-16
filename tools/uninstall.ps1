# Remove herdr machine entries and local setup state created by this package.
# Keeps herdr, Tailscale, and SSH keys installed.
# Usage: powershell -File tools\uninstall.ps1 [-RemoveLogs]

param([switch]$RemoveLogs)

$ErrorActionPreference = "Continue"

$stateFile = Join-Path $env:LOCALAPPDATA "HerdrSetup\machines.txt"

Write-Output "Herdr Remote Setup - uninstall"

if (Get-Command herdr -ErrorAction SilentlyContinue) {
    $labels = @()
    if (Test-Path $stateFile) {
        $labels = Get-Content $stateFile | Where-Object { $_.Trim() }
    }

    if ($labels.Count -eq 0) {
        Write-Output "No machine labels recorded. Current machines:"
        & herdr machine list
    } else {
        foreach ($label in $labels) {
            Write-Output "Removing machine entry: $label"
            & herdr machine remove $label 2>&1 | Out-Null
        }
        Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Output "herdr not found; nothing to remove"
}

if ($RemoveLogs) {
    $logFolder = Join-Path $env:LOCALAPPDATA "HerdrSetup"
    if (Test-Path $logFolder) {
        Write-Output "Removing $logFolder"
        Remove-Item -Recurse -Force $logFolder -ErrorAction SilentlyContinue
    }
}

Write-Output "Done. Tailscale, herdr, and SSH keys were kept."
