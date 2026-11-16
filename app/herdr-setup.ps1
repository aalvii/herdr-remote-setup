# Herdr Remote Setup - thin cross-platform front end (Windows).
#
# Why WinForms and not Tkinter: on the three targets only Windows PowerShell 5.1
# gives a GUI toolkit with zero install. The Linux host has python3 but no
# tkinter and no DISPLAY, and the macOS Command Line Tools python3 does not ship
# tkinter reliably. Linux and macOS use app/herdr-setup.sh instead.
#
# This file is a front end only: the scripts under host/ and client/ are the
# source of truth and are never modified here.
#
# ASCII only. PowerShell 5.1 compatible.

#Requires -Version 5.1

param(
    [ValidateSet('Host', 'Client')]
    [string]$Role,

    [ValidateSet('Linux', 'macOS', 'Windows')]
    [string]$Os,

    [string]$Code = '',

    [switch]$SelfTest,

    [switch]$NoGui
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$PackageRoot = Split-Path $ScriptRoot -Parent
$AppRoot = $ScriptRoot

$Version = '0.0.0'
$VersionFile = Join-Path $PackageRoot 'VERSION'
if (Test-Path -LiteralPath $VersionFile) {
    $Version = (Get-Content -LiteralPath $VersionFile -Raw).Trim()
}

# This front end is the Windows one. On anything else no flow can run here.
$LocalOs = 'Windows'
if ($env:OS -ne 'Windows_NT') { $LocalOs = 'Unknown' }

# ---------------------------------------------------------------------------
# The support matrix. This is the only place that knows which combination is
# run, guidance, or unsupported. Message is the guidance text used when the
# flow cannot run on this machine.
# ---------------------------------------------------------------------------
function Get-Matrix {
    return @(
        [pscustomobject]@{ Role = 'Host';   Os = 'Linux';   Kind = 'run';         Path = 'host/provision.sh';     Message = 'Runs on the Linux host. Generate the connection code there, then send it to the client.' }
        [pscustomobject]@{ Role = 'Host';   Os = 'macOS';   Kind = 'run';         Path = 'host/provision.sh';     Message = 'Runs on the macOS host. Generate the connection code there, then send it to the client.' }
        [pscustomobject]@{ Role = 'Host';   Os = 'Windows'; Kind = 'unsupported'; Path = '';                      Message = 'Host mode is not shipped for Windows. Run host/provision.sh on the Linux host or the macOS host.' }
        [pscustomobject]@{ Role = 'Client'; Os = 'Linux';   Kind = 'unsupported'; Path = '';                      Message = 'Client mode is not shipped for Linux. Run client/setup.ps1 on the Windows client or client/setup-macos.sh on the macOS client.' }
        [pscustomobject]@{ Role = 'Client'; Os = 'macOS';   Kind = 'run';         Path = 'client/setup-macos.sh'; Message = 'Runs on the macOS client with the connection code from the host.' }
        [pscustomobject]@{ Role = 'Client'; Os = 'Windows'; Kind = 'run';         Path = 'client/setup.ps1';      Message = 'Runs on the Windows client with the connection code from the host.' }
    )
}

function Get-Row {
    param([string]$RoleName, [string]$OsName)
    $key = "$RoleName|$OsName"
    foreach ($row in (Get-Matrix)) {
        if (("$($row.Role)|$($row.Os)") -eq $key) { return $row }
    }
    return $null
}

# The command a user must type on the machine that owns the flow. The connection
# code is always shown as <code>; the real value never reaches this function.
function Get-DisplayCommand {
    param([string]$RelPath, [string]$TargetOs)
    if (-not $RelPath) { return '' }
    $abs = Join-Path $PackageRoot $RelPath
    if ($TargetOs -eq 'Windows') {
        return ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -ConnectionCode <code>' -f $abs)
    }
    if ($RelPath -like '*setup-macos.sh') {
        return ('bash "{0}" --code "<code>"' -f $abs)
    }
    return ('bash "{0}"' -f $abs)
}

function Resolve-Action {
    param([string]$RoleName, [string]$OsName, [string]$CodeValue)

    $row = Get-Row -RoleName $RoleName -OsName $OsName
    if ($null -eq $row) { throw "Unknown combination: $RoleName + $OsName" }

    $kind = $row.Kind
    $message = $row.Message
    $relPath = $row.Path
    $targetOs = $OsName

    # A run row is still guidance when the selected OS is not this machine.
    if ($kind -eq 'run' -and $OsName -ne $LocalOs) {
        $kind = 'guidance'
        $message = "This machine is $LocalOs. " + $message
    }

    # Unsupported rows still point at the nearest real script.
    if ($kind -eq 'unsupported') {
        if ($RoleName -eq 'Host') {
            $relPath = 'host/provision.sh'
            $targetOs = 'Linux'
        } else {
            $relPath = 'client/setup.ps1'
            $targetOs = 'Windows'
        }
        $message = $row.Message + ' Use it on the right machine; this app will not start it here.'
    }

    $absPath = ''
    if ($relPath) { $absPath = Join-Path $PackageRoot $relPath }
    $display = Get-DisplayCommand -RelPath $relPath -TargetOs $targetOs

    $launchFile = ''
    $launchArgs = @()

    if ($kind -eq 'run') {
        if (-not (Test-Path -LiteralPath $absPath)) {
            $kind = 'guidance'
            $message = "Missing script: $absPath"
        } elseif ($targetOs -eq 'Windows' -and $relPath -like '*.ps1') {
            $launchFile = 'powershell.exe'
            # Only this array may hold the secret, and it is never printed.
            $launchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $absPath)
            if ($CodeValue) { $launchArgs += @('-ConnectionCode', $CodeValue) }
        } else {
            $kind = 'guidance'
            $message = "This front end cannot start $relPath here."
        }
    }

    return [pscustomobject]@{
        Role       = $RoleName
        Os         = $OsName
        Kind       = $kind
        Path       = $absPath
        Display    = $display
        Message    = $message
        LaunchFile = $launchFile
        LaunchArgs = $launchArgs
    }
}

