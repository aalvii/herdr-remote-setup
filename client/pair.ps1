# Herdr Connect - Windows client for the PIN pairing flow.
# Version: see ..\VERSION
#
# No connection code and no Tailscale auth key. The host shows a 6-digit PIN.
# This script finds the host on the tailnet, sends its SSH public key and the
# PIN to the host pairing service, then registers the machine in herdr.
#
# Usage:
#   pair.ps1 -HostName 100.x.y.z -Pin 123456
#   pair.ps1 -HostName host -Pin 123456 -Json
#   pair.ps1 -SelfTest
#
# Exit codes: 0 ok, 2 prerequisite, 3 network, 4 transport, 5 herdr, 6 internal

[CmdletBinding()]
param(
    [string]$HostName,
    [string]$Pin,
    [int]$Port = 8765,
    [switch]$Json,
    [switch]$NoWatchdog,
    [string]$KeyPath,
    [string]$Label,
    [switch]$NewEntry,
    [switch]$SelfTest,
    [switch]$ShowVersion,
    [string]$LogDir
)

$ErrorActionPreference = "Continue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$EXIT_OK=0; $EXIT_PREREQ=2; $EXIT_NET=3; $EXIT_KEY=4; $EXIT_HERDR=5; $EXIT_INTERNAL=6

$ScriptRoot = $PSScriptRoot
$PackageRoot = Split-Path $ScriptRoot -Parent
$Version = "0.0.0"
$vf = Join-Path $PackageRoot "VERSION"
if (Test-Path $vf) { $Version = (Get-Content $vf -Raw).Trim() }

if (-not $LogDir) { $LogDir = Join-Path $env:LOCALAPPDATA "HerdrSetup\logs" }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("pair-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

function Log { param([string]$Message, [string]$Level="INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"), $Level, $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { } }
function Say  { param($m) if (-not $Json) { Write-Host $m }; Log $m }
function Step { param($m) if (-not $Json) { Write-Host ">> $m" -ForegroundColor Blue }; Log "STEP $m" }
function Ok   { param($m) if (-not $Json) { Write-Host "OK $m" -ForegroundColor Green }; Log "OK $m" }
function Warn { param($m) if (-not $Json) { Write-Host "! $m" -ForegroundColor Yellow }; Log "WARN $m" }
function Fail {
    param([int]$Code, [string]$Message)
    if (-not $Json) { Write-Host "X $Message" -ForegroundColor Red }
    Log "EXIT $Code : $Message"
    if ($Json) { [ordered]@{ version=$Version; ok=$false; exitCode=$Code; error=$Message; log=$LogFile } | ConvertTo-Json -Depth 5 -Compress | Write-Output }
    exit $Code
}

function Get-TailscaleExe {
    $c = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\Tailscale\tailscale.exe","${env:ProgramFiles(x86)}\Tailscale\tailscale.exe")) { if (Test-Path $p) { return $p } }
    return $null
}

function Connect-Tailscale {
    param([string]$Target)
    $tsExe = Get-TailscaleExe
    if (-not $tsExe) {
        Warn "Tailscale not installed"
        $msi = Join-Path $env:TEMP "tailscale-setup.msi"
        $url = "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi"
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Step "Installing Tailscale (winget)"
            & winget install --id Tailscale.Tailscale --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-String | ForEach-Object { Log $_ }
            Start-Sleep -Seconds 3
            $tsExe = Get-TailscaleExe
        }
        if (-not $tsExe) {
            Step "Installing Tailscale (MSI)"
            try {
                Invoke-WebRequest -Uri $url -OutFile $msi -TimeoutSec 300 -UseBasicParsing
                $p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
                Start-Sleep -Seconds 3
                $tsExe = Get-TailscaleExe
                if (-not $tsExe) { throw "installer exit $($p.ExitCode)" }
            } catch { Fail $EXIT_NET "Tailscale install failed: $($_.Exception.Message)" }
        }
        Ok "Tailscale installed"
    } else { Ok "Tailscale found" }

    $svc = Get-Service Tailscale -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne "Running") {
        try { Start-Service Tailscale -ErrorAction Stop } catch { Warn "Start-Service failed: $($_.Exception.Message)" }
    }

    $visible = $false
    $st = (& $tsExe status 2>&1 | Out-String)
    if ($st -match [regex]::Escape($Target)) { $visible = $true }

    if (-not $visible) {
        Step "Signing in to Tailscale"
        Say "A browser window opens. Sign in with the same account as the host."
        try {
            & $tsExe up --accept-routes=false 2>&1 | Out-String | ForEach-Object { Log $_ }
        } catch { Warn "tailscale up: $($_.Exception.Message)" }
        Step "Waiting for the host"
        $deadline = (Get-Date).AddSeconds(180)
        while ((Get-Date) -lt $deadline) {
            $st = (& $tsExe status 2>&1 | Out-String)
            if ($st -match [regex]::Escape($Target)) { $visible = $true; break }
            Start-Sleep -Seconds 5
        }
    }
    if (-not $visible) { Fail $EXIT_NET "Host is not visible in the tailnet. Sign in to Tailscale with the same account as the host." }
    Ok "Tailnet path ready"
    return $tsExe
}

