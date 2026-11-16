# Herdr Connect - simple Windows client.
#
# Two actions:
#   Connect to a computer  - scan the tailnet, enter the host PIN, connect
#   Share this computer    - not available on Windows in this release
#
# The old role/OS and connection-code flow remains under Advanced setup.
# ASCII only. PowerShell 5.1 compatible.

#Requires -Version 5.1

param(
    [string]$HostName,
    [string]$Pin,
    [string]$JoinCode,
    [int]$Port = 8765,
    [switch]$SelfTest,
    [switch]$NoGui,
    [switch]$NoWatchdog
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$PackageRoot = Split-Path $ScriptRoot -Parent
$Version = '0.0.0'
$VersionFile = Join-Path $PackageRoot 'VERSION'
if (Test-Path -LiteralPath $VersionFile) {
    $Version = (Get-Content -LiteralPath $VersionFile -Raw).Trim()
}

# The guest join code prefix. Built from parts so the self-test's secret scan
# stays meaningful for real keys.
$JoinPrefix = 'tskey' + '-auth-'

function Invoke-SelfTest {
    $problems = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $VersionFile)) { $problems.Add('VERSION file missing') }
    foreach ($rel in @('client\pair.ps1', 'client\install-watchdog.ps1', 'app\herdr-setup.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $rel))) {
            $problems.Add("missing: $rel")
        }
    }
    if ($Pin -and $Pin -notmatch '^[0-9]{6}$') { $problems.Add('PIN must be 6 digits') }
    if ($JoinCode -and -not $JoinCode.StartsWith($JoinPrefix)) { $problems.Add('join code has the wrong prefix') }
    $secretPrefix = 'tskey' + '-'
    foreach ($file in (Get-ChildItem -LiteralPath $ScriptRoot -File | Where-Object { $_.Extension -in @('.ps1', '.sh') })) {
        try {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            if ($text -and $text.Contains($secretPrefix)) { $problems.Add("secret-like literal in app/$($file.Name)") }
        } catch { $problems.Add("cannot read app/$($file.Name)") }
    }
    if ($problems.Count -gt 0) {
        $problems | ForEach-Object { Write-Output "SELFTEST FAIL: $_" }
        exit 6
    }
    Write-Output "SELFTEST OK (v$Version; pair protocol 1)"
    exit 0
}

if ($SelfTest) { Invoke-SelfTest }

if ($NoGui) {
    if (-not $HostName -or -not $Pin) {
        Write-Output '{"ok":false,"exitCode":2,"error":"-NoGui needs -HostName and -Pin"}'
        exit 2
    }
    $pair = Join-Path $ScriptRoot '..\client\pair.ps1'
    $pair = (Resolve-Path $pair).Path
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $pair, '-HostName', $HostName, '-Pin', $Pin, '-Port', "$Port", '-Json')
    if ($NoWatchdog) { $childArgs += '-NoWatchdog' }
    & powershell.exe @childArgs
    exit $LASTEXITCODE
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$runnerSource = @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

public class HerdrPairRunner
{
    private Process proc;
    public ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    public string StartError = "";
    public int ExitCode = -1;

    public bool Start(string fileName, string arguments)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(fileName, arguments);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            proc = new Process();
            proc.StartInfo = psi;
            proc.OutputDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data != null) { Lines.Enqueue(e.Data); }
            };
            proc.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data != null) { Lines.Enqueue("! " + e.Data); }
            };
            proc.Start();
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            return true;
        }
        catch (Exception ex)
        {
            StartError = ex.Message;
            return false;
        }
    }

    public bool HasExited
    {
        get { try { return proc == null || proc.HasExited; } catch { return true; } }
    }

    public int Finish()
    {
        try { proc.WaitForExit(); ExitCode = proc.ExitCode; } catch { }
        return ExitCode;
    }

    public string DrainOne()
    {
        string line;
        if (Lines.TryDequeue(out line)) { return line; }
        return null;
    }
}
'@

Add-Type -TypeDefinition $runnerSource -Language CSharp

