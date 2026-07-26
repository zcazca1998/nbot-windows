' run-hidden.vbs - run the given program with its console window hidden.
' Used by the \NBot\NapCat scheduled task so the napcat-launch.bat
' console does not pop up on the user's desktop (the QQ GUI still shows).
' Pure ASCII. Usage: wscript.exe //B run-hidden.vbs <program> [args...]
If WScript.Arguments.Count < 1 Then WScript.Quit 1
Dim shell, cmd, i
Set shell = CreateObject("WScript.Shell")
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
    cmd = cmd & """" & WScript.Arguments(i) & """ "
Next
' 0 = hidden window, False = do not wait
shell.Run Trim(cmd), 0, False
WScript.Quit 0
