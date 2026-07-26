# =============================================================================
# nbot-installer-windows / lib/theme.ps1
# WinForms 二次元风格 UI 组件库:渐变背景、圆角卡片、发光按钮、状态灯、
# 自绘标题栏(可拖动)、吉祥物装饰。供 gui.ps1(面板)与 wizard.ps1(向导)共用。
# 只用 GDI+ 与 .NET 2.0 API,保持与项目其余部分一致的兼容性。
# 用法:先 dot-source 本文件,再调用 New-ThemeWindow 等函数。
# =============================================================================

try { Add-Type -AssemblyName System.Windows.Forms } catch {
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
}
try { Add-Type -AssemblyName System.Drawing } catch {
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')
}
[System.Windows.Forms.Application]::EnableVisualStyles()

# 记录本文件路径(PowerShell 2.0 没有 $PSScriptRoot),用于定位 assets\bin\nbot.ico
$script:ThemePs1Path = $MyInvocation.MyCommand.Path

# --- 任务栏身份 --------------------------------------------------------------
# 不设 AppUserModelID 时,窗口会按进程路径(powershell.exe)归组到任务栏上
# 已固定的 PowerShell 按钮里,于是任务栏显示的是 PowerShell 图标而不是本程序
# 的图标。显式设一个自己的 AppID 就能脱离归组、显示窗口自己的图标。

$script:AppIdSet = $false

function Set-ThemeAppId {
    param([string]$AppId)
    if ($script:AppIdSet) { return }
    if (-not $AppId) { $AppId = 'NBot.ControlPanel' }
    try {
        if ($null -eq ('NBot.Shell32' -as [type])) {
            $signature = '[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]' + [Environment]::NewLine +
                'public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);'
            Add-Type -Namespace 'NBot' -Name 'Shell32' -MemberDefinition $signature -ErrorAction Stop
        }
        [void][NBot.Shell32]::SetCurrentProcessExplicitAppUserModelID($AppId)
        $script:AppIdSet = $true
    } catch { }
}

Set-ThemeAppId 'NBot.ControlPanel'

# --- 调色板(深色二次元:夜空紫底 + 樱花粉 + 星光青)-------------------------

$script:T = @{}
$script:T['BgTop']     = [System.Drawing.Color]::FromArgb(32, 22, 58)
$script:T['BgBottom']  = [System.Drawing.Color]::FromArgb(18, 14, 34)
$script:T['Card']      = [System.Drawing.Color]::FromArgb(44, 32, 74)
$script:T['CardEdge']  = [System.Drawing.Color]::FromArgb(86, 62, 140)
$script:T['Pink']      = [System.Drawing.Color]::FromArgb(255, 111, 174)
$script:T['PinkDark']  = [System.Drawing.Color]::FromArgb(214, 71, 138)
$script:T['Purple']    = [System.Drawing.Color]::FromArgb(124, 92, 255)
$script:T['Cyan']      = [System.Drawing.Color]::FromArgb(89, 227, 255)
$script:T['Text']      = [System.Drawing.Color]::FromArgb(240, 236, 255)
$script:T['TextDim']   = [System.Drawing.Color]::FromArgb(168, 158, 205)
$script:T['Ok']        = [System.Drawing.Color]::FromArgb(126, 240, 168)
$script:T['Warn']      = [System.Drawing.Color]::FromArgb(255, 197, 87)
$script:T['Bad']       = [System.Drawing.Color]::FromArgb(255, 108, 129)

function Get-ThemeColor {
    param([string]$Name)
    return $script:T[$Name]
}

# 绘制期异常收集:Paint 事件里抛异常会直接崩掉整个窗口,所以每个绘制
# 处理器都包 try/catch,把问题记在这里(tests\render-check.ps1 会断言为空)。
$script:ThemePaintErrors = New-Object System.Collections.ArrayList

function Add-ThemePaintError {
    param([string]$Where, $Err)
    $message = $Where + ': ' + [string]$Err
    [void]$script:ThemePaintErrors.Add($message)
}

function Get-ThemePaintErrors {
    return $script:ThemePaintErrors
}

