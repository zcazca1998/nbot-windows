@echo off
rem SnowLuma launch script (run by Task Scheduler task \NBot\SnowLuma).
rem
rem Difference from the NapCat edition: NapCat ships a launcher that starts QQ
rem itself with the hook already injected. SnowLuma does NOT start QQ -- it is a
rem plain Node process that watches for a running QQ.exe and injects its hook
rem into it. So this script owns both halves:
rem   1. start QQ.exe    (unless it is already running)
rem   2. start SnowLuma  (node index.mjs; see the two logging paths set up
rem      below -- SNOWLUMA_LOG_DIR and the cmd-redirected snowluma.log)
rem SnowLuma's watcher then discovers QQ and, with SNOWLUMA_HOOK_AUTOLOAD=1,
rem injects without any manual step in the WebUI.
rem
rem Runs in the logged-on user's session with the highest privileges: QQ is a
rem GUI program and hook injection needs administrator rights.
rem This file must stay pure ASCII.
setlocal EnableExtensions

rem The three checks below (missing config file, missing SL_ROOT, missing
rem SL_PAYLOAD_ROOT) all happen before LOGFILE can be computed further down
rem (it is built from %SL_ROOT%). Without a fallback path that does not
rem depend on the config at all, a broken config (e.g. a hand-edited line
rem with a space before "=", which the watchdog's Read-Conf can also choke
rem on) makes SnowLuma silently never start: the panel shows nothing wrong,
rem the scheduled task reports exit code 0 to Task Scheduler, and not one
rem byte is written anywhere to explain why (verified). ERRLOG is anchored to
rem %ProgramData% (always defined by Windows itself) so it exists regardless
rem of what is or is not in the config.
set "ERRLOG=%ProgramData%\nbot\logs\snowluma-launch.err.log"
if not exist "%ProgramData%\nbot\logs" md "%ProgramData%\nbot\logs" 2>nul
if exist "%ERRLOG%" for %%f in ("%ERRLOG%") do if %%~zf GTR 10485760 move /y "%ERRLOG%" "%ERRLOG%.old" >nul 2>&1

set "CONF=%ProgramData%\nbot\nbot.conf"
if not exist "%CONF%" (
  >> "%ERRLOG%" echo %date% %time% [snowluma-launch] ERROR: config file not found: "%CONF%"
  exit /b 3
)
rem Every KEY=value in the config becomes an environment variable. The keys
rem named SNOWLUMA_* are deliberately identical to SnowLuma's own environment
rem variables (webui port, hook auto-load, agreement acceptance), so they take
rem effect just by being exported here -- no config file rewriting needed.
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%CONF%") do set "%%a=%%b"

if not defined SL_ROOT (
  >> "%ERRLOG%" echo %date% %time% [snowluma-launch] ERROR: SL_ROOT is not defined in "%CONF%"
  exit /b 3
)
if not defined SL_PAYLOAD_ROOT (
  >> "%ERRLOG%" echo %date% %time% [snowluma-launch] ERROR: SL_PAYLOAD_ROOT is not defined in "%CONF%"
  exit /b 3
)
if not defined SL_NODE set "SL_NODE=node.exe"

rem SNOWLUMA_LOG_DIR tells SnowLuma itself where to write logs\snowluma-*.log
rem (its own writer: proper UTF-8, INFO+WARN+ERROR, daily rotation/retention --
rem far better than the cmd redirect below, which mangles Chinese text because
rem cmd writes it in the console codepage while node emits UTF-8). Left unset,
rem SnowLuma resolves it relative to its working directory, i.e. INSIDE the
rem payload, so it would be discarded on every update. Default it into the
rem managed logs folder, but only if the conf loop above did not already
rem export a value: a value present there was placed by the operator (or a
rem future installer feature) and must win.
if not defined SNOWLUMA_LOG_DIR set "SNOWLUMA_LOG_DIR=%SL_ROOT%\logs"

if not exist "%SL_ROOT%\logs" md "%SL_ROOT%\logs" 2>nul
if not exist "%SL_ROOT%\config" md "%SL_ROOT%\config" 2>nul

rem This is the SECOND log, produced by redirecting this script's own stdout
rem and SnowLuma's stdout/stderr with cmd. Its Chinese text is mojibake (wrong
rem codepage) and it duplicates most of what SNOWLUMA_LOG_DIR above already
rem captures cleanly, but it is kept because it also catches things SnowLuma
rem cannot log about itself: node failing to launch at all, DLL load errors,
rem and this script's own QQ.exe bootstrap messages below.
set "LOGFILE=%SL_ROOT%\logs\snowluma.log"
rem Rotate the log when it grows beyond 10 MB.
if exist "%LOGFILE%" for %%f in ("%LOGFILE%") do if %%~zf GTR 10485760 move /y "%LOGFILE%" "%LOGFILE%.old" >nul 2>&1

