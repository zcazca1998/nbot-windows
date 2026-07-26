@echo off
rem nbot command entry point: forwards to the installer.
rem "nbot help" prints the command list without opening the interactive menu.
if /i "%~1"=="help" goto :help
if "%~1"=="/?" goto :help
if /i "%~1"=="-h" goto :help
if /i "%~1"=="--help" goto :help
"%ProgramData%\nbot\installer\install.bat" %*
exit /b %errorlevel%

:help
echo Usage: nbot ^<command^> [args]
echo.
echo   menu                 open the interactive menu (default)
echo   install-all          one-click full install
echo   configure            edit the base configuration (incl. bot backend)
echo   install-astrbot      install/update AstrBot
echo   install-napcat       install/update NapCat + QQ (napcat backend)
echo   install-snowluma     install/update SnowLuma + QQ (snowluma backend)
echo   install-qq           install/update QQ only
echo   configure-onebot     wire OneBot between the bot and AstrBot
echo   reset-astrbot        reset the AstrBot dashboard password
echo   reset-napcat [tok]   reset the NapCat WebUI token
echo   reset-snowluma       reset the SnowLuma WebUI password
echo   restart-astrbot      restart only the AstrBot task
echo   restart-bot          restart the bot task (NapCat or SnowLuma)
echo   qqlogin              bring up the QQ login window
echo   status               show runtime status
echo   doctor               run environment diagnostics
echo   logs {astrbot^|napcat^|snowluma^|watchdog}
echo   start / stop         start or stop everything
echo   autostart-on / autostart-off
echo   repair               repair the installation
echo   panel                open the graphical panel
echo   uninstall            uninstall nbot
exit /b 0
