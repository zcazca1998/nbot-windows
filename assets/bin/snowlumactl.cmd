@echo off
rem SnowLuma control helper (Task Scheduler based).
setlocal EnableExtensions

set "CONF=%ProgramData%\nbot\nbot.conf"
if exist "%CONF%" for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%CONF%") do set "%%a=%%b"

if "%~1"=="" goto usage
if /i "%~1"=="status" goto status
if /i "%~1"=="logs" goto logs
if /i "%~1"=="start" goto start
if /i "%~1"=="stop" goto stop
if /i "%~1"=="restart" goto restart
if /i "%~1"=="qq-status" goto qqstatus
goto usage

:status
"%ProgramData%\nbot\installer\install.bat" status
exit /b %errorlevel%

:logs
if not defined SL_ROOT (
  echo SL_ROOT is not configured in "%CONF%".
  exit /b 3
)
if not exist "%SL_ROOT%\logs\snowluma.log" (
  echo No log file found at "%SL_ROOT%\logs\snowluma.log".
  exit /b 1
)
powershell -NoProfile -Command "Get-Content -LiteralPath '%SL_ROOT%\logs\snowluma.log' -Tail 200"
exit /b %errorlevel%

:start
schtasks /run /tn "\NBot\SnowLuma"
exit /b %errorlevel%

:stop
schtasks /end /tn "\NBot\SnowLuma"
exit /b %errorlevel%

:restart
schtasks /end /tn "\NBot\SnowLuma"
schtasks /run /tn "\NBot\SnowLuma"
exit /b %errorlevel%

:qqstatus
tasklist /FI "IMAGENAME eq QQ.exe"
exit /b %errorlevel%

:usage
echo Usage: snowlumactl {status^|start^|stop^|restart^|logs^|qq-status}
echo   status     Show nbot status
echo   start      Start the SnowLuma scheduled task
echo   stop       Stop the SnowLuma scheduled task
echo   restart    Restart the SnowLuma scheduled task
echo   logs       Show the last 200 lines of snowluma.log
echo   qq-status  Show whether QQ.exe is running
exit /b 2
