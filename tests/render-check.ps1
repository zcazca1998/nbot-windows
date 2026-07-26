# render-check.ps1
# 真实渲染测试:把窗口显示在屏幕外并强制触发一次完整绘制,断言所有 Paint
# 处理器都没有抛异常。仅构建窗体的无头测试抓不到绘制期错误(GDI+ 重载解析
# 失败只会在 Paint 事件里炸),所以这个检查是必需的。
#
# 用法:powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests\render-check.ps1
# 退出码:0 全部通过,1 有绘制错误。

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir

. (Join-Path $root 'lib\theme.ps1')

$failures = 0

function Test-Render {
    param([string]$Label, $Form)
    # 放到屏幕外,避免测试时窗口闯进用户视野
    $Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $Form.Location = New-Object System.Drawing.Point(-4000, -4000)
    $Form.ShowInTaskbar = $false
    $Form.Show()
    for ($i = 0; $i -lt 5; $i++) {
        $Form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 120
    }
    # 触发按钮 hover 重绘路径
    foreach ($control in $Form.Controls) {
        try { $control.Invalidate() } catch { }
    }
    $Form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    $Form.Close()
    $Form.Dispose()
    [System.Windows.Forms.Application]::DoEvents()
    Write-Host ('  rendered: ' + $Label)
}

Write-Host '== 渲染测试:主题组件 =='
$form = New-ThemeWindow '渲染测试' 520 380 -WithMinimize
$card = New-ThemeCard $form 16 52 488 120 '状态卡片'
$row = New-ThemeStatusRow $card 14 34 90 '示例'
Set-ThemeStatusRow $row '运行中' 'Ok'
[void](New-ThemeLabel $card 14 66 460 20 '普通文字' 9)
[void](New-ThemeLabel $card 14 88 460 20 '次要文字' 8.5 -ColorName 'TextDim')
$card2 = New-ThemeCard $form 16 184 488 170 '按钮与输入'
[void](New-ThemeButton $card2 14 34 140 34 '主按钮' 'primary' { })
[void](New-ThemeButton $card2 166 34 140 34 '强调按钮' 'accent' { })
[void](New-ThemeButton $card2 318 34 140 34 '描边按钮' 'ghost' { })
[void](New-ThemeButton $card2 14 76 140 34 '危险按钮' 'danger' { })
[void](New-ThemeTextBox $card2 166 80 140 '文本框')
[void](New-ThemeCombo $card2 318 80 140 @('选项一', '选项二') 0)
[void](New-ThemeLogBox $card2 14 120 444 40)
Test-Render 'theme components' $form

Write-Host '== 渲染测试:控制面板与安装向导 =='
# gui.ps1 / wizard.ps1 在 RENDERTEST 模式下把窗口画在屏幕外并打印
# 'PAINT ERRORS: n';它们要在独立进程里跑(各自有消息循环与托盘资源)。
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($target in @('gui.ps1', 'wizard.ps1')) {
    $full = Join-Path $root $target
    $env:NBOT_GUI_RENDERTEST = '1'
    $env:NBOT_GUI_NOSHOW = ''
    $output = & $psExe '-NoProfile' '-ExecutionPolicy' 'Bypass' '-STA' '-File' $full 2>&1
    $code = $LASTEXITCODE
    $env:NBOT_GUI_RENDERTEST = ''
    $text = ($output | Out-String)
    if ($code -ne 0 -or $text -notmatch 'PAINT ERRORS: 0') {
        Write-Host ('[FAIL] ' + $target + ' 渲染失败(退出码 ' + $code + '):')
        Write-Host $text
        $failures = $failures + 1
    } else {
        Write-Host ('  rendered: ' + $target)
    }
}

Write-Host '== 状态逻辑自检(非提权真跑 Update-Status)=='
# 这一段专抓渲染测试的盲区:面板状态刷新会调用 schtasks 等外部命令,
# 它们的 stderr 在 ErrorActionPreference=Stop 下会抛异常并崩掉窗口。
$env:NBOT_GUI_SELFTEST = '1'
$env:NBOT_GUI_RENDERTEST = ''
# 必须同时设 NOSHOW:否则自检里的对话框会真的 ShowDialog 阻塞,
# 而且会走单实例检查——已有面板在跑时会静默退出、什么都测不到。
$env:NBOT_GUI_NOSHOW = '1'
$selfOut = & $psExe '-NoProfile' '-ExecutionPolicy' 'Bypass' '-STA' '-File' (Join-Path $root 'gui.ps1') 2>&1
$selfCode = $LASTEXITCODE
$env:NBOT_GUI_SELFTEST = ''
$selfText = ($selfOut | Out-String)
if ($selfCode -ne 0 -or $selfText -notmatch 'STATUS OK') {
    Write-Host ('[FAIL] 面板状态逻辑异常(退出码 ' + $selfCode + '):')
    Write-Host $selfText
    $failures = $failures + 1
} else {
    Write-Host '  status logic: OK'
}

$errors = Get-ThemePaintErrors
if ($errors.Count -gt 0) {
    Write-Host ''
    Write-Host ('[FAIL] 绘制期出现 ' + $errors.Count + ' 个错误:')
    $seen = @{}
    foreach ($message in $errors) {
        if ($seen.ContainsKey($message)) { continue }
        $seen[$message] = $true
        Write-Host ('  - ' + $message)
    }
    $failures = $failures + 1
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host '[FAIL] render-check: 存在绘制错误'
    exit 1
}
Write-Host '[OK] render-check: 所有窗口绘制正常'
exit 0