# ---------------------------------------------------------------------------
# Headless self-test: no network, no child processes.
# ---------------------------------------------------------------------------
function Invoke-SelfTest {
    $problems = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $VersionFile)) {
        $problems.Add('VERSION file missing')
    } elseif ([string]::IsNullOrWhiteSpace($Version)) {
        $problems.Add('VERSION file is empty')
    }

    $rows = Get-Matrix
    if ($rows.Count -ne 6) {
        $problems.Add("matrix has $($rows.Count) rows, expected 6")
    }

    foreach ($row in $rows) {
        if ($row.Kind -eq 'run') {
            $abs = Join-Path $PackageRoot $row.Path
            if (-not (Test-Path -LiteralPath $abs)) {
                $problems.Add("runnable script missing: $($row.Path)")
            }
        }
    }

    # No key material may be pasted into the front end.
    $secretPrefix = 'tskey' + '-'
    foreach ($file in (Get-ChildItem -LiteralPath $AppRoot -File | Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.sh' })) {
        try {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            if ($text -and $text.Contains($secretPrefix)) {
                $problems.Add("secret-like literal in app/$($file.Name)")
            }
        } catch {
            $problems.Add("cannot read app/$($file.Name)")
        }
    }

    $runnableHere = 0
    foreach ($row in $rows) {
        if ($row.Kind -eq 'run' -and $row.Os -eq $LocalOs) { $runnableHere++ }
    }

    foreach ($roleName in @('Host', 'Client')) {
        foreach ($osName in @('Linux', 'macOS', 'Windows')) {
            try {
                $probe = Resolve-Action -RoleName $roleName -OsName $osName -CodeValue ''
                if (@('run', 'guidance', 'unsupported') -notcontains $probe.Kind) {
                    $problems.Add("$roleName + $osName resolved to '$($probe.Kind)'")
                }
            } catch {
                $problems.Add("$roleName + $osName threw: $($_.Exception.Message)")
            }
        }
    }

    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { Write-Output "SELFTEST FAIL: $p" }
        exit 6
    }

    Write-Output ("SELFTEST OK (v{0}; 6 combos; {1} runnable here)" -f $Version, $runnableHere)
    exit 0
}

