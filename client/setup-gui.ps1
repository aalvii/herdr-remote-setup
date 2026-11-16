# Herdr Remote Setup - Client GUI (Windows)
# Product version: see ..\VERSION

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptRoot = $PSScriptRoot
$PackageRoot = Split-Path $ScriptRoot -Parent
$Version = "0.0.0"
$versionFile = Join-Path $PackageRoot "VERSION"
if (Test-Path $versionFile) { $Version = (Get-Content $versionFile -Raw).Trim() }

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Re-launch elevated once, because installing Tailscale needs administrator rights.
if (-not (Test-Admin)) {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Administrator rights are needed to install Tailscale.`n`nRestart this setup with elevated rights?",
        "Herdr Remote Setup v$Version", "YesNo", "Question")
    if ($answer -eq "Yes") {
        try {
            Start-Process -FilePath "powershell.exe" `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath) `
                -Verb RunAs | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Elevation cancelled: $_", "Notice", "OK", "Warning") | Out-Null
        }
        exit 0
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Herdr Remote Setup v$Version"
$form.Size = New-Object System.Drawing.Size(640, 470)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$title = New-Object System.Windows.Forms.Label
$title.Location = New-Object System.Drawing.Point(20, 15)
$title.Size = New-Object System.Drawing.Size(590, 28)
$title.Text = "Herdr Remote Setup - Client (v$Version)"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($title)

$desc = New-Object System.Windows.Forms.Label
$desc.Location = New-Object System.Drawing.Point(20, 48)
$desc.Size = New-Object System.Drawing.Size(590, 36)
$desc.Text = "Paste the connection code from the remote machine. The setup installs Tailscale, herdr, and the SSH key, then registers the machine."
$form.Controls.Add($desc)

$codeBox = New-Object System.Windows.Forms.TextBox
$codeBox.Location = New-Object System.Drawing.Point(20, 88)
$codeBox.Size = New-Object System.Drawing.Size(590, 90)
$codeBox.Multiline = $true
$codeBox.ScrollBars = "Vertical"
$codeBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($codeBox)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(20, 186)
$status.Size = New-Object System.Drawing.Size(590, 122)
$status.Text = "Ready."
$status.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($status)

$watchdogBox = New-Object System.Windows.Forms.CheckBox
$watchdogBox.Location = New-Object System.Drawing.Point(20, 312)
$watchdogBox.Size = New-Object System.Drawing.Size(420, 24)
$watchdogBox.Text = "Install the connection watchdog (recommended)"
$watchdogBox.Checked = $true
$form.Controls.Add($watchdogBox)

$startBtn = New-Object System.Windows.Forms.Button
$startBtn.Location = New-Object System.Drawing.Point(20, 348)
$startBtn.Size = New-Object System.Drawing.Size(140, 32)
$startBtn.Text = "Start setup"
$startBtn.Enabled = $false
$form.Controls.Add($startBtn)

$logBtn = New-Object System.Windows.Forms.Button
$logBtn.Location = New-Object System.Drawing.Point(170, 348)
$logBtn.Size = New-Object System.Drawing.Size(140, 32)
$logBtn.Text = "Open log folder"
$logBtn.Enabled = $false
$form.Controls.Add($logBtn)

$closeBtn = New-Object System.Windows.Forms.Button
$closeBtn.Location = New-Object System.Drawing.Point(470, 348)
$closeBtn.Size = New-Object System.Drawing.Size(140, 32)
$closeBtn.Text = "Close"
$closeBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($closeBtn)

$codeBox.Add_TextChanged({
    $startBtn.Enabled = -not [string]::IsNullOrWhiteSpace($codeBox.Text)
})

$logFolder = Join-Path $env:LOCALAPPDATA "HerdrSetup\logs"

$logBtn.Add_Click({
    if (Test-Path $logFolder) { Start-Process explorer.exe $logFolder }
})

$startBtn.Add_Click({
    $code = $codeBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($code)) { return }

    $startBtn.Enabled = $false
    $closeBtn.Enabled = $false
    $codeBox.Enabled = $false
    $status.ForeColor = [System.Drawing.Color]::RoyalBlue
    $status.Text = "Running setup...`nThis can take several minutes. Keep this window open."
    $form.Refresh()

    try {
        $setup = Join-Path $PSScriptRoot "setup.ps1"
        if (-not (Test-Path $setup)) { throw "setup.ps1 not found: $setup" }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$setup`" -ConnectionCode `"$code`""
        if (-not $watchdogBox.Checked) { $psi.Arguments += " -NoWatchdog" }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode

        $tail = (($stdout + "`n" + $stderr) -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 12) -join "`n"

        if ($exitCode -eq 0) {
            $status.ForeColor = [System.Drawing.Color]::ForestGreen
            $status.Text = "Setup complete.`n`n$tail"
            [System.Windows.Forms.MessageBox]::Show(
                "Setup completed.`n`nYou can now run: herdr --machine <name>`n`nLog folder: $logFolder",
                "Success", "OK", "Information") | Out-Null
        } else {
            $status.ForeColor = [System.Drawing.Color]::Firebrick
            $status.Text = "Setup failed (exit $exitCode).`n`n$tail"
            [System.Windows.Forms.MessageBox]::Show(
                "Setup failed with exit code $exitCode.`n`n$tail`n`nLog folder: $logFolder",
                "Failed", "OK", "Error") | Out-Null
        }

        $logBtn.Enabled = $true
    } catch {
        $status.ForeColor = [System.Drawing.Color]::Firebrick
        $status.Text = "Error: $_"
        [System.Windows.Forms.MessageBox]::Show("Error: $_", "Error", "OK", "Error") | Out-Null
    }

    $startBtn.Enabled = $true
    $closeBtn.Enabled = $true
    $codeBox.Enabled = $true
})

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
exit 0
