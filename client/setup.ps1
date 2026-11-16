# Herdr Remote Setup - Client (Windows)
# Version: see ..\VERSION
#
# Stack: network (Tailscale) -> transport (Tailscale SSH or OpenSSH key) -> herdr
#
# Usage:
#   setup.ps1 -ConnectionCode "<code>" [-Json]
#   setup.ps1 -ShowVersion
#   setup.ps1 -SelfTest
#
# Exit codes: 0 ok, 2 prerequisite, 3 network, 4 transport, 5 herdr, 6 internal

[CmdletBinding()]
param(
    [string]$ConnectionCode,
    [switch]$Json,
    [switch]$ShowVersion,
    [switch]$SelfTest,
    [string]$LogDir,
    [switch]$NoWatchdog,
    [int]$WatchdogIntervalMinutes = 2
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
$LogFile = Join-Path $LogDir ("setup-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

function Log { param([string]$Message, [string]$Level="INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"), $Level, $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { } }
function Say  { param($m) if (-not $Json) { Write-Host $m }; Log $m }
function Step { param($m) if (-not $Json) { Write-Host ">> $m" -ForegroundColor Blue }; Log "STEP $m" }
function Ok   { param($m) if (-not $Json) { Write-Host "OK $m" -ForegroundColor Green }; Log "OK $m" }
function Warn { param($m) if (-not $Json) { Write-Host "! $m" -ForegroundColor Yellow }; Log "WARN $m" }
function Redact { param([string]$t) if (-not $t) { return $t }; return ($t -replace 'tskey-[A-Za-z0-9-]+','tskey-***REDACTED***') }
function Fail {
    param([int]$Code, [string]$Message)
    if (-not $Json) { Write-Host "X $Message" -ForegroundColor Red }
    Log "EXIT $Code : $Message"
    if ($Json) { [ordered]@{ version=$Version; ok=$false; exitCode=$Code; error=$Message; log=$LogFile } | ConvertTo-Json -Depth 5 | Write-Output }
    exit $Code
}

function Get-TailscaleExe {
    $c = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\Tailscale\tailscale.exe","${env:ProgramFiles(x86)}\Tailscale\tailscale.exe")) { if (Test-Path $p) { return $p } }
    return $null
}

function ConvertFrom-ConnectionCode {
    param([string]$Code)
    $raw = $Code.Trim()
    while ($raw.Length % 4 -ne 0) { $raw += "=" }
    $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($raw))

    $out = [ordered]@{
        format="v1"; mode="key"; user=""; host=""; dns=""; ips=@(); authKey=$null; tag=$null; ts=$null
        enrollPort=0; enrollToken=$null
    }

    if ($text -match '(^|;)v=\d+;') {
        $out.format = "v2"
        foreach ($pair in ($text -split ';')) {
            if (-not $pair) { continue }
            $kv = $pair -split '=', 2
            if ($kv.Count -ne 2) { continue }
            $k = $kv[0]; $v = $kv[1]
            switch ($k) {
                "v"    { }
                "mode" { $out.mode = $v }
                "user" { $out.user = $v }
                "host" { $out.host = $v }
                "dns"  { $out.dns = $v }
                "ips"  { $out.ips = @($v -split ',' | Where-Object { $_ }) }
                "key"  { $out.authKey = $v }
                "tag"  { $out.tag = $v }
                "ts"   { $out.ts = $v }
                "enroll" {
                    $pair = $v -split ':', 2
                    if ($pair.Count -eq 2) {
                        $out.enrollPort = [int]$pair[0]
                        $out.enrollToken = $pair[1]
                    }
                }
            }
        }
    } else {
        $parts = $text -split ':'
        if ($parts.Count -lt 3) { throw "code has too few fields" }
        $uh = $parts[0]
        $out.user = ($uh -split '@')[0]
        $out.host = ($uh -split '@')[1]
        $out.ips = @($parts[1] -split ',' | Where-Object { $_ })
        if ($parts.Count -ge 4 -and $parts[3] -match '^tskey-') { $out.authKey = $parts[3] }
    }

    if (-not $out.user -or -not $out.host -or $out.ips.Count -eq 0) { throw "code fields are empty" }
    return $out
}

# ---------------------------------------------------------------
if ($ShowVersion) { Write-Output $Version; exit 0 }

if ($SelfTest) {
    $problems = @()
    if (-not (Test-Path (Join-Path $PackageRoot "VERSION"))) { $problems += "VERSION file missing" }
    $asset = Join-Path $ScriptRoot "assets\herdr-windows-x86_64.zip"
    if (-not (Test-Path $asset)) { $problems += "herdr asset missing" }

    $v2payload = "v=2;mode=key;user=alice;host=host1;dns=host1.tail.ts.net;ips=100.64.0.1,10.0.0.5;ts=1700000000;tag=tag:herdr-host;key=example-auth-key;enroll=8787:abc123def456"
    $v2code = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($v2payload))
    try {
        $p = ConvertFrom-ConnectionCode -Code $v2code
        if ($p.format -ne "v2") { $problems += "v2 parse: format" }
        if ($p.mode -ne "key") { $problems += "v2 parse: mode" }
        if ($p.dns -ne "host1.tail.ts.net") { $problems += "v2 parse: dns" }
        if (-not $p.authKey) { $problems += "v2 parse: authKey" }
        if ($p.tag -ne "tag:herdr-host") { $problems += "v2 parse: tag" }
        if ($p.enrollPort -ne 8787) { $problems += "v2 parse: enrollPort" }
        if ($p.enrollToken -ne "abc123def456") { $problems += "v2 parse: enrollToken" }
    } catch { $problems += "v2 parse threw: $($_.Exception.Message)" }

    $v1payload = "alice@host1:100.64.0.1,10.0.0.5:1700000000"
    $v1code = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($v1payload))
    try {
        $p1 = ConvertFrom-ConnectionCode -Code $v1code
        if ($p1.format -ne "v1") { $problems += "v1 parse: format" }
        if ($p1.mode -ne "key") { $problems += "v1 parse: default mode" }
    } catch { $problems += "v1 parse threw: $($_.Exception.Message)" }

    $ts = Get-TailscaleExe
    if ($problems.Count -eq 0) {
        Write-Output ("SELFTEST OK (v{0}; tailscale={1}; v1+v2 parse ok)" -f $Version, $(if ($ts) { "found" } else { "not installed" }))
        exit 0
    }
    $problems | ForEach-Object { Write-Output "SELFTEST FAIL: $_" }
    exit $EXIT_INTERNAL
}

