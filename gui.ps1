# =============================================================================
# nbot-installer-windows / gui.ps1
# 图形控制面板（WinForms + lib\theme.ps1 深色二次元主题）：
#   状态仪表盘 + 快捷操作 + 服务守护 + 日志维护 + 扫码登录 + 常驻托盘。
# 由 panel.bat 以管理员身份、-STA 模式启动。
# 兼容范围：Windows 7 SP1 - Windows 11（PowerShell 2.0 + .NET 2.0 WinForms）。
# 重操作（安装/更新/卸载）在独立控制台窗口中运行 install.bat，面板不阻塞。
# 环境变量：
#   NBOT_GUI_NOSHOW=1  只构建窗体不显示（自动化测试用）
#   NBOT_GUI_TRAY=1    启动即隐藏到托盘（登录自启用）
# =============================================================================

$ErrorActionPreference = 'Stop'

$script:GuiDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:GuiDir 'lib\common.ps1')
. (Join-Path $script:GuiDir 'lib\theme.ps1')
Load-Config

$script:InstallBat = Join-Path $script:GuiDir 'install.bat'
$script:NoShow = [bool]$env:NBOT_GUI_NOSHOW
$script:TrayMode = [bool]$env:NBOT_GUI_TRAY
$script:RunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunValueName = 'NBotTray'
$script:Tray = $null
$script:SuppressBalloon = $false

# -----------------------------------------------------------------------------
# 单实例:已经有面板在跑时,第二次启动不开新窗,而是给老实例发「现身」信号
# 后直接退出。信号 = state 目录下的 panel.show-request 文件,老实例的状态
# 定时器每 5 秒检查一次,看到就删掉并把窗口唤出来。
# 测试模式(NOSHOW / RENDERTEST)跳过,避免影响自动化检查。
# -----------------------------------------------------------------------------

$script:SingleMutex = $null
if (-not $script:NoShow -and $env:NBOT_GUI_RENDERTEST -ne '1' -and $env:NBOT_GUI_SELFTEST -ne '1') {
    # 先探测锁是否已存在。注意:提权实例创建的互斥体,非提权实例来开会抛
    # UnauthorizedAccessException(完整性级别不同)——「打不开但存在」同样
    # 说明面板已在运行,绝不能当成「锁不存在」继续启动(否则就双开了)。
    $already = $false
    try {
        $probe = [System.Threading.Mutex]::OpenExisting('Local\NBotPanel')
        $probe.Close()
        $already = $true
    } catch [System.Threading.WaitHandleCannotBeOpenedException] {
        $already = $false
    } catch {
        $already = $true
    }

    if (-not $already) {
        $created = $false
        try {
            $script:SingleMutex = New-Object System.Threading.Mutex($true, 'Local\NBotPanel', [ref]$created)
        } catch {
            $created = $false
        }
        # 创建失败或输掉竞态(别人先建了)都视为已有实例
        if (-not $created) { $already = $true }
    }

    if ($already) {
        try {
            $marker = Join-Path (Get-StateDir) 'panel.show-request'
            [IO.File]::WriteAllText($marker, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        } catch { }
        exit 0
    }
    # 拿到锁的是唯一实例:清掉可能残留的旧信号,避免启动后被误唤醒
    try {
        $stale = Join-Path (Get-StateDir) 'panel.show-request'
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
    } catch { }
}

# -----------------------------------------------------------------------------
# 基础辅助
# -----------------------------------------------------------------------------

function Start-ConsoleCommand {
    # 在新控制台窗口里运行 install.bat 子命令。
    # -Quick:秒级完成的操作(启停/自启/重启),跑完自动关窗,不要求按键;
    # 默认:安装/更新/诊断这类需要看输出的,结束后停留等待按键。
    param([string]$Command, [string]$Extra, [switch]$Quick)
    # 这些命令会改动计划任务,让任务存在性缓存立即失效,避免面板显示滞后
    if ('install-all', 'install-astrbot', 'install-napcat', 'install-snowluma', 'repair', 'uninstall',
        'uninstall-quiet', 'autostart-on', 'autostart-off' -contains $Command) {
        Clear-TaskCache
    }
    $line = '"' + $script:InstallBat + '" ' + $Command
    if ($Extra) { $line = $line + ' ' + $Extra }
    if ($Quick) {
        Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $line + '"') -WindowStyle Minimized
    } else {
        Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $line + ' & echo. & pause"')
    }
}

