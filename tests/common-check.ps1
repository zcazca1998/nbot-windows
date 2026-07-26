# common-check.ps1
# Functional checks for lib\common.ps1 and the SnowLuma OneBot template in
# modules\onebot.ps1 (run on the dev machine, PS 5.1+).
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
# Case 6: the SnowLuma OneBot template in modules\onebot.ps1 generates a
# config with SnowLuma's field names, an explicit host on every listening
# adapter, and none of NapCat's field names. SnowLuma rejects unknown keys
# (rejectUnknownKeys), so a NapCat field name sneaking into the template
# would make SnowLuma refuse the whole file at runtime.
#
# Driven from the source text on purpose: Configure-OneBot itself restarts
# scheduled tasks and touches the AstrBot install, which a test must not do.
# The template here-string is extracted from the SnowLuma branch, expanded
# with placeholder values (exactly what the code does at run time), and the
# resulting JSON is validated.
# ---------------------------------------------------------------------------
$case6 = 'case 6: SnowLuma onebot.json template (fields, explicit host, no NapCat keys)'
try {
    $onebotPath = Join-Path $root 'modules\onebot.ps1'
    if (-not (Test-Path -LiteralPath $onebotPath -PathType Leaf)) {
        throw "modules\onebot.ps1 not found: $onebotPath"
    }
    $obText = [System.IO.File]::ReadAllText($onebotPath)

    # Narrow to the SnowLuma template function when one exists (a `function`
    # line naming SnowLuma whose body carries the "networks" key); otherwise
    # scan the whole file for the template here-string. Braces in the JSON
    # are balanced, so depth counting finds the end of the function.
    $scope = $null
    foreach ($m in [regex]::Matches($obText, '(?im)^[ \t]*function\s+[A-Za-z0-9_-]*snowluma[A-Za-z0-9_-]*')) {
        $open = $obText.IndexOf('{', $m.Index)
        if ($open -lt 0) { continue }
        $depth = 0
        $close = -1
        for ($i = $open; $i -lt $obText.Length; $i++) {
            $ch = $obText[$i]
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) { $close = $i; break }
            }
        }
        if ($close -lt 0) { continue }
        $body = $obText.Substring($m.Index, $close - $m.Index + 1)
        if ($body -cmatch '"networks"') { $scope = $body; break }
    }
    if ($null -eq $scope) { $scope = $obText }

    # Pull out the expandable here-string that carries the SnowLuma template.
    $template = $null
    foreach ($hs in [regex]::Matches($scope, '@"[ \t]*\r?\n(.*?)\r?\n"@', [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        if ($hs.Groups[1].Value -cmatch '"networks"') { $template = $hs.Groups[1].Value; break }
    }
    if ($null -eq $template) {
        throw 'no here-string containing "networks" found in modules\onebot.ps1 (SnowLuma template missing?)'
    }

    # Expand it the same way the here-string expands at run time: give every
    # referenced variable a placeholder (numeric for *port* variables so the
    # JSON stays well-formed, a token string for everything else).
    $tokenValue = 'TESTTOKEN0123456789abcdef'
    $varNames = @{}
    foreach ($vm in [regex]::Matches($template, '\$([A-Za-z_][A-Za-z0-9_]*)')) {
        $varNames[$vm.Groups[1].Value] = $true
    }
    foreach ($vn in $varNames.Keys) {
        if ($vn -match '(?i)port') {
            Set-Variable -Name $vn -Value 3199 -Scope Local
        } else {
            Set-Variable -Name $vn -Value $tokenValue -Scope Local
        }
    }
    $json = $ExecutionContext.InvokeCommand.ExpandString($template)

    $problems = @()

    # The expanded template must be well-formed JSON at all.
    try {
        [void]($json | ConvertFrom-Json)
    } catch {
        $problems += ('not valid JSON: ' + $_.Exception.Message)
    }

    # SnowLuma field names that must be present (case-sensitive).
    foreach ($needle in @('"networks"', '"wsClients"', '"accessToken"', '"enabled"', '"messageFormat"', '"reconnectIntervalMs"', '"enableWebSocket"')) {
        if (-not ($json.Contains($needle))) {
            $problems += ("missing SnowLuma field {0}" -f $needle)
        }
    }

    # NapCat field names that must be absent (case-sensitive: enableWebsocket
    # with a lowercase s is NapCat's; SnowLuma's enableWebSocket must not
    # trip it).
    foreach ($bad in @('"network"\s*:', 'websocketClients', 'messagePostFormat', 'enableWebsocket')) {
        if ($json -cmatch $bad) {
            $problems += ("NapCat field name present: {0}" -f $bad)
        }
    }

    # Every non-empty listening adapter (httpServers / wsServers) must pin an
    # explicit host; SnowLuma defaults a missing host to 0.0.0.0.
    foreach ($blk in [regex]::Matches($json, '"(httpServers|wsServers)"\s*:\s*\[(.*?)\]', 'Singleline')) {
        $kind = $blk.Groups[1].Value
        $body = $blk.Groups[2].Value
        if ($body.Trim() -eq '') { continue }
        foreach ($entry in [regex]::Matches($body, '\{(.*?)\}', 'Singleline')) {
            if ($entry.Groups[1].Value -notmatch '"host"\s*:') {
                $problems += ("a {0} entry has no explicit host" -f $kind)
            }
        }
    }

    if ($problems.Count -eq 0) {
        Pass $case6
    } else {
        Fail $case6 ($problems -join '; ')
    }
} catch {
    Fail $case6 $_.Exception.Message
}

# ---------------------------------------------------------------------------
# Case 7: cleanup temp files
# ---------------------------------------------------------------------------
try {
    if (Test-Path -LiteralPath $tmpConfig) { Remove-Item -LiteralPath $tmpConfig -Force }
    if (Test-Path -LiteralPath $tmpWork) { Remove-Item -LiteralPath $tmpWork -Recurse -Force }
    Remove-Item Env:\NBOT_CONFIG -ErrorAction SilentlyContinue
    Pass 'case 7: cleanup temp files'
} catch {
    Fail 'case 7: cleanup temp files' $_.Exception.Message
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
