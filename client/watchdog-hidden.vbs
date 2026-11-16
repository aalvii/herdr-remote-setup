' Run the Herdr watchdog with no console window.
' wscript.exe has no console. Window style 0 keeps the child PowerShell hidden,
' so the scheduled task no longer flashes a terminal window every 2 minutes.
'
' Usage (scheduled task action):
'   wscript.exe "C:\path\to\watchdog-hidden.vbs"

Option Explicit

Dim fso, shell, here, ps, cmd, q
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

q = Chr(34)
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

cmd = q & ps & q _
    & " -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass" _
    & " -File " & q & here & "\watchdog.ps1" & q & " -Quiet"

' 0 = hidden window, False = do not wait for the child process.
shell.Run cmd, 0, False
