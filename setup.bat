@echo off
rem =========================================================================
rem nbot graphical setup wizard bootstrap (Windows 7 SP1 - Windows 11).
rem Double-click this file: it asks for administrator rights (UAC) and then
rem opens the WinForms install wizard (wizard.ps1) in -STA mode.
rem Any extra arguments are forwarded to wizard.ps1, which ignores them.
rem This file must stay pure ASCII.
rem =========================================================================
setlocal

rem ---- Check for administrator rights ----
net session >nul 2>&1
if %errorlevel% equ 0 goto :admin

echo [INFO] Administrator rights are required. Requesting elevation...
set "ELEV_VBS=%TEMP%\nbot-setup-elevate-%RANDOM%.vbs"
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
rem Launch the wizard detached so this console does not stay in the way.
start "" "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0wizard.ps1" %*
exit /b 0
