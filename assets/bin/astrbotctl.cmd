@echo off
rem AstrBot control helper (Task Scheduler based).
setlocal EnableExtensions

set "CONF=%ProgramData%\nbot\nbot.conf"
if exist "%CONF%" for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%CONF%") do set "%%a=%%b"

if "%~1"=="" goto usage
if /i "%~1"=="status" goto status
if /i "%~1"=="logs" goto logs
if /i "%~1"=="start" goto start
if /i "%~1"=="stop" goto stop
if /i "%~1"=="restart" goto restart
goto usage

:status
"%ProgramData%\nbot\installer\install.bat" status
exit /b %errorlevel%

:logs
if not defined ASTRBOT_ROOT (
  echo ASTRBOT_ROOT is not configured in "%CONF%".
  exit /b 3
)
if not exist "%ASTRBOT_ROOT%\logs\astrbot.log" (
  echo No log file found at "%ASTRBOT_ROOT%\logs\astrbot.log".
  exit /b 1
)
powershell -NoProfile -Command "Get-Content -LiteralPath '%ASTRBOT_ROOT%\logs\astrbot.log' -Tail 200"
exit /b %errorlevel%

:start
schtasks /run /tn "\NBot\AstrBot"
exit /b %errorlevel%

:stop
schtasks /end /tn "\NBot\AstrBot"
exit /b %errorlevel%

:restart
schtasks /end /tn "\NBot\AstrBot"
schtasks /run /tn "\NBot\AstrBot"
exit /b %errorlevel%

:usage
echo Usage: astrbotctl {status^|start^|stop^|restart^|logs}
echo   status   Show nbot status
echo   start    Start the AstrBot scheduled task
echo   stop     Stop the AstrBot scheduled task
echo   restart  Restart the AstrBot scheduled task
echo   logs     Show the last 200 lines of astrbot.log
exit /b 2
