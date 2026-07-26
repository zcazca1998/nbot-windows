' tray-autostart.vbs - start the nbot panel straight into the tray at logon.
' Registered under HKCU ...\CurrentVersion\Run as:
'     wscript.exe //B "<ProgramData>\nbot\bin\tray-autostart.vbs"
' The panel is launched hidden; NBOT_GUI_TRAY=1 tells gui.ps1 to stay in
' the tray instead of showing its window.
' Pure ASCII. Comments and messages are English on purpose.

Option Explicit

Dim shell, fso, programData, guiPath, psExe, cmd

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

programData = shell.ExpandEnvironmentStrings("%ProgramData%")
guiPath = programData & "\nbot\installer\gui.ps1"

' Nothing to do when the installer copy is missing (uninstalled or moved).
If Not fso.FileExists(guiPath) Then
    WScript.Quit 0
End If

psExe = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(psExe) Then
    psExe = "powershell.exe"
End If

' Set the flag on this process: WScript.Shell's PROCESS environment is inherited
' by whatever we launch, so no cmd.exe wrapper is needed. Going through cmd.exe
' would blink a console window at every logon.
shell.Environment("PROCESS").Item("NBOT_GUI_TRAY") = "1"

cmd = """" & psExe & """" _
    & " -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & guiPath & """"

' 0 = hidden window, False = do not wait for the panel to exit.
shell.Run cmd, 0, False
WScript.Quit 0
