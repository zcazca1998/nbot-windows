@echo off
rem =========================================================================
rem nbot GUI panel bootstrap (Windows 7 SP1 - Windows 11).
rem Elevates to administrator, then opens the WinForms panel (gui.ps1).
rem This file must stay pure ASCII.
rem =========================================================================
setlocal

rem ---- Check for administrator rights ----
net session >nul 2>&1
if %errorlevel% equ 0 goto :admin

set "ELEV_VBS=%TEMP%\nbot-panel-elevate-%RANDOM%.vbs"
> "%ELEV_VBS%"  echo Set objShell = CreateObject("Shell.Application")
>> "%ELEV_VBS%" echo objShell.ShellExecute "%~f0", "", "", "runas", 1
cscript //nologo "%ELEV_VBS%"
del "%ELEV_VBS%" >nul 2>&1
exit /b

:admin
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" (
  echo [ERROR] Windows PowerShell was not found.
  pause
  exit /b 1
)
start "" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0gui.ps1"
exit /b 0