function Resolve-Peer {
    param([string]$Target, [string]$TsExe)
    $raw = (& $TsExe status --json 2>&1 | Out-String)
    try { $data = $raw | ConvertFrom-Json } catch { return $null }
    $peers = @()
    if ($data.Peer) { $peers = @($data.Peer.PSObject.Properties | ForEach-Object { $_.Value }) }
    foreach ($p in $peers) {
        $ips = @($p.TailscaleIPs)
        $dns = ([string]$p.DNSName).TrimEnd('.')
        if ($ips -contains $Target -or [string]$p.HostName -eq $Target -or $dns -eq $Target) {
            $ip = ($ips | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)
            if (-not $ip) { $ip = ($ips | Select-Object -First 1) }
            return [pscustomobject]@{ IP = $ip; HostName = [string]$p.HostName; DNSName = $dns }
        }
    }
    return $null
}

function Get-Herdr {
    $c = Get-Command herdr -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $candidate = Get-ChildItem "$env:USERPROFILE\.herdr\packages\standalone\releases\*\herdr.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function Install-Herdr {
    $exe = Get-Herdr
    if ($exe) { Ok "herdr found"; return $exe }
    Warn "herdr not installed"
    Step "Attempt 1: online installer"
    try {
        $installer = Join-Path $env:TEMP "herdr-install.ps1"
        Invoke-WebRequest -Uri "https://herdr.dev/install.ps1" -OutFile $installer -TimeoutSec 60 -UseBasicParsing
        & $installer 2>&1 | Out-String | ForEach-Object { Log $_ }
        $env:Path = "$([System.Environment]::GetEnvironmentVariable('Path','Machine'));$([System.Environment]::GetEnvironmentVariable('Path','User'))"
        $exe = Get-Herdr
        if ($exe) { Ok "herdr installed (online)"; return $exe }
    } catch { Warn "Online install failed: $($_.Exception.Message)" }

    $asset = Join-Path $ScriptRoot "assets\herdr-windows-x86_64.zip"
    if (Test-Path $asset) {
        Step "Attempt 2: local package"
        try {
            $sha = (Get-FileHash -Path $asset -Algorithm SHA256).Hash
            $installer = Join-Path $env:TEMP "herdr-install.ps1"
            if (-not (Test-Path $installer)) { Invoke-WebRequest -Uri "https://herdr.dev/install.ps1" -OutFile $installer -TimeoutSec 60 -UseBasicParsing }
            & $installer -LocalPackagePath $asset -LocalPackageFormat "zip" -LocalPackageIdentity "0.9.5" -LocalPackageSha256 $sha 2>&1 | Out-String | ForEach-Object { Log $_ }
            $env:Path = "$([System.Environment]::GetEnvironmentVariable('Path','Machine'));$([System.Environment]::GetEnvironmentVariable('Path','User'))"
            $exe = Get-Herdr
            if ($exe) { Ok "herdr installed (local package)"; return $exe }
        } catch { Warn "Local package install failed: $($_.Exception.Message)" }
    }
    Fail $EXIT_HERDR "herdr could not be installed"
}

