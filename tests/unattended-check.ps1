# unattended-check.ps1
# 验证「无人值守」能力：离线、快速、确定性。
#   A) NBOT_ASSUME_DEFAULTS=1 时 Prompt-Default / Confirm-Action 直接采用默认值，
#      根本不碰 Read-Host（也不会在非交互环境卡死）；
#   B) 即便在非交互环境（Read-Host 抛异常或返回空），二者也回退默认值，不挂死；
#   C) 真实命令分发 install-core.ps1 configure 在无人值守下跑完退出 0、写出配置，
#      验证「不卡交互、不崩」的端到端路径。
#
# 说明：完整的 install-all 需要外网 + 管理员权限，不在离线测试范围；doctor 的
# GitHub 镜像探针依赖外网，已在手动验证中确认离线 exit 0（约 25s）。本测试只覆盖
# 不依赖外网的无人值守机制与离线安全命令。
#
# 结果写入与本脚本同目录的 .unattended-results.txt（避免子进程继承 stdout 管道
# 导致 Write-Host 缓冲丢失）。退出码：0 全部通过，1 有失败。

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:failCount = 0

$script:ResultsFile = Join-Path $scriptDir '.unattended-results.txt'
if (Test-Path -LiteralPath $script:ResultsFile) { Remove-Item -LiteralPath $script:ResultsFile -Force }
function Write-Result { param([string]$Line); Add-Content -LiteralPath $script:ResultsFile -Value $Line -Encoding utf8 }

# ---------------------------------------------------------------------------
# A / B：无人值守机制单元测试（纯函数，无网络）
# ---------------------------------------------------------------------------
$env:NBOT_CONFIG = Join-Path $env:TEMP ('nbot-u-' + [Guid]::NewGuid().ToString('N') + '.conf')
try {
    . (Join-Path $root 'lib\common.ps1')
    Initialize-NBot

    # A) NBOT_ASSUME_DEFAULTS=1 直接返回默认值，不调 Read-Host
    $env:NBOT_ASSUME_DEFAULTS = '1'
    $a = Prompt-Default '后端' 'napcat'
    if ($a -ceq 'napcat') { Write-Result '[OK] A: NBOT_ASSUME_DEFAULTS=1 时 Prompt-Default 直接采用默认值' }
    else { $script:failCount++; Write-Result ('[FAIL] A: Prompt-Default 返回了 ' + $a) }
    $b = Confirm-Action '确认?' $true
    if ($b -eq $true) { Write-Result '[OK] A: Confirm-Action 默认 Yes 直接返回 $true' }
    else { $script:failCount++; Write-Result '[FAIL] A: Confirm-Action 未返回 $true' }

    # B) 非交互环境（Read-Host 抛异常或返回空）仍回退默认值，不挂死、不崩
    $env:NBOT_ASSUME_DEFAULTS = ''
    $c = Prompt-Default '端口' '6185'
    if ($c -ceq '6185') { Write-Result '[OK] B: 非交互环境下 Prompt-Default 回退默认值（未卡 Read-Host）' }
    else { $script:failCount++; Write-Result ('[FAIL] B: Prompt-Default 返回了 ' + $c) }
    $d = Confirm-Action '确认?' $false
    if ($d -eq $false) { Write-Result '[OK] B: 非交互环境下 Confirm-Action 回退默认值 $false' }
    else { $script:failCount++; Write-Result '[FAIL] B: Confirm-Action 未回退 $false' }

    # D) CI=true 环境变量也应触发无人值守(不依赖 Read-Host 抛异常,避免伪终端下挂死)
    $env:CI = 'true'
    $e = Prompt-Default 'CI端口' '8080'
    if ($e -ceq '8080') { Write-Result '[OK] D: CI=true 时 Prompt-Default 直接采用默认值' }
    else { $script:failCount++; Write-Result ('[FAIL] D: Prompt-Default 返回了 ' + $e) }
    $f = Confirm-Action 'CI确认?' $true
    if ($f -eq $true) { Write-Result '[OK] D: CI=true 时 Confirm-Action 直接返回 $true' }
    else { $script:failCount++; Write-Result '[FAIL] D: Confirm-Action 未返回 $true' }
    $env:CI = ''

    # E) NBOT_NONINTERACTIVE=1 也应触发无人值守
    $env:NBOT_NONINTERACTIVE = '1'
    $g = Prompt-Default 'NI端口' '9090'
    if ($g -ceq '9090') { Write-Result '[OK] E: NBOT_NONINTERACTIVE=1 时 Prompt-Default 直接采用默认值' }
    else { $script:failCount++; Write-Result ('[FAIL] E: Prompt-Default 返回了 ' + $g) }
    $h = Confirm-Action 'NI确认?' $false
    if ($h -eq $false) { Write-Result '[OK] E: NBOT_NONINTERACTIVE=1 时 Confirm-Action 直接返回 $false' }
    else { $script:failCount++; Write-Result '[FAIL] E: Confirm-Action 未返回 $false' }
    $env:NBOT_NONINTERACTIVE = ''
} catch {
    $script:failCount++
    Write-Result ('[FAIL] A/B 机制测试异常: ' + $_.Exception.Message)
}

# ---------------------------------------------------------------------------
# C：端到端命令分发（子进程，离线安全命令 configure；子进程输出写文件，避免继承
#     父进程 stdout 管道导致缓冲丢失）
# ---------------------------------------------------------------------------
$cfg = Join-Path $env:TEMP ('nbot-u-' + [Guid]::NewGuid().ToString('N') + '.conf')
$childLog = Join-Path $env:TEMP ('nbot-u-child-' + [Guid]::NewGuid().ToString('N') + '.log')
$env:NBOT_CONFIG = $cfg
$env:NBOT_ASSUME_DEFAULTS = '1'
$env:NBOT_TEST = '1'
try {
    & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install-core.ps1') configure > $childLog 2>&1
    $code = $LASTEXITCODE
} finally {
    if (Test-Path Env:\NBOT_CONFIG) { Remove-Item Env:\NBOT_CONFIG -ErrorAction SilentlyContinue }
    if (Test-Path Env:\NBOT_ASSUME_DEFAULTS) { Remove-Item Env:\NBOT_ASSUME_DEFAULTS -ErrorAction SilentlyContinue }
    if (Test-Path Env:\NBOT_TEST) { Remove-Item Env:\NBOT_TEST -ErrorAction SilentlyContinue }
}
if ($code -eq 0 -and (Test-Path -LiteralPath $cfg)) {
    Write-Result '[OK] C: install-core.ps1 configure 无人值守退出 0 且写出配置文件'
} else {
    $script:failCount++
    Write-Result ('[FAIL] C: configure 退出 ' + $code + ' 或配置未写出')
    if (Test-Path -LiteralPath $childLog) { Write-Result (('--- child output ---' + [Environment]::NewLine) + (Get-Content -LiteralPath $childLog -Raw)) }
}
if (Test-Path Env:\NBOT_CONFIG) { Remove-Item Env:\NBOT_CONFIG -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath $cfg) { Remove-Item -LiteralPath $cfg -Force }
if (Test-Path -LiteralPath $childLog) { Remove-Item -LiteralPath $childLog -Force }

Write-Result ''
if ($script:failCount -gt 0) {
    Write-Result ('[FAIL] unattended-check: ' + $script:failCount + ' failure(s)')
    exit 1
}
Write-Result '[OK] unattended-check: 无人值守机制与命令分发离线通过'
exit 0
