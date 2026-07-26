# nbot watchdog. Runs every minute as SYSTEM via the Task Scheduler
# task \NBot\Watchdog. Windows port of the Linux astrbot-healthcheck
# and bot-healthcheck scripts, merged into one file. Guards either the
# NapCat backend (Check-NapCat) or the SnowLuma backend (Check-SnowLuma
# + Check-QQ) depending on the BOT_BACKEND key in nbot.conf.
#
# Must stay PowerShell 2.0 compatible: no $PSScriptRoot, Get-Content -Raw,
# ConvertFrom-Json, Invoke-WebRequest, Get-CimInstance, [pscustomobject]
# or [type]::new(). Uses Get-WmiObject, [IO.File], [Net.WebRequest] and
# schtasks.exe instead. Fast, idempotent and silent; it never throws.

$ErrorActionPreference = 'Stop'

$BaseDir  = Join-Path $env:ProgramData 'nbot'
$StateDir = Join-Path $BaseDir 'state'
$LogDir   = Join-Path $BaseDir 'logs'
$LogFile  = Join-Path $LogDir 'watchdog.log'
$ConfFile = Join-Path $BaseDir 'nbot.conf'
# lib\common.ps1's Get-ConfigPath honors $env:NBOT_CONFIG as an override;
# a watchdog that always reads the default path would silently read an empty
# config on any machine using that override (verified: this reads back empty,
# masking real config as if every key were unset).
if ($env:NBOT_CONFIG) { $ConfFile = $env:NBOT_CONFIG }