function Get-Key {
    if (-not $KeyPath) { $KeyPath = Join-Path $env:USERPROFILE ".ssh\id_ed25519" }
    $dir = Split-Path $KeyPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $KeyPath)) {
        Warn "Generating SSH key"
        & ssh-keygen -t ed25519 -f $KeyPath -N '""' -C "$env:USERNAME@$env:COMPUTERNAME" 2>&1 | Out-String | ForEach-Object { Log $_ }
    }
    if (-not (Test-Path "$KeyPath.pub")) { Fail $EXIT_KEY "Public key missing: $KeyPath.pub" }
    return $KeyPath
}

function Get-ErrorMessage {
    param($ErrorRecord)
    $status = 0
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { }
    if ($status -eq 401) { return "wrong PIN" }
    if ($status -eq 429) { return "too many attempts" }
    if ($status -eq 400) { return "the host rejected the key" }
    if ($status -gt 0) { return "host returned HTTP $status" }
    return $ErrorRecord.Exception.Message
}

if ($ShowVersion) { Write-Output $Version; exit 0 }

if ($SelfTest) {
    $problems = @()
    if (-not (Test-Path (Join-Path $PackageRoot "VERSION"))) { $problems += "VERSION file missing" }
    if (-not (Test-Path (Join-Path $ScriptRoot "install-watchdog.ps1"))) { $problems += "install-watchdog.ps1 missing" }
    if ($Pin -and $Pin -notmatch '^[0-9]{6}$') { $problems += "PIN must be 6 digits" }
    $ts = Get-TailscaleExe
    if ($problems.Count -eq 0) {
        Write-Output ("SELFTEST OK (v{0}; pair protocol 1; tailscale={1})" -f $Version, $(if ($ts) { "found" } else { "not installed" }))
        exit 0
    }
    $problems | ForEach-Object { Write-Output "SELFTEST FAIL: $_" }
    exit $EXIT_INTERNAL
}

if (-not $HostName) { Fail $EXIT_PREREQ "Missing -HostName" }
if (-not $Pin) { Fail $EXIT_PREREQ "Missing -Pin" }
if ($Pin -notmatch '^[0-9]{6}$') { Fail $EXIT_PREREQ "PIN must be 6 digits" }
if ($env:OS -ne "Windows_NT") { Fail $EXIT_PREREQ "This script targets Windows." }

Step "Herdr Connect v$Version"
Log "log file: $LogFile"

$tsExe = Connect-Tailscale -Target $HostName
$ip = $HostName
$peer = Resolve-Peer -Target $HostName -TsExe $tsExe
if ($peer) {
    $ip = $peer.IP
    Ok ("Host: {0} ({1})" -f $peer.HostName, $ip)
} elseif ($HostName -match '^100\.') {
    Ok "Host: $ip"
} else {
    Fail $EXIT_NET "Host '$HostName' is not a tailnet peer. Start the sharing service on the host and try the IP or tailnet name."
}

$herdr = Install-Herdr
$key = Get-Key
$pubKey = (Get-Content "$key.pub" -Raw).Trim()

Step "Reading the host pairing service"
$info = $null
try {
    $info = Invoke-RestMethod -Uri ("http://{0}:{1}/api/info" -f $ip, $Port) -Method Get -TimeoutSec 8
} catch {
    Fail $EXIT_NET ("No Herdr sharing service on {0}:{1}. Start 'host/pair.sh' on the other computer." -f $ip, $Port)
}
if ($info.service -ne "herdr-pair") { Fail $EXIT_NET "The service on the host is not herdr-pair." }
$user = [string]$info.user
$hostLabel = [string]$info.host
if (-not $user) { Fail $EXIT_NET "The host did not report a login user." }
Ok ("Sharing host: {0} (user {1})" -f $hostLabel, $user)