if (-not $ConnectionCode) { Fail $EXIT_PREREQ "Missing -ConnectionCode (use -ShowVersion or -SelfTest for diagnostics)" }

Step "Herdr Remote Setup client v$Version"
Log "log file: $LogFile"

# ---------------------------------------------------------------
Step "Decoding connection code"
try { $code = ConvertFrom-ConnectionCode -Code $ConnectionCode }
catch { Fail $EXIT_PREREQ "Invalid connection code: $($_.Exception.Message)" }

$mode = $code.mode
Ok "Format: $($code.format)"
Ok "Mode: $mode"
Ok "Remote: $($code.user)@$($code.host)"
if ($code.dns) { Ok "DNS name: $($code.dns)" }
Ok "Addresses: $($code.ips -join ', ')"
if ($code.authKey) { Ok "Tailscale auth key: present" } else { Warn "No auth key in code" }

$tsTarget = $null
foreach ($ip in $code.ips) { if ($ip -match '^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.') { $tsTarget = $ip; break } }

# ---------------------------------------------------------------
Step "Checking prerequisites"
if ($env:OS -ne "Windows_NT") { Fail $EXIT_PREREQ "This script targets Windows." }
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) { Fail $EXIT_PREREQ "OpenSSH client missing" }
Ok "OpenSSH client present"

