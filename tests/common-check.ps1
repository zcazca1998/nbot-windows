# common-check.ps1
# Functional checks for lib\common.ps1 (run on the dev machine, PS 5.1+).
# Uses a throwaway config file via $env:NBOT_CONFIG so the real
# %ProgramData% config is never touched.
#
# Contract functions expected in lib\common.ps1:
#   Load-Config, Get-Cfg, Set-Cfg, Write-Config,
#   New-RandomToken, Strip-TopLevel, Expand-Zip, Test-HttpOk
#
# Exit code: 0 when all cases pass, 1 on any failure.

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$commonPath = Join-Path $root 'lib\common.ps1'

$script:failCount = 0

function Pass {
    param([string]$Name)
    Write-Host "[OK] $Name"
}

function Fail {
    param([string]$Name, [string]$Detail)
    $script:failCount++
    Write-Host "[FAIL] $Name - $Detail"
}

if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    Fail 'lib\common.ps1 present' "not found: $commonPath"
    Write-Host "[FAIL] common-check: 1 failure(s)"
    exit 1
}

# Point the config path at a throwaway temp file before dot-sourcing.
$stamp = [Guid]::NewGuid().ToString('N')
$tmpConfig = Join-Path $env:TEMP ("nbot-check-{0}.conf" -f $stamp)
$tmpWork = Join-Path $env:TEMP ("nbot-check-{0}" -f $stamp)
$env:NBOT_CONFIG = $tmpConfig

try {
    . $commonPath
    Pass 'dot-source lib\common.ps1'
} catch {
    Fail 'dot-source lib\common.ps1' $_.Exception.Message
    Write-Host "[FAIL] common-check: cannot continue without common.ps1"
    exit 1
}

# ---------------------------------------------------------------------------
# Contract: required functions exist
# ---------------------------------------------------------------------------
$requiredFunctions = @(
    'Load-Config', 'Get-Cfg', 'Set-Cfg', 'Write-Config',
    'New-RandomToken', 'Strip-TopLevel', 'Expand-Zip', 'Test-HttpOk'
)
$missing = @{}
foreach ($fn in $requiredFunctions) {
    if (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue) {
        Pass "function exists: $fn"
    } else {
        $missing[$fn] = $true
        Fail "function exists: $fn" 'not defined after dot-sourcing common.ps1'
    }
}

function Test-HasFn {
    param([string[]]$Names)
    foreach ($n in $Names) { if ($missing.ContainsKey($n)) { return $false } }
    return $true
}

# ---------------------------------------------------------------------------
# Case 1: Load-Config then Get-Cfg ASTRBOT_PORT default 6185
# ---------------------------------------------------------------------------
if (Test-HasFn @('Load-Config', 'Get-Cfg')) {
    try {
        Load-Config
        $port = Get-Cfg 'ASTRBOT_PORT'
        if ("$port" -eq '6185') {
            Pass 'case 1: default ASTRBOT_PORT is 6185'
        } else {
            Fail 'case 1: default ASTRBOT_PORT is 6185' "got '$port'"
        }
    } catch {
        Fail 'case 1: default ASTRBOT_PORT is 6185' $_.Exception.Message
    }
} else {
    Fail 'case 1: default ASTRBOT_PORT is 6185' 'skipped: required function missing'
}

# ---------------------------------------------------------------------------
# Case 2: Set-Cfg + Write-Config persists, fresh Load-Config reads it back
# ---------------------------------------------------------------------------
if (Test-HasFn @('Load-Config', 'Get-Cfg', 'Set-Cfg', 'Write-Config')) {
    try {
        Set-Cfg 'ASTRBOT_PORT' '7000'
        Write-Config
        if (-not (Test-Path -LiteralPath $tmpConfig)) {
            throw "Write-Config did not create $tmpConfig"
        }
        # Reload from disk and verify the value survived the round trip.
        Load-Config
        $port = Get-Cfg 'ASTRBOT_PORT'
        if ("$port" -eq '7000') {
            Pass 'case 2: Set-Cfg/Write-Config/Load-Config round trip (7000)'
        } else {
            Fail 'case 2: Set-Cfg/Write-Config/Load-Config round trip (7000)' "got '$port'"
        }
    } catch {
        Fail 'case 2: Set-Cfg/Write-Config/Load-Config round trip (7000)' $_.Exception.Message
    }
} else {
    Fail 'case 2: Set-Cfg/Write-Config/Load-Config round trip (7000)' 'skipped: required function missing'
}

