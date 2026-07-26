# nbot watchdog. Runs every minute as SYSTEM via the Task Scheduler
# task \NBot\Watchdog. Windows port of the Linux astrbot-healthcheck
# and napcat-healthcheck scripts, merged into one file.
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
            if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
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
    # NapCat's WebUI may answer 404 on the root path, so its liveness probe
    # is a bare TCP connect instead of an HTTP GET.
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
    $file = Join-Path $StateDir $name
    if (Test-Path $file) { Remove-Item -Path $file -Force }
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
        $clLower = $cl.ToLower()
        $ok = $true
        foreach ($s in $substrings) {
            if (-not $clLower.Contains(([string]$s).ToLower())) { $ok = $false; break }
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
        Log ('AstrBot WebUI on port ' + $port + ' failed 3 checks while PID ' + $procPid + ' stayed alive; restarting hung process')
        Stop-ProcTreeByPid $procPid
        Clear-Counter 'astrbot.web-failures'
        Clear-Counter 'astrbot.grace'
        $rc = Invoke-Task '\NBot\AstrBot'
        if ($rc -ne 0) { Log ('schtasks /run \NBot\AstrBot failed with exit code ' + $rc) }
    }
}

function Check-NapCat($conf) {
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
        Log ('WebUI on port ' + $port + ' failed 3 checks; restarting NapCat stack')
        Stop-ProcTreeByName 'QQ.exe'
        Clear-Counter 'napcat.web-failures'
        Clear-Counter 'napcat.grace'
        $rc = Invoke-Task '\NBot\NapCat'
        if ($rc -ne 0) {
            Log ('schtasks /run \NBot\NapCat failed with exit code ' + $rc + '; the task needs a logged-on user session')
        }
    }
}

function Write-Liveness {
    # Prove the watchdog is alive even when it has nothing to guard.
    # Logs on state change (guarding <-> idle) and, while idle, a heartbeat at
    # most once an hour - enough to show liveness without flooding the log.
    param([string]$State)
    $stateFile = Join-Path $StateDir 'watchdog.laststate'
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
    $changed = ($previous -ne $State)
    $stale = (($now - $stamp) -ge 3600)
    if ($changed -or $stale) {
        if ($State -eq 'idle') {
            Log 'watchdog alive; nothing to guard (no astrbot.enabled / napcat.enabled marker - services stopped or not installed)'
        } else {
            Log ('watchdog alive; guarding ' + $State)
        }
        [IO.File]::WriteAllText($stateFile, ($State + ' ' + $now))
    }
}

try {
    if (-not (Test-Path $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    $conf = Read-Conf

    $guarded = @()
    if (Test-Marker 'astrbot.enabled') { $guarded += 'astrbot' }
    if (Test-Marker 'napcat.enabled') { $guarded += 'napcat' }
    if ($guarded.Count -eq 0) { Write-Liveness 'idle' }
    else { Write-Liveness ($guarded -join '+') }

    Check-AstrBot $conf
    Check-NapCat $conf
} catch {
    Log ('Watchdog error: ' + $_.Exception.Message)
}
exit 0
