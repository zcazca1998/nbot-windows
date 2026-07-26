# static-check.ps1
# Static checks for nbot-installer-windows.
# Run on the dev machine with Windows PowerShell 5.1 (the checks target
# scripts that must stay PowerShell 2.0 compatible, but this checker itself
# may use modern syntax).
#
# Checks:
#   1.  Every .ps1 file parses without syntax errors (PSParser tokenizer).
#   2.  Every .bat/.cmd file is pure ASCII (every byte < 128).
#   2b. Every .ps1 file starts with a UTF-8 BOM (PS 5.1 reads BOM-less files
#       as the local ANSI codepage and the Chinese text breaks parsing).
#   3.  No .ps1 file (outside tests\) uses forbidden PS3+ constructs.
#       ConvertFrom-Json / Expand-Archive are warn-only (allowed inside try).
#   4.  Required file manifest is present.
#   5.  The SnowLuma OneBot template's listening adapters (httpServers /
#       wsServers) all pin an explicit host (SnowLuma defaults to 0.0.0.0).
#
# Exit code: 0 when all checks pass, 1 on any failure.

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir

$script:failCount = 0
$script:warnCount = 0

function Report-Fail {
    param([string]$Message)
    $script:failCount++
    Write-Host "[FAIL] $Message"
}

function Report-Warn {
    param([string]$Message)
    $script:warnCount++
    Write-Host "[WARN] $Message"
}