if ($SelfTest) { Invoke-SelfTest }

# ---------------------------------------------------------------------------
# Headless verification path.
# ---------------------------------------------------------------------------
if ($NoGui) {
    if (-not $Role -or -not $Os) {
        $result = [ordered]@{
            version = $Version; role = $Role; os = $Os; kind = 'unsupported'
            command = ''; message = 'Both -Role and -Os are required.'
        }
        Write-Output ($result | ConvertTo-Json -Compress)
        Write-Output $result.message
        exit 2
    }

    try {
        $action = Resolve-Action -RoleName $Role -OsName $Os -CodeValue $Code
    } catch {
        $result = [ordered]@{
            version = $Version; role = $Role; os = $Os; kind = 'unsupported'
            command = ''; message = $_.Exception.Message
        }
        Write-Output ($result | ConvertTo-Json -Compress)
        Write-Output $result.message
        exit 2
    }

    # The command field is the masked form; the code is never printed.
    $json = [ordered]@{
        version = $Version
        role    = $action.Role
        os      = $action.Os
        kind    = $action.Kind
        command = $action.Display
        message = $action.Message
    }
    Write-Output ($json | ConvertTo-Json -Compress)

    if ($action.Kind -ne 'run') {
        Write-Output $action.Message
        exit 2
    }

    if ($Role -eq 'Client' -and -not $Code) {
        Write-Output 'A connection code is required for the client flow (-Code).'
        exit 2
    }

    # No elevation prompt is possible headless; setup.ps1 already warns when it
    # is not elevated. The child inherits stdout and streams to the console.
    & $action.LaunchFile @($action.LaunchArgs)
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# A command-line process already works, but PowerShell event handlers cannot be
# relied on while a modal dialog owns the pipeline. This tiny helper moves the
# redirected streams into a queue on background threads, and the UI timer
# drains that queue on the UI thread.
$runnerSource = @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

public class HerdrRunner
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
        get
        {
            if (proc == null) { return true; }
            try { return proc.HasExited; }
            catch { return true; }
        }
    }

    public int Finish()
    {
        try
        {
            proc.WaitForExit();
            ExitCode = proc.ExitCode;
        }
        catch { }
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

$script:runner = $null
$script:timer = $null

$form = New-Object System.Windows.Forms.Form
$form.Text = "Herdr Remote Setup v$Version"
$form.ClientSize = New-Object System.Drawing.Size(704, 521)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false

$title = New-Object System.Windows.Forms.Label
$title.Location = New-Object System.Drawing.Point(16, 12)
$title.Size = New-Object System.Drawing.Size(672, 26)
$title.Text = "Herdr Remote Setup v$Version"
$title.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($title)

$roleLabel = New-Object System.Windows.Forms.Label
$roleLabel.Location = New-Object System.Drawing.Point(16, 46)
$roleLabel.Size = New-Object System.Drawing.Size(60, 20)
$roleLabel.Text = 'Role:'
$form.Controls.Add($roleLabel)

$rbHost = New-Object System.Windows.Forms.RadioButton
$rbHost.Location = New-Object System.Drawing.Point(80, 44)
$rbHost.Size = New-Object System.Drawing.Size(90, 22)
$rbHost.Text = 'Host'
$form.Controls.Add($rbHost)

$rbClient = New-Object System.Windows.Forms.RadioButton
$rbClient.Location = New-Object System.Drawing.Point(174, 44)
$rbClient.Size = New-Object System.Drawing.Size(90, 22)
$rbClient.Text = 'Client'
$form.Controls.Add($rbClient)

$osLabel = New-Object System.Windows.Forms.Label
$osLabel.Location = New-Object System.Drawing.Point(16, 74)
$osLabel.Size = New-Object System.Drawing.Size(60, 20)
$osLabel.Text = 'OS:'
$form.Controls.Add($osLabel)

$osBox = New-Object System.Windows.Forms.ComboBox
$osBox.Location = New-Object System.Drawing.Point(80, 72)
$osBox.Size = New-Object System.Drawing.Size(180, 24)
$osBox.DropDownStyle = 'DropDownList'
[void]$osBox.Items.Add('Linux')
[void]$osBox.Items.Add('macOS')
[void]$osBox.Items.Add('Windows')
$form.Controls.Add($osBox)

$hint = New-Object System.Windows.Forms.Label
$hint.Location = New-Object System.Drawing.Point(270, 76)
$hint.Size = New-Object System.Drawing.Size(418, 20)
$hint.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($hint)

$codeLabel = New-Object System.Windows.Forms.Label
$codeLabel.Location = New-Object System.Drawing.Point(16, 104)
$codeLabel.Size = New-Object System.Drawing.Size(672, 18)
$codeLabel.Text = 'Connection code (client on Windows only):'
$form.Controls.Add($codeLabel)

# WinForms masks only single-line boxes, so this stays visible. The value is
# never echoed, logged, or written to the output box.
$codeBox = New-Object System.Windows.Forms.TextBox
$codeBox.Location = New-Object System.Drawing.Point(16, 124)
$codeBox.Size = New-Object System.Drawing.Size(672, 58)
$codeBox.Multiline = $true
$codeBox.ScrollBars = 'Vertical'
$codeBox.WordWrap = $false
$codeBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($codeBox)

$runBtn = New-Object System.Windows.Forms.Button
$runBtn.Location = New-Object System.Drawing.Point(16, 192)
$runBtn.Size = New-Object System.Drawing.Size(120, 30)
$runBtn.Text = 'Run'
$form.Controls.Add($runBtn)

$copyBtn = New-Object System.Windows.Forms.Button
$copyBtn.Location = New-Object System.Drawing.Point(146, 192)
$copyBtn.Size = New-Object System.Drawing.Size(120, 30)
$copyBtn.Text = 'Copy code'
$form.Controls.Add($copyBtn)

$logBtn = New-Object System.Windows.Forms.Button
$logBtn.Location = New-Object System.Drawing.Point(276, 192)
$logBtn.Size = New-Object System.Drawing.Size(120, 30)
$logBtn.Text = 'Open logs'
$form.Controls.Add($logBtn)

$closeBtn = New-Object System.Windows.Forms.Button
$closeBtn.Location = New-Object System.Drawing.Point(568, 192)
$closeBtn.Size = New-Object System.Drawing.Size(120, 30)
$closeBtn.Text = 'Close'
$closeBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($closeBtn)

$outLabel = New-Object System.Windows.Forms.Label
$outLabel.Location = New-Object System.Drawing.Point(16, 230)
$outLabel.Size = New-Object System.Drawing.Size(200, 18)
$outLabel.Text = 'Output'
$form.Controls.Add($outLabel)

$outputBox = New-Object System.Windows.Forms.RichTextBox
$outputBox.Location = New-Object System.Drawing.Point(16, 250)
$outputBox.Size = New-Object System.Drawing.Size(672, 255)
$outputBox.ReadOnly = $true
$outputBox.BackColor = [System.Drawing.Color]::White
$outputBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$outputBox.WordWrap = $false
$outputBox.ScrollBars = 'Vertical'
$form.Controls.Add($outputBox)

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

function Get-SelectedRole {
    if ($rbHost.Checked) { return 'Host' }
    return 'Client'
}

function Get-OsSelection {
    return [string]$osBox.SelectedItem
}

function Update-Selection {
    $role = Get-SelectedRole
    $osSel = Get-OsSelection
    $row = Get-Row -RoleName $role -OsName $osSel

    $showCode = ($role -eq 'Client' -and $osSel -eq 'Windows')
    $codeLabel.Visible = $showCode
    $codeBox.Visible = $showCode

    if ($null -eq $row) {
        $hint.Text = ''
        $hint.ForeColor = [System.Drawing.Color]::DimGray
        return
    }
    if ($row.Kind -eq 'unsupported') {
        $hint.Text = 'Not shipped for this combination.'
        $hint.ForeColor = [System.Drawing.Color]::Firebrick
    } elseif ($row.Os -eq $LocalOs) {
        $hint.Text = 'Runs on this machine.'
        $hint.ForeColor = [System.Drawing.Color]::ForestGreen
    } else {
        $hint.Text = 'Runs on the other machine; this app shows the command.'
        $hint.ForeColor = [System.Drawing.Color]::DarkOrange
    }
}

function Set-Busy {
    param([bool]$Busy)
    $runBtn.Enabled = -not $Busy
    $copyBtn.Enabled = -not $Busy
    $rbHost.Enabled = -not $Busy
    $rbClient.Enabled = -not $Busy
    $osBox.Enabled = -not $Busy
    $codeBox.Enabled = -not $Busy
}

function Show-Guidance {
    param($Action)
    Add-Line ''
    Add-Line $Action.Message ([System.Drawing.Color]::DarkOrange)
    if ($Action.Path) { Add-Line ('  file: ' + $Action.Path) ([System.Drawing.Color]::DimGray) }
    if ($Action.Display) { Add-Line ('  run:  ' + $Action.Display) ([System.Drawing.Color]::DimGray) }
    $body = $Action.Message
    if ($Action.Path) { $body = $body + "`r`n`r`nFile: " + $Action.Path }
    if ($Action.Display) { $body = $body + "`r`nCommand: " + $Action.Display }
    [void][System.Windows.Forms.MessageBox]::Show($body, "Herdr Remote Setup", 'OK', 'Information')
}

function Start-Elevated {
    param([string]$CodeValue)
    # Start-Process joins the array without quoting, so the executable path and
    # the code are quoted explicitly. The code is a base64 token and is not
    # written anywhere by this script.
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Role Client -Os Windows'
    if ($CodeValue) { $argLine = $argLine + ' -Code "' + $CodeValue + '"' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null
    } catch {
        Add-Line ('Elevation failed: ' + $_.Exception.Message) ([System.Drawing.Color]::Firebrick)
        [void][System.Windows.Forms.MessageBox]::Show('Could not restart as administrator: ' + $_.Exception.Message, 'Herdr Remote Setup', 'OK', 'Error')
        return $false
    }
    return $true
}

$runBtn.Add_Click({
    $role = Get-SelectedRole
    $osSel = Get-OsSelection
    $codeValue = $codeBox.Text.Trim()

    try {
        $action = Resolve-Action -RoleName $role -OsName $osSel -CodeValue $codeValue
    } catch {
        Add-Line $_.Exception.Message ([System.Drawing.Color]::Firebrick)
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Herdr Remote Setup', 'OK', 'Error')
        return
    }

    if ($action.Kind -ne 'run') {
        Show-Guidance -Action $action
        return
    }

    if ($role -eq 'Client' -and $osSel -eq 'Windows' -and -not $codeValue) {
        Add-Line 'Enter the connection code from the host first.' ([System.Drawing.Color]::Firebrick)
        [void][System.Windows.Forms.MessageBox]::Show('Enter the connection code from the host first.', 'Herdr Remote Setup', 'OK', 'Warning')
        return
    }

    # Tailscale installation needs administrator rights on the Windows client.
    if ($role -eq 'Client' -and $osSel -eq 'Windows' -and -not (Test-Admin)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Administrator rights are needed to install Tailscale.`r`n`r`nRestart as administrator?",
            "Herdr Remote Setup v$Version", 'YesNo', 'Question')
        if ($answer -eq 'Yes') {
            if (Start-Elevated -CodeValue $codeValue) {
                $form.Close()
                exit 0
            }
            return
        }
    }

    Set-Busy -Busy $true
    Add-Line ''
    Add-Line 'Running...' ([System.Drawing.Color]::RoyalBlue)
    Add-Line ('  ' + $action.Display) ([System.Drawing.Color]::DimGray)

    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $action.Path + '"'
    if ($codeValue) { $argLine = $argLine + ' -ConnectionCode "' + $codeValue + '"' }

    $script:runner = New-Object HerdrRunner
    if (-not $script:runner.Start($action.LaunchFile, $argLine)) {
        Add-Line ('Could not start the setup: ' + $script:runner.StartError) ([System.Drawing.Color]::Firebrick)
        [void][System.Windows.Forms.MessageBox]::Show('Could not start the setup: ' + $script:runner.StartError, 'Herdr Remote Setup', 'OK', 'Error')
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

    # WaitForExit also flushes the asynchronous stream reads.
    $exitCode = $script:runner.Finish()
    $line = $script:runner.DrainOne()
    while ($null -ne $line) {
        Add-Line $line
        $line = $script:runner.DrainOne()
    }

    $script:timer.Stop()
    $script:runner = $null
    Set-Busy -Busy $false

    if ($exitCode -eq 0) {
        Add-Line ''
        Add-Line 'Finished with exit code 0.' ([System.Drawing.Color]::ForestGreen)
    } else {
        Add-Line ''
        Add-Line ("Failed with exit code $exitCode.") ([System.Drawing.Color]::Firebrick)
        [void][System.Windows.Forms.MessageBox]::Show(
            "Setup failed with exit code $exitCode.`r`n`r`nSee the output window for details.",
            'Herdr Remote Setup', 'OK', 'Error')
    }
})

$copyBtn.Add_Click({
    # A connection code is a long bare base64 line. Pick the last such line and
    # never invent one.
    $candidate = $null
    $lines = $outputBox.Text -split "`r?`n"
    foreach ($raw in $lines) {
        $t = $raw.Trim()
        if ($t.Length -ge 40 -and $t -match '^[A-Za-z0-9+/]+={0,2}$') { $candidate = $t }
    }
    if ($null -eq $candidate) {
        Add-Line 'No connection code was produced in this run.' ([System.Drawing.Color]::DarkOrange)
        [void][System.Windows.Forms.MessageBox]::Show('No connection code was produced in this run.', 'Herdr Remote Setup', 'OK', 'Information')
        return
    }
    try {
        [System.Windows.Forms.Clipboard]::SetText($candidate)
        Add-Line 'Connection code copied to the clipboard (value not shown).' ([System.Drawing.Color]::ForestGreen)
    } catch {
        Add-Line ('Could not copy: ' + $_.Exception.Message) ([System.Drawing.Color]::Firebrick)
    }
})

$logBtn.Add_Click({
    $logDir = Join-Path $env:LOCALAPPDATA 'HerdrSetup\logs'
    if (Test-Path -LiteralPath $logDir) {
        Start-Process explorer.exe $logDir
    } else {
        [void][System.Windows.Forms.MessageBox]::Show("No log folder yet:`r`n$logDir", 'Herdr Remote Setup', 'OK', 'Information')
    }
})

$form.Add_FormClosing({
    param($formSender, $e)
    if ($null -ne $script:runner -and -not $script:runner.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'A setup is still running. Close anyway?', 'Herdr Remote Setup', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $e.Cancel = $true }
    }
})

$rbHost.Add_CheckedChanged({ Update-Selection })
$rbClient.Add_CheckedChanged({ Update-Selection })
$osBox.Add_SelectedIndexChanged({ Update-Selection })

# Pre-fill from the command line, which is how the elevated restart comes back.
if ($Role -eq 'Host') { $rbHost.Checked = $true } else { $rbClient.Checked = $true }
switch ($Os) {
    'Linux' { $osBox.SelectedIndex = 0 }
    'macOS' { $osBox.SelectedIndex = 1 }
    'Windows' { $osBox.SelectedIndex = 2 }
    default { $osBox.SelectedIndex = 2 }
}
if ($Code) { $codeBox.Text = $Code }
Update-Selection

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
exit 0
