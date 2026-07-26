# =============================================================================
# nbot-installer-windows / wizard.ps1
# 二次元风格图形安装向导（WinForms + lib\theme.ps1 组件库）。
# 由 setup.bat 以管理员身份、-STA 模式启动；用户全程点鼠标即可完成安装。
# 三个步骤放在同一个窗口里，用页面（Panel）切换实现：
#   第 1 页 配置（安装位置 / 网络与端口）
#   第 2 页 安装（实时日志 + 走马灯进度条）
#   第 3 页 完成（管理页地址与后续操作按钮）
# 兼容范围：Windows 7 SP1 - Windows 11（PowerShell 2.0 + .NET 2.0 WinForms）。
# 设置环境变量 NBOT_GUI_NOSHOW=1 时只构建窗体不显示、不安装（供自动化测试）。
# 本文件必须保存为带 BOM 的 UTF-8，否则旧版 PowerShell 按 ANSI 读取会乱码。
# =============================================================================

$ErrorActionPreference = 'Stop'

# PowerShell 2.0 里没有自动的脚本目录变量，用 $MyInvocation 自己求。
# 命令行上多余的参数会落进 $args，向导直接忽略。
$script:WizDir = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $script:WizDir 'lib\common.ps1')
. (Join-Path $script:WizDir 'lib\theme.ps1')

Load-Config

$script:InstallBat = Join-Path $script:WizDir 'install.bat'
$script:PanelBat = Join-Path $script:WizDir 'panel.bat'
$script:Installing = $false
$script:InstallProc = $null
$script:LogFile = ''
$script:LastLogText = ''
$script:CurrentPage = 1
$script:ExitCode = 0

# 安装日志统一按 UTF-8 读:install-core.ps1 在输出被重定向时会把控制台输出
# 编码切成 UTF-8,python / node 的输出本身也是 UTF-8,这样中文不会变乱码。
$script:LogEncoding = New-Object System.Text.UTF8Encoding($false)

# 下拉项与实际配置值的对应表
$script:GhItems = @('gh-proxy.com（推荐）', 'ghfast.top', 'ghproxy.net', '不使用加速（直连）')
$script:GhValues = @('https://gh-proxy.com', 'https://ghfast.top', 'https://ghproxy.net', '')
$script:PipItems = @('清华 TUNA（推荐）', '阿里云', '腾讯云', '中科大 USTC', '华为云', '官方 pypi.org')
$script:PipValues = @(
    'https://pypi.tuna.tsinghua.edu.cn/simple',
    'https://mirrors.aliyun.com/pypi/simple',
    'https://mirrors.cloud.tencent.com/pypi/simple',
    'https://mirrors.ustc.edu.cn/pypi/simple',
    'https://repo.huaweicloud.com/repository/pypi/simple',
    '')

# -----------------------------------------------------------------------------
# 小工具
# -----------------------------------------------------------------------------

function Show-Msg {
    param([string]$Text)
    [void][System.Windows.Forms.MessageBox]::Show($Text, 'nbot')
}

function Ask-YesNo {
    param([string]$Text)
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $Text, 'nbot', [System.Windows.Forms.MessageBoxButtons]::YesNo)
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Test-AbsPath {
    param([string]$Value)
    return ($Value -match '^[A-Za-z]:\\')
}

function Test-PortValue {
    param([string]$Value)
    if ($Value -notmatch '^\d{1,5}$') { return $false }
    $number = [int]$Value
    return ($number -ge 1 -and $number -le 65535)
}