function Get-TailscaleExe {
    $c = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\Tailscale\tailscale.exe", "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-TailnetPeer {
    $ts = Get-TailscaleExe
    if (-not $ts) { return @() }
    try {
        $data = (& $ts status --json 2>&1 | Out-String) | ConvertFrom-Json
        if (-not $data.Peer) { return @() }
        return @($data.Peer.PSObject.Properties | ForEach-Object { $_.Value })
    } catch { return @() }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Herdr Connect v$Version"
$form.ClientSize = New-Object System.Drawing.Size(760, 600)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$title = New-Object System.Windows.Forms.Label
$title.Location = New-Object System.Drawing.Point(18, 14)
$title.Size = New-Object System.Drawing.Size(720, 30)
$title.Text = "Herdr Connect v$Version"
$title.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Location = New-Object System.Drawing.Point(20, 48)
$sub.Size = New-Object System.Drawing.Size(720, 22)
$sub.Text = 'Connect two computers with a 6-digit PIN. No connection code.'
$sub.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($sub)

$connectTop = New-Object System.Windows.Forms.Button
$connectTop.Location = New-Object System.Drawing.Point(20, 82)
$connectTop.Size = New-Object System.Drawing.Size(230, 46)
$connectTop.Text = 'Connect to a computer'
$connectTop.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($connectTop)

$shareTop = New-Object System.Windows.Forms.Button
$shareTop.Location = New-Object System.Drawing.Point(260, 82)
$shareTop.Size = New-Object System.Drawing.Size(230, 46)
$shareTop.Text = 'Share this computer'
$form.Controls.Add($shareTop)

$advancedTop = New-Object System.Windows.Forms.Button
$advancedTop.Location = New-Object System.Drawing.Point(500, 82)
$advancedTop.Size = New-Object System.Drawing.Size(230, 46)
$advancedTop.Text = 'Advanced setup'
$form.Controls.Add($advancedTop)

$panel = New-Object System.Windows.Forms.Panel
$panel.Location = New-Object System.Drawing.Point(16, 140)
$panel.Size = New-Object System.Drawing.Size(728, 442)
$panel.Visible = $false
$form.Controls.Add($panel)

$hostsLabel = New-Object System.Windows.Forms.Label
$hostsLabel.Location = New-Object System.Drawing.Point(4, 0)
$hostsLabel.Size = New-Object System.Drawing.Size(300, 20)
$hostsLabel.Text = 'Computers sharing on your tailnet'
$panel.Controls.Add($hostsLabel)

$hostList = New-Object System.Windows.Forms.ListBox
$hostList.Location = New-Object System.Drawing.Point(4, 22)
$hostList.Size = New-Object System.Drawing.Size(360, 120)
$panel.Controls.Add($hostList)

$refreshBtn = New-Object System.Windows.Forms.Button
$refreshBtn.Location = New-Object System.Drawing.Point(374, 22)
$refreshBtn.Size = New-Object System.Drawing.Size(110, 28)
$refreshBtn.Text = 'Refresh'
$panel.Controls.Add($refreshBtn)

$hostLabel = New-Object System.Windows.Forms.Label
$hostLabel.Location = New-Object System.Drawing.Point(374, 60)
$hostLabel.Size = New-Object System.Drawing.Size(100, 20)
$hostLabel.Text = 'Host or IP'
$panel.Controls.Add($hostLabel)

$hostBox = New-Object System.Windows.Forms.TextBox
$hostBox.Location = New-Object System.Drawing.Point(474, 58)
$hostBox.Size = New-Object System.Drawing.Size(250, 24)
$panel.Controls.Add($hostBox)

$joinLabel = New-Object System.Windows.Forms.Label
$joinLabel.Location = New-Object System.Drawing.Point(4, 96)
$joinLabel.Size = New-Object System.Drawing.Size(460, 20)
$joinLabel.Text = 'Join code (optional, from the host)'
$panel.Controls.Add($joinLabel)

$joinBox = New-Object System.Windows.Forms.TextBox
$joinBox.Location = New-Object System.Drawing.Point(4, 118)
$joinBox.Size = New-Object System.Drawing.Size(460, 24)
$panel.Controls.Add($joinBox)

$joinWarn = New-Object System.Windows.Forms.Label
$joinWarn.Location = New-Object System.Drawing.Point(474, 118)
$joinWarn.Size = New-Object System.Drawing.Size(250, 40)
$joinWarn.Text = "This joins the host's tailnet as a tagged guest device."
$joinWarn.ForeColor = [System.Drawing.Color]::DarkOrange
$joinWarn.Visible = $false
$panel.Controls.Add($joinWarn)

$joinBox.Add_TextChanged({
    $joinWarn.Visible = ($joinBox.Text.Trim().Length -gt 0)
})

$pinLabel = New-Object System.Windows.Forms.Label
$pinLabel.Location = New-Object System.Drawing.Point(4, 168)
$pinLabel.Size = New-Object System.Drawing.Size(200, 20)
$pinLabel.Text = 'PIN from the other computer'
$panel.Controls.Add($pinLabel)

$pinBox = New-Object System.Windows.Forms.TextBox
$pinBox.Location = New-Object System.Drawing.Point(4, 190)
$pinBox.Size = New-Object System.Drawing.Size(140, 24)
$pinBox.MaxLength = 6
$pinBox.PasswordChar = '*'
$panel.Controls.Add($pinBox)

$watchdogBox = New-Object System.Windows.Forms.CheckBox
$watchdogBox.Location = New-Object System.Drawing.Point(160, 190)
$watchdogBox.Size = New-Object System.Drawing.Size(300, 24)
$watchdogBox.Text = 'Install the connection watchdog'
$watchdogBox.Checked = $true
$panel.Controls.Add($watchdogBox)

$connectBtn = New-Object System.Windows.Forms.Button
$connectBtn.Location = New-Object System.Drawing.Point(474, 184)
$connectBtn.Size = New-Object System.Drawing.Size(130, 34)
$connectBtn.Text = 'Connect'
$panel.Controls.Add($connectBtn)

$openBtn = New-Object System.Windows.Forms.Button
$openBtn.Location = New-Object System.Drawing.Point(614, 184)
$openBtn.Size = New-Object System.Drawing.Size(110, 34)
$openBtn.Text = 'Open herdr'
$openBtn.Enabled = $false
$panel.Controls.Add($openBtn)

$outLabel = New-Object System.Windows.Forms.Label
$outLabel.Location = New-Object System.Drawing.Point(4, 226)
$outLabel.Size = New-Object System.Drawing.Size(200, 20)
$outLabel.Text = 'Output'
$panel.Controls.Add($outLabel)

$outputBox = New-Object System.Windows.Forms.RichTextBox
$outputBox.Location = New-Object System.Drawing.Point(4, 248)
$outputBox.Size = New-Object System.Drawing.Size(720, 186)
$outputBox.ReadOnly = $true
$outputBox.BackColor = [System.Drawing.Color]::White
$outputBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$outputBox.WordWrap = $false
$outputBox.ScrollBars = 'Vertical'
$panel.Controls.Add($outputBox)

function Add-Line {
    param([string]$Text, $Color)
    if ($null -eq $Color) { $Color = [System.Drawing.Color]::Black }
    $outputBox.SelectionStart = $outputBox.TextLength
    $outputBox.SelectionLength = 0
    $outputBox.SelectionColor = $Color
    $outputBox.AppendText($Text + "`r`n")
    $outputBox.SelectionStart = $outputBox.TextLength
    $outputBox.ScrollToCaret()
}

function Find-Host {
    $hostList.Items.Clear()
    Add-Line 'Scanning the tailnet...' ([System.Drawing.Color]::RoyalBlue)
    $peers = Get-TailnetPeer
    $found = 0
    foreach ($p in $peers) {
        $ips = @($p.TailscaleIPs)
        $ip = ($ips | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)
        if (-not $ip) { continue }
        try {
            $info = Invoke-RestMethod -Uri ("http://{0}:{1}/api/info" -f $ip, $Port) -Method Get -TimeoutSec 1
            if ($info.service -eq 'herdr-pair') {
                $label = "{0}  ({1})" -f $info.host, $ip
                [void]$hostList.Items.Add($label)
                $found++
            }
        } catch { }
        [System.Windows.Forms.Application]::DoEvents()
    }
    if ($found -eq 0) {
        Add-Line 'No sharing computer found. Start host/pair.sh on the other computer, or type its IP.' ([System.Drawing.Color]::DarkOrange)
    } else {
        Add-Line ("Found {0} sharing computer(s)." -f $found) ([System.Drawing.Color]::ForestGreen)
    }
}

$connectTop.Add_Click({
    $panel.Visible = $true
    $connectTop.Enabled = $false
    Find-Host
})

$refreshBtn.Add_Click({ Find-Host })

$hostList.Add_SelectedIndexChanged({
    $t = [string]$hostList.SelectedItem
    $m = [regex]::Match($t, '\(([0-9.]+)\)$')
    if ($m.Success) { $hostBox.Text = $m.Groups[1].Value }
})

$shareTop.Add_Click({
    [void][System.Windows.Forms.MessageBox]::Show(
        "This Windows build can only connect.`r`n`r`nRun the host share flow on the Linux or macOS computer, then use the PIN here.",
        'Share this computer', 'OK', 'Information')
})

$advancedTop.Add_Click({
    $old = Join-Path $ScriptRoot 'herdr-setup.ps1'
    if (Test-Path $old) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $old)
    } else {
        [void][System.Windows.Forms.MessageBox]::Show("herdr-setup.ps1 not found.", 'Advanced setup', 'OK', 'Warning')
    }
})