function Show-Toast {
    # 优先用托盘气泡提示，托盘不可用时退回消息框。
    param([string]$Text)
    if ($null -ne $script:Tray -and $script:Tray.Visible) {
        $script:Tray.ShowBalloonTip(2500, 'nbot', $Text,
            [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }
    if (-not $script:NoShow) {
        [void][System.Windows.Forms.MessageBox]::Show($Text, 'nbot')
    }
}

function Get-AstrPort {
    $port = Get-Cfg 'ASTRBOT_PORT'
    if (-not $port) { $port = '6185' }
    return $port
}

function Test-TaskExists {
    param([string]$Name)
    # 用缓存:每次查任务都要新建 cmd 进程,三个组件就是三次,放在 5 秒一跳的
    # 状态刷新里会明显拖慢 UI(拖窗口发飘)。任务是否存在几乎不变,缓存 60 秒,
    # 安装/修复这类会改任务的操作再主动失效。
    # 时间戳必须按 key 存,不能用一个全局单值:Update-Status 依次查
    # AstrBot -> 机器人后端 -> Watchdog,若共用一个时间戳,任何一次 miss 都会
    # 把它刷成 now,导致排在后面的任务永远在有效期内、再也不会重新查询——
    # 面板会一直显示「守护中」,即使那个任务早被删掉了。
    if ($null -eq $script:TaskCache) { $script:TaskCache = @{} }
    $now = [DateTime]::UtcNow
    $entry = $script:TaskCache[$Name]
    if ($null -ne $entry) {
        if (($now - $entry['t']).TotalSeconds -lt 60) {
            return [bool]$entry['v']
        }
    }

    # AstrBot/Watchdog 是 SYSTEM 任务:非提权查询返回「拒绝访问」而不是
    # 「不存在」,只看退出码会误判成缺失。用 cmd 把 stderr 收进 stdout 再判断
    # 内容;不能让 schtasks 的 stderr 直接进 PowerShell 错误流——EAP=Stop 下
    # 会抛异常,在 UI 事件里会崩窗。
    $out = & cmd.exe /c ('schtasks /query /tn "\NBot\' + $Name + '" 2>&1')
    $exists = $false
    if ($LASTEXITCODE -eq 0) {
        $exists = $true
    } else {
        $text = ($out | Out-String)
        # 「拒绝访问」= 任务存在但没权限看;「找不到」才是真的不存在
        if ($text -match 'denied|拒绝') { $exists = $true }
    }
    $script:TaskCache[$Name] = @{ 'v' = $exists; 't' = $now }
    return $exists
}

function Clear-TaskCache {
    $script:TaskCache = @{}
}

function Test-AutostartDisabled {
    $flag = $false
    try {
        $flag = Test-Path -LiteralPath (Join-Path (Get-StateDir) 'autostart.disabled')
    } catch {
        $flag = $false
    }
    return $flag
}

function Get-QrCodePath {
    # 当前载荷 cache 目录下的登录二维码（NapCat 登录时生成）。
    $payload = Get-Cfg 'NAPCAT_PAYLOAD_ROOT'
    if (-not $payload) { return $null }
    $qr = Join-Path $payload 'current\cache\qrcode.png'
    if (Test-Path -LiteralPath $qr) { return $qr }
    return $null
}

# -----------------------------------------------------------------------------
# 开机常驻托盘（HKCU Run 项）
# -----------------------------------------------------------------------------

function Test-TrayAutostart {
    $item = $null
    try {
        $item = Get-ItemProperty -Path $script:RunKeyPath -Name $script:RunValueName -ErrorAction SilentlyContinue
    } catch {
        $item = $null
    }
    return ($null -ne $item)
}

function Get-TrayVbsPath {
    # 优先使用已安装到 bin 目录的副本；缺失时从安装器 assets 拷一份过去。
    $target = Join-Path (Get-BinDir) 'tray-autostart.vbs'
    if (-not (Test-Path -LiteralPath $target)) {
        $source = Join-Path $script:GuiDir 'assets\bin\tray-autostart.vbs'
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
    }
    if (Test-Path -LiteralPath $target) { return $target }
    return $null
}

function Toggle-TrayAutostart {
    try {
        if (Test-TrayAutostart) {
            try {
                Remove-ItemProperty -Path $script:RunKeyPath -Name $script:RunValueName
            } catch { }
            Show-Toast '已关闭：登录 Windows 后不再自动常驻托盘。'
        } else {
            $vbs = Get-TrayVbsPath
            if (-not $vbs) {
                Show-Toast '未找到 tray-autostart.vbs，请先执行一次「一键安装/更新」或「修复」。'
                return
            }
            Set-ItemProperty -Path $script:RunKeyPath -Name $script:RunValueName `
                -Value ('wscript.exe //B "' + $vbs + '"')
            Show-Toast '已开启：登录 Windows 后面板会自动常驻托盘。'
        }
    } catch {
        Show-Toast ('切换开机常驻托盘失败：' + $_.Exception.Message)
    }
    Update-TrayMenuLabel
}

function Update-TrayMenuLabel {
    if ($null -eq $script:MiTrayAuto) { return }
    $state = '关'
    if (Test-TrayAutostart) { $state = '开' }
    $script:MiTrayAuto.Text = '开机时常驻托盘: ' + $state
}

# -----------------------------------------------------------------------------
# 日志查看窗口（面板内置，按 UTF-8 读取，避免控制台代码页乱码）
# -----------------------------------------------------------------------------

function Show-LogWindow {
    param([string]$Title, [string]$Path)

    $script:LogPath = $Path
    $win = New-ThemeWindow $Title 800 560 -WithMinimize
    [void](New-ThemeLabel $win 20 52 760 20 $Path 8.5 -ColorName 'TextDim')
    $script:LogBox = New-ThemeLogBox $win 20 78 760 400
    $script:LogStatus = New-ThemeLabel $win 20 490 500 20 '' 8.5 -ColorName 'TextDim'

    $loadLog = {
        if (-not (Test-Path -LiteralPath $script:LogPath)) {
            $script:LogBox.Text = '日志文件还不存在：' + $script:LogPath + [Environment]::NewLine +
                '（对应组件可能尚未启动过）'
            $script:LogStatus.Text = ''
            return
        }
        $lines = Get-TailLines $script:LogPath 400
        $clean = @()
        foreach ($line in $lines) { $clean += (Remove-AnsiEscapes $line) }
        $script:LogBox.Text = ($clean -join [Environment]::NewLine)
        $script:LogBox.SelectionStart = $script:LogBox.Text.Length
        $script:LogBox.ScrollToCaret()
        $size = 0
        try { $size = (New-Object System.IO.FileInfo($script:LogPath)).Length } catch { $size = 0 }
        $script:LogStatus.Text = '最后 ' + $clean.Count + ' 行 / 文件 ' +
            [math]::Round($size / 1KB, 1) + ' KB · 刷新于 ' + (Get-Date -Format 'HH:mm:ss')
    }

    [void](New-ThemeButton $win 20 516 150 32 '刷新' 'accent' $loadLog)
    [void](New-ThemeButton $win 180 516 150 32 '打开所在文件夹' 'ghost' {
        try {
            $folder = Split-Path -Parent $script:LogPath
            if (Test-Path -LiteralPath $folder) { Start-Process 'explorer.exe' $folder }
        } catch { }
    })
    $script:LogAuto = New-Object System.Windows.Forms.CheckBox
    $script:LogAuto.SetBounds(346, 522, 150, 20)
    $script:LogAuto.Text = '每 3 秒自动刷新'
    $script:LogAuto.Checked = $true
    $script:LogAuto.Font = (New-ThemeFont 9)
    $script:LogAuto.ForeColor = (Get-ThemeColor 'Text')
    $script:LogAuto.BackColor = [System.Drawing.Color]::Transparent
    $script:LogAuto.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
    $win.Controls.Add($script:LogAuto)
    [void](New-ThemeButton $win 630 516 150 32 '关闭' 'ghost' { $script:LogBox.FindForm().Close() })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.Add_Tick({ if ($script:LogAuto.Checked) { & $script:LogLoader } })
    $script:LogLoader = $loadLog

    & $loadLog
    $win.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })
    $timer.Start()
    if (-not $script:NoShow) { [void]$win.ShowDialog() }
    $win.Dispose()
}

# -----------------------------------------------------------------------------
# QQ 号输入小窗（主题化，不用 InputBox）
# -----------------------------------------------------------------------------

function Show-UinDialog {
    # 返回值用哨兵区分:「取消」返回 $null,「确认」返回输入内容(可能是 ''）。
    # 两者不能用同一个真值判断合并,否则"留空确认"会被当成"取消"。
    # napcat 后端:Configure-OneBot 写 per-uin 的 onebot11_<uin>.json,QQ 号必填,
    # 空输入仍视为无效、留在弹窗里重新输入。
    # snowluma 后端:Configure-OneBot 写的是全局 onebot.json,对所有登录账号
    # 生效,$Uin 只是"传了就记进 QQ_UIN 备查",可以留空确认——早前强制纯数字、
    # 不填没有出口,会把"改完端口想重新配置、但还没扫码登录过"的用户卡死。
    $script:UinValue = $null
    $script:UinConfirmed = $false
    $script:UinRequired = -not (Test-SnowLuma)

    $title = '对接 AstrBot'
    $labelText = '请输入机器人 QQ 号（登录 NapCat 的那个号）：'
    $hintText = 'OneBot token 会自动生成，无需手动填写。'
    if (-not $script:UinRequired) {
        $title = '配置 OneBot 对接'
        $labelText = '机器人 QQ 号（可选，仅作记录，留空也能对接）：'
        $hintText = '可留空；仅作记录，全局配置对所有已登录账号生效。'
    }
    $dlg = New-ThemeWindow $title 400 216
    [void](New-ThemeLabel $dlg 24 60 352 20 $labelText 9)
    $existing = Get-Cfg 'QQ_UIN'
    $script:UinBox = New-ThemeTextBox $dlg 24 88 352 $existing
    $script:UinHint = New-ThemeLabel $dlg 24 118 352 20 $hintText 8.5 -ColorName 'TextDim'

    [void](New-ThemeButton $dlg 24 152 170 34 '开始对接' 'primary' {
        $text = ''
        try { $text = ([string]$script:UinBox.Text).Trim() } catch { $text = '' }
        $ok = $false
        if ($text -match '^\d+$') { $ok = $true }
        elseif ($text -eq '' -and -not $script:UinRequired) { $ok = $true }
        if ($ok) {
            $script:UinValue = $text
            $script:UinConfirmed = $true
            $script:UinBox.FindForm().Close()
        } else {
            if ($script:UinRequired) {
                $script:UinHint.Text = 'QQ 号必须是纯数字，请重新输入。'
            } else {
                $script:UinHint.Text = 'QQ 号必须是纯数字，或留空。'
            }
            $script:UinHint.ForeColor = (Get-ThemeColor 'Bad')
        }
    })
    [void](New-ThemeButton $dlg 206 152 170 34 '取消' 'ghost' {
        $script:UinValue = $null
        $script:UinConfirmed = $false
        $script:UinBox.FindForm().Close()
    })

    if (-not $script:NoShow) { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
    if (-not $script:UinConfirmed) { return $null }
    return $script:UinValue
}

# -----------------------------------------------------------------------------
# 登录信息窗口:展示两个 WebUI 的地址/账号/密码/token,支持一键复制
# -----------------------------------------------------------------------------

function Add-CredRow {
    param($Parent, [int]$Y, [string]$Label, [string]$Value, [bool]$CanCopy)
    [void](New-ThemeLabel $Parent 20 $Y 92 20 $Label 9 -ColorName 'TextDim')
    $box = New-Object System.Windows.Forms.TextBox
    $box.SetBounds(116, ($Y - 2), 300, 24)
    $box.Text = $Value
    $box.ReadOnly = $true
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $box.BackColor = [System.Drawing.Color]::FromArgb(28, 20, 52)
    $box.ForeColor = (Get-ThemeColor 'Text')
    $box.Font = (New-ThemeFont 9)
    $Parent.Controls.Add($box)
    if ($CanCopy) {
        [void](New-ThemeButton $Parent 424 ($Y - 2) 60 24 '复制' 'ghost' {
            try { [System.Windows.Forms.Clipboard]::SetText($box.Text) } catch { }
        }.GetNewClosure())
    }
}

function Show-ResetAstrbotDialog {
    $dlg = New-ThemeWindow '重置 AstrBot 密码' 420 320
    [void](New-ThemeLabel $dlg 24 58 372 20 '用户名(默认 astrbot)' 9 -ColorName 'TextDim')
    $boxUser = New-ThemeTextBox $dlg 24 80 372 'astrbot'
    [void](New-ThemeLabel $dlg 24 112 372 20 '新密码' 9 -ColorName 'TextDim')
    $boxPass = New-ThemeTextBox $dlg 24 134 372 ''
    $boxPass.PasswordChar = [char]0x25CF
    [void](New-ThemeLabel $dlg 24 166 372 20 '再输一次' 9 -ColorName 'TextDim')
    $boxPass2 = New-ThemeTextBox $dlg 24 188 372 ''
    $boxPass2.PasswordChar = [char]0x25CF
    $hint = New-ThemeLabel $dlg 24 218 372 20 '重置后会重启 AstrBot 使新密码生效。' 8.5 -ColorName 'TextDim'

    [void](New-ThemeButton $dlg 24 254 180 36 '确认重置' 'primary' {
        $u = ([string]$boxUser.Text).Trim()
        $p = [string]$boxPass.Text
        $p2 = [string]$boxPass2.Text
        if (-not $p) { $hint.Text = '新密码不能为空。'; $hint.ForeColor = (Get-ThemeColor 'Bad'); return }
        if ($p -ne $p2) { $hint.Text = '两次输入的密码不一致。'; $hint.ForeColor = (Get-ThemeColor 'Bad'); return }
        $tmp = Join-Path $env:TEMP ('nbot-pass-' + [Guid]::NewGuid().ToString('N') + '.txt')
        try {
            [IO.File]::WriteAllText($tmp, ($u + "`r`n" + $p), (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            $hint.Text = '写入临时文件失败。'; $hint.ForeColor = (Get-ThemeColor 'Bad'); return
        }
        Start-ConsoleCommand 'reset-astrbot' ('"' + $tmp + '"')
        $boxUser.FindForm().Close()
    }.GetNewClosure())
    [void](New-ThemeButton $dlg 216 254 180 36 '取消' 'ghost' { $boxUser.FindForm().Close() }.GetNewClosure())

    if (-not $script:NoShow) { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
}

function Show-ResetNapcatDialog {
    $dlg = New-ThemeWindow '重置 NapCat Token' 420 240
    [void](New-ThemeLabel $dlg 24 60 372 20 '新 Token(留空=随机生成 16 位)' 9 -ColorName 'TextDim')
    $box = New-ThemeTextBox $dlg 24 84 372 ''
    $hint = New-ThemeLabel $dlg 24 118 372 20 '重置后会重启 NapCat 使新 Token 生效。' 8.5 -ColorName 'TextDim'
    [void](New-ThemeButton $dlg 24 160 180 36 '确认重置' 'primary' {
        $t = ([string]$box.Text).Trim()
        Start-ConsoleCommand 'reset-napcat' $t
        $box.FindForm().Close()
    }.GetNewClosure())
    [void](New-ThemeButton $dlg 216 160 180 36 '取消' 'ghost' { $box.FindForm().Close() }.GetNewClosure())
    if (-not $script:NoShow) { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
}

function Show-ResetSnowlumaDialog {
    # SnowLuma 的 WebUI 登录是「admin + 密码」,密码哈希存储改不回明文;
    # 重置 = 删凭据文件重启,SnowLuma 自己生成新的随机初始密码并写进日志。
    $dlg = New-ThemeWindow '重置 SnowLuma 密码' 420 240
    [void](New-ThemeLabel $dlg 24 60 372 40 ('重置后 SnowLuma 会重启,并生成一个新的随机初始密码,' +
        '结果窗口和「登录信息」里都能看到。') 9 -ColorName 'TextDim')
    $hint = New-ThemeLabel $dlg 24 108 372 20 '当前密码(包括你自己改过的)将立即失效。' 8.5 -ColorName 'TextDim'
    [void](New-ThemeButton $dlg 24 160 180 36 '确认重置' 'primary' {
        Start-ConsoleCommand 'reset-snowluma' ''
        $hint.FindForm().Close()
    }.GetNewClosure())
    [void](New-ThemeButton $dlg 216 160 180 36 '取消' 'ghost' { $hint.FindForm().Close() }.GetNewClosure())
    if (-not $script:NoShow) { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
}

function Show-CredWindow {
    if (Test-SnowLuma) {
        # SnowLuma 后端:两侧的密码都是哈希存储:AstrBot 改过密码后无法回显;
        # SnowLuma 的初始密码只在日志里出现,且 mustChangePassword 翻 false 后
        # 同样无法回显。所以这里只展示「当前确实有效」的信息,失效的初始密码
        # 不摆出来误导人。
        $cred = Get-AstrbotCred
        $slCred = Get-SnowlumaCred
        $aPort = Get-AstrPort

        $dlg = New-ThemeWindow 'nbot 登录信息' 540 480
        [void](New-ThemeLabel $dlg 20 56 500 18 'SnowLuma WebUI（密码为哈希存储，只有未改密时才能看到初始密码）' 9.5 -Bold -ColorName 'Pink')
        Add-CredRow $dlg 84 '地址' (Get-BotWebuiUrl) $true
        Add-CredRow $dlg 114 '账号' $slCred['user'] $true
        $slNote = 'SnowLuma 密码为哈希存储,已改过密码后无法回显。忘记密码就点下面「重置 SnowLuma 密码」重新生成。'
        if ($slCred['found']) {
            $slNote = 'SnowLuma 初始密码(未改密前每次重启都会换一个新的): ' + $slCred['pass'] + ' —— 登录后请尽快修改;忘记可点下面重置。'
        }
        [void](New-ThemeLabel $dlg 20 144 500 34 $slNote 8.5 -ColorName 'TextDim')

        [void](New-ThemeLabel $dlg 20 192 500 18 'AstrBot 管理页' 9.5 -Bold -ColorName 'Pink')
        Add-CredRow $dlg 220 '地址' ('http://127.0.0.1:' + $aPort + '/') $true
        Add-CredRow $dlg 250 '账号' $cred['user'] $true
        $astrNote = 'AstrBot 密码为哈希存储,已改过密码后无法回显。忘记密码就点下面「重置 AstrBot 密码」设个新的。'
        if ($cred['found']) {
            $astrNote = 'AstrBot 初始密码(尚未改过,仅首次登录前有效): ' + $cred['pass'] + ' —— 登录后请改;忘记可点下面重置。'
        }
        [void](New-ThemeLabel $dlg 20 280 500 34 $astrNote 8.5 -ColorName 'TextDim')

        # 重置行:忘记密码就在这里改
        [void](New-ThemeButton $dlg 20 328 244 34 '重置 SnowLuma 密码' 'accent' { Show-ResetSnowlumaDialog })
        [void](New-ThemeButton $dlg 276 328 244 34 '重置 AstrBot 密码' 'accent' { Show-ResetAstrbotDialog })

        [void](New-ThemeButton $dlg 20 384 150 34 '打开 SnowLuma' 'primary' { Start-Process (Get-BotWebuiUrl) })
        [void](New-ThemeButton $dlg 184 384 150 34 '打开 AstrBot' 'accent' { Start-Process ('http://127.0.0.1:' + (Get-AstrPort) + '/') })
        [void](New-ThemeButton $dlg 356 384 150 34 '关闭' 'ghost' { $dlg.Close() }.GetNewClosure())
    } else {
        # NapCat 后端:只展示「长期可查」的真实凭据:NapCat WebUI token 明文存
        # webui.json,持久有效;AstrBot 密码是哈希存储,首次改密后无法还原,所以
        # 这里只给地址+账号+重置提示,不摆一个可能已失效的初始密码误导人。
        $cred = Get-AstrbotCred
        $token = Get-NapcatToken
        $aPort = Get-AstrPort

        $dlg = New-ThemeWindow 'nbot 登录信息' 540 440
        [void](New-ThemeLabel $dlg 20 56 500 18 'NapCat WebUI（Token 长期有效,可随时用这里的值登录）' 9.5 -Bold -ColorName 'Pink')
        Add-CredRow $dlg 84 '地址' (Get-BotWebuiUrl) $true
        $tok = $token
        if (-not $tok) { $tok = '(未找到 webui.json,可能尚未安装 NapCat)' }
        Add-CredRow $dlg 114 'Token' $tok ($null -ne $token)

        [void](New-ThemeLabel $dlg 20 156 500 18 'AstrBot 管理页' 9.5 -Bold -ColorName 'Pink')
        Add-CredRow $dlg 184 '地址' ('http://127.0.0.1:' + $aPort + '/') $true
        Add-CredRow $dlg 214 '账号' $cred['user'] $true
        $astrNote = 'AstrBot 密码为哈希存储,已改过密码后无法回显。忘记密码就点下面「重置 AstrBot 密码」设个新的。'
        if ($cred['found']) {
            $astrNote = 'AstrBot 初始密码(尚未改过,仅首次登录前有效): ' + $cred['pass'] + ' —— 登录后请改;忘记可点下面重置。'
        }
        [void](New-ThemeLabel $dlg 20 244 500 34 $astrNote 8.5 -ColorName 'TextDim')

        # 重置行:忘记密码/token 就在这里改
        [void](New-ThemeButton $dlg 20 288 244 34 '重置 AstrBot 密码' 'accent' { Show-ResetAstrbotDialog })
        [void](New-ThemeButton $dlg 276 288 244 34 '重置 NapCat Token' 'accent' { Show-ResetNapcatDialog })

        [void](New-ThemeButton $dlg 20 344 150 34 '打开 AstrBot' 'primary' { Start-Process ('http://127.0.0.1:' + (Get-AstrPort) + '/') })
        [void](New-ThemeButton $dlg 184 344 150 34 '打开 NapCat' 'accent' { Start-Process (Get-BotWebuiUrl) })
        [void](New-ThemeButton $dlg 356 344 150 34 '关闭' 'ghost' { $dlg.Close() }.GetNewClosure())
    }

    if (-not $script:NoShow) { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
}

# -----------------------------------------------------------------------------
# 卸载对话框:必做项固定说明,数据删除逐项勾选(默认全保留)
# -----------------------------------------------------------------------------

function New-UnCheckBox {
    param($Parent, [int]$X, [int]$Y, [int]$W, [string]$Text)
    $box = New-Object System.Windows.Forms.CheckBox
    $box.SetBounds($X, $Y, $W, 22)
    $box.Text = $Text
    $box.Checked = $false
    $box.Font = (New-ThemeFont 9)
    $box.ForeColor = (Get-ThemeColor 'Text')
    $box.BackColor = [System.Drawing.Color]::Transparent
    $box.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
    $Parent.Controls.Add($box)
    return $box
}

function Show-UninstallDialog {
    $dlg = New-ThemeWindow '卸载 nbot' 480 430

    [void](New-ThemeLabel $dlg 24 54 432 36 ('必做:移除计划任务、nbot 命令、桌面快捷方式与托盘自启。' +
        'QQ 程序本体不会被卸载。') 9 -ColorName 'TextDim')

    $card = New-ThemeCard $dlg 20 96 440 176 '同时删除哪些数据?(默认全部保留)'
    $aRoot = Get-Cfg 'ASTRBOT_ROOT'
    $nRoot = Get-BotRoot
    $botName = Get-BotName
    $script:UnChkAstr = New-UnCheckBox $card 16 34 408 ('AstrBot 数据目录 ' + $aRoot)
    [void](New-ThemeLabel $card 32 56 392 16 ('机器人配置、插件、聊天数据、' + $botName + ' 载荷都在这里') 8 -ColorName 'TextDim')
    $script:UnChkNap = New-UnCheckBox $card 16 78 408 ($botName + ' 数据目录 ' + $nRoot)
    [void](New-ThemeLabel $card 32 100 392 16 'OneBot / WebUI 配置与日志(QQ 登录态不在这里,不受影响)' 8 -ColorName 'TextDim')
    $script:UnChkProg = New-UnCheckBox $card 16 122 408 '安装器与运行数据 %ProgramData%\nbot'
    [void](New-ThemeLabel $card 32 144 392 16 '控制脚本、看门狗日志、状态记录;删除后本面板随之失效' 8 -ColorName 'TextDim')

    $script:UnHint = New-ThemeLabel $dlg 24 282 432 34 '不勾选 = 只解除托管,数据原样保留,以后重装可直接继续用。' 8.5 -ColorName 'TextDim'

    [void](New-ThemeButton $dlg 24 330 200 36 '开始卸载' 'danger' {
        $flags = @()
        if ($script:UnChkAstr.Checked) { $flags += 'data' }
        if ($script:UnChkNap.Checked) { $flags += (Get-BotMarker) }
        if ($script:UnChkProg.Checked) { $flags += 'programdata' }
        $flagText = ($flags -join ',')
        $summary = '将执行卸载:移除任务/命令/快捷方式/托盘自启'
        if ($flags.Count -gt 0) { $summary = $summary + ',并删除所勾选的 ' + $flags.Count + ' 项数据' }
        $summary = $summary + '。确定?'
        $answer = [System.Windows.Forms.MessageBox]::Show($summary, 'nbot',
            [System.Windows.Forms.MessageBoxButtons]::YesNo)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        Start-ConsoleCommand 'uninstall-quiet' $flagText
        $script:UnChkAstr.FindForm().Close()
        # 卸载会停掉后台并可能删除面板文件,面板真正退出(不进托盘)
        $script:ReallyExit = $true
        $script:MainForm.Close()
    })
    [void](New-ThemeButton $dlg 256 330 200 36 '取消' 'ghost' {
        $script:UnChkAstr.FindForm().Close()
    })

    if (-not $script:NoShow) { [void]$dlg.ShowDialog() }
    $dlg.Dispose()
}

# -----------------------------------------------------------------------------
# 扫码登录窗口
# -----------------------------------------------------------------------------

function Update-QrImage {
    param([bool]$Force)
    # 先看是否已经登录成功——成功了就没必要再显示二维码,自动关窗。
    if (Test-QqLoggedIn) {
        $script:QrLoggedIn = $true
        $script:QrTip.Text = '登录成功!窗口即将自动关闭。'
        $script:QrTip.ForeColor = (Get-ThemeColor 'Ok')
        # 只有「已经显示出来」的窗口才能 Close:对尚未 ShowDialog 的窗体调
        # Close() 会直接释放它,随后 ShowDialog 就抛「无法访问已释放的对象」。
        if ($null -ne $script:QrForm -and $script:QrForm.Visible) {
            try { $script:QrForm.Close() } catch { }
        }
        return
    }
    $path = Get-QrCodePath
    if (-not $path) {
        $script:QrStamp = ''
        $script:QrTip.Text = '暂未生成二维码；若已登录则无需扫码。'
        $script:QrTip.ForeColor = (Get-ThemeColor 'Warn')
        return
    }
    $stamp = ''
    try {
        $info = New-Object System.IO.FileInfo($path)
        $stamp = $info.LastWriteTimeUtc.Ticks.ToString() + '-' + $info.Length.ToString()
    } catch {
        $stamp = ''
    }
    if ((-not $Force) -and $stamp -ne '' -and $stamp -eq $script:QrStamp) { return }
    try {
        # 用内存流加载，避免 PictureBox 锁定文件导致 NapCat 无法覆盖二维码。
        $bytes = [IO.File]::ReadAllBytes($path)
        $stream = New-Object System.IO.MemoryStream(@(,$bytes))
        $image = [System.Drawing.Image]::FromStream($stream)
        $previous = $script:QrPic.Image
        $script:QrPic.Image = $image
        if ($null -ne $previous) { try { $previous.Dispose() } catch { } }
        $script:QrStamp = $stamp
        $script:QrTip.Text = '用手机 QQ 扫描上方二维码。过期后 NapCat 会自动换新码，本窗口每 3 秒自动同步，无需手动操作；若几分钟都没出新码，再点「重启 NapCat」。'
        $script:QrTip.ForeColor = (Get-ThemeColor 'TextDim')
    } catch {
        $script:QrTip.Text = '二维码读取失败：' + $_.Exception.Message
        $script:QrTip.ForeColor = (Get-ThemeColor 'Bad')
    }
}

function Update-QrStatus {
    # SnowLuma 不提供网页二维码图片,这里只做「登录成功了没」的轮询：
    # 成功了就没必要再等,自动关窗。
    if (-not (Test-QqLoggedIn)) { return }
    $script:QrLoggedIn = $true
    $script:QrTip.Text = '登录成功!窗口即将自动关闭。'
    $script:QrTip.ForeColor = (Get-ThemeColor 'Ok')
    # 只有「已经显示出来」的窗口才能 Close:对尚未 ShowDialog 的窗体调
    # Close() 会直接释放它,随后 ShowDialog 就抛「无法访问已释放的对象」。
    if ($null -ne $script:QrForm -and $script:QrForm.Visible) {
        try { $script:QrForm.Close() } catch { }
    }
}

function Test-QqLoggedIn {
    # 判断 QQ 是否已登录:登录成功后后端会开 OneBot HTTP 端口(未登录时
    # 不监听),这是最干净的信号;端口没配就退回看日志里的登录成功标记
    # (两个后端的日志格式不同,按后端分支)。
    $httpPort = Get-Cfg 'ONEBOT_HTTP_PORT'
    if ($httpPort) {
        if (Test-TcpOk '127.0.0.1' $httpPort 400) { return $true }
    }
    if (Test-SnowLuma) {
        try {
            # SnowLuma 的 OneBot 适配器是按账号(per-uin)实例化的,没有账号
            # 登录时不会有任何 [OneBot] 行,所以下面两条一旦出现即可确认已登录
            # (实测到的真实日志格式)。
            $log = Join-Path (Get-Cfg 'SL_ROOT') 'logs\snowluma.log'
            $lines = Get-TailLines $log 40
            foreach ($line in $lines) {
                if ($line -match '\[Hook\] login detected') { return $true }
                if ($line -match 'session started: UIN=\d+') { return $true }
            }
        } catch { }
        return $false
    }
    try {
        $log = Join-Path (Get-Cfg 'NAPCAT_ROOT') 'logs\napcat.log'
        $lines = Get-TailLines $log 40
        foreach ($line in $lines) {
            # 登录后 NapCat 会开始打印「<昵称> | 接收 <- ...」这类消息流水
            if ($line -match '\|\s*(接收|发送)\s*(<-|->)') { return $true }
            if ($line -match '已登录,无法重复登录') { return $true }
        }
    } catch { }
    return $false
}

function Show-QrWindowNapcat {
    # NapCat 后端:展示 NapCat 生成的二维码图片,3 秒一轮询自动换新码。
    $script:QrStamp = ''
    $script:QrLoggedIn = $false
    $qrForm = New-ThemeWindow '扫码登录 QQ' 400 560
    $script:QrForm = $qrForm

    $frame = New-ThemeCard $qrForm 20 56 360 376 ''

    $script:QrPic = New-Object System.Windows.Forms.PictureBox
    $script:QrPic.SetBounds(20, 28, 320, 320)
    $script:QrPic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $script:QrPic.BackColor = [System.Drawing.Color]::FromArgb(20, 14, 38)
    $frame.Controls.Add($script:QrPic)

    $script:QrTip = New-ThemeLabel $qrForm 24 438 352 52 '正在读取二维码...' 8.5 -ColorName 'TextDim'

    [void](New-ThemeButton $qrForm 24 494 170 34 '刷新二维码' 'accent' {
        Update-QrImage $true
    })
    [void](New-ThemeButton $qrForm 206 494 170 34 '重启 NapCat' 'primary' {
        & cmd.exe /c 'schtasks /end /tn "\NBot\NapCat" >nul 2>nul'
        & cmd.exe /c 'taskkill /im QQ.exe /t /f >nul 2>nul'
        & cmd.exe /c 'schtasks /run /tn "\NBot\NapCat" >nul 2>nul'
        $script:QrStamp = ''
        $script:QrTip.Text = '已请求重启 NapCat，请等待约 20 秒后二维码会自动出现。'
        $script:QrTip.ForeColor = (Get-ThemeColor 'Warn')
    })

    $script:QrTimer = New-Object System.Windows.Forms.Timer
    $script:QrTimer.Interval = 3000
    $script:QrTimer.Add_Tick({ Update-QrImage $false })

    $qrForm.Add_FormClosed({
        if ($null -ne $script:QrTimer) {
            $script:QrTimer.Stop()
            $script:QrTimer.Dispose()
            $script:QrTimer = $null
        }
        if ($null -ne $script:QrPic -and $null -ne $script:QrPic.Image) {
            $image = $script:QrPic.Image
            $script:QrPic.Image = $null
            try { $image.Dispose() } catch { }
        }
        $script:QrForm = $null
        if ($script:QrLoggedIn) {
            Show-Toast 'QQ 已登录成功。下一步:点「对接 AstrBot」填机器人 QQ 号完成对接。'
        }
    })

    Update-QrImage $true
    if (-not $script:NoShow) {
        $script:QrTimer.Start()
        [void]$qrForm.ShowDialog()
    }
    $qrForm.Dispose()
}

function Show-QrWindowSnowluma {
    # SnowLuma 不像 NapCat 那样在 WebUI 里出二维码图片：它只负责注入 QQ,
    # 扫码/确认登录全程都在 QQ 客户端窗口里完成。这里只负责把 QQ 窗口带到
    # 前台(qqlogin 命令做这件事),然后轮询登录结果。
    $script:QrLoggedIn = $false
    $qrForm = New-ThemeWindow 'QQ 扫码登录' 400 260
    $script:QrForm = $qrForm

    $script:QrTip = New-ThemeLabel $qrForm 24 56 352 100 ('SnowLuma 不提供网页二维码,扫码和确认都在 QQ 客户端窗口里完成。' +
        '点击下方按钮把 QQ 窗口带到前台;本窗口每 3 秒自动检测一次登录结果,' +
        '成功后会自动关闭。') 9 -ColorName 'TextDim'

    [void](New-ThemeButton $qrForm 24 172 170 34 '打开 QQ 登录' 'primary' {
        Start-ConsoleCommand 'qqlogin'
    })
    [void](New-ThemeButton $qrForm 206 172 170 34 '关闭' 'ghost' { $qrForm.Close() }.GetNewClosure())

    $script:QrTimer = New-Object System.Windows.Forms.Timer
    $script:QrTimer.Interval = 3000
    $script:QrTimer.Add_Tick({ Update-QrStatus })

    $qrForm.Add_FormClosed({
        if ($null -ne $script:QrTimer) {
            $script:QrTimer.Stop()
            $script:QrTimer.Dispose()
            $script:QrTimer = $null
        }
        $script:QrForm = $null
        if ($script:QrLoggedIn) {
            Show-Toast 'QQ 已登录成功。下一步:点「配置 OneBot 对接」即可完成对接(QQ 号可留空)。'
        }
    })

    if (-not $script:NoShow) {
        $script:QrTimer.Start()
        [void]$qrForm.ShowDialog()
    }
    $qrForm.Dispose()
}

function Show-QrWindow {
    # 已经登录就别开窗了:既省事,也避免「窗口没显示就被关掉」的释放问题。
    if (Test-QqLoggedIn) {
        Show-Toast 'QQ 已经登录,无需扫码。要换账号请先在 QQ 里退出登录。'
        return
    }
    if (Test-SnowLuma) {
        Show-QrWindowSnowluma
    } else {
        Show-QrWindowNapcat
    }
}

# -----------------------------------------------------------------------------
# 状态刷新
# -----------------------------------------------------------------------------

function Update-AutostartButton {
    if ($null -eq $script:BtnAuto) { return }
    $info = $script:BtnAuto.Tag
    if (Test-AutostartDisabled) {
        $script:BtnAuto.Text = '开启开机自启'
        $info['kind'] = 'accent'
    } else {
        $script:BtnAuto.Text = '关闭开机自启'
        $info['kind'] = 'ghost'
    }
    $script:BtnAuto.Tag = $info
    $script:BtnAuto.Invalidate()
}

function Update-Status {
    $astrPort = Get-AstrPort
    $napPort = Get-BotWebuiPort
    $running = $false

    # 本机端口:开着就立刻回,没开也几乎立刻拒绝;超时给 200ms 足够,
    # 给太长会让 UI 线程在服务停着时每轮都卡住。
    if (Test-TcpOk '127.0.0.1' $astrPort 200) {
        Set-ThemeStatusRow $script:RowAstr ('运行中 (端口 ' + $astrPort + ')') 'Ok'
        $running = $true
    } else {
        Set-ThemeStatusRow $script:RowAstr '未运行' 'Bad'
    }

    if (Test-TcpOk '127.0.0.1' $napPort 200) {
        Set-ThemeStatusRow $script:RowNap ('运行中 (端口 ' + $napPort + ')') 'Ok'
        $running = $true
    } else {
        Set-ThemeStatusRow $script:RowNap '未运行' 'Bad'
    }

    # QQ 行:napcat 模型下 QQ 是被拉起的孙进程,「QQ 在跑」约等于「这套在跑」,
    # 计入 $running;但 SnowLuma 是注入型的,QQ 是用户自己的聊天软件,跟 nbot
    # 死活无关——用户平时开着 QQ 聊天、两个服务全停时,不能让「启动全部/停止
    # 全部」按钮的高亮被 QQ 这一行带偏,所以 snowluma 下只展示状态,不参与判定。
    $qq = Get-Process -Name QQ -ErrorAction SilentlyContinue
    if ($null -ne $qq) {
        Set-ThemeStatusRow $script:RowQQ '运行中' 'Ok'
        if (-not (Test-SnowLuma)) { $running = $true }
    } else {
        Set-ThemeStatusRow $script:RowQQ '未运行' 'Bad'
    }
    $script:AnyRunning = $running

    $tasksOk = (Test-TaskExists 'AstrBot') -and (Test-TaskExists (Get-BotName)) -and (Test-TaskExists 'Watchdog')
    $autoOff = Test-AutostartDisabled
    if ($tasksOk -and $autoOff) {
        Set-ThemeStatusRow $script:RowTask '自启已关闭' 'Warn'
    } elseif ($tasksOk) {
        Set-ThemeStatusRow $script:RowTask '守护中 (3/3)' 'Ok'
    } else {
        Set-ThemeStatusRow $script:RowTask '不完整，请点修复' 'Bad'
    }

    $script:LblTime.Text = '刷新于 ' + (Get-Date -Format 'HH:mm:ss')
    Update-AutostartButton
    Update-ServiceButtons
}

# -----------------------------------------------------------------------------
# 主窗体
# -----------------------------------------------------------------------------

$script:MainForm = New-ThemeWindow 'nbot 控制面板' 640 600 -WithMinimize

# --- 卡片 1：运行状态 --------------------------------------------------------

$cardStatus = New-ThemeCard $script:MainForm 16 52 608 128 '运行状态'
$script:RowAstr = New-ThemeStatusRow $cardStatus 16 34 78 'AstrBot'
$script:RowNap = New-ThemeStatusRow $cardStatus 16 56 78 (Get-BotName)
$script:RowQQ = New-ThemeStatusRow $cardStatus 16 78 78 'QQ'
$script:RowTask = New-ThemeStatusRow $cardStatus 16 100 78 '计划任务'
$script:LblTime = New-ThemeLabel $cardStatus 420 102 174 16 '刷新于 --:--:--' 8 -ColorName 'TextDim'
$script:LblTime.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight

# --- 卡片 2：快捷操作 --------------------------------------------------------

$cardQuick = New-ThemeCard $script:MainForm 16 188 608 116 '快捷操作'
[void](New-ThemeButton $cardQuick 14 36 186 32 '一键安装/更新' 'primary' {
    Start-ConsoleCommand 'install-all'
})
[void](New-ThemeButton $cardQuick 211 36 186 32 'QQ 扫码登录' 'primary' {
    Show-QrWindow
})
# napcat 下对接必填 QQ 号,按钮沿用「对接 AstrBot」;snowluma 写全局配置,
# QQ 号可留空,按钮叫「配置 OneBot 对接」更贴切。
$script:OnebotBtnText = '对接 AstrBot'
if (Test-SnowLuma) { $script:OnebotBtnText = '配置 OneBot 对接' }
[void](New-ThemeButton $cardQuick 408 36 186 32 $script:OnebotBtnText 'accent' {
    $uin = Show-UinDialog
    # $null = 用户取消;'' = 确认对接但留空 QQ 号——两者不能用同一个真值
    # 判断合并,否则"留空确认"会被当成"取消"处理,按钮变空操作。
    if ($null -ne $uin) { Start-ConsoleCommand 'configure-onebot' $uin }
})
[void](New-ThemeButton $cardQuick 14 74 186 32 'AstrBot 管理页' 'ghost' {
    Start-Process ('http://127.0.0.1:' + (Get-AstrPort) + '/')
})
[void](New-ThemeButton $cardQuick 211 74 186 32 ((Get-BotName) + ' 管理页') 'ghost' {
    Start-Process (Get-BotWebuiUrl)
})
[void](New-ThemeButton $cardQuick 408 74 186 32 '登录信息' 'accent' {
    Show-CredWindow
})

# --- 卡片 3：服务与守护 ------------------------------------------------------

$cardSvc = New-ThemeCard $script:MainForm 16 312 608 116 '服务与守护'
# 启动/停止:按当前可做的动作高亮——服务在跑时「停止全部」亮,都停了则
# 「启动全部」亮,另一个变描边(仍可点)。高亮由 Update-ServiceButtons 维护。
$script:BtnStart = New-ThemeButton $cardSvc 14 36 186 32 '启动全部' 'primary' {
    Start-ConsoleCommand 'start' '' -Quick
}
$script:BtnStop = New-ThemeButton $cardSvc 211 36 186 32 '停止全部' 'ghost' {
    Start-ConsoleCommand 'stop' '' -Quick
}
[void](New-ThemeButton $cardSvc 408 36 186 32 '修复' 'accent' {
    Start-ConsoleCommand 'repair'
})
$script:BtnAuto = New-ThemeButton $cardSvc 14 74 186 32 '关闭开机自启' 'ghost' {
    if (Test-AutostartDisabled) {
        Start-ConsoleCommand 'autostart-on' '' -Quick
    } else {
        Start-ConsoleCommand 'autostart-off' '' -Quick
    }
}
[void](New-ThemeButton $cardSvc 211 74 186 32 '单独重启 AstrBot' 'ghost' {
    # 任务链是 wscript -> bat -> 解释器,schtasks /End 收不到孙进程,必须走
    # install-core.ps1 的 restart-astrbot(它调 Restart-BotTask,按命令行
    # 精确终止孙进程)。这里不能自己复制一份进程终止逻辑——那需要 WMI
    # 命令行匹配,跑在 UI 线程上会卡顿(PITFALLS 记过这个坑)。
    Start-ConsoleCommand 'restart-astrbot' '' -Quick
})
[void](New-ThemeButton $cardSvc 408 74 186 32 ('单独重启 ' + (Get-BotName)) 'ghost' {
    Start-ConsoleCommand 'restart-bot' '' -Quick
})

function Set-ButtonKind {
    param($Button, [string]$Kind)
    if ($null -eq $Button) { return }
    $info = $Button.Tag
    if ($null -eq $info) { return }
    if ([string]$info['kind'] -eq $Kind) { return }
    $info['kind'] = $Kind
    $Button.Tag = $info
    $Button.Invalidate()
}

function Update-ServiceButtons {
    # $script:AnyRunning 由 Update-Status 根据端口/进程探测结果设置
    if ($script:AnyRunning) {
        Set-ButtonKind $script:BtnStart 'ghost'
        Set-ButtonKind $script:BtnStop 'primary'
    } else {
        Set-ButtonKind $script:BtnStart 'primary'
        Set-ButtonKind $script:BtnStop 'ghost'
    }
}

# --- 卡片 4：日志与维护 ------------------------------------------------------

$cardLog = New-ThemeCard $script:MainForm 16 436 608 116 '日志与维护'
[void](New-ThemeButton $cardLog 14 36 139 32 'AstrBot 日志' 'ghost' {
    Show-LogWindow 'AstrBot 日志' (Join-Path (Get-Cfg 'ASTRBOT_ROOT') 'logs\astrbot.log')
})
[void](New-ThemeButton $cardLog 161 36 139 32 ((Get-BotName) + ' 日志') 'ghost' {
    Show-LogWindow ((Get-BotName) + ' 日志') (Get-BotLogFile)
})
[void](New-ThemeButton $cardLog 308 36 139 32 '守护日志' 'ghost' {
    Show-LogWindow '守护日志' (Join-Path (Get-NBotLogDir) 'watchdog.log')
})
[void](New-ThemeButton $cardLog 455 36 139 32 '环境诊断' 'ghost' {
    Start-ConsoleCommand 'doctor'
})
[void](New-ThemeButton $cardLog 14 74 186 32 '安装/更新 AstrBot' 'ghost' {
    Start-ConsoleCommand 'install-astrbot'
})
[void](New-ThemeButton $cardLog 211 74 186 32 ('安装/更新 ' + (Get-BotName)) 'ghost' {
    Start-ConsoleCommand ('install-' + (Get-BotMarker))
})
[void](New-ThemeButton $cardLog 408 74 186 32 '卸载' 'danger' { Show-UninstallDialog })

# --- 底部：关闭行为(持久化)-------------------------------------------------

$script:ReallyExit = $false

function Get-CloseToTray {
    # 默认开(点 X 最小化到托盘)。state 目录有 panel.close-exits 标记 =
    # 用户取消了勾选,点 X 直接退出。
    return (-not (Test-Path -LiteralPath (Join-Path (Get-StateDir) 'panel.close-exits')))
}

function Set-CloseToTray {
    param([bool]$Enabled)
    $flag = Join-Path (Get-StateDir) 'panel.close-exits'
    try {
        if ($Enabled) {
            if (Test-Path -LiteralPath $flag) { Remove-Item -LiteralPath $flag -Force }
        } else {
            Write-TextFile $flag ''
        }
    } catch { }
}

$script:ChkCloseTray = New-Object System.Windows.Forms.CheckBox
$script:ChkCloseTray.SetBounds(20, 558, 380, 22)
$script:ChkCloseTray.Text = '点 X 关闭时最小化到托盘（不勾则直接退出）'
$script:ChkCloseTray.Checked = (Get-CloseToTray)
$script:ChkCloseTray.Font = (New-ThemeFont 8.5)
$script:ChkCloseTray.ForeColor = (Get-ThemeColor 'TextDim')
$script:ChkCloseTray.BackColor = [System.Drawing.Color]::Transparent
$script:ChkCloseTray.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
$script:ChkCloseTray.add_CheckedChanged({ Set-CloseToTray $script:ChkCloseTray.Checked })
$script:MainForm.Controls.Add($script:ChkCloseTray)

[void](New-ThemeLabel $script:MainForm 410 560 214 20 '后台服务不受面板开关影响。' 8.5 -ColorName 'TextDim')

# -----------------------------------------------------------------------------
# 托盘（常驻）
# -----------------------------------------------------------------------------

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
# NotifyIcon.Text 最长 63 字符，这里保持极短。
$script:Tray.Text = 'nbot'
# 主题猫头图标:优先随包的 nbot.ico,否则现场绘制。
# 不用 ExtractAssociatedIcon 从系统 dll 取图标——那样常常拿到一张空白纸。
try {
    $script:Tray.Icon = New-ThemeIcon
} catch {
    $script:Tray.Icon = [System.Drawing.SystemIcons]::Application
}

$script:RestorePanel = {
    $script:MainForm.Show()
    $script:MainForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $script:MainForm.ShowInTaskbar = $true
    [void]$script:MainForm.Activate()
}

$trayMenu = New-Object System.Windows.Forms.ContextMenu

$miShow = New-Object System.Windows.Forms.MenuItem
$miShow.Text = '显示面板'
$miShow.Add_Click($script:RestorePanel)
[void]$trayMenu.MenuItems.Add($miShow)

$miStart = New-Object System.Windows.Forms.MenuItem
$miStart.Text = '启动全部'
$miStart.Add_Click({ Start-ConsoleCommand 'start' })
[void]$trayMenu.MenuItems.Add($miStart)

$miStop = New-Object System.Windows.Forms.MenuItem
$miStop.Text = '停止全部'
$miStop.Add_Click({ Start-ConsoleCommand 'stop' })
[void]$trayMenu.MenuItems.Add($miStop)

$miQr = New-Object System.Windows.Forms.MenuItem
$miQr.Text = 'QQ 扫码登录'
$miQr.Add_Click({ Show-QrWindow })
[void]$trayMenu.MenuItems.Add($miQr)

$miAstrWeb = New-Object System.Windows.Forms.MenuItem
$miAstrWeb.Text = 'AstrBot 管理页'
$miAstrWeb.Add_Click({ Start-Process ('http://127.0.0.1:' + (Get-AstrPort) + '/') })
[void]$trayMenu.MenuItems.Add($miAstrWeb)

$miNapWeb = New-Object System.Windows.Forms.MenuItem
$miNapWeb.Text = (Get-BotName) + ' 管理页'
$miNapWeb.Add_Click({ Start-Process (Get-BotWebuiUrl) })
[void]$trayMenu.MenuItems.Add($miNapWeb)

$miSep = New-Object System.Windows.Forms.MenuItem
$miSep.Text = '-'
[void]$trayMenu.MenuItems.Add($miSep)

$script:MiTrayAuto = New-Object System.Windows.Forms.MenuItem
$script:MiTrayAuto.Text = '开机时常驻托盘: 关'
$script:MiTrayAuto.Add_Click({ Toggle-TrayAutostart })
[void]$trayMenu.MenuItems.Add($script:MiTrayAuto)

$miExit = New-Object System.Windows.Forms.MenuItem
$miExit.Text = '退出面板'
$miExit.Add_Click({ $script:ReallyExit = $true; $script:MainForm.Close() })
[void]$trayMenu.MenuItems.Add($miExit)

$trayMenu.Add_Popup({ Update-TrayMenuLabel })
$script:Tray.ContextMenu = $trayMenu
# 左键单击就唤出面板(右键仍然出菜单);双击也保留。
$script:Tray.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        & $script:RestorePanel
    }
})
$script:Tray.Add_DoubleClick($script:RestorePanel)
$script:Tray.Visible = (-not $script:NoShow)

# -----------------------------------------------------------------------------
# 事件与定时器
# -----------------------------------------------------------------------------

$script:MainForm.Add_Resize({
    if ($null -eq $script:Tray) { return }
    if ($script:MainForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $script:MainForm.Hide()
        $script:MainForm.ShowInTaskbar = $false
        if (-not $script:SuppressBalloon) {
            $script:Tray.ShowBalloonTip(1500, 'nbot', '面板已最小化到托盘',
                [System.Windows.Forms.ToolTipIcon]::Info)
        }
        $script:SuppressBalloon = $false
    }
})

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 5000
$script:Timer.Add_Tick({
    # 第二个实例留下的「现身」信号:删掉并把窗口唤出来
    try {
        $marker = Join-Path (Get-StateDir) 'panel.show-request'
        if (Test-Path -LiteralPath $marker) {
            Remove-Item -LiteralPath $marker -Force
            & $script:RestorePanel
        }
    } catch { }
    Update-Status
})

$script:MainForm.Add_Shown({
    Update-TrayMenuLabel
    Update-Status
    $script:Timer.Start()
    if ($script:TrayMode) {
        $script:SuppressBalloon = $true
        $script:MainForm.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
        $script:MainForm.Hide()
        $script:MainForm.ShowInTaskbar = $false
    }
})

$script:MainForm.Add_FormClosing({
    param($sender, $e)
    # 用户点 X / Alt+F4 关闭时:若勾了「最小化到托盘」且不是真退出请求,
    # 就取消关闭、收进托盘。托盘「退出面板」会先置 ReallyExit=$true。
    if ($script:ReallyExit) { return }
    $userClosing = ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing)
    if ($userClosing -and (Get-CloseToTray) -and ($null -ne $script:Tray)) {
        $e.Cancel = $true
        $script:MainForm.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
        $script:MainForm.Hide()
        $script:MainForm.ShowInTaskbar = $false
        if (-not $script:SuppressBalloon) {
            $script:Tray.ShowBalloonTip(1500, 'nbot', '面板已最小化到托盘,右键托盘图标可退出',
                [System.Windows.Forms.ToolTipIcon]::Info)
        }
        $script:SuppressBalloon = $false
    }
})

$script:MainForm.Add_FormClosed({
    if ($null -ne $script:Timer) {
        $script:Timer.Stop()
        $script:Timer.Dispose()
        $script:Timer = $null
    }
    if ($null -ne $script:Tray) {
        $script:Tray.Visible = $false
        $script:Tray.Dispose()
        $script:Tray = $null
    }
})

# -----------------------------------------------------------------------------
# 启动
# -----------------------------------------------------------------------------

if ($env:NBOT_GUI_SELFTEST -eq '1') {
    # 状态逻辑自检:直接跑 Update-Status(会真实调用 schtasks / 端口探测 /
    # 进程查询)。渲染测试抓不到这类「外部命令 stderr 在 EAP=Stop 下抛异常」
    # 的问题,必须单独在非提权环境里真跑一遍。
    try {
        Update-TrayMenuLabel
        Update-Status
        Update-Status
        # 逐个构建对话框:NOSHOW 下不会真的 ShowDialog,但会跑完窗体构建与
        # 初始数据加载(读日志/配置/探测登录),能抓到「窗体已释放」「空引用」
        # 这类只在真实调用时才暴露的问题。
        # 扫码窗不走 Show-QrWindow 派发:它在「已登录」时会直接 return,
        # 窗体构建代码就没被测到,这里必须直接构建具体后端的窗体。
        Show-CredWindow
        if (Test-SnowLuma) { Show-QrWindowSnowluma } else { Show-QrWindowNapcat }
        Show-UninstallDialog
        Show-ResetAstrbotDialog
        Show-ResetNapcatDialog
        Show-ResetSnowlumaDialog
        Show-LogWindow '自检日志' (Join-Path (Get-NBotLogDir) 'watchdog.log')
        # 双后端全覆盖:临时把 BOT_BACKEND 切成另一个值,把按后端分支的窗体
        # (扫码窗/凭据窗/重置窗/卸载窗)再构建一遍,保证两条分支的构建代码都
        # 被真实执行过;结束后恢复原值。
        $origBackend = [string]$script:Cfg['BOT_BACKEND']
        $otherBackend = 'snowluma'
        if (Test-SnowLuma) { $otherBackend = 'napcat' }
        $script:Cfg['BOT_BACKEND'] = $otherBackend
        try {
            Show-CredWindow
            if (Test-SnowLuma) { Show-QrWindowSnowluma } else { Show-QrWindowNapcat }
            Show-ResetNapcatDialog
            Show-ResetSnowlumaDialog
            Show-UninstallDialog
        } finally {
            $script:Cfg['BOT_BACKEND'] = $origBackend
        }
        Write-Host 'STATUS OK'
        exit 0
    } catch {
        Write-Host ('STATUS FAIL: ' + $_.Exception.Message)
        exit 1
    }
}

if ($env:NBOT_GUI_RENDERTEST -eq '1') {
    # 渲染自检:显示在屏幕外强制完整绘制一遍,报告 Paint 期错误后退出。
    if ($null -ne $script:Tray) { $script:Tray.Visible = $false }
    $script:MainForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $script:MainForm.Location = New-Object System.Drawing.Point(-4000, -4000)
    $script:MainForm.ShowInTaskbar = $false
    $script:MainForm.Show()
    for ($i = 0; $i -lt 6; $i++) {
        $script:MainForm.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 120
    }
    $paintErrors = Get-ThemePaintErrors
    Write-Host ('PAINT ERRORS: ' + $paintErrors.Count)
    foreach ($message in $paintErrors) { Write-Host ('  - ' + $message) }
    $script:MainForm.Close()
    if ($paintErrors.Count -gt 0) { exit 1 }
    exit 0
} elseif ($script:NoShow) {
    Write-Host ('GUI form built OK: ' + $script:MainForm.Text +
        ' / controls: ' + $script:MainForm.Controls.Count)
    $script:Timer.Dispose()
    $script:Tray.Dispose()
    $script:Tray = $null
    $script:MainForm.Dispose()
} else {
    [System.Windows.Forms.Application]::Run($script:MainForm)
}