$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    $isAdmin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
if (-not $isAdmin) { Warn "Not running as Administrator; Tailscale install may fail" }

# ---------------------------------------------------------------
# Tailscale is required only when the code points at a tailnet address or name.
$needTailscale = ($null -ne $tsTarget) -or ($code.dns -and $code.dns -match '\.ts\.net\.?$')
if (-not $needTailscale) {
    Step "No tailnet address in code; skipping Tailscale"
}

if ($needTailscale) {
    Step "Network layer (Tailscale)"
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

    $status = (& $tsExe status 2>&1 | Out-String)
    $visible = $false
    if ($tsTarget) { $visible = ($status -match [regex]::Escape($tsTarget)) }
    if (-not $visible -and $code.dns) { $visible = ($status -match [regex]::Escape($code.dns.Split('.')[0])) }

    if (-not $visible) {
        if ($code.authKey) {
            Step "Joining the tailnet"
            $join = (& $tsExe up --authkey=$($code.authKey) --accept-routes=false 2>&1 | Out-String)
            Log (Redact $join)
        } else {
            Warn "Target not visible and no auth key"
            Warn "Run 'tailscale up' and log in, then rerun"
        }
        Step "Waiting for the host"
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline) {
            $st = (& $tsExe status 2>&1 | Out-String)
            if (($tsTarget -and $st -match [regex]::Escape($tsTarget)) -or ($code.dns -and $st -match [regex]::Escape($code.dns.Split('.')[0]))) { $visible = $true; break }
            Start-Sleep -Seconds 5
        }
    }
    if (-not $visible) { Fail $EXIT_NET "Host is not reachable in the tailnet" }
    Ok "Tailnet path ready"
}

# ---------------------------------------------------------------
Step "Workspace layer (herdr)"
$herdrCmd = Get-Command herdr -ErrorAction SilentlyContinue
if (-not $herdrCmd) {
    Warn "herdr not installed"
    $installed = $false
    Step "Attempt 1: online installer"
    try {
        $installer = Join-Path $env:TEMP "herdr-install.ps1"
        Invoke-WebRequest -Uri "https://herdr.dev/install.ps1" -OutFile $installer -TimeoutSec 60 -UseBasicParsing
        & $installer 2>&1 | Out-String | ForEach-Object { Log $_ }
        $env:Path = "$([System.Environment]::GetEnvironmentVariable('Path','Machine'));$([System.Environment]::GetEnvironmentVariable('Path','User'))"
        $herdrCmd = Get-Command herdr -ErrorAction SilentlyContinue
        if ($herdrCmd) { $installed = $true; Ok "herdr installed (online)" }
    } catch { Warn "Online install failed: $($_.Exception.Message)" }

    if (-not $installed) {
        $asset = Join-Path $ScriptRoot "assets\herdr-windows-x86_64.zip"
        if (Test-Path $asset) {
            Step "Attempt 2: local package"
            try {
                $sha = (Get-FileHash -Path $asset -Algorithm SHA256).Hash
                $installer = Join-Path $env:TEMP "herdr-install.ps1"
                if (-not (Test-Path $installer)) { Invoke-WebRequest -Uri "https://herdr.dev/install.ps1" -OutFile $installer -TimeoutSec 60 -UseBasicParsing }
                & $installer -LocalPackagePath $asset -LocalPackageFormat "zip" -LocalPackageIdentity "0.9.5" -LocalPackageSha256 $sha 2>&1 | Out-String | ForEach-Object { Log $_ }
                $env:Path = "$([System.Environment]::GetEnvironmentVariable('Path','Machine'));$([System.Environment]::GetEnvironmentVariable('Path','User'))"
                $herdrCmd = Get-Command herdr -ErrorAction SilentlyContinue
                if ($herdrCmd) { $installed = $true; Ok "herdr installed (local package)" }
            } catch { Warn "Local package install failed: $($_.Exception.Message)" }
        }
    }
    if (-not $installed) { Fail $EXIT_HERDR "herdr could not be installed" }
} else { Ok "herdr found" }

