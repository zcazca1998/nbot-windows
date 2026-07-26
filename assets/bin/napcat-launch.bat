@echo off
rem NapCat launch script (run by Task Scheduler task \NBot\NapCat).
rem Boots the official NapCat.Shell launcher, which starts QQ with the
rem NapCat hook injected. Runs in the logged-on user's session with the
rem highest privileges (the NapCat launcher requires administrator mode).
setlocal EnableExtensions

set "CONF=%ProgramData%\nbot\nbot.conf"
if not exist "%CONF%" exit /b 3
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%CONF%") do set "%%a=%%b"

if not defined NAPCAT_ROOT exit /b 3
if not defined NAPCAT_PAYLOAD_ROOT exit /b 3
if not defined NAPCAT_LAUNCH set "NAPCAT_LAUNCH=launcher-win10.bat"

if not exist "%NAPCAT_ROOT%\logs" md "%NAPCAT_ROOT%\logs" 2>nul
if not exist "%NAPCAT_ROOT%\config" md "%NAPCAT_ROOT%\config" 2>nul

set "LOGFILE=%NAPCAT_ROOT%\logs\napcat.log"
rem Rotate the log when it grows beyond 10 MB.
if exist "%LOGFILE%" for %%f in ("%LOGFILE%") do if %%~zf GTR 10485760 move /y "%LOGFILE%" "%LOGFILE%.old" >nul 2>&1

set "CURRENT=%NAPCAT_PAYLOAD_ROOT%\current"
set "LAUNCHER=%CURRENT%\%NAPCAT_LAUNCH%"
if not exist "%LAUNCHER%" (
  >> "%LOGFILE%" echo [napcat-launch] ERROR: launcher not found: "%LAUNCHER%"
  exit /b 3
)

rem Config lives in two places and must be synced BOTH ways:
rem   NAPCAT_ROOT\config      persistent master copy, survives updates
rem   <payload>\current\config  what NapCat actually reads and WRITES
rem The payload directory is swapped wholesale on every update, so anything
rem NapCat wrote there (webui.json, onebot11_*.json, napcat_<uin>.json,
rem passkey.json ...) is lost unless it is harvested back first.
if not exist "%CURRENT%\config" md "%CURRENT%\config" 2>nul

rem 1) Harvest: pull anything newer from the payload back into the master copy,
rem    so changes made through NapCat's own WebUI are not thrown away.
xcopy "%CURRENT%\config\*" "%NAPCAT_ROOT%\config\" /D /Y /I /Q >nul 2>&1

rem 2) Push: master copy wins for files the installer manages, then NapCat
rem    starts from a complete config set.
xcopy "%NAPCAT_ROOT%\config\*" "%CURRENT%\config\" /D /Y /I /Q >nul 2>&1

rem Pass the QQ number for quick login when configured (falls back to the
rem QR code / saved-session login window when absent or not yet logged in).
set "LOGIN_ARG="
if defined QQ_UIN set "LOGIN_ARG=%QQ_UIN%"

cd /d "%CURRENT%"
call "%NAPCAT_LAUNCH%" %LOGIN_ARG% >> "%LOGFILE%" 2>&1

rem NapCat exited: harvest once more so the last state (new tokens, login
rem records) lands in the master copy before any future update swaps it out.
xcopy "%CURRENT%\config\*" "%NAPCAT_ROOT%\config\" /D /Y /I /Q >nul 2>&1