Step "Sending the public key and PIN"
$body = [ordered]@{ pin = $Pin; name = $env:COMPUTERNAME; publicKey = $pubKey } | ConvertTo-Json -Compress
$paired = $null
try {
    $paired = Invoke-RestMethod -Uri ("http://{0}:{1}/api/request" -f $ip, $Port) -Method Post -Body $body -ContentType "application/json" -TimeoutSec 20
} catch {
    $msg = Get-ErrorMessage -ErrorRecord $_
    if ($msg -eq "wrong PIN" -or $msg -eq "too many attempts") { Fail $EXIT_PREREQ $msg }
    Fail $EXIT_NET ("Pairing failed: {0}" -f $msg)
}
if (-not $paired.ok) { Fail $EXIT_NET "The host did not approve the key." }
Ok "Host accepted the key"

Step "Testing the SSH session"
$connected = $false
for ($i = 0; $i -lt 5; $i++) {
    $probe = & ssh -i $key -o IdentitiesOnly=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes "$user@$ip" "echo CONNECT_OK" 2>&1 | Out-String
    if ($probe -match "CONNECT_OK") { $connected = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $connected) { Fail $EXIT_KEY "SSH failed after pairing. Check the host sshd and authorized_keys." }
Ok "SSH session: $user@$ip"

Step "Registering the machine in herdr"
$machineName = $hostLabel -replace '\..*$', ''
if ($Label) { $machineName = $Label }

$existing = $null
if (-not $NewEntry) {
    try {
        $list = (& $herdr machine list --json 2>&1 | Out-String) | ConvertFrom-Json
        foreach ($m in @($list)) {
            $t = [string]$m.target
            $hit = $false
            if ($t -match [regex]::Escape($hostLabel)) { $hit = $true }
            if ($info.host -and $t -match [regex]::Escape([string]$info.host)) { $hit = $true }
            if ($t -match [regex]::Escape($ip)) { $hit = $true }
            if ($hit) { $existing = $m; break }
        }
    } catch { Log "machine list --json unavailable: $($_.Exception.Message)" }
}

if ($existing) {
    if ($existing.label) { $machineName = [string]$existing.label }
    if ($existing.target -ne "$user@$ip") {
        if ($existing.id) {
            & $herdr machine remove $existing.id 2>&1 | Out-Null
            & $herdr machine add "$user@$ip" --label $machineName 2>&1 | Out-String | ForEach-Object { Log $_ }
            Ok "Machine entry updated: $machineName"
        } else {
            Warn "Existing entry targets $($existing.target) but its id is unavailable; left unchanged"
        }
    } else {
        Ok "Machine entry already present: $machineName"
    }
} else {
    & $herdr machine add "$user@$ip" --label $machineName 2>&1 | Out-String | ForEach-Object { Log $_ }
    Ok "Machine entry created: $machineName"
}

$statusOut = (& $herdr machine status $machineName 2>&1 | Out-String)
$reachable = ($statusOut -match "reachable") -and ($statusOut -notmatch "not reachable|unreachable")
if ($reachable) { Ok "herdr machine reachable" } else { Warn "herdr status: $($statusOut.Trim())" }

if (-not $NoWatchdog) {
    Step "Installing the connection watchdog"
    $installer = Join-Path $ScriptRoot "install-watchdog.ps1"
    if (Test-Path $installer) {
        try {
            & $installer -IntervalMinutes 2 2>&1 | Out-String | ForEach-Object { Log $_ }
            Ok "Watchdog installed (every 2 min)"
        } catch { Warn "Watchdog install failed: $($_.Exception.Message)" }
    } else { Warn "install-watchdog.ps1 not found; watchdog skipped" }
} else { Warn "Watchdog skipped (-NoWatchdog)" }

if ($Json) {
    [ordered]@{ version=$Version; ok=$true; exitCode=0; host=$hostLabel; user=$user; ip=$ip; machine=$machineName; reachable=$reachable; log=$LogFile } | ConvertTo-Json -Depth 5 -Compress | Write-Output
} else {
    Say ""
    Say "================================================================"
    Say "  Connected to $hostLabel (v$Version)"
    Say "================================================================"
    Say ""
    Say "  herdr --machine $machineName"
    Say ""
    Say "  log: $LogFile"
    Say ""
}
exit $EXIT_OK