function New-LinearBrush {
    # 用「两点」构造渐变画刷:LinearGradientBrush 的 (Rectangle,Color,Color,float)
    # 重载在 PowerShell 里会因 double/Rectangle 歧义解析失败,两点构造无歧义。
    param([int]$X1, [int]$Y1, [int]$X2, [int]$Y2, $ColorA, $ColorB)
    if ($X1 -eq $X2 -and $Y1 -eq $Y2) { $X2 = $X1 + 1 }
    $p1 = New-Object System.Drawing.Point($X1, $Y1)
    $p2 = New-Object System.Drawing.Point($X2, $Y2)
    return (New-Object System.Drawing.Drawing2D.LinearGradientBrush($p1, $p2, $ColorA, $ColorB))
}

function New-ThemePen {
    param($Color, [single]$Width)
    if ($Width -le 0) { $Width = 1 }
    return (New-Object System.Drawing.Pen($Color, $Width))
}

function Enable-DoubleBuffer {
    # 打开双缓冲 + 一次性绘制,消除自绘渐变窗口/卡片打开时的闪烁。
    # DoubleBuffered 与 SetStyle 都是 protected,PowerShell 里用反射调用
    # (.NET 2.0 起即可用,保持与全项目一致的兼容性)。
    param($Control)
    try {
        $t = [System.Windows.Forms.Control]
        $flags = [System.Reflection.BindingFlags]'Instance,NonPublic'
        $prop = $t.GetProperty('DoubleBuffered', $flags)
        $prop.SetValue($Control, $true, $null)
        $m = $t.GetMethod('SetStyle', $flags)
        $styles = [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
            [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint
        [void]$m.Invoke($Control, @([System.Windows.Forms.ControlStyles]$styles, $true))
    } catch { }
}

# 前台置顶(不闪):比 TopMost 翻转更干净地把窗口带到最前
if ($null -eq ('NBot.Win' -as [type])) {
    try {
        $winSig = @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@
        Add-Type -Namespace 'NBot' -Name 'Win' -MemberDefinition $winSig -ErrorAction Stop
    } catch { }
}

# --- 图标(自绘猫头,窗口与托盘共用)----------------------------------------
# 不用 ExtractAssociatedIcon 从系统 dll 取图标:那样常常拿到一张空白纸。

$script:ThemeIcon = $null

function New-ThemeIconBitmap {
    # 画出图标位图(猫头 + 深紫圆角底),供托盘、窗口与 .ico 文件共用。
    param([int]$Size)
    if ($Size -le 0) { $Size = 32 }
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    # 按 32x32 设计,其他尺寸按比例缩放
    $g.ScaleTransform(([single]$Size / 32.0), ([single]$Size / 32.0))

    $bgPath = New-RoundedPath 0 0 31 31 8
    $bg = New-Object System.Drawing.SolidBrush($script:T['BgTop'])
    $g.FillPath($bg, $bgPath)
    $edge = New-ThemePen $script:T['Purple'] 2
    $g.DrawPath($edge, $bgPath)
    $bg.Dispose(); $edge.Dispose(); $bgPath.Dispose()

    $pink = New-Object System.Drawing.SolidBrush($script:T['Pink'])
    $earL = @(
        (New-Object System.Drawing.Point(7, 13)),
        (New-Object System.Drawing.Point(11, 4)),
        (New-Object System.Drawing.Point(16, 12)))
    $earR = @(
        (New-Object System.Drawing.Point(16, 12)),
        (New-Object System.Drawing.Point(21, 4)),
        (New-Object System.Drawing.Point(25, 13)))
    $g.FillPolygon($pink, $earL)
    $g.FillPolygon($pink, $earR)
    $g.FillEllipse($pink, 5, 11, 22, 17)

    $dark = New-Object System.Drawing.SolidBrush($script:T['BgBottom'])
    $g.FillEllipse($dark, 11, 17, 3, 5)
    $g.FillEllipse($dark, 18, 17, 3, 5)
    $cyan = New-Object System.Drawing.SolidBrush($script:T['Cyan'])
    $g.FillEllipse($cyan, 7, 22, 4, 3)
    $g.FillEllipse($cyan, 21, 22, 4, 3)
    $pink.Dispose(); $dark.Dispose(); $cyan.Dispose()
    $g.Dispose()
    return $bmp
}

function Save-ThemeIcoFile {
    # 手写 ICO 容器(32bpp DIB + 空 AND 掩码)。Icon.Save 对由句柄创建的图标
    # 不可靠,所以自己拼字节,得到能被快捷方式 IconLocation 使用的真实 .ico。
    param([string]$Path, $Sizes)
    if (-not $Sizes) { $Sizes = @(16, 32, 48) }

    $images = @()
    foreach ($size in $Sizes) {
        $bmp = New-ThemeIconBitmap $size
        $body = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($body)
        # BITMAPINFOHEADER:高度写两倍(XOR 图 + AND 掩码)
        $bw.Write([int]40)
        $bw.Write([int]$size)
        $bw.Write([int]($size * 2))
        $bw.Write([int16]1)
        $bw.Write([int16]32)
        $bw.Write([int]0)
        $bw.Write([int]0)
        $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
        # 像素自下而上、BGRA
        for ($y = $size - 1; $y -ge 0; $y--) {
            for ($x = 0; $x -lt $size; $x++) {
                $pixel = $bmp.GetPixel($x, $y)
                $bw.Write([byte]$pixel.B)
                $bw.Write([byte]$pixel.G)
                $bw.Write([byte]$pixel.R)
                $bw.Write([byte]$pixel.A)
            }
        }
        # AND 掩码:每行按 4 字节对齐,全 0 表示完全依赖 alpha
        $maskRow = [math]::Floor(($size + 31) / 32) * 4
        for ($y = 0; $y -lt $size; $y++) {
            for ($i = 0; $i -lt $maskRow; $i++) { $bw.Write([byte]0) }
        }
        $bw.Flush()
        $entry = @{}
        $entry['size'] = $size
        $entry['bytes'] = $body.ToArray()
        $images += $entry
        $bw.Close()
        $bmp.Dispose()
    }

    $out = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($out)
    $w.Write([int16]0)
    $w.Write([int16]1)
    $w.Write([int16]$images.Count)
    $offset = 6 + (16 * $images.Count)
    foreach ($image in $images) {
        $size = [int]$image['size']
        $bytes = $image['bytes']
        $dim = $size
        if ($dim -ge 256) { $dim = 0 }
        $w.Write([byte]$dim)
        $w.Write([byte]$dim)
        $w.Write([byte]0)
        $w.Write([byte]0)
        $w.Write([int16]1)
        $w.Write([int16]32)
        $w.Write([int]$bytes.Length)
        $w.Write([int]$offset)
        $offset = $offset + $bytes.Length
    }
    foreach ($image in $images) {
        $bytes = $image['bytes']
        $w.Write($bytes, 0, $bytes.Length)
    }
    $w.Flush()
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllBytes($Path, $out.ToArray())
    $w.Close()
    return $Path
}

function New-ThemeIcon {
    if ($null -ne $script:ThemeIcon) { return $script:ThemeIcon }
    # 优先用随包发布的 .ico(多尺寸更清晰),没有再现场绘制
    try {
        $icoPath = Join-Path (Split-Path -Parent (Split-Path -Parent $script:ThemePs1Path)) 'assets\bin\nbot.ico'
        if (Test-Path -LiteralPath $icoPath) {
            $script:ThemeIcon = New-Object System.Drawing.Icon($icoPath)
            return $script:ThemeIcon
        }
    } catch { }
    try {
        $bmp = New-ThemeIconBitmap 32
        $handle = $bmp.GetHicon()
        $script:ThemeIcon = [System.Drawing.Icon]::FromHandle($handle)
        $bmp.Dispose()
        return $script:ThemeIcon
    } catch {
        return [System.Drawing.SystemIcons]::Application
    }
}

# --- 字体 --------------------------------------------------------------------

$script:ThemeFontName = $null
function Get-ThemeFontName {
    if ($script:ThemeFontName) { return $script:ThemeFontName }
    $script:ThemeFontName = 'Microsoft Sans Serif'
    foreach ($candidate in @('Microsoft YaHei UI', 'Microsoft YaHei', 'SimHei')) {
        try {
            $family = New-Object System.Drawing.FontFamily($candidate)
            if ($family.Name -eq $candidate) { $script:ThemeFontName = $candidate; break }
        } catch { }
    }
    return $script:ThemeFontName
}

function New-ThemeFont {
    param([single]$Size, [switch]$Bold)
    $style = [System.Drawing.FontStyle]::Regular
    if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
    return (New-Object System.Drawing.Font((Get-ThemeFontName), $Size, $style))
}

# --- 图形辅助 ----------------------------------------------------------------

function New-RoundedPath {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$R)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($R -le 0) {
        $path.AddRectangle((New-Object System.Drawing.Rectangle($X, $Y, $W, $H)))
        return $path
    }
    $d = $R * 2
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
    $path.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
    $path.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function Set-RoundedRegion {
    param($Control, [int]$Radius)
    $path = New-RoundedPath 0 0 $Control.Width $Control.Height $Radius
    $Control.Region = New-Object System.Drawing.Region($path)
    $path.Dispose()
}

# --- 顶层窗口(无边框 + 渐变背景 + 自绘标题栏)-------------------------------

function New-ThemeWindow {
    param([string]$Title, [int]$Width, [int]$Height, [switch]$WithMinimize)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.ClientSize = New-Object System.Drawing.Size($Width, $Height)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = $script:T['BgBottom']
    $form.Font = (New-ThemeFont 9)
    $form.ForeColor = $script:T['Text']
    Enable-DoubleBuffer $form
    $form.add_Paint({
        param($sender, $e)
        try {
            $rect = New-Object System.Drawing.Rectangle(0, 0, $sender.Width, $sender.Height)
            $brush = New-LinearBrush 0 0 0 $sender.Height $script:T['BgTop'] $script:T['BgBottom']
            $e.Graphics.FillRectangle($brush, $rect)
            $brush.Dispose()
            # 顶部一条霞光高亮
            $glowRect = New-Object System.Drawing.Rectangle(0, 0, $sender.Width, 3)
            $glow = New-LinearBrush 0 0 $sender.Width 0 $script:T['Pink'] $script:T['Cyan']
            $e.Graphics.FillRectangle($glow, $glowRect)
            $glow.Dispose()
            # 边框
            $pen = New-ThemePen $script:T['CardEdge'] 1
            $e.Graphics.DrawRectangle($pen, 0, 0, ($sender.Width - 1), ($sender.Height - 1))
            $pen.Dispose()
        } catch {
            Add-ThemePaintError 'window' $_.Exception.Message
        }
    })

    # 标题文字
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.SetBounds(46, 12, ($Width - 160), 26)
    $lblTitle.Text = $Title
    $lblTitle.Font = (New-ThemeFont 11 -Bold)
    $lblTitle.ForeColor = $script:T['Text']
    $lblTitle.BackColor = [System.Drawing.Color]::Transparent
    $form.Controls.Add($lblTitle)

    # 吉祥物(猫耳圆脸)绘制在左上角
    $mascot = New-Object System.Windows.Forms.Panel
    $mascot.SetBounds(12, 10, 28, 28)
    $mascot.BackColor = [System.Drawing.Color]::Transparent
    $mascot.add_Paint({
        param($sender, $e)
        try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pink = New-Object System.Drawing.SolidBrush($script:T['Pink'])
        # 耳朵
        $earL = @(
            (New-Object System.Drawing.Point(5, 10)),
            (New-Object System.Drawing.Point(9, 1)),
            (New-Object System.Drawing.Point(14, 9)))
        $earR = @(
            (New-Object System.Drawing.Point(14, 9)),
            (New-Object System.Drawing.Point(19, 1)),
            (New-Object System.Drawing.Point(23, 10)))
        $g.FillPolygon($pink, $earL)
        $g.FillPolygon($pink, $earR)
        # 脸
        $g.FillEllipse($pink, 3, 7, 22, 18)
        # 眼睛
        $dark = New-Object System.Drawing.SolidBrush($script:T['BgBottom'])
        $g.FillEllipse($dark, 9, 13, 3, 5)
        $g.FillEllipse($dark, 16, 13, 3, 5)
        # 腮红
        $cyan = New-Object System.Drawing.SolidBrush($script:T['Cyan'])
        $g.FillEllipse($cyan, 5, 18, 4, 3)
        $g.FillEllipse($cyan, 19, 18, 4, 3)
        $pink.Dispose(); $dark.Dispose(); $cyan.Dispose()
        } catch {
            Add-ThemePaintError 'mascot' $_.Exception.Message
        }
    })
    $form.Controls.Add($mascot)

    # 拖动:标题区域按下即可拖窗
    $script:DragOrigin = $null
    $dragDown = {
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $script:DragOrigin = New-Object System.Drawing.Point($e.X, $e.Y)
        }
    }
    $dragMove = {
        param($sender, $e)
        if ($script:DragOrigin -ne $null -and $e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $form = $sender.FindForm()
            $form.Location = New-Object System.Drawing.Point(
                ($form.Location.X + $e.X - $script:DragOrigin.X),
                ($form.Location.Y + $e.Y - $script:DragOrigin.Y))
        }
    }
    $dragUp = { $script:DragOrigin = $null }
    foreach ($dragTarget in @($form, $lblTitle, $mascot)) {
        $dragTarget.add_MouseDown($dragDown)
        $dragTarget.add_MouseMove($dragMove)
        $dragTarget.add_MouseUp($dragUp)
    }

    # 关闭按钮
    $btnClose = New-Object System.Windows.Forms.Label
    $btnClose.SetBounds(($Width - 42), 10, 30, 26)
    $btnClose.Text = 'X'
    $btnClose.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $btnClose.Font = (New-ThemeFont 10 -Bold)
    $btnClose.ForeColor = $script:T['TextDim']
    $btnClose.BackColor = [System.Drawing.Color]::Transparent
    $btnClose.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnClose.add_MouseEnter({ param($s, $e) $s.ForeColor = $script:T['Bad'] })
    $btnClose.add_MouseLeave({ param($s, $e) $s.ForeColor = $script:T['TextDim'] })
    $btnClose.add_Click({ param($s, $e) $s.FindForm().Close() })
    $form.Controls.Add($btnClose)

    if ($WithMinimize) {
        $btnMin = New-Object System.Windows.Forms.Label
        $btnMin.SetBounds(($Width - 76), 10, 30, 26)
        $btnMin.Text = '-'
        $btnMin.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $btnMin.Font = (New-ThemeFont 12 -Bold)
        $btnMin.ForeColor = $script:T['TextDim']
        $btnMin.BackColor = [System.Drawing.Color]::Transparent
        $btnMin.Cursor = [System.Windows.Forms.Cursors]::Hand
        $btnMin.add_MouseEnter({ param($s, $e) $s.ForeColor = $script:T['Cyan'] })
        $btnMin.add_MouseLeave({ param($s, $e) $s.ForeColor = $script:T['TextDim'] })
        $btnMin.add_Click({
            param($s, $e)
            $s.FindForm().WindowState = [System.Windows.Forms.FormWindowState]::Minimized
        })
        $form.Controls.Add($btnMin)
    }

    # 窗口图标(alt-tab、任务栏预览会用到)
    try { $form.Icon = New-ThemeIcon } catch { }

    # 无边框窗口在其他程序占据焦点时可能开在后面,显示后主动置前一次。
    # 用 SetForegroundWindow 而不是 TopMost 翻转——后者会让窗口闪一下。
    $form.add_Shown({
        param($sender, $e)
        try {
            $sender.Activate()
            if ($null -ne ('NBot.Win' -as [type])) {
                [void][NBot.Win]::SetForegroundWindow($sender.Handle)
            }
        } catch { }
    })

    Set-RoundedRegion $form 12
    return $form
}

