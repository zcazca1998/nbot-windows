@echo off
rem Bring up the NapCat stack (which starts QQ) for an interactive login.
schtasks /run /tn "\NBot\NapCat"
echo Please scan the QR code or confirm login in the QQ window.
echo If no window appears, make sure you are logged into the Windows desktop.
