# Verify package integrity against MANIFEST.sha256
# Usage: powershell -File tools\verify-package.ps1

param([string]$Root)

$ErrorActionPreference = "Stop"
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$Root = (Resolve-Path $Root).Path
$manifest = Join-Path $Root "MANIFEST.sha256"

if (-not (Test-Path $manifest)) {
    Write-Output "FAIL: MANIFEST.sha256 not found"
    exit 6
}

$bad = 0
$missing = 0
$checked = 0
$secretHits = 0

# Secret-shaped literals must never ship in executable files. Docs may show
# tskey-auth-xxxx placeholders, so only code extensions are scanned.
$codeExtensions = @('.ps1', '.sh', '.py', '.cmd', '.command', '.psm1', '.json')
$secretPattern = 'tskey-auth-[A-Za-z0-9]{6,}'

foreach ($line in Get-Content $manifest) {
    if (-not $line.Trim()) { continue }
    $parts = $line -split '\s{2,}', 2
    if ($parts.Count -ne 2) { continue }
    $expected = $parts[0].Trim().ToLower()
    $rel = $parts[1].Trim()
    $path = Join-Path $Root ($rel -replace '/', '\')
    $checked++

    if (-not (Test-Path $path)) {
        Write-Output "MISSING: $rel"
        $missing++
        continue
    }
    $actual = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        Write-Output "MISMATCH: $rel"
        $bad++
    }
    if ($codeExtensions -contains [IO.Path]::GetExtension($rel).ToLower()) {
        try {
            $text = Get-Content -LiteralPath $path -Raw
            if ($text -match $secretPattern) {
                Write-Output "SECRET-LIKE: $rel"
                $secretHits++
            }
        } catch { }
    }
}

if ($bad -eq 0 -and $missing -eq 0 -and $secretHits -eq 0) {
    Write-Output "VERIFY OK ($checked files)"
    exit 0
}
Write-Output "VERIFY FAILED ($checked checked, $missing missing, $bad mismatch, $secretHits secret-like)"
exit 6