# ---------------------------------------------------------------
# Transport
# ---------------------------------------------------------------
$targets = @()
if ($code.dns) { $targets += $code.dns }
foreach ($ip in $code.ips) { if ($targets -notcontains $ip) { $targets += $ip } }

$workingTarget = $null

if ($mode -eq "ts-ssh") {
    Step "Transport layer (Tailscale SSH)"
    Say "Tailscale SSH uses the tailnet identity; no SSH key is used."
    foreach ($t in $targets) {
        $dst = "$($code.user)@$t"
        Say "Trying $dst"
        $probe = & ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes -o PreferredAuthentications=none $dst "echo CONNECT_OK" 2>&1 | Out-String
        if ($probe -match "CONNECT_OK") { $workingTarget = $dst; break }
        $reason = ($probe -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        Warn "Failed: $t ($reason)"
        if ($probe -match "Permission denied|no supported authentication|denied") {
            Warn "Tailscale SSH refused. Check the tailnet ACL 'ssh' section."
        }
        if ($probe -match "kbd-interactive|check mode|browser") {
            Warn "ACL uses action=check; it needs interactive approval. Use action=accept."
        }
    }
    if (-not $workingTarget) {
        Fail $EXIT_KEY "Tailscale SSH failed on every target. Enable 'tailscale up --ssh' on the host and add an ACL 'ssh' rule for its tag."
    }
} else {
    Step "Transport layer (OpenSSH key)"
    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    $sshKey = Join-Path $sshDir "id_ed25519"
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
    if (-not (Test-Path $sshKey)) {
        Warn "Generating SSH key"
        & ssh-keygen -t ed25519 -f $sshKey -N '""' -C "$env:USERNAME@$env:COMPUTERNAME" 2>&1 | Out-String | ForEach-Object { Log $_ }
    }
    if (-not (Test-Path "$sshKey.pub")) { Fail $EXIT_KEY "Public key missing" }
    $pubKey = (Get-Content "$sshKey.pub" -Raw).Trim()

    foreach ($t in $targets) {
        $dst = "$($code.user)@$t"
        Say "Trying $dst"
        $probe = & ssh -i $sshKey -o IdentitiesOnly=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes $dst "echo CONNECT_OK" 2>&1 | Out-String
        if ($probe -match "CONNECT_OK") { $workingTarget = $dst; break }
        Warn "Failed: $t"
    }

    if (-not $workingTarget -and $code.enrollToken) {
        Step "Requesting key enrollment from the host"
        Say "Token and port come from the connection code; no manual key copy is needed."
        $body = @{ code = $code.enrollToken; key = $pubKey } | ConvertTo-Json -Compress
        $enrolled = $false

        foreach ($t in $targets) {
            $uri = "http://{0}:{1}/enroll" -f $t, $code.enrollPort
            try {
                $resp = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json" -TimeoutSec 10
                if ($resp.ok) {
                    Ok "Host accepted the key via $t"
                    $enrolled = $true
                    break
                }
            } catch {
                Warn "Enrollment failed via ${t}: $($_.Exception.Message)"
            }
        }

        if ($enrolled) {
            Start-Sleep -Seconds 2
            foreach ($t in $targets) {
                $dst = "$($code.user)@$t"
                Say "Retrying $dst after enrollment"
                $probe = & ssh -i $sshKey -o IdentitiesOnly=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes $dst "echo CONNECT_OK" 2>&1 | Out-String
                if ($probe -match "CONNECT_OK") { $workingTarget = $dst; break }
                Warn "Still failing: $t"
            }
        } else {
            Warn "Enrollment endpoint unreachable. The host service may have expired (default TTL 600s)."
        }
    }

    if (-not $workingTarget) {
        Fail $EXIT_KEY "SSH authentication failed and enrollment did not succeed. Add this key on the host manually:`n$pubKey"
    }
}

Ok "SSH session: $workingTarget"

# ---------------------------------------------------------------
Step "Registering the machine in herdr"
$machineName = $code.host -replace '\..*$', ''

# Reuse an existing entry for the same target, and keep its user-chosen label.
$existing = $null
try {
    $list = (& herdr machine list --json 2>&1 | Out-String) | ConvertFrom-Json
    foreach ($m in @($list)) {
        $t = [string]$m.target
        $hit = $false
        if ($t -match [regex]::Escape($code.host)) { $hit = $true }
        if (-not $hit -and $code.dns -and $t -match [regex]::Escape($code.dns)) { $hit = $true }
        if (-not $hit) { foreach ($ip in $code.ips) { if ($t -match [regex]::Escape($ip)) { $hit = $true; break } } }
        if ($hit) { $existing = $m; break }
    }
} catch { Log "machine list --json unavailable: $($_.Exception.Message)" }

if ($existing) {
    if ($existing.label) { $machineName = [string]$existing.label }
    if ($existing.target -ne $workingTarget) {
        & herdr machine remove $existing.id 2>&1 | Out-Null
        & herdr machine add $workingTarget --label $machineName 2>&1 | Out-String | ForEach-Object { Log $_ }
        Ok "Machine entry updated: $machineName"
    } else {
        Ok "Machine entry already present: $machineName"
    }
} else {
    & herdr machine add $workingTarget --label $machineName 2>&1 | Out-String | ForEach-Object { Log $_ }
    Ok "Machine entry created: $machineName"
}

$statusOut = (& herdr machine status $machineName 2>&1 | Out-String)
$reachable = ($statusOut -match "reachable")
if ($reachable) { Ok "herdr machine reachable" } else { Warn "herdr status: $($statusOut.Trim())" }

try {
    $sd = Join-Path $env:LOCALAPPDATA "HerdrSetup"; New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $sf = Join-Path $sd "machines.txt"
    $known = @(); if (Test-Path $sf) { $known = Get-Content $sf | Where-Object { $_ } }
    if ($known -notcontains $machineName) { Add-Content -LiteralPath $sf -Value $machineName }
} catch { }

# ---------------------------------------------------------------
# Install the watchdog as part of the standard flow.
# ---------------------------------------------------------------
if (-not $NoWatchdog) {
    Step "Installing the connection watchdog"
    $installer = Join-Path $ScriptRoot "install-watchdog.ps1"
    if (Test-Path $installer) {
        try {
            & $installer -IntervalMinutes $WatchdogIntervalMinutes 2>&1 | Out-String | ForEach-Object { Log $_ }
            Ok "Watchdog installed (every $WatchdogIntervalMinutes min)"
        } catch {
            Warn "Watchdog install failed: $($_.Exception.Message)"
        }
    } else {
        Warn "install-watchdog.ps1 not found; watchdog skipped"
    }
} else {
    Warn "Watchdog skipped (-NoWatchdog)"
}

# ---------------------------------------------------------------
if ($Json) {
    [ordered]@{ version=$Version; ok=$true; exitCode=0; mode=$mode; host=$code.host; dns=$code.dns; target=$workingTarget; machine=$machineName; reachable=$reachable; log=$LogFile } | ConvertTo-Json -Depth 5 | Write-Output
} else {
    Say ""
    Say "================================================================"
    Say "  Setup complete (v$Version, mode $mode)"
    Say "================================================================"
    Say ""
    Say "  herdr --machine $machineName"
    Say "  herdr --remote $workingTarget"
    Say ""
    Say "  log: $LogFile"
    Say ""
}

Log "client setup v$Version complete mode=$mode target=$workingTarget reachable=$reachable"
exit $EXIT_OK