function Get-DefaultInstallRoot {
    # 已真实装过(配置文件存在)且 ASTRBOT_ROOT 形如 <root>\AstrBot、且 <root>
    # 不是裸盘符时,沿用旧根;否则选可用空间最大的固定磁盘,默认 <盘>\nbot。
    # 注意:不能只看 Get-Cfg——它带内置默认值 C:\AstrBot,会把首次运行误判成旧装。
    if (Test-Path -LiteralPath (Get-ConfigPath)) {
        $existing = Get-Cfg 'ASTRBOT_ROOT'
        if ($existing -and ($existing -match '(?i)^(.+)\\AstrBot$')) {
            $parent = $matches[1]
            if ($parent.TrimEnd('\').Length -gt 2) { return $parent }
        }
    }
    $best = $null
    $bestFree = -1
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            try {
                if ($d.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
                if (-not $d.IsReady) { continue }
                if ($d.AvailableFreeSpace -gt $bestFree) {
                    $bestFree = $d.AvailableFreeSpace
                    $best = $d.Name  # 形如 "F:\"
                }
            } catch { }
        }
    } catch { }
    if (-not $best) { $best = 'C:\' }
    return ($best.TrimEnd('\') + '\nbot')
}

function Enable-PathAutoComplete {
    # 给路径输入框开启文件系统目录自动补全(边打边提示已存在的文件夹)。
    param($Box)
    try {
        $Box.AutoCompleteMode = [System.Windows.Forms.AutoCompleteMode]::SuggestAppend
        $Box.AutoCompleteSource = [System.Windows.Forms.AutoCompleteSource]::FileSystemDirectories
    } catch { }
}

function Browse-Into {
    param($Box)
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '请选择目录'
    try {
        if ($Box.Text -and (Test-AbsPath $Box.Text)) { $dialog.SelectedPath = $Box.Text }
    } catch { }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $Box.Text = $dialog.SelectedPath
    }
    $dialog.Dispose()
}

function Get-ControlCount {
    param($Parent)
    $total = 0
    foreach ($child in $Parent.Controls) {
        $total = $total + 1
        if ($child.Controls.Count -gt 0) {
            $total = $total + (Get-ControlCount $child)
        }
    }
    return $total
}

# -----------------------------------------------------------------------------
# 主窗体与步骤指示
# -----------------------------------------------------------------------------

$script:Form = New-ThemeWindow 'nbot 安装向导' 680 620 -WithMinimize

$script:StepLabels = @()
$script:StepLabels += (New-ThemeLabel $script:Form 22 52 160 22 '① 配置' 10 -Bold 'Pink')
$script:StepLabels += (New-ThemeLabel $script:Form 188 52 160 22 '② 安装' 10 -Bold 'TextDim')
$script:StepLabels += (New-ThemeLabel $script:Form 354 52 160 22 '③ 完成' 10 -Bold 'TextDim')

$script:Page1 = New-Object System.Windows.Forms.Panel
$script:Page1.SetBounds(0, 80, 680, 530)
$script:Page1.BackColor = [System.Drawing.Color]::Transparent
$script:Form.Controls.Add($script:Page1)

$script:Page2 = New-Object System.Windows.Forms.Panel
$script:Page2.SetBounds(0, 80, 680, 530)
$script:Page2.BackColor = [System.Drawing.Color]::Transparent
$script:Form.Controls.Add($script:Page2)

$script:Page3 = New-Object System.Windows.Forms.Panel
$script:Page3.SetBounds(0, 80, 680, 530)
$script:Page3.BackColor = [System.Drawing.Color]::Transparent
$script:Form.Controls.Add($script:Page3)

function Show-Page {
    param([int]$Index)
    $script:CurrentPage = $Index
    if ($Index -eq 1) { $script:Page1.Show() } else { $script:Page1.Hide() }
    if ($Index -eq 2) { $script:Page2.Show() } else { $script:Page2.Hide() }
    if ($Index -eq 3) { $script:Page3.Show() } else { $script:Page3.Hide() }
    $position = 1
    foreach ($label in $script:StepLabels) {
        if ($position -eq $Index) {
            $label.ForeColor = Get-ThemeColor 'Pink'
        } else {
            $label.ForeColor = Get-ThemeColor 'TextDim'
        }
        $position = $position + 1
    }
}

# =============================================================================
# 第 1 页：配置
# =============================================================================

$cardPath = New-ThemeCard $script:Page1 20 8 640 186 '安装位置'

# 只选一个安装根目录,三个程序自动分类放在它下面的子文件夹里。
[void](New-ThemeLabel $cardPath 14 38 90 20 '安装根目录' 9 'TextDim')
$script:TxtRoot = New-ThemeTextBox $cardPath 108 36 420 (Get-DefaultInstallRoot)
Enable-PathAutoComplete $script:TxtRoot
[void](New-ThemeButton $cardPath 536 36 88 24 '浏览' 'ghost' { Browse-Into $script:TxtRoot })

# 自动分类预览(只读):AstrBot / NapCat / 载荷各占一个子目录
$script:LblSub1 = New-ThemeLabel $cardPath 30 68 594 18 '' 8.5 -ColorName 'Cyan'
$script:LblSub2 = New-ThemeLabel $cardPath 30 88 594 18 '' 8.5 -ColorName 'Cyan'
$script:LblSub3 = New-ThemeLabel $cardPath 30 108 594 18 '' 8.5 -ColorName 'Cyan'

$script:LblFree = New-ThemeLabel $cardPath 14 138 610 20 '正在检测磁盘可用空间...' 9 'TextDim'

function Get-SubPaths {
    # 由安装根目录推导三个子目录;根目录规范化去掉尾部反斜杠。
    param([string]$Root)
    $r = ([string]$Root).TrimEnd('\')
    $paths = @{}
    $paths['astr'] = $r + '\AstrBot'
    $paths['nap'] = $r + '\NapCat'
    $paths['payload'] = $r + '\payload'
    return $paths
}

function Update-Location {
    $root = $script:TxtRoot.Text.Trim()
    if (Test-AbsPath $root) {
        $p = Get-SubPaths $root
        $script:LblSub1.Text = 'AstrBot 程序与数据  ->  ' + $p['astr']
        $script:LblSub2.Text = 'NapCat 配置与日志   ->  ' + $p['nap']
        $script:LblSub3.Text = 'NapCat/QQ 程序载荷  ->  ' + $p['payload']
    } else {
        $script:LblSub1.Text = '请填写一个绝对路径,例如 F:\nbot(建议放在空间大的盘)'
        $script:LblSub2.Text = ''
        $script:LblSub3.Text = ''
    }
    try {
        if (-not (Test-AbsPath $root)) { throw 'x' }
        $freeGb = Get-FreeGB $root
        $script:LblFree.Text = '所在磁盘可用 ' + $freeGb + ' GB（建议 ≥ 8 GB）'
        if ($freeGb -lt 4) { $script:LblFree.ForeColor = Get-ThemeColor 'Bad' }
        elseif ($freeGb -lt 8) { $script:LblFree.ForeColor = Get-ThemeColor 'Warn' }
        else { $script:LblFree.ForeColor = Get-ThemeColor 'Ok' }
    } catch {
        $script:LblFree.Text = '路径待确认'
        $script:LblFree.ForeColor = Get-ThemeColor 'TextDim'
    }
}

$script:TxtRoot.add_TextChanged({ Update-Location })

$cardNet = New-ThemeCard $script:Page1 20 202 640 224 '网络与端口'

[void](New-ThemeLabel $cardNet 14 36 100 20 'GitHub 加速' 9 'TextDim')
$script:CmbGh = New-ThemeCombo $cardNet 118 34 250 $script:GhItems 0

[void](New-ThemeLabel $cardNet 388 36 80 20 'PyPI 镜像' 9 'TextDim')
$script:CmbPip = New-ThemeCombo $cardNet 468 34 156 $script:PipItems 0

# 加速说明:默认已选好国内推荐节点,新手直接下一步即可
[void](New-ThemeLabel $cardNet 14 60 610 30 ('国内网络请保持上面两个加速（已默认选好）：直连 GitHub 常被重置、直连 PyPI 装依赖很慢。' +
    '若某个节点抽风,换一个再重试即可；有全局代理/在海外可都选“不使用/官方”。') 8.5 'Warn')

[void](New-ThemeLabel $cardNet 14 100 110 20 'AstrBot WebUI' 9 'TextDim')
$script:TxtPortWeb = New-ThemeTextBox $cardNet 128 98 70 (Get-Cfg 'ASTRBOT_PORT')
[void](New-ThemeLabel $cardNet 218 100 90 20 'OneBot WS' 9 'TextDim')
$script:TxtPortWs = New-ThemeTextBox $cardNet 312 98 70 (Get-Cfg 'ASTRBOT_WS_PORT')

[void](New-ThemeLabel $cardNet 14 130 110 20 'NapCat WebUI' 9 'TextDim')
$script:TxtPortNap = New-ThemeTextBox $cardNet 128 128 70 (Get-Cfg 'NAPCAT_WEBUI_PORT')
[void](New-ThemeLabel $cardNet 218 130 90 20 'OneBot HTTP' 9 'TextDim')
$script:TxtPortHttp = New-ThemeTextBox $cardNet 312 128 70 (Get-Cfg 'ONEBOT_HTTP_PORT')

[void](New-ThemeLabel $cardNet 14 162 320 20 'QQ 安装目录（可选，留空自动探测）' 9 'TextDim')
$script:TxtQQ = New-ThemeTextBox $cardNet 14 186 510 (Get-Cfg 'QQ_INSTALL_DIR')
Enable-PathAutoComplete $script:TxtQQ
[void](New-ThemeButton $cardNet 536 186 88 24 '浏览' 'ghost' { Browse-Into $script:TxtQQ })

[void](New-ThemeLabel $script:Page1 22 430 636 42 '提示：安装过程会自动下载托管 Python、AstrBot 源码、NapCat 与 QQ 安装包，请保持网络畅通；全程约 10 - 30 分钟。' 9 'TextDim')

# -----------------------------------------------------------------------------
# 校验与开始安装
# -----------------------------------------------------------------------------

function Invoke-BeginInstall {
    $root = $script:TxtRoot.Text.Trim()
    if (-not $root) {
        Show-Msg '安装根目录不能为空。'
        return
    }
    if (-not (Test-AbsPath $root)) {
        Show-Msg '安装根目录必须是绝对路径（例如 F:\nbot）。'
        return
    }
    if ($root.TrimEnd('\').Length -le 2) {
        Show-Msg '请不要直接选盘符根目录（如 F:\），填一个子文件夹（如 F:\nbot），程序会分类放进去。'
        return
    }
    $sub = Get-SubPaths $root
    $astrRoot = $sub['astr']
    $napRoot = $sub['nap']
    $payloadRoot = $sub['payload']

    $qqDir = $script:TxtQQ.Text.Trim()
    if ($qqDir -and -not (Test-AbsPath $qqDir)) {
        Show-Msg 'QQ 安装目录必须是绝对路径，或者留空由安装器自动探测。'
        return
    }

    $portChecks = @(
        @('AstrBot WebUI 端口', $script:TxtPortWeb),
        @('OneBot WS 端口', $script:TxtPortWs),
        @('NapCat WebUI 端口', $script:TxtPortNap),
        @('OneBot HTTP 端口', $script:TxtPortHttp))
    $ports = @()
    foreach ($item in $portChecks) {
        $value = $item[1].Text.Trim()
        if (-not (Test-PortValue $value)) {
            Show-Msg ($item[0] + '必须是 1 - 65535 之间的纯数字。')
            return
        }
        $ports += [int]$value
    }
    for ($i = 0; $i -lt $ports.Count; $i++) {
        for ($j = $i + 1; $j -lt $ports.Count; $j++) {
            if ($ports[$i] -eq $ports[$j]) {
                Show-Msg ('四个端口不能重复：' + $ports[$i] + ' 被使用了两次。')
                return
            }
        }
    }

    Set-Cfg 'ASTRBOT_ROOT' $astrRoot
    Set-Cfg 'NAPCAT_ROOT' $napRoot
    Set-Cfg 'NAPCAT_PAYLOAD_ROOT' $payloadRoot
    Set-Cfg 'ASTRBOT_PORT' ([string]$ports[0])
    Set-Cfg 'ASTRBOT_WS_PORT' ([string]$ports[1])
    Set-Cfg 'NAPCAT_WEBUI_PORT' ([string]$ports[2])
    Set-Cfg 'ONEBOT_HTTP_PORT' ([string]$ports[3])
    Set-Cfg 'GITHUB_ACCESS' 'auto'
    Set-Cfg 'GITHUB_MIRROR' $script:GhValues[$script:CmbGh.SelectedIndex]
    Set-Cfg 'PIP_INDEX_URL' $script:PipValues[$script:CmbPip.SelectedIndex]
    Set-Cfg 'QQ_INSTALL_DIR' $qqDir
    try {
        Write-Config
    } catch {
        Show-Msg ('写入配置文件失败：' + $_.Exception.Message)
        return
    }

    Show-Page 2
    Start-InstallProcess
}

[void](New-ThemeButton $script:Page1 496 482 164 42 '开始安装' 'primary' { Invoke-BeginInstall })
[void](New-ThemeButton $script:Page1 380 482 104 42 '取消' 'ghost' { $script:Form.Close() })

# =============================================================================
# 第 2 页：安装
# =============================================================================

$cardRun = New-ThemeCard $script:Page2 20 8 640 486 '安装进度'

$script:LblStage = New-ThemeLabel $cardRun 14 36 610 24 '正在准备安装环境...' 10 -Bold 'Pink'

$script:Bar = New-Object System.Windows.Forms.ProgressBar
$script:Bar.SetBounds(14, 66, 610, 16)
$script:Bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
$script:Bar.MarqueeAnimationSpeed = 30
$script:Bar.BackColor = [System.Drawing.Color]::FromArgb(20, 14, 38)
$script:Bar.ForeColor = Get-ThemeColor 'Pink'
$cardRun.Controls.Add($script:Bar)

$script:LogBox = New-ThemeLogBox $cardRun 14 92 610 380

[void](New-ThemeLabel $script:Page2 22 504 620 20 '安装期间请不要关闭本窗口；日志同时完整写入临时文件，失败后可在第 3 页打开查看。' 9 'TextDim')

function Get-StageText {
    param([string]$Text)
    if (-not $Text) { return '正在准备安装环境...' }
    if ($Text -match '已启动') { return '即将完成...' }
    if ($Text -match '计划任务') { return '正在注册自启与守护任务...' }
    if ($Text -match '下载 NapCat' -or $Text -match 'NapCat') { return '正在安装 NapCat 与 QQ...' }
    if ($Text -match '安装 AstrBot') { return '正在安装 AstrBot（下载源码、创建 venv、装依赖，较慢）...' }
    return '正在准备安装环境...'
}

function Get-LogTailText {
    param([string]$Path, [int]$Count)
    if (-not $Path) { return '' }
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = $null
    $reader = $null
    $content = ''
    try {
        # 共享读：安装进程还在往这个文件里写，必须允许 ReadWrite 共享。
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = New-Object IO.StreamReader($stream, $script:LogEncoding)
        $content = $reader.ReadToEnd()
    } catch {
        $content = ''
    } finally {
        if ($null -ne $reader) {
            $reader.Close()
        } elseif ($null -ne $stream) {
            $stream.Close()
        }
    }
    if (-not $content) { return '' }
    $lines = $content -split "`r?`n"
    $first = $lines.Length - $Count
    if ($first -lt 0) { $first = 0 }
    $builder = New-Object System.Text.StringBuilder
    for ($i = $first; $i -lt $lines.Length; $i++) {
        [void]$builder.AppendLine($lines[$i])
    }
    return $builder.ToString()
}

function Start-InstallProcess {
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $script:LogFile = Join-Path $env:TEMP ('nbot-install-' + $stamp + '.log')
    $script:LastLogText = ''
    $script:LogBox.Text = '正在启动安装进程，请稍候...'
    $script:LblStage.Text = '正在准备安装环境...'
    $script:Bar.MarqueeAnimationSpeed = 30

    # 用 cmd 内部重定向把安装输出落到日志文件；标准输入接到 nul，
    # 让 install-all 里的确认提示取默认值（全部使用默认配置），不会卡住等按键。
    $arguments = '/c ""' + $script:InstallBat + '" install-all <nul > "' + $script:LogFile + '" 2>&1"'
    try {
        $script:InstallProc = Start-Process -FilePath 'cmd.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
    } catch {
        $script:Installing = $false
        $script:Bar.MarqueeAnimationSpeed = 0
        Show-Msg ('无法启动安装进程：' + $_.Exception.Message)
        Complete-Install 1
        return
    }
    $script:Installing = $true
    $script:Timer.Start()
}

# =============================================================================
# 第 3 页：完成
# =============================================================================

$cardDone = New-ThemeCard $script:Page3 20 8 640 396 ''

$script:Lbl3Title = New-ThemeLabel $cardDone 16 16 606 34 '安装完成！' 14 -Bold 'Pink'

# 信息区用 10 个单行 Label 逐行排布：Label 的自动换行会把长路径挤成一团，
# 一行一个控件才能保证「一条信息一行」的可读性。
$script:Lbl3Rows = @()
for ($rowIndex = 0; $rowIndex -lt 10; $rowIndex++) {
    $rowLabel = New-ThemeLabel $cardDone 16 (54 + $rowIndex * 22) 606 20 '' 9.5 'Text'
    $rowLabel.AutoEllipsis = $true
    $script:Lbl3Rows += $rowLabel
}

function Set-BodyLines {
    param($Lines)
    $Lines = @($Lines)
    for ($i = 0; $i -lt $script:Lbl3Rows.Count; $i++) {
        if ($i -lt $Lines.Count) {
            $script:Lbl3Rows[$i].Text = [string]$Lines[$i]
        } else {
            $script:Lbl3Rows[$i].Text = ''
        }
    }
}

$script:Btn3Panel = New-ThemeButton $cardDone 16 286 156 40 '打开控制面板' 'primary' {
    try {
        Start-Process -FilePath $script:PanelBat
    } catch {
        Show-Msg ('无法打开控制面板：' + $_.Exception.Message)
    }
}
$script:Btn3QQ = New-ThemeButton $cardDone 184 286 156 40 '扫码登录 QQ' 'accent' {
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $script:InstallBat + '" qqlogin')
    } catch {
        Show-Msg ('无法打开 QQ 登录：' + $_.Exception.Message)
    }
}
$script:Btn3Log = New-ThemeButton $cardDone 16 286 156 40 '打开日志' 'accent' {
    if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $script:LogFile + '"')
    } else {
        Show-Msg '日志文件不存在，可能安装进程尚未产生任何输出。'
    }
}
$script:Btn3Back = New-ThemeButton $cardDone 184 286 156 40 '返回配置' 'ghost' { Show-Page 1 }
$script:Btn3Close = New-ThemeButton $cardDone 352 286 156 40 '完成' 'ghost' { $script:Form.Close() }

# 失败分支的两个按钮与成功分支同槽位，先隐藏，Complete-Install 里再按退出码取舍。
$script:Btn3Log.Hide()
$script:Btn3Back.Hide()

[void](New-ThemeLabel $cardDone 16 340 606 40 '后续管理请使用桌面「nbot 面板」快捷方式。' 9 'TextDim')

function Complete-Install {
    param([int]$Code)
    $script:ExitCode = $Code
    $script:Installing = $false
    $astrPort = Get-Cfg 'ASTRBOT_PORT'
    if (-not $astrPort) { $astrPort = '6185' }
    $napPort = Get-Cfg 'NAPCAT_WEBUI_PORT'
    if (-not $napPort) { $napPort = '6099' }

    if ($Code -eq 0) {
        $script:Lbl3Title.Text = '安装完成！'
        $script:Lbl3Title.ForeColor = Get-ThemeColor 'Pink'
        # 抓取两个 WebUI 的登录凭据(AstrBot 初始账号密码 / NapCat token)
        $cred = Get-AstrbotCred
        $napToken = Get-NapcatToken
        $astrPassLine = 'AstrBot 登录：账号 ' + $cred['user'] + '  密码 '
        if ($cred['found']) { $astrPassLine = $astrPassLine + $cred['pass'] + '(初始密码,登录后请改)' }
        else { $astrPassLine = $astrPassLine + '见 AstrBot 日志(可能已改过)' }
        $napTokenLine = 'NapCat 登录：WebUI Token '
        if ($napToken) { $napTokenLine = $napTokenLine + $napToken } else { $napTokenLine = $napTokenLine + '见 NapCat\config\webui.json' }
        # 每个元素都要用括号包住：逗号的优先级高于加号，不包括号会被拼成一整串。
        $lines = @(
            ('AstrBot 管理页：http://127.0.0.1:' + $astrPort + '/'),
            $astrPassLine,
            ('NapCat 管理页：http://127.0.0.1:' + $napPort + '/webui'),
            $napTokenLine,
            ('配置文件：' + (Get-ConfigPath) + '   数据目录：' + (Get-Cfg 'ASTRBOT_ROOT')),
            '',
            '登录信息也能随时在控制面板点「登录信息」查看/复制。',
            '',
            '下一步：点「扫码登录 QQ」用手机 QQ 扫码；登录完成后在控制面板点',
            '「配置 OneBot 对接」填入机器人 QQ 号，即可完成最后一步对接。')
        Set-BodyLines $lines
        $script:Btn3Panel.Show()
        $script:Btn3QQ.Show()
        $script:Btn3Log.Hide()
        $script:Btn3Back.Hide()
        $script:Btn3Close.Text = '完成'
        $script:Btn3Close.Show()
    } else {
        $script:Lbl3Title.Text = '安装未完成'
        $script:Lbl3Title.ForeColor = Get-ThemeColor 'Bad'
        $lines = @(
            ('安装进程以退出码 ' + $Code + ' 结束，部分组件可能没有装好。'),
            '',
            ('安装日志：' + $script:LogFile),
            ('配置文件：' + (Get-ConfigPath)),
            '',
            '请点「打开日志」查看最后的报错信息。常见原因：',
            '  · 网络不通或 GitHub 加速节点失效 —— 回到第 1 页换一个加速地址重试；',
            '  · 磁盘空间不足 —— 换一个可用空间更大的盘；',
            '  · Windows 7 缺少 TLS 1.2 更新 —— 先装 KB3140245 再重试。')
        Set-BodyLines $lines
        $script:Btn3Panel.Hide()
        $script:Btn3QQ.Hide()
        $script:Btn3Log.Show()
        $script:Btn3Back.Show()
        $script:Btn3Close.Text = '关闭'
        $script:Btn3Close.Show()
    }
    Show-Page 3
}

# =============================================================================
# 轮询定时器与窗体事件
# =============================================================================

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 1000
$script:Timer.add_Tick({
    $text = Get-LogTailText $script:LogFile 200
    if ($text -and $text -ne $script:LastLogText) {
        $script:LastLogText = $text
        $script:LogBox.Text = $text
        $script:LogBox.SelectionStart = $script:LogBox.Text.Length
        $script:LogBox.ScrollToCaret()
        $script:LblStage.Text = Get-StageText $text
    }
    if ($null -ne $script:InstallProc) {
        $exited = $false
        try { $exited = $script:InstallProc.HasExited } catch { $exited = $true }
        if ($exited) {
            $script:Timer.Stop()
            $script:Bar.MarqueeAnimationSpeed = 0
            $code = 1
            try { $code = [int]$script:InstallProc.ExitCode } catch { $code = 1 }
            $script:InstallProc = $null
            Complete-Install $code
        }
    }
})

$script:Form.add_FormClosing({
    param($sender, $e)
    if ($script:Installing) {
        if (-not (Ask-YesNo '安装正在进行，确定要中断吗？')) {
            $e.Cancel = $true
            return
        }
    }
    $script:Timer.Stop()
})

Update-Location
Show-Page 1

if ($env:NBOT_GUI_RENDERTEST -eq '1') {
    # 渲染自检:三页都显示在屏幕外强制绘制一遍,报告 Paint 期错误后退出。
    $script:Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $script:Form.Location = New-Object System.Drawing.Point(-4000, -4000)
    $script:Form.ShowInTaskbar = $false
    $script:Form.Show()
    foreach ($page in @(1, 2, 3)) {
        Show-Page $page
        for ($i = 0; $i -lt 3; $i++) {
            $script:Form.Refresh()
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
    }
    $paintErrors = Get-ThemePaintErrors
    Write-Host ('PAINT ERRORS: ' + $paintErrors.Count)
    foreach ($message in $paintErrors) { Write-Host ('  - ' + $message) }
    $script:Installing = $false
    $script:Form.Close()
    if ($paintErrors.Count -gt 0) { exit 1 }
    exit 0
} elseif ($env:NBOT_GUI_NOSHOW -eq '1') {
    Write-Host ('Wizard form built OK: ' + (Get-ControlCount $script:Form))
    $script:Timer.Dispose()
    $script:Form.Dispose()
} else {
    [System.Windows.Forms.Application]::Run($script:Form)
}
