' panel.vbs - open the nbot control panel without any console flash.
' A .bat bootstrap always blinks a cmd window; wscript has no console, so this
' script elevates straight to a hidden PowerShell running gui.ps1.
' Pure ASCII on purpose (see PITFALLS.md).
Option Explicit

Dim fso, shell, app, base, gui, psExe, psArgs
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

base = fso.GetParentFolderName(WScript.ScriptFullName)
gui = base & "\gui.ps1"
If Not fso.FileExists(gui) Then
    MsgBox "gui.ps1 not found next to panel.vbs:" & vbCrLf & gui, 16, "nbot"
    WScript.Quit 1
End If

psExe = shell.ExpandEnvironmentStrings("%SystemRoot%") & _
    "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(psExe) Then
    MsgBox "Windows PowerShell was not found:" & vbCrLf & psExe, 16, "nbot"
    WScript.Quit 1
End If

psArgs = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & gui & """"

' "runas" asks for administrator rights (needed for the scheduled tasks);
' the final 0 keeps the PowerShell host window hidden.
Set app = CreateObject("Shell.Application")
app.ShellExecute psExe, psArgs, base, "runas", 0