set "CURRENT=%SL_PAYLOAD_ROOT%\current"
if not exist "%CURRENT%\index.mjs" (
  >> "%LOGFILE%" echo [snowluma-launch] ERROR: payload not found: "%CURRENT%\index.mjs"
  exit /b 3
)

rem Config lives in two places and must be synced BOTH ways:
rem   SL_ROOT\config            persistent master copy, survives updates
rem   <payload>\current\config  what SnowLuma actually reads and WRITES
rem SnowLuma resolves "config" relative to its working directory, and the
rem payload directory is swapped wholesale on every update, so anything it
rem wrote there (webui.json, onebot*.json, runtime.json, consent.json ...) is
rem lost unless it is harvested back first.
if not exist "%CURRENT%\config" md "%CURRENT%\config" 2>nul

rem 1) Harvest: pull anything newer from the payload back into the master copy,
rem    so changes made through SnowLuma's own WebUI are not thrown away.
xcopy "%CURRENT%\config\*" "%SL_ROOT%\config\" /D /Y /I /Q >nul 2>&1

rem 2) Push: master copy wins for files the installer manages, then SnowLuma
rem    starts from a complete config set.
xcopy "%SL_ROOT%\config\*" "%CURRENT%\config\" /D /Y /I /Q >nul 2>&1

rem Last-resort guard against SnowLuma's built-in OneBot defaults. With no
rem onebot.json at all it starts http-default on 0.0.0.0:3000 and ws-default on
rem 0.0.0.0:3001 -- bound to every interface, with a token nobody has seen.
rem The installer writes a no-adapter config during setup, but that only covers
rem the install path: "repair" after the SnowLuma data dir was deleted, or a
rem hand-run of this script, would both reach SnowLuma with an empty config dir.
rem Doing it here makes "cannot expose those ports" structural rather than a
rem convention every future code path has to remember. Any file suppresses the
rem defaults (freshInstall is false as soon as one exists), so an empty
rem four-array config is enough.
if not exist "%CURRENT%\config\onebot.json" (
  >"%CURRENT%\config\onebot.json" echo {"networks":{"httpServers":[],"httpClients":[],"wsServers":[],"wsClients":[]}}
  >> "%LOGFILE%" echo [snowluma-launch] no onebot.json found; wrote a no-adapter config so the 0.0.0.0 defaults stay off
)

rem Pick the Node runtime: the full release bundles node.exe next to index.mjs;
rem the lite release relies on a system-wide Node 22+.
set "NODE_EXE=%CURRENT%\%SL_NODE%"
if not exist "%NODE_EXE%" set "NODE_EXE=node.exe"

rem Start QQ first when it is not already running, so SnowLuma finds it on its
rem very first watcher tick instead of waiting for a later poll. QQ keeps its
rem own login session, so after a reboot this comes back logged in by itself.
tasklist /fi "imagename eq QQ.exe" /nh 2>nul | find /i "QQ.exe" >nul
if errorlevel 1 (
  if defined QQ_EXE (
    if exist "%QQ_EXE%" (
      >> "%LOGFILE%" echo [snowluma-launch] starting QQ: "%QQ_EXE%"
      start "" "%QQ_EXE%"
    ) else (
      >> "%LOGFILE%" echo [snowluma-launch] WARNING: QQ_EXE does not exist: "%QQ_EXE%"
    )
  ) else (
    >> "%LOGFILE%" echo [snowluma-launch] WARNING: QQ_EXE is not configured; run repair or start QQ manually
  )
) else (
  >> "%LOGFILE%" echo [snowluma-launch] QQ.exe is already running
)

rem cd into the payload first: SnowLuma resolves "config" (and "logs" when
rem SNOWLUMA_LOG_DIR is not set) relative to the working directory, not to
rem the script location.
cd /d "%CURRENT%"
>> "%LOGFILE%" echo [snowluma-launch] starting SnowLuma via "%NODE_EXE%"
rem Pass the script as an ABSOLUTE path (not ./index.mjs) on purpose: it puts
rem the payload path into the process command line, which is how the installer
rem and the watchdog identify "our" node.exe among any other Node programs on
rem the machine. With the lite release NODE_EXE is a bare system node.exe, so
rem the command line would otherwise carry no trace of this installation.
"%NODE_EXE%" "%CURRENT%\index.mjs" >> "%LOGFILE%" 2>&1

rem SnowLuma exited: harvest once more so the last state (credentials, consent,
rem OneBot changes) lands in the master copy before a future update swaps it out.
xcopy "%CURRENT%\config\*" "%SL_ROOT%\config\" /D /Y /I /Q >nul 2>&1
