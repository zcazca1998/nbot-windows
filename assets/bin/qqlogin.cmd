@echo off
rem Bring up the bot task for an interactive QQ login. Backend-aware:
rem   napcat   - the NapCat task starts QQ itself (hook already injected).
rem   snowluma - the SnowLuma launcher starts QQ first, then SnowLuma,
rem              which is what lets QQ show its interactive login window.
setlocal EnableExtensions

set "BOT_BACKEND="
set "CONF=%ProgramData%\nbot\nbot.conf"
if exist "%CONF%" for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%CONF%") do set "%%a=%%b"

set "BOT_TASK=\NBot\NapCat"
if /i "%BOT_BACKEND%"=="snowluma" set "BOT_TASK=\NBot\SnowLuma"

schtasks /run /tn "%BOT_TASK%"
echo Please scan the QR code or confirm login in the QQ window.
echo If no window appears, make sure you are logged into the Windows desktop.
