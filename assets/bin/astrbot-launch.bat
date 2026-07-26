@echo off
rem AstrBot launch script (run by Task Scheduler task \NBot\AstrBot).
setlocal EnableExtensions

set "CONF=%ProgramData%\nbot\nbot.conf"
if not exist "%CONF%" exit /b 3
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%CONF%") do set "%%a=%%b"

if not defined ASTRBOT_ROOT exit /b 3

set "PYTHONUNBUFFERED=1"
set "PYTHONIOENCODING=utf-8"

if not exist "%ASTRBOT_ROOT%\logs" md "%ASTRBOT_ROOT%\logs" 2>nul

set "LOGFILE=%ASTRBOT_ROOT%\logs\astrbot.log"
rem Rotate the log when it grows beyond 10 MB.
if exist "%LOGFILE%" for %%f in ("%LOGFILE%") do if %%~zf GTR 10485760 move /y "%LOGFILE%" "%LOGFILE%.old" >nul 2>&1

set "PYEXE=%ASTRBOT_ROOT%\.venv\Scripts\python.exe"
if not exist "%PYEXE%" (
  >> "%LOGFILE%" echo [astrbot-launch] ERROR: "%PYEXE%" not found; run the installer to repair the venv.
  exit /b 3
)

rem Prepare step (first-time init and dashboard port sync).
rem A failing prepare step must never block the launch.
"%PYEXE%" "%ProgramData%\nbot\bin\astrbot-prepare.py" >> "%LOGFILE%" 2>&1

cd /d "%ASTRBOT_ROOT%"
"%PYEXE%" "%ASTRBOT_ROOT%\app\main.py" >> "%LOGFILE%" 2>&1