# --- 卡片容器 ----------------------------------------------------------------

function New-ThemeCard {
    param($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Title)

    $card = New-Object System.Windows.Forms.Panel
    $card.SetBounds($X, $Y, $W, $H)
    $card.BackColor = [System.Drawing.Color]::Transparent
    $card.add_Paint({
        param($sender, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $path = New-RoundedPath 0 0 ($sender.Width - 1) ($sender.Height - 1) 10
            $fill = New-Object System.Drawing.SolidBrush($script:T['Card'])
            $g.FillPath($fill, $path)
            $pen = New-ThemePen $script:T['CardEdge'] 1
            $g.DrawPath($pen, $path)
            $fill.Dispose(); $pen.Dispose(); $path.Dispose()
        } catch {
            Add-ThemePaintError 'card' $_.Exception.Message
        }
    })
    $Parent.Controls.Add($card)

    if ($Title) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.SetBounds(14, 8, ($W - 28), 20)
        $lbl.Text = $Title
        $lbl.Font = (New-ThemeFont 9.5 -Bold)
        $lbl.ForeColor = $script:T['Pink']
        $lbl.BackColor = [System.Drawing.Color]::Transparent
        $card.Controls.Add($lbl)
    }
    return $card
}

# --- 按钮(圆角渐变 + hover 发光)-------------------------------------------
# Kind: primary(粉紫渐变) / accent(青) / ghost(描边) / danger(红)