$script:runner = $null
$script:timer = $null
$script:machine = ''

function Set-Busy {
    param([bool]$Busy)
    $connectBtn.Enabled = -not $Busy
    $refreshBtn.Enabled = -not $Busy
    $hostList.Enabled = -not $Busy
    $hostBox.Enabled = -not $Busy
    $joinBox.Enabled = -not $Busy
    $pinBox.Enabled = -not $Busy
    $watchdogBox.Enabled = -not $Busy
}

$connectBtn.Add_Click({
    $hostValue = $hostBox.Text.Trim()
    $pinValue = $pinBox.Text.Trim()
    $joinValue = $joinBox.Text.Trim()
    if (-not $hostValue) {
        [void][System.Windows.Forms.MessageBox]::Show('Choose a computer or type its host name or IP.', 'Herdr Connect', 'OK', 'Warning')
        return
    }
    if ($joinValue -and -not $joinValue.StartsWith($JoinPrefix)) {
        [void][System.Windows.Forms.MessageBox]::Show('The join code is not valid. Copy the whole code from the host window, or leave the field empty to sign in to Tailscale yourself.', 'Herdr Connect', 'OK', 'Warning')
        return
    }
    if ($pinValue -notmatch '^[0-9]{6}$') {
        [void][System.Windows.Forms.MessageBox]::Show('Enter the 6-digit PIN shown on the other computer.', 'Herdr Connect', 'OK', 'Warning')
        return
    }

    $pair = Join-Path $ScriptRoot '..\client\pair.ps1'
    $pair = (Resolve-Path $pair).Path
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $pair + '" -HostName "' + $hostValue + '" -Pin "' + $pinValue + '" -Port ' + $Port + ' -Json'
    if ($joinValue) { $argLine += ' -JoinCode "' + $joinValue + '"' }
    if (-not $watchdogBox.Checked) { $argLine += ' -NoWatchdog' }

    Set-Busy -Busy $true
    $openBtn.Enabled = $false
    $script:machine = ''
    Add-Line ''
    Add-Line 'Connecting...' ([System.Drawing.Color]::RoyalBlue)

    $script:runner = New-Object HerdrPairRunner
    if (-not $script:runner.Start('powershell.exe', $argLine)) {
        Add-Line ('Could not start the client: ' + $script:runner.StartError) ([System.Drawing.Color]::Firebrick)
        $script:runner = $null
        Set-Busy -Busy $false
        return
    }
    $script:timer.Start()
})

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 150
$script:timer.Add_Tick({
    if ($null -eq $script:runner) { $script:timer.Stop(); return }
    $line = $script:runner.DrainOne()
    while ($null -ne $line) {
        Add-Line $line
        $line = $script:runner.DrainOne()
    }
    if (-not $script:runner.HasExited) { return }

    $code = $script:runner.Finish()
    $line = $script:runner.DrainOne()
    while ($null -ne $line) {
        Add-Line $line
        $line = $script:runner.DrainOne()
    }
    $script:timer.Stop()
    $script:runner = $null
    Set-Busy -Busy $false

    $jsonLine = $null
    foreach ($l in ($outputBox.Text -split "`r?`n")) {
        if ($l.Trim().StartsWith('{')) { $jsonLine = $l.Trim() }
    }
    if ($code -eq 0 -and $jsonLine) {
        try {
            $result = $jsonLine | ConvertFrom-Json
            if ($result.ok) {
                $script:machine = [string]$result.machine
                Add-Line ''
                Add-Line ("Connected. Machine: {0}" -f $script:machine) ([System.Drawing.Color]::ForestGreen)
                $openBtn.Enabled = $true
                [void][System.Windows.Forms.MessageBox]::Show("Connected.`r`n`r`nClick Open herdr to start.", 'Herdr Connect', 'OK', 'Information')
                return
            }
        } catch { }
    }
    Add-Line ''
    Add-Line ("Failed with exit code {0}." -f $code) ([System.Drawing.Color]::Firebrick)
    [void][System.Windows.Forms.MessageBox]::Show("Connection failed. See the output window.", 'Herdr Connect', 'OK', 'Error')
})

$openBtn.Add_Click({
    if (-not $script:machine) { return }
    $herdr = 'herdr'
    $cmd = Get-Command herdr -ErrorAction SilentlyContinue
    if ($cmd) { $herdr = $cmd.Source }
    else {
        $cand = Get-ChildItem "$env:USERPROFILE\.herdr\packages\standalone\releases\*\herdr.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($cand) { $herdr = $cand.FullName }
    }
    $arg = '/c start "" "' + $herdr + '" --machine "' + $script:machine + '"'
    Start-Process -FilePath 'cmd.exe' -ArgumentList $arg
})

$form.Add_FormClosing({
    param($formSender, $e)
    if ($null -ne $script:runner -and -not $script:runner.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show('A connection is still running. Close anyway?', 'Herdr Connect', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $e.Cancel = $true }
    }
})

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
exit 0
