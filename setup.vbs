' setup.vbs - open the graphical setup wizard without any console flash.
' Same trick as panel.vbs: wscript has no console window, so it elevates
' directly into a hidden PowerShell that shows the WinForms wizard.
' Pure ASCII on purpose (see PITFALLS.md).
Option Explicit

Dim fso, shell, app, base, wizard, psExe, psArgs
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

base = fso.GetParentFolderName(WScript.ScriptFullName)
wizard = base & "\wizard.ps1"
If Not fso.FileExists(wizard) Then
    MsgBox "wizard.ps1 not found next to setup.vbs:" & vbCrLf & wizard, 16, "nbot"
    WScript.Quit 1
End If

psExe = shell.ExpandEnvironmentStrings("%SystemRoot%") & _
    "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(psExe) Then
    MsgBox "Windows PowerShell was not found:" & vbCrLf & psExe, 16, "nbot"
    WScript.Quit 1
End If

psArgs = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & wizard & """"

Set app = CreateObject("Shell.Application")
app.ShellExecute psExe, psArgs, base, "runas", 0