function Get-RelPath {
    param([string]$FullPath)
    if ($FullPath.Length -gt $root.Length) {
        return $FullPath.Substring($root.Length).TrimStart('\')
    }
    return $FullPath
}

Write-Host "Project root: $root"

# ---------------------------------------------------------------------------
# 1. Syntax check all .ps1 files with the PowerShell tokenizer
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Check 1: .ps1 syntax (PSParser tokenizer) =='

$ps1Files = @(Get-ChildItem -Path $root -Recurse -Filter '*.ps1' -File |
    Where-Object { $_.FullName -notmatch '\\(\.git|\.claude|offline)\\' })

if ($ps1Files.Count -eq 0) {
    Report-Fail 'No .ps1 files found under project root.'
}

foreach ($file in $ps1Files) {
    $rel = Get-RelPath $file.FullName
    try {
        $source = [System.IO.File]::ReadAllText($file.FullName)
        $parseErrors = $null
        [void][System.Management.Automation.PSParser]::Tokenize($source, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            foreach ($pe in $parseErrors) {
                Report-Fail ("{0}: syntax error at line {1}: {2}" -f $rel, $pe.Token.StartLine, $pe.Message)
            }
        } else {
            Write-Host "  ok  $rel"
        }
    } catch {
        Report-Fail ("{0}: tokenizer threw: {1}" -f $rel, $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# 2. .bat / .cmd files must be pure ASCII (chcp 65001 pitfalls on Win7 cmd)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Check 2: .bat/.cmd pure ASCII =='

$batFiles = @(Get-ChildItem -Path $root -Recurse -File -Include '*.bat', '*.cmd', '*.vbs' |
    Where-Object { $_.FullName -notmatch '\\(\.git|\.claude|offline)\\' })

foreach ($file in $batFiles) {
    $rel = Get-RelPath $file.FullName
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $badOffset = -1
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -ge 128) { $badOffset = $i; break }
    }
    if ($badOffset -ge 0) {
        Report-Fail ("{0}: non-ASCII byte 0x{1:X2} at offset {2} (bat/cmd must be pure ASCII)" -f $rel, $bytes[$badOffset], $badOffset)
    } else {
        Write-Host "  ok  $rel"
    }
}

# ---------------------------------------------------------------------------
# 2b. Every .ps1 must start with a UTF-8 BOM.
#     Windows PowerShell 5.1 decodes a BOM-less file as the local ANSI
#     codepage (GBK on a Chinese system), so the Chinese comments and strings
#     in these scripts turn into mojibake and the mangled bytes break quote
#     pairing -- the file fails to parse at dot-source time. It bit us for
#     real: modules\onebot.ps1 lost its BOM during an edit and the installer
#     died on startup with a parser error that pointed at an unrelated line.
#     Cheap to check, near-impossible to spot by reading a diff.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Check 2b: .ps1 files have a UTF-8 BOM =='

foreach ($file in $ps1Files) {
    $rel = Get-RelPath $file.FullName
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hasBom) {
        Write-Host "  ok  $rel"
    } else {
        Report-Fail ("{0}: missing UTF-8 BOM (PowerShell 5.1 would read it as GBK and fail to parse)" -f $rel)
    }
}

# ---------------------------------------------------------------------------
# 3. Forbidden PS3+ constructs in .ps1 (core scripts must run on PS 2.0)
#    tests\ is excluded: test scripts run on the dev machine with PS 5.1.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Check 3: forbidden PS3+ constructs in .ps1 =='

$forbiddenPatterns = @(
    '\$PSScriptRoot',
    '-Raw\b',
    'Get-CimInstance',
    'Invoke-WebRequest',
    'Invoke-RestMethod',
    '\[pscustomobject\]',
    '\[ordered\]',
    '::new\('
)
$warnPatterns = @(
    'ConvertFrom-Json',
    'Expand-Archive'
)

$coreFiles = @($ps1Files | Where-Object { $_.FullName -notmatch '\\tests\\' })

foreach ($file in $coreFiles) {
    $rel = Get-RelPath $file.FullName
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    for ($n = 0; $n -lt $lines.Length; $n++) {
        $line = $lines[$n]
        # Skip pure comment lines and strip trailing comments: the sources
        # deliberately mention forbidden constructs in "do not use X" notes.
        if ($line.TrimStart().StartsWith('#')) { continue }
        $hashAt = $line.IndexOf('#')
        if ($hashAt -ge 0 -and $line.IndexOfAny([char[]]@("'", '"')) -lt 0) {
            $line = $line.Substring(0, $hashAt)
        }
        foreach ($pat in $forbiddenPatterns) {
            if ($line -match $pat) {
                Report-Fail ("{0}:{1}: forbidden PS3+ pattern '{2}': {3}" -f $rel, ($n + 1), $pat, $line.Trim())
            }
        }
        foreach ($pat in $warnPatterns) {
            if ($line -match $pat) {
                Report-Warn ("{0}:{1}: '{2}' is PS3+; make sure it only runs inside a guarded try block: {3}" -f $rel, ($n + 1), $pat, $line.Trim())
            }
        }
    }
}
Write-Host ("  scanned {0} core .ps1 file(s)" -f $coreFiles.Count)

# ---------------------------------------------------------------------------
# 4. Required file manifest
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Check 4: required files =='

$requiredFiles = @(
    'install.bat',
    'panel.bat',
    'panel.vbs',
    'setup.bat',
    'setup.vbs',
    'gui.ps1',
    'wizard.ps1',
    'lib\theme.ps1',
    'assets\bin\tray-autostart.vbs',
    'tests\render-check.ps1',
    'install-core.ps1',
    'lib\common.ps1',
    'modules\astrbot.ps1',
    'modules\qq.ps1',
    'modules\napcat.ps1',
    'modules\snowluma.ps1',
    'modules\onebot.ps1',
    'modules\tasks.ps1',
    'assets\bin\astrbot-launch.bat',
    'assets\bin\napcat-launch.bat',
    'assets\bin\snowluma-launch.bat',
    'assets\bin\watchdog.ps1',
    'assets\bin\nbot.cmd',
    'assets\bin\napcatctl.cmd',
    'assets\bin\snowlumactl.cmd',
    'assets\bin\astrbotctl.cmd',
    'assets\bin\qqlogin.cmd',
    'assets\bin\astrbot-prepare.py',
    'assets\bin\run-hidden.vbs',
    'build-single-exe.ps1',
    'README.md',
    'PITFALLS.md',
    'VERSION'
)

foreach ($relPath in $requiredFiles) {
    $full = Join-Path $root $relPath
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        Write-Host "  ok  $relPath"
    } else {
        Report-Fail "missing required file: $relPath"
    }
}