function New-ThemeButton {
    param($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text,
          [string]$Kind, $OnClick)

    if (-not $Kind) { $Kind = 'ghost' }
    $btn = New-Object System.Windows.Forms.Label
    $btn.SetBounds($X, $Y, $W, $H)
    $btn.Text = $Text
    $btn.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $btn.Font = (New-ThemeFont 9.5 -Bold)
    $btn.BackColor = [System.Drawing.Color]::Transparent
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.ForeColor = $script:T['Text']
    $btn.Tag = @{ 'kind' = $Kind; 'hover' = $false }

    $btn.add_Paint({
        param($sender, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $info = $sender.Tag
            $kind = [string]$info['kind']
            $hover = [bool]$info['hover']
            $path = New-RoundedPath 0 0 ($sender.Width - 1) ($sender.Height - 1) 8

            if ($kind -eq 'primary') {
                $c1 = $script:T['Pink']; $c2 = $script:T['Purple']
                if ($hover) { $c1 = $script:T['Cyan']; $c2 = $script:T['Pink'] }
                $brush = New-LinearBrush 0 0 $sender.Width 0 $c1 $c2
                $g.FillPath($brush, $path)
                $brush.Dispose()
            } elseif ($kind -eq 'accent') {
                $c1 = $script:T['Cyan']; $c2 = $script:T['Purple']
                if ($hover) { $c1 = $script:T['Pink']; $c2 = $script:T['Cyan'] }
                $brush = New-LinearBrush 0 0 $sender.Width 0 $c1 $c2
                $g.FillPath($brush, $path)
                $brush.Dispose()
            } elseif ($kind -eq 'danger') {
                $fillColor = $script:T['Card']
                if ($hover) { $fillColor = $script:T['Bad'] }
                $fill = New-Object System.Drawing.SolidBrush($fillColor)
                $g.FillPath($fill, $path)
                $fill.Dispose()
                $pen = New-ThemePen $script:T['Bad'] 1
                $g.DrawPath($pen, $path)
                $pen.Dispose()
            } else {
                $fill = New-Object System.Drawing.SolidBrush($script:T['Card'])
                $g.FillPath($fill, $path)
                $fill.Dispose()
                $edge = $script:T['CardEdge']
                if ($hover) { $edge = $script:T['Pink'] }
                $pen = New-ThemePen $edge 1
                $g.DrawPath($pen, $path)
                $pen.Dispose()
            }
            $path.Dispose()

            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $textBrush = New-Object System.Drawing.SolidBrush($sender.ForeColor)
            $layout = New-Object System.Drawing.RectangleF(
                [single]0, [single]0, [single]$sender.Width, [single]$sender.Height)
            $g.DrawString($sender.Text, $sender.Font, $textBrush, $layout, $sf)
            $textBrush.Dispose(); $sf.Dispose()
        } catch {
            Add-ThemePaintError 'button' $_.Exception.Message
        }
    })
    $btn.add_MouseEnter({
        param($s, $e)
        $info = $s.Tag; $info['hover'] = $true; $s.Tag = $info; $s.Invalidate()
    })
    $btn.add_MouseLeave({
        param($s, $e)
        $info = $s.Tag; $info['hover'] = $false; $s.Tag = $info; $s.Invalidate()
    })
    if ($OnClick) { $btn.add_Click($OnClick) }
    $Parent.Controls.Add($btn)
    return $btn
}

