@echo off
rem =========================================================================
rem nbot installer bootstrap for Windows (Windows 7 SP1 - Windows 11).
rem Elevates itself to administrator if needed, then launches
rem install-core.ps1 with the built-in Windows PowerShell.
rem This file must stay pure ASCII.
rem =========================================================================
setlocal

rem ---- Check for administrator rights ----
net session >nul 2>&1
if %errorlevel% equ 0 goto :admin

echo [INFO] Administrator rights are required. Requesting elevation...
set "ELEV_VBS=%TEMP%\nbot-elevate-%RANDOM%.vbs"
> "%ELEV_VBS%"  echo Set objShell = CreateObject("Shell.Application")
>> "%ELEV_VBS%" echo objShell.ShellExecute "%~f0", "%*", "", "runas", 1
cscript //nologo "%ELEV_VBS%"
if %errorlevel% neq 0 echo [ERROR] Elevation was cancelled or failed.
del "%ELEV_VBS%" >nul 2>&1
exit /b

:admin
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%PS_EXE%" goto :run
echo [ERROR] Windows PowerShell was not found at:
echo         %PS_EXE%
echo         Please install Windows PowerShell 2.0 or later and retry.
pause
exit /b 1

:run
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-core.ps1" %*
set "EXIT_CODE=%errorlevel%"

rem Pause only when double-clicked (no arguments), so the window stays open.
if "%~1"=="" pause
exit /b %EXIT_CODE%