# ---------------------------------------------------------------------------
# Helper for content scans that must ignore documentation: the sources
# deliberately spell out "wrong" identifiers in comments (modules\onebot.ps1
# carries a NapCat<->SnowLuma field mapping table precisely so nobody copies
# the other backend's field names by mistake). Flagging those would push
# authors to delete the very documentation that prevents the regression.
# ---------------------------------------------------------------------------
function Test-IsCommentLine {
    param([string]$Line)
    $trimmed = $Line.TrimStart()
    if ($trimmed.StartsWith('#')) { return $true }
    if ($trimmed -match '^(?i)rem\s') { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# 5. Every listening adapter in the SnowLuma OneBot template must pin an
#    explicit host. SnowLuma's parser defaults a missing host to 0.0.0.0
#    (parseHttpServer / parseWsServer: `host: asString(value.host, "0.0.0.0")`),
#    so dropping the field as redundant would silently publish the adapter on
#    every interface. The generated template says 127.0.0.1; this keeps it
#    that way. Only the SnowLuma template inside modules\onebot.ps1 is in
#    scope: this is a dual-backend repo, so NapCat identifiers elsewhere are
#    legal and the NapCat template follows its own schema.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Check 5: SnowLuma OneBot listening adapters pin an explicit host =='

$onebotSrc = Join-Path $root 'modules\onebot.ps1'
if (-not (Test-Path -LiteralPath $onebotSrc -PathType Leaf)) {
    Report-Fail 'modules\onebot.ps1 not found; cannot verify SnowLuma OneBot host binding'
} else {
    $obText = [System.IO.File]::ReadAllText($onebotSrc)
    # Locate the SnowLuma template: a `function` line whose name mentions
    # SnowLuma and whose body (up to the matching closing brace) contains the
    # SnowLuma-only "networks" key. Braces inside the JSON template are
    # balanced, so plain depth counting finds the end of the function.
    $scanText = $null
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
        if ($body -cmatch '"networks"') { $scanText = $body; break }
    }
    if ($null -eq $scanText) {
        if ($obText -cmatch '"networks"') {
            # Template exists but lives outside a SnowLuma-named function
            # (e.g. inlined in Configure-OneBot): fall back to the whole file.
            # The NapCat template's listeners also pin a host, so the wider
            # scan stays false-positive free.
            Report-Warn 'modules\onebot.ps1: no SnowLuma-named function carries the "networks" template; scanning the whole file'
            $scanText = $obText
        } else {
            Report-Fail 'modules\onebot.ps1: SnowLuma OneBot template ("networks") not found'
        }
    }
    if ($null -ne $scanText) {
        # Only httpServers / wsServers listen; httpClients / wsClients dial
        # out and legitimately have no host field.
        $listenerBlocks = [regex]::Matches($scanText, '"(httpServers|wsServers)"\s*:\s*\[(.*?)\]', 'Singleline')
        $hostMissing = $false
        foreach ($blk in $listenerBlocks) {
            $kind = $blk.Groups[1].Value
            $body = $blk.Groups[2].Value
            if ($body.Trim() -eq '') { continue }   # empty array: nothing listens
            foreach ($entry in [regex]::Matches($body, '\{(.*?)\}', 'Singleline')) {
                if ($entry.Groups[1].Value -notmatch '"host"\s*:') {
                    $hostMissing = $true
                    Report-Fail ("modules\onebot.ps1: a {0} entry has no explicit `"host`" (SnowLuma would default it to 0.0.0.0)" -f $kind)
                }
            }
        }
        if (-not $hostMissing) {
            Write-Host ("  ok  {0} listening-adapter block(s) all pin an explicit host" -f $listenerBlocks.Count)
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
if ($script:failCount -gt 0) {
    Write-Host ("[FAIL] static-check: {0} failure(s), {1} warning(s)" -f $script:failCount, $script:warnCount)
    exit 1
}
Write-Host ("[OK] static-check: all checks passed ({0} warning(s))" -f $script:warnCount)
exit 0