# --- 文本与输入 --------------------------------------------------------------

function New-ThemeLabel {
    param($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text,
          [single]$Size, [switch]$Bold, [string]$ColorName)

    if ($Size -le 0) { $Size = 9 }
    if (-not $ColorName) { $ColorName = 'Text' }
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.SetBounds($X, $Y, $W, $H)
    $lbl.Text = $Text
    if ($Bold) { $lbl.Font = (New-ThemeFont $Size -Bold) } else { $lbl.Font = (New-ThemeFont $Size) }
    $lbl.ForeColor = $script:T[$ColorName]
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $Parent.Controls.Add($lbl)
    return $lbl
}

function New-ThemeTextBox {
    param($Parent, [int]$X, [int]$Y, [int]$W, [string]$Text)
    $box = New-Object System.Windows.Forms.TextBox
    $box.SetBounds($X, $Y, $W, 24)
    $box.Text = $Text
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $box.BackColor = [System.Drawing.Color]::FromArgb(28, 20, 52)
    $box.ForeColor = $script:T['Text']
    $box.Font = (New-ThemeFont 9)
    $Parent.Controls.Add($box)
    return $box
}

function New-ThemeCombo {
    param($Parent, [int]$X, [int]$Y, [int]$W, $Items, [int]$SelectedIndex)
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.SetBounds($X, $Y, $W, 24)
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $combo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $combo.BackColor = [System.Drawing.Color]::FromArgb(28, 20, 52)
    $combo.ForeColor = $script:T['Text']
    $combo.Font = (New-ThemeFont 9)
    foreach ($item in $Items) { [void]$combo.Items.Add($item) }
    if ($combo.Items.Count -gt 0) { $combo.SelectedIndex = $SelectedIndex }
    $Parent.Controls.Add($combo)
    return $combo
}

