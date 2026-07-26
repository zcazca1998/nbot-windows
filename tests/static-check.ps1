# static-check.ps1
# Static checks for nbot-installer-windows.
# Run on the dev machine with Windows PowerShell 5.1 (the checks target
# scripts that must stay PowerShell 2.0 compatible, but this checker itself
# may use modern syntax).
#
# Checks:
#   1. Every .ps1 file parses without syntax errors (PSParser tokenizer).
#   2. Every .bat/.cmd file is pure ASCII (every byte < 128).
#   3. No .ps1 file (outside tests\) uses forbidden PS3+ constructs.
#      ConvertFrom-Json / Expand-Archive are warn-only (allowed inside try).
#   4. Required file manifest is present.
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
    Where-Object { $_.FullName -notmatch '\\(\.git|offline)\\' })

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
    Where-Object { $_.FullName -notmatch '\\(\.git|offline)\\' })

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
    'modules\napcat.ps1',
    'modules\onebot.ps1',
    'modules\tasks.ps1',
    'assets\bin\astrbot-launch.bat',
    'assets\bin\napcat-launch.bat',
    'assets\bin\watchdog.ps1',
    'assets\bin\nbot.cmd',
    'assets\bin\astrbot-prepare.py',
    'assets\bin\run-hidden.vbs',
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
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
if ($script:failCount -gt 0) {
    Write-Host ("[FAIL] static-check: {0} failure(s), {1} warning(s)" -f $script:failCount, $script:warnCount)
    exit 1
}
Write-Host ("[OK] static-check: all checks passed ({0} warning(s))" -f $script:warnCount)
exit 0