# ---------------------------------------------------------------------------
# Case 3: New-RandomToken length 48 and unique
# ---------------------------------------------------------------------------
if (Test-HasFn @('New-RandomToken')) {
    try {
        $t1 = New-RandomToken
        $t2 = New-RandomToken
        if ($t1.Length -ne 48) {
            Fail 'case 3: New-RandomToken length 48, two calls differ' "length was $($t1.Length)"
        } elseif ($t1 -ceq $t2) {
            Fail 'case 3: New-RandomToken length 48, two calls differ' 'two calls returned the same token'
        } else {
            Pass 'case 3: New-RandomToken length 48, two calls differ'
        }
    } catch {
        Fail 'case 3: New-RandomToken length 48, two calls differ' $_.Exception.Message
    }
} else {
    Fail 'case 3: New-RandomToken length 48, two calls differ' 'skipped: required function missing'
}

# ---------------------------------------------------------------------------
# Case 4: Strip-TopLevel flattens a single wrapper directory
# ---------------------------------------------------------------------------
if (Test-HasFn @('Strip-TopLevel')) {
    try {
        $nest = Join-Path $tmpWork 'strip'
        $wrap = Join-Path $nest 'wrapper-1.2.0'
        New-Item -ItemType Directory -Force -Path (Join-Path $wrap 'sub') | Out-Null
        Set-Content -LiteralPath (Join-Path $wrap 'a.txt') -Value 'alpha' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $wrap 'sub\b.txt') -Value 'bravo' -Encoding Ascii

        Strip-TopLevel $nest

        $aOk = Test-Path -LiteralPath (Join-Path $nest 'a.txt') -PathType Leaf
        $bOk = Test-Path -LiteralPath (Join-Path $nest 'sub\b.txt') -PathType Leaf
        if ($aOk -and $bOk) {
            Pass 'case 4: Strip-TopLevel flattens single nested directory'
        } else {
            Fail 'case 4: Strip-TopLevel flattens single nested directory' "a.txt found=$aOk, sub\b.txt found=$bOk"
        }
    } catch {
        Fail 'case 4: Strip-TopLevel flattens single nested directory' $_.Exception.Message
    }
} else {
    Fail 'case 4: Strip-TopLevel flattens single nested directory' 'skipped: required function missing'
}

# ---------------------------------------------------------------------------
# Case 5: Expand-Zip extracts a small zip
# ---------------------------------------------------------------------------
if (Test-HasFn @('Expand-Zip')) {
    try {
        $zipSrc = Join-Path $tmpWork 'zipsrc'
        $zipFile = Join-Path $tmpWork 'sample.zip'
        $zipDest = Join-Path $tmpWork 'zipdest'
        New-Item -ItemType Directory -Force -Path $zipSrc | Out-Null
        Set-Content -LiteralPath (Join-Path $zipSrc 'hello.txt') -Value 'hello zip' -Encoding Ascii
        Compress-Archive -Path (Join-Path $zipSrc 'hello.txt') -DestinationPath $zipFile -Force

        Expand-Zip $zipFile $zipDest

        $out = Join-Path $zipDest 'hello.txt'
        if (Test-Path -LiteralPath $out -PathType Leaf) {
            $content = (Get-Content -LiteralPath $out | Select-Object -First 1)
            if ("$content" -eq 'hello zip') {
                Pass 'case 5: Expand-Zip extracts zip content'
            } else {
                Fail 'case 5: Expand-Zip extracts zip content' "unexpected content: '$content'"
            }
        } else {
            Fail 'case 5: Expand-Zip extracts zip content' "hello.txt not found under $zipDest"
        }
    } catch {
        Fail 'case 5: Expand-Zip extracts zip content' $_.Exception.Message
    }
} else {
    Fail 'case 5: Expand-Zip extracts zip content' 'skipped: required function missing'
}

# ---------------------------------------------------------------------------
# Case 6: cleanup temp files
# ---------------------------------------------------------------------------
try {
    if (Test-Path -LiteralPath $tmpConfig) { Remove-Item -LiteralPath $tmpConfig -Force }
    if (Test-Path -LiteralPath $tmpWork) { Remove-Item -LiteralPath $tmpWork -Recurse -Force }
    Remove-Item Env:\NBOT_CONFIG -ErrorAction SilentlyContinue
    Pass 'case 6: cleanup temp files'
} catch {
    Fail 'case 6: cleanup temp files' $_.Exception.Message
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
if ($script:failCount -gt 0) {
    Write-Host ("[FAIL] common-check: {0} failure(s)" -f $script:failCount)
    exit 1
}
Write-Host '[OK] common-check: all cases passed'
exit 0