function Log($msg) {
    try {
        if (-not (Test-Path $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        if (Test-Path $LogFile) {
            $item = Get-Item $LogFile
            if ($item.Length -gt 2097152) {
                Move-Item -Path $LogFile -Destination ($LogFile + '.old') -Force
            }
        }
        $line = ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
        [IO.File]::AppendAllText($LogFile, $line + "`r`n")
    } catch { }
}

function Read-Conf {
    $conf = @{}
    if (Test-Path $ConfFile) {
        $lines = [IO.File]::ReadAllLines($ConfFile)
        foreach ($line in $lines) {
            # Tolerate whitespace around the key/value, matching lib\common.ps1's
            # Load-Config (which Trims both sides). Without this, a hand-edited
            # line like "SL_PAYLOAD_ROOT =C:\..." (space before '=', common when
            # editing by hand) is silently dropped whole here while the panel
            # reads it fine -- the panel looks healthy while the watchdog reads
            # an empty config (verified).
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
                $conf[$matches[1]] = $matches[2]
            }
        }
    }
    return $conf
}

function Test-HttpOk($url, $timeoutMs) {
    $resp = $null
    try {
        $req = [Net.WebRequest]::Create($url)
        $req.Timeout = $timeoutMs
        $req.Method = 'GET'
        $resp = $req.GetResponse()
        return $true
    } catch {
        return $false
    } finally {
        if ($resp -ne $null) { $resp.Close() }
    }
}

function Test-TcpOk($tcpHost, $port, $timeoutMs) {
    # The bot backend's WebUI may answer 404 on the root path, so its liveness
    # probe is a bare TCP connect instead of an HTTP GET.
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($tcpHost, [int]$port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($timeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-Counter($name) {
    $file = Join-Path $StateDir $name
    if (Test-Path $file) {
        $text = ([IO.File]::ReadAllText($file)).Trim()
        $value = 0
        if ([int]::TryParse($text, [ref]$value)) { return $value }
    }
    return 0
}

function Set-Counter($name, $value) {
    [IO.File]::WriteAllText((Join-Path $StateDir $name), ([string]$value))
}

function Clear-Counter($name) {
    # No Test-Path guard: modules\tasks.ps1's Start-Stack (fired by "Start
    # all" in the panel) can Remove-FileSafe this same marker between our
    # Test-Path and Remove-Item (verified TOCTOU race), which used to throw
    # ItemNotFoundException under $ErrorActionPreference='Stop' and abort the
    # rest of this tick's checks. -Force -ErrorAction SilentlyContinue makes
    # "already gone" a non-event either way.
    $file = Join-Path $StateDir $name
    Remove-Item -Path $file -Force -ErrorAction SilentlyContinue
}

function Test-Marker($name) {
    return (Test-Path (Join-Path $StateDir $name))
}

function Set-Marker($name) {
    [IO.File]::WriteAllText((Join-Path $StateDir $name), (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
}

function Get-NowSec {
    return [long]([DateTime]::UtcNow.Ticks / 10000000)
}

# Read "pid time" from a grace file. Returns a two-element array.
function Read-Grace($name) {
    $gracePid = ''
    $graceTime = [long]0
    $file = Join-Path $StateDir $name
    if (Test-Path $file) {
        $parts = ([IO.File]::ReadAllText($file)).Trim() -split '\s+'
        if ($parts.Count -ge 2) {
            $gracePid = $parts[0]
            $parsed = [long]0
            if ([long]::TryParse($parts[1], [ref]$parsed)) { $graceTime = $parsed }
        }
    }
    return @($gracePid, $graceTime)
}

function Write-Grace($name, $processId, $timeSec) {
    [IO.File]::WriteAllText((Join-Path $StateDir $name), ('{0} {1}' -f $processId, $timeSec))
}

# Find processes whose Name matches $namePattern (wildcard) and whose
# CommandLine contains every substring in $substrings (case-insensitive).
function Get-ProcByCmdline($namePattern, $substrings) {
    $result = @()
    $procs = Get-WmiObject -Class Win32_Process -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if ($p.Name -notlike $namePattern) { continue }
        $cl = $p.CommandLine
        if ($cl -eq $null) { continue }
        # Normalize slash direction before comparing: WMI CommandLine echoes
        # back exactly whatever the launcher put on the command line (case and
        # separators untouched), and a needle built from a config value that
        # happens to use forward slashes would otherwise never match a
        # backslash path (measured on a real box: 0% match rate). Only the
        # separator is normalized; substring containment (not a fixed number
        # of spaces) is deliberately kept as the match rule because the exe
        # and script can be separated by one or two spaces depending on how
        # the launcher's redirection was written.
        $clLower = $cl.Replace('/', '\').ToLower()
        $ok = $true
        foreach ($s in $substrings) {
            $needle = ([string]$s).Replace('/', '\').ToLower()
            if (-not $clLower.Contains($needle)) { $ok = $false; break }
        }
        if ($ok) { $result += $p }
    }
    # Return the bare array: callers wrap with @(...), and returning ",$result"
    # here would double-wrap it (a 1-element jagged array whose [0] is the real
    # array), breaking both the emptiness check and the PID selection.
    return $result
}

# Native commands are wrapped in cmd.exe /c so that stderr never reaches
# the PowerShell error stream (avoids NativeCommandError under EAP Stop).
function Invoke-Task($taskName) {
    & cmd.exe /c ('schtasks.exe /run /tn "' + $taskName + '" >nul 2>&1')
    return $LASTEXITCODE
}

# /T (kill the whole tree) is required, not cosmetic: node forks a child
# process, and killing only the parent PID leaves that child running as an
# orphan holding the WebUI/OneBot port open and no longer reachable via its
# PPID (which now points at a dead process, so it cannot be found later
# either). /F (force) is used without a prior graceful attempt on purpose --
# a plain (non-forced) /T stop was verified to also release the port cleanly,
# but the watchdog's one hard requirement is to be fast, idempotent and never
# throw; a two-step graceful-then-force sequence would add a wait and a second
# code path for a benefit (a shutdown log line) that is not worth that risk.
function Stop-ProcTreeByPid($processId) {
    & cmd.exe /c ('taskkill.exe /PID ' + $processId + ' /T /F >nul 2>&1')
}

function Stop-ProcTreeByName($imageName) {
    & cmd.exe /c ('taskkill.exe /IM ' + $imageName + ' /T /F >nul 2>&1')
}

# --- Crash-loop protection -------------------------------------------------
# The watchdog should revive a component that died unexpectedly (hang, OOM
# kill, crash), but must NOT keep relaunching something that cannot start at
# all: retrying forever floods the log and, for QQ, risks triggering Tencent's
# anti-abuse controls. So we count restart attempts in a rolling window and
# give up after too many, until the user intervenes (start / repair clears it).

$RestartWindowSec = 1800   # look back 30 minutes
$RestartMaxTries = 3       # more than this in the window => stop trying
$AliveResetSec = 300       # staying alive 5 minutes counts as recovered

function Get-RestartHistory($name) {
    $file = Join-Path $StateDir ($name + '.restart-history')
    if (-not (Test-Path $file)) { return @() }
    $raw = ([IO.File]::ReadAllText($file)).Trim()
    if ($raw -eq '') { return @() }
    $now = Get-NowSec
    $kept = @()
    foreach ($part in ($raw -split '\s+')) {
        $value = [long]0
        if ([long]::TryParse($part, [ref]$value)) {
            if (($now - $value) -le $RestartWindowSec) { $kept += $value }
        }
    }
    return $kept
}

function Add-RestartAttempt($name) {
    $history = @(Get-RestartHistory $name)
    $history += (Get-NowSec)
    if ($history.Count -gt 10) { $history = $history[-10..-1] }
    [IO.File]::WriteAllText((Join-Path $StateDir ($name + '.restart-history')),
        ($history -join ' '))
}

function Clear-RestartHistory($name) {
    Clear-Counter ($name + '.restart-history')
    Clear-Counter ($name + '.giveup')
}

function Test-GaveUp($name) {
    # Already gave up? Stay quiet (one log line was written when giving up).
    if (Test-Marker ($name + '.giveup')) { return $true }
    $history = @(Get-RestartHistory $name)
    if ($history.Count -ge $RestartMaxTries) {
        Set-Marker ($name + '.giveup')
        Log ($name + ' failed to stay running after ' + $history.Count +
            ' restart attempts in the last ' + [int]($RestartWindowSec / 60) +
            ' minutes; giving up. Fix the cause, then click Start in the panel ' +
            '(or run: nbot start) to resume guarding.')
        return $true
    }
    return $false
}

function Check-AstrBot($conf) {
    if (-not (Test-Marker 'astrbot.enabled')) { return }
    $root = [string]$conf['ASTRBOT_ROOT']
    if ($root -eq '') { return }
    $port = [string]$conf['ASTRBOT_PORT']
    if ($port -eq '') { $port = '6185' }

    $procs = @(Get-ProcByCmdline 'python*' @('\app\main.py', $root))
    if ($procs.Count -eq 0) {
        # Gave up earlier because it kept failing to start? Do nothing.
        if (Test-GaveUp 'astrbot') { return }
        if (-not (Test-Marker 'astrbot.dead-restarted')) {
            Log 'AstrBot process is not running; starting task \NBot\AstrBot'
            Add-RestartAttempt 'astrbot'
            $rc = Invoke-Task '\NBot\AstrBot'
            if ($rc -ne 0) { Log ('schtasks /run \NBot\AstrBot failed with exit code ' + $rc) }
            Set-Marker 'astrbot.dead-restarted'
        }
        return
    }
    Clear-Counter 'astrbot.dead-restarted'

    # Deterministic choice when several candidates exist: smallest PID.
    $procPid = $procs[0].ProcessId
    foreach ($p in $procs) {
        if ($p.ProcessId -lt $procPid) { $procPid = $p.ProcessId }
    }

    # Startup grace: give a fresh process 120 seconds before probing the web UI.
    $now = Get-NowSec
    $grace = Read-Grace 'astrbot.grace'
    if ($grace[0] -ne [string]$procPid) {
        Write-Grace 'astrbot.grace' $procPid $now
        Clear-Counter 'astrbot.web-failures'
        return
    }
    if (($now - $grace[1]) -lt 120) { return }

    # Same process alive long enough => treat as recovered, forget past attempts.
    if (($now - $grace[1]) -ge $AliveResetSec) { Clear-RestartHistory 'astrbot' }

    if (Test-HttpOk ('http://127.0.0.1:{0}/' -f $port) 8000) {
        Clear-Counter 'astrbot.web-failures'
        return
    }
    $count = (Get-Counter 'astrbot.web-failures') + 1
    Set-Counter 'astrbot.web-failures' $count
    if ($count -ge 3) {
        # This restart path (process alive, WebUI unreachable) must obey the
        # same crash-loop cap as the "process is gone" path above -- otherwise
        # a stuck-port failure (port occupied by something else, wrong
        # ASTRBOT_PORT, hung mid-startup) restarts every 5 minutes forever,
        # since Test-GaveUp never sees any history from this branch (verified).
        if (Test-GaveUp 'astrbot') { return }
        Log ('AstrBot WebUI on port ' + $port + ' failed 3 checks while PID ' + $procPid + ' stayed alive; restarting hung process')
        Add-RestartAttempt 'astrbot'
        Stop-ProcTreeByPid $procPid
        Clear-Counter 'astrbot.web-failures'
        Clear-Counter 'astrbot.grace'
        # Give the dying process's own harvest xcopy (config sync on exit) a
        # moment to finish before the relaunch starts its own, mirroring
        # modules\tasks.ps1's Restart-BotTask -- otherwise both cmd instances
        # race on the same config files.
        Start-Sleep -Seconds 2
        $rc = Invoke-Task '\NBot\AstrBot'
        if ($rc -ne 0) { Log ('schtasks /run \NBot\AstrBot failed with exit code ' + $rc) }
    }
}

function Check-NapCat($conf) {
    # NapCat lives inside the QQ process (its launcher starts QQ with the
    # NapCat loader), so liveness is tracked on QQ.exe itself and a restart
    # means killing and relaunching the whole QQ process tree.
    if (-not (Test-Marker 'napcat.enabled')) { return }
    $port = [string]$conf['NAPCAT_WEBUI_PORT']
    if ($port -eq '') { $port = '6099' }

    $qq = @(Get-Process -Name 'QQ' -ErrorAction SilentlyContinue)
    if ($qq.Count -eq 0) {
        # Gave up earlier because it kept failing to start? Do nothing.
        # (Also protects the QQ account: repeated relaunch attempts that keep
        # failing look like abuse to Tencent.)
        if (Test-GaveUp 'napcat') { return }
        if (-not (Test-Marker 'napcat.dead-restarted')) {
            Log 'QQ process is not running; starting task \NBot\NapCat'
            Add-RestartAttempt 'napcat'
            $rc = Invoke-Task '\NBot\NapCat'
            if ($rc -ne 0) {
                Log ('schtasks /run \NBot\NapCat failed with exit code ' + $rc + '; the task needs a logged-on user session')
            }
            Set-Marker 'napcat.dead-restarted'
        }
        return
    }
    Clear-Counter 'napcat.dead-restarted'

    # Use the smallest PID as the stable identity of the QQ main process.
    $qqPid = $qq[0].Id
    foreach ($p in $qq) {
        if ($p.Id -lt $qqPid) { $qqPid = $p.Id }
    }

    # Startup grace: give a fresh QQ session 90 seconds before probing the web UI.
    $now = Get-NowSec
    $grace = Read-Grace 'napcat.grace'
    if ($grace[0] -ne [string]$qqPid) {
        Write-Grace 'napcat.grace' $qqPid $now
        Clear-Counter 'napcat.web-failures'
        return
    }
    if (($now - $grace[1]) -lt 90) { return }

    # Same QQ session alive long enough => recovered, forget past attempts.
    if (($now - $grace[1]) -ge $AliveResetSec) { Clear-RestartHistory 'napcat' }

    if (Test-TcpOk '127.0.0.1' $port 8000) {
        Clear-Counter 'napcat.web-failures'
        return
    }
    $count = (Get-Counter 'napcat.web-failures') + 1
    Set-Counter 'napcat.web-failures' $count
    if ($count -ge 3) {
        # Same crash-loop cap as the "process is gone" path above. Without
        # this, a WebUI port that never comes up (port taken by something
        # else, wrong NAPCAT_WEBUI_PORT, stuck mid-startup) restarts every
        # 5 minutes forever, since Test-GaveUp never accrues history from this
        # branch otherwise.
        if (Test-GaveUp 'napcat') { return }
        Log ('WebUI on port ' + $port + ' failed 3 checks; restarting NapCat stack')
        Add-RestartAttempt 'napcat'
        Stop-ProcTreeByName 'QQ.exe'
        Clear-Counter 'napcat.web-failures'
        Clear-Counter 'napcat.grace'
        $rc = Invoke-Task '\NBot\NapCat'
        if ($rc -ne 0) {
            Log ('schtasks /run \NBot\NapCat failed with exit code ' + $rc + '; the task needs a logged-on user session')
        }
    }
}

function Check-SnowLuma($conf) {
    # Unlike NapCat, SnowLuma and QQ are two independent processes: SnowLuma is
    # a Node process that injects its hook into a QQ.exe that is already
    # running, and the launcher starts both. So liveness is tracked on the
    # SnowLuma process, not on QQ -- QQ can be alive while SnowLuma is dead
    # (bot offline, nothing guarding it) which the NapCat-style check would
    # have reported as healthy.
    if (-not (Test-Marker 'snowluma.enabled')) { return }
    $port = [string]$conf['SNOWLUMA_WEBUI_PORT']
    if ($port -eq '') { $port = '5099' }
    $payload = [string]$conf['SL_PAYLOAD_ROOT']
    if ($payload -eq '') {
        # Without the payload path, 'index.mjs' alone would match ANY node
        # process on the machine running a file by that name (Vite, Next.js,
        # any ESM project) -- Stop-ProcTreeByPid would then taskkill /T /F an
        # unrelated process. This is reachable in practice (verified): a
        # config line with whitespace around the key, or $env:NBOT_CONFIG
        # pointing elsewhere, can both leave this key unreadable even though
        # the panel reads it fine. Refusing to guard is the safe default --
        # better to miss a real SnowLuma crash than to kill a stranger's node.
        Log 'SnowLuma check skipped: SL_PAYLOAD_ROOT is empty (config unreadable or key missing) -- refusing to guard rather than risk killing an unrelated node.exe matched by "index.mjs" alone'
        return
    }

    # Identify our node.exe by the payload path on its command line (the
    # launcher passes index.mjs as an absolute path precisely for this).
    $needles = @('index.mjs', $payload)
    $procs = @(Get-ProcByCmdline 'node*' $needles)

    if ($procs.Count -eq 0) {
        # Gave up earlier because it kept failing to start? Do nothing.
        # (Also protects the QQ account: repeated relaunch attempts that keep
        # failing look like abuse to Tencent.)
        if (Test-GaveUp 'snowluma') { return }
        if (-not (Test-Marker 'snowluma.dead-restarted')) {
            Log 'SnowLuma process is not running; starting task \NBot\SnowLuma'
            Add-RestartAttempt 'snowluma'
            $rc = Invoke-Task '\NBot\SnowLuma'
            if ($rc -ne 0) {
                Log ('schtasks /run \NBot\SnowLuma failed with exit code ' + $rc + '; the task needs a logged-on user session')
            }
            Set-Marker 'snowluma.dead-restarted'
        }
        return
    }
    Clear-Counter 'snowluma.dead-restarted'

    # Deterministic choice when several candidates exist: smallest PID.
    $procPid = $procs[0].ProcessId
    foreach ($p in $procs) {
        if ($p.ProcessId -lt $procPid) { $procPid = $p.ProcessId }
    }

    # Cheap "half-dead" signal: only one SnowLuma process can hold QQ's hook
    # named pipe at a time. Verified on a real box: a second instance starts
    # up fine and its WebUI answers normally, but it never gets an OneBot
    # adapter -- its own log shows just one line, "[Hook] ... already has
    # SnowLuma pipe; will reconnect". A leftover process from an unclean stop
    # produces exactly this, and $procs already enumerates every match so the
    # count is free to check here. Only warn (once) instead of auto-killing
    # the extras: nothing here reliably tells the leftover apart from the
    # live one, and killing the wrong PID would be worse than doing nothing.
    if ($procs.Count -gt 1) {
        if (-not (Test-Marker 'snowluma.dup-warned')) {
            Log ('WARNING: ' + $procs.Count + ' SnowLuma node processes are running at once (health checks use PID ' + $procPid + '); a previous stop likely left one behind without the QQ hook pipe -- see SnowLuma''s own log for "already has SnowLuma pipe". The TCP WebUI check below cannot see this half-dead state. If OneBot looks unresponsive, stop and restart the SnowLuma task by hand.')
            Set-Marker 'snowluma.dup-warned'
        }
    } else {
        Clear-Counter 'snowluma.dup-warned'
    }

    # Startup grace: give a fresh process 90 seconds before probing the web UI.
    $now = Get-NowSec
    $grace = Read-Grace 'snowluma.grace'
    if ($grace[0] -ne [string]$procPid) {
        Write-Grace 'snowluma.grace' $procPid $now
        Clear-Counter 'snowluma.web-failures'
        return
    }
    if (($now - $grace[1]) -lt 90) { return }

    # Same process alive long enough => recovered, forget past attempts.
    if (($now - $grace[1]) -ge $AliveResetSec) { Clear-RestartHistory 'snowluma' }

    if (Test-TcpOk '127.0.0.1' $port 8000) {
        Clear-Counter 'snowluma.web-failures'
        return
    }
    $count = (Get-Counter 'snowluma.web-failures') + 1
    Set-Counter 'snowluma.web-failures' $count
    if ($count -ge 3) {
        # Same crash-loop cap as the "process is gone" path above. Without
        # this, a WebUI port that never comes up (port taken by something
        # else, wrong SNOWLUMA_WEBUI_PORT, stuck mid-startup) restarts every
        # 5 minutes forever, since Test-GaveUp never accrues history from this
        # branch otherwise (verified).
        if (Test-GaveUp 'snowluma') { return }
        Log ('WebUI on port ' + $port + ' failed 3 checks while PID ' + $procPid + ' stayed alive; restarting hung SnowLuma')
        Add-RestartAttempt 'snowluma'
        # Only the SnowLuma process is restarted. QQ keeps running: the hook
        # stays loaded inside it and the new SnowLuma instance reattaches over
        # the existing named pipe, so the login session is not disturbed.
        Stop-ProcTreeByPid $procPid
        Clear-Counter 'snowluma.web-failures'
        Clear-Counter 'snowluma.grace'
        # Give the dying process's own exit-time harvest xcopy a moment to
        # finish before the relaunch starts its own push/harvest, mirroring
        # modules\tasks.ps1's Restart-BotTask -- otherwise both cmd instances
        # race on the same config files.
        Start-Sleep -Seconds 2
        $rc = Invoke-Task '\NBot\SnowLuma'
        if ($rc -ne 0) {
            Log ('schtasks /run \NBot\SnowLuma failed with exit code ' + $rc + '; the task needs a logged-on user session')
        }
    }
}

function Check-QQ($conf) {
    # QQ is guarded separately: SnowLuma has nothing to inject into when QQ is
    # gone, but SnowLuma itself keeps running and its WebUI keeps answering, so
    # the SnowLuma check above cannot notice.
    #
    # The watchdog runs as SYSTEM: starting QQ.exe directly from here would put
    # a GUI process into session 0 where nobody can see it. The only correct
    # relauncher is the \NBot\SnowLuma task (ONLOGON, runs in the user's
    # desktop session, and its launch script starts QQ when it is missing). The
    # already-running SnowLuma node is stopped first so the task's relaunch does
    # not stack a second instance onto the occupied WebUI port.
    if (-not (Test-Marker 'snowluma.enabled')) { return }
    $qq = @(Get-Process -Name 'QQ' -ErrorAction SilentlyContinue)
    if ($qq.Count -gt 0) {
        Clear-Counter 'qq.dead-restarted'
        # Self-heal: once the same QQ process has stayed up long enough,
        # forget past crash-loop history. Without this, qq.giveup (set after
        # 3 crashes in 30 minutes) is permanent -- Clear-RestartHistory is
        # never otherwise called for 'qq' (unlike astrbot/snowluma, which
        # both clear via their own grace file), so QQ crashing again after
        # days of healthy uptime would be silently ignored (verified: only
        # clicking Start in the panel could clear it).
        $qqPid = $qq[0].Id
        foreach ($p in $qq) { if ($p.Id -lt $qqPid) { $qqPid = $p.Id } }
        $now = Get-NowSec
        $grace = Read-Grace 'qq.grace'
        if ($grace[0] -ne [string]$qqPid) {
            Write-Grace 'qq.grace' $qqPid $now
        } elseif (($now - $grace[1]) -ge $AliveResetSec) {
            Clear-RestartHistory 'qq'
        }
        return
    }
    if (Test-GaveUp 'qq') { return }
    if (Test-Marker 'qq.dead-restarted') { return }

    $payload = [string]$conf['SL_PAYLOAD_ROOT']
    if ($payload -eq '') {
        # Same reasoning as Check-SnowLuma: without the payload path we
        # cannot tell "our" node.exe apart from an unrelated one, and killing
        # a stranger's process to make room for the relaunch would be worse
        # than skipping this cycle. Refuse rather than guess.
        Log 'QQ check skipped: SL_PAYLOAD_ROOT is empty (config unreadable or key missing) -- refusing to identify/kill a SnowLuma node process by "index.mjs" alone'
        return
    }

    Log 'QQ process is not running; restarting the SnowLuma task to bring it back'
    Add-RestartAttempt 'qq'
    $needles = @('index.mjs', $payload)
    foreach ($p in @(Get-ProcByCmdline 'node*' $needles)) {
        Stop-ProcTreeByPid $p.ProcessId
    }
    # Tell the next Check-SnowLuma call this absence is expected: this kill
    # just made SnowLuma's own process count drop to zero, and without this
    # marker the very next check would log "process is not running" and burn
    # one of SnowLuma's 3 restart-attempt slots for a restart it did not
    # decide to make (verified) -- eventually giving up on SnowLuma for a
    # problem that was actually QQ's.
    Set-Marker 'snowluma.dead-restarted'
    Clear-Counter 'snowluma.grace'
    # Let the killed process's own exit-time config harvest finish before the
    # relaunch starts its own push/harvest (same race as the hang-restart
    # paths above; modules\tasks.ps1's Restart-BotTask sleeps for the same
    # reason).
    Start-Sleep -Seconds 2
    $rc = Invoke-Task '\NBot\SnowLuma'
    if ($rc -ne 0) {
        Log ('schtasks /run \NBot\SnowLuma failed with exit code ' + $rc + '; the task needs a logged-on user session')
    } else {
        # Only mark as handled when the task actually ran. Leaving the marker
        # unset on failure (e.g. no logged-on session) lets the next tick try
        # again instead of silently giving up after one failed attempt
        # (verified: rc from an unattended reboot with no auto-logon is
        # non-zero, and the old code marked qq.dead-restarted unconditionally).
        Set-Marker 'qq.dead-restarted'
    }
}

function Write-Liveness {
    # Prove the watchdog is alive even when it has nothing to guard.
    # Logs on state change (guarding <-> idle, or a backend switch) and, while
    # idle, a heartbeat at most once an hour - enough to show liveness without
    # flooding the log.
    param([string]$State, [string]$Backend)
    $stateFile = Join-Path $StateDir 'watchdog.laststate'
    # Backend is folded into the stored state token so switching BOT_BACKEND
    # also logs a state-change line ('/' never appears in either part, and the
    # file format stays "token stamp" split on whitespace).
    $full = $State + '/' + $Backend
    $previous = ''
    $stamp = [long]0
    if (Test-Path $stateFile) {
        $parts = ([IO.File]::ReadAllText($stateFile)).Trim() -split '\s+'
        if ($parts.Count -ge 1) { $previous = $parts[0] }
        if ($parts.Count -ge 2) {
            $parsed = [long]0
            if ([long]::TryParse($parts[1], [ref]$parsed)) { $stamp = $parsed }
        }
    }
    $now = Get-NowSec
    $changed = ($previous -ne $full)
    $stale = (($now - $stamp) -ge 3600)
    if ($changed -or $stale) {
        if ($State -eq 'idle') {
            Log ('watchdog alive; backend=' + $Backend + '; nothing to guard (no astrbot.enabled / napcat.enabled / snowluma.enabled marker - services stopped or not installed)')
        } else {
            Log ('watchdog alive; backend=' + $Backend + '; guarding ' + $State)
        }
        [IO.File]::WriteAllText($stateFile, ($full + ' ' + $now))
    }
}

try {
    if (-not (Test-Path $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    $conf = Read-Conf

    # Which bot backend to guard. The watchdog runs standalone (it does not
    # dot-source lib\common.ps1), so it reads BOT_BACKEND itself with the same
    # fallback rule as common.ps1's Get-Backend: anything but 'snowluma'
    # (missing key, empty, typo) falls back to napcat.
    $backend = ([string]$conf['BOT_BACKEND']).Trim().ToLower()
    if ($backend -ne 'snowluma') { $backend = 'napcat' }

    $guarded = @()
    if (Test-Marker 'astrbot.enabled') { $guarded += 'astrbot' }
    if ($backend -eq 'snowluma') {
        if (Test-Marker 'snowluma.enabled') { $guarded += 'snowluma' }
    } else {
        if (Test-Marker 'napcat.enabled') { $guarded += 'napcat' }
    }
    if ($guarded.Count -eq 0) { Write-Liveness 'idle' $backend }
    else { Write-Liveness ($guarded -join '+') $backend }

    # Each check gets its own try/catch: a single IO hiccup (state file
    # read/write racing another process, a transient AppendAllText failure)
    # must not abort the rest of this tick's checks under
    # $ErrorActionPreference='Stop' -- the watchdog's one hard requirement is
    # to never let one bad check take down the whole run.
    try { Check-AstrBot $conf } catch { Log ('Check-AstrBot error: ' + $_.Exception.Message) }
    if ($backend -eq 'snowluma') {
        try { Check-SnowLuma $conf } catch { Log ('Check-SnowLuma error: ' + $_.Exception.Message) }
        try { Check-QQ $conf } catch { Log ('Check-QQ error: ' + $_.Exception.Message) }
    } else {
        try { Check-NapCat $conf } catch { Log ('Check-NapCat error: ' + $_.Exception.Message) }
    }
} catch {
    Log ('Watchdog error: ' + $_.Exception.Message)
}
exit 0