function New-ThemeLogBox {
    param($Parent, [int]$X, [int]$Y, [int]$W, [int]$H)
    $box = New-Object System.Windows.Forms.TextBox
    $box.SetBounds($X, $Y, $W, $H)
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $box.BackColor = [System.Drawing.Color]::FromArgb(20, 14, 38)
    $box.ForeColor = $script:T['Ok']
    $box.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $Parent.Controls.Add($box)
    return $box
}

# --- 状态灯(圆点 + 文字)---------------------------------------------------

function New-ThemeStatusRow {
    param($Parent, [int]$X, [int]$Y, [int]$LabelW, [string]$Name)

    $dot = New-Object System.Windows.Forms.Panel
    $dot.SetBounds($X, ($Y + 5), 10, 10)
    $dot.BackColor = [System.Drawing.Color]::Transparent
    $dot.Tag = 'TextDim'
    $dot.add_Paint({
        param($sender, $e)
        try {
            $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $brush = New-Object System.Drawing.SolidBrush($script:T[[string]$sender.Tag])
            $e.Graphics.FillEllipse($brush, 0, 0, 9, 9)
            $brush.Dispose()
        } catch {
            Add-ThemePaintError 'statusdot' $_.Exception.Message
        }
    })
    $Parent.Controls.Add($dot)

    $lblName = New-Object System.Windows.Forms.Label
    $lblName.SetBounds(($X + 18), $Y, $LabelW, 20)
    $lblName.Text = $Name
    $lblName.Font = (New-ThemeFont 9)
    $lblName.ForeColor = $script:T['TextDim']
    $lblName.BackColor = [System.Drawing.Color]::Transparent
    $Parent.Controls.Add($lblName)

    $lblValue = New-Object System.Windows.Forms.Label
    $lblValue.SetBounds(($X + 18 + $LabelW), $Y, 240, 20)
    $lblValue.Text = '检测中...'
    $lblValue.Font = (New-ThemeFont 9 -Bold)
    $lblValue.ForeColor = $script:T['TextDim']
    $lblValue.BackColor = [System.Drawing.Color]::Transparent
    $Parent.Controls.Add($lblValue)

    $row = @{}
    $row['dot'] = $dot
    $row['value'] = $lblValue
    return $row
}

function Set-ThemeStatusRow {
    param($Row, [string]$Text, [string]$ColorName)
    $Row['dot'].Tag = $ColorName
    $Row['dot'].Invalidate()
    $Row['value'].Text = $Text
    $Row['value'].ForeColor = $script:T[$ColorName]
}
