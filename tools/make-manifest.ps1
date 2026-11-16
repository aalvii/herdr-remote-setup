# Build MANIFEST.sha256 for the package.
# Usage: powershell -File tools\make-manifest.ps1
#
# The manifest covers the shipped payload. Repository plumbing (.git*, .github,
# .editorconfig) and local material (.audit, legacy, extras) are excluded.

param([string]$Root)

$ErrorActionPreference = "Stop"
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$Root = (Resolve-Path $Root).Path
$out = Join-Path $Root "MANIFEST.sha256"

$excludeExact = @(
    "MANIFEST.sha256",
    ".git",
    ".gitignore",
    ".gitattributes",
    ".editorconfig"
)
$excludePrefixes = @(
    ".git/",
    ".audit/",
    ".github/",
    "dist/",
    "extras/",
    "legacy/"
)

$files = Get-ChildItem -Path $Root -Recurse -File |
    Where-Object {
        $rel = $_.FullName.Substring($Root.Length + 1).Replace('\', '/')
        $skip = $excludeExact -contains $rel
        foreach ($prefix in $excludePrefixes) {
            if ($rel.StartsWith($prefix)) { $skip = $true }
        }
        (-not $skip) -and
        $rel -notlike "herdr-remote-setup-*.zip" -and
        $rel -notlike "*.zip.tmp" -and
        $rel -notlike "*.pyc" -and
        $rel -notlike "*/__pycache__/*"
    } |
    Sort-Object FullName

$lines = foreach ($f in $files) {
    $rel = $f.FullName.Substring($Root.Length + 1).Replace('\', '/')
    $hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLower()
    "{0}  {1}" -f $hash, $rel
}

$body = ($lines -join "`n") + "`n"
[IO.File]::WriteAllText($out, $body, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Wrote $out with $($lines.Count) entries"
