# modules\tasks.ps1 - 计划任务 / 运行资产 / 生命周期管理(PowerShell 2.0 兼容)
# 由 install-core.ps1 dot-source;依赖 lib\common.ps1 提供的公共函数。

function Invoke-Schtasks {
    # 调用 schtasks.exe,吞掉输出与错误,返回退出码(异常时返回 1)。
    param($ArgList)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $code = 1
    try {
        & schtasks.exe $ArgList 2>$null | Out-Null
        $code = $LASTEXITCODE
    } catch {
        $code = 1
    }
    $ErrorActionPreference = $old
    return $code
}

function Remove-DirSafe {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try { Remove-Item -LiteralPath $Path -Recurse -Force } catch { }
    }
}

function Remove-FileSafe {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try { Remove-Item -LiteralPath $Path -Force } catch { }
    }
}

function Add-BinToMachinePath {
    param([string]$Bin)
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
        if (-not $key) {
            Write-Warn '无法打开系统环境变量注册表项,跳过 PATH 配置。'
            return
        }
        $cur = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $norm = $Bin.TrimEnd('\')
        $found = $false
        foreach ($part in ($cur -split ';')) {
            if ($part.Trim().TrimEnd('\') -eq $norm) { $found = $true; break }
        }
        if (-not $found) {
            $new = $cur.TrimEnd(';')
            if ($new) { $new = $new + ';' + $norm } else { $new = $norm }
            $key.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            Write-Info "已将 $norm 加入系统 PATH,新开的命令行窗口可直接使用 nbot 命令。"
        }
        $key.Close()
    } catch {
        Write-Warn "更新系统 PATH 失败: $($_.Exception.Message)"
    }
}

function Remove-BinFromMachinePath {
    param([string]$Bin)
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
        if (-not $key) { return }
        $cur = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $norm = $Bin.TrimEnd('\')
        $parts = @()
        $changed = $false
        foreach ($part in ($cur -split ';')) {
            if ($part.Trim().TrimEnd('\') -eq $norm) { $changed = $true; continue }
            if ($part -ne '') { $parts += $part }
        }
        if ($changed) {
            $key.SetValue('Path', ($parts -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
            Write-Info "已从系统 PATH 移除 $norm。"
        }
        $key.Close()
    } catch {
        Write-Warn "更新系统 PATH 失败: $($_.Exception.Message)"
    }
}

function Install-DesktopShortcut {
    # 在公共桌面创建「nbot 面板」快捷方式,指向安装器自拷贝目录的 panel.bat。
    try {
        # 用 wscript 引导 panel.vbs:.bat 每次启动都会闪一下 cmd 控制台窗口,
        # wscript 没有控制台,提权与隐藏启动全部在 vbs 里完成。
        $panel = Join-Path (Get-InstallerDir) 'panel.vbs'
        $useWscript = $true
        if (-not (Test-Path -LiteralPath $panel)) {
            $panel = Join-Path (Get-InstallerDir) 'panel.bat'
            $useWscript = $false
        }
        if (-not (Test-Path -LiteralPath $panel)) { return }
        $desktop = Join-Path $env:PUBLIC 'Desktop'
        if (-not (Test-Path -LiteralPath $desktop)) { return }
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut((Join-Path $desktop 'nbot 面板.lnk'))
        if ($useWscript) {
            $lnk.TargetPath = (Join-Path $env:SystemRoot 'System32\wscript.exe')
            $lnk.Arguments = '"' + $panel + '"'
        } else {
            $lnk.TargetPath = $panel
        }
        $lnk.WorkingDirectory = (Get-InstallerDir)
        # 用自带的猫头图标;缺失时退回系统图标(不要用 wscript.exe 自己的图标)
        $ico = Join-Path (Get-BinDir) 'nbot.ico'
        if (Test-Path -LiteralPath $ico) {
            $lnk.IconLocation = $ico + ',0'
        } else {
            $lnk.IconLocation = '%SystemRoot%\System32\shell32.dll,21'
        }
        $lnk.Description = 'nbot 图形控制面板 (AstrBot + NapCat + QQ)'
        $lnk.Save()
        Write-Info '已创建桌面快捷方式:nbot 面板'
    } catch {
        Write-Warn ('创建桌面快捷方式失败: ' + $_.Exception.Message)
    }
}

function Remove-DesktopShortcut {
    $lnkPath = Join-Path (Join-Path $env:PUBLIC 'Desktop') 'nbot 面板.lnk'
    Remove-FileSafe $lnkPath
}

function Install-RuntimeAssets {
    $src = Join-Path (Get-ScriptRoot) 'assets\bin'
    $bin = Get-BinDir
    if (-not (Test-Path -LiteralPath $src)) {
        Die "未找到运行资产目录: $src"
    }
    Get-ChildItem -Path $src | ForEach-Object {
        if (-not $_.PSIsContainer) {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $bin $_.Name) -Force
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $bin 'nbot.cmd'))) {
        Die "运行资产不完整: $bin 中缺少 nbot.cmd。"
    }
    Add-BinToMachinePath $bin
    Install-DesktopShortcut
}

function Install-Tasks {
    $bin = Get-BinDir
    $astr = Join-Path $bin 'astrbot-launch.bat'
    $snow = Join-Path $bin 'napcat-launch.bat'
    $wd = Join-Path $bin 'watchdog.ps1'

    # AstrBot: 开机以 SYSTEM 运行
    & schtasks.exe /Create /F /TN '\NBot\AstrBot' /SC ONSTART /RU SYSTEM /RL HIGHEST /TR ('"' + $astr + '"') | Out-Null
    if ($LASTEXITCODE -ne 0) { Die '创建计划任务 \NBot\AstrBot 失败。' }

    # NapCat: 用户登录时以当前用户最高权限运行(不加 /RU,仅登录时运行)。
    # 经 run-hidden.vbs 启动,隐藏 napcat-launch.bat 的控制台窗口(QQ 界面不受影响)。
    $hidden = Join-Path $bin 'run-hidden.vbs'
    $snowTr = 'wscript.exe //B "' + $hidden + '" "' + $snow + '"'
    & schtasks.exe /Create /F /TN '\NBot\NapCat' /SC ONLOGON /RL HIGHEST /TR $snowTr | Out-Null
    if ($LASTEXITCODE -ne 0) { Die '创建计划任务 \NBot\NapCat 失败。' }

    # Watchdog: 每分钟以 SYSTEM 运行
    $wdTr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $wd + '"'
    & schtasks.exe /Create /F /TN '\NBot\Watchdog' /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST /TR $wdTr | Out-Null
    if ($LASTEXITCODE -ne 0) { Die '创建计划任务 \NBot\Watchdog 失败。' }

    Write-Info '计划任务已创建: \NBot\AstrBot、\NBot\NapCat、\NBot\Watchdog'
}

function Enable-Autostart {
    foreach ($t in @('AstrBot', 'NapCat', 'Watchdog')) {
        [void](Invoke-Schtasks @('/Change', '/TN', "\NBot\$t", '/Enable'))
    }
    Remove-FileSafe (Join-Path (Get-StateDir) 'autostart.disabled')
    Write-Info '开机自启已开启:AstrBot 开机自动运行,NapCat+QQ 随用户登录桌面自动运行,看门狗恢复守护。'
}

function Disable-Autostart {
    foreach ($t in @('AstrBot', 'NapCat', 'Watchdog')) {
        [void](Invoke-Schtasks @('/End', '/TN', "\NBot\$t"))
        [void](Invoke-Schtasks @('/Change', '/TN', "\NBot\$t", '/Disable'))
    }
    $state = Get-StateDir
    Remove-FileSafe (Join-Path $state 'astrbot.enabled')
    Remove-FileSafe (Join-Path $state 'napcat.enabled')
    Write-TextFile (Join-Path $state 'autostart.disabled') ''
    Write-Info '开机自启已关闭:三个计划任务已禁用并停止,开机/登录不再自动运行(数据不受影响)。'
    Write-Info '重新使用请点「启动全部」(会自动恢复自启),或执行 nbot autostart-on。'
}

function Restart-BotTask {
    param([string]$Name)
    [void](Invoke-Schtasks @('/End', '/TN', "\NBot\$Name"))
    if ($Name -eq 'NapCat') {
        # schtasks /end 只结束任务直接启动的进程,QQ 是启动器拉起的孙子进程,
        # 杀不掉。残留的旧 QQ 还占着登录态,新实例快速登录时会被「当前账号
        # 已登录,无法重复登录」挡住 -> OneBot 网络不启动 -> 连不上 AstrBot。
        # 所以重启 NapCat 必须连 QQ 进程树一起收掉(登录态存在本地,会自动
        # 快速登录回来,不需要重新扫码)。
        & cmd.exe /c 'taskkill /im QQ.exe /t /f >nul 2>nul'
        Start-Sleep -Seconds 3
    }
    if ($Name -eq 'AstrBot') {
        Stop-AstrBotProcess
    }
    $rc = Invoke-Schtasks @('/Run', '/TN', "\NBot\$Name")
    if ($rc -ne 0) {
        Write-Warn "启动计划任务 \NBot\$Name 失败,请检查任务是否已创建(NapCat 需要用户已登录桌面)。"
    }
}

function Start-Stack {
    $state = Get-StateDir
    # 若此前关闭过自启,启动时自动恢复(禁用状态下 schtasks /run 会失败)
    if (Test-Path -LiteralPath (Join-Path $state 'autostart.disabled')) {
        Enable-Autostart
    }
    Write-TextFile (Join-Path $state 'astrbot.enabled') ''
    Write-TextFile (Join-Path $state 'napcat.enabled') ''
    # 用户主动启动 = 明确表示「现在该跑了」:清掉看门狗因反复启动失败而
    # 设下的放弃标记与重启计数,让守护重新生效。
    foreach ($n in @('astrbot', 'napcat')) {
        Remove-FileSafe (Join-Path $state ($n + '.giveup'))
        Remove-FileSafe (Join-Path $state ($n + '.restart-history'))
        Remove-FileSafe (Join-Path $state ($n + '.dead-restarted'))
    }
    $rc = Invoke-Schtasks @('/Run', '/TN', '\NBot\AstrBot')
    if ($rc -ne 0) { Write-Warn '启动 AstrBot 计划任务失败,请先执行安装或修复。' }
    $rc = Invoke-Schtasks @('/Run', '/TN', '\NBot\NapCat')
    if ($rc -ne 0) { Write-Warn '启动 NapCat 计划任务失败:该任务仅在用户登录 Windows 桌面时可运行。' }
    Write-Info '已请求启动 AstrBot 与 NapCat,看门狗将持续守护。'
}

function Stop-Stack {
    $state = Get-StateDir
    Remove-FileSafe (Join-Path $state 'astrbot.enabled')
    Remove-FileSafe (Join-Path $state 'napcat.enabled')
    [void](Invoke-Schtasks @('/End', '/TN', '\NBot\AstrBot'))
    [void](Invoke-Schtasks @('/End', '/TN', '\NBot\NapCat'))

    # WMI 兜底终止 AstrBot 的 python 进程
    try {
        $procs = Get-WmiObject Win32_Process -Filter "Name='python.exe'"
        foreach ($p in @($procs)) {
            if (-not $p) { continue }
            if ($p.CommandLine -and $p.CommandLine.ToLower().Contains('\app\main.py')) {
                try { [void]$p.Terminate() } catch { }
            }
        }
    } catch { }
    # WMI 兜底终止 QQ 进程
    try {
        $procs = Get-WmiObject Win32_Process -Filter "Name='QQ.exe'"
        foreach ($p in @($procs)) {
            if (-not $p) { continue }
            try { [void]$p.Terminate() } catch { }
        }
    } catch { }
    Write-Info '已停止 AstrBot 与 NapCat(已移除守护标记,看门狗不会再拉起)。'
}

function Show-Status {
    Write-Bold '== 计划任务状态 =='
    foreach ($t in @('AstrBot', 'NapCat', 'Watchdog')) {
        $out = $null
        $code = 1
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & schtasks.exe /Query /TN "\NBot\$t" /FO LIST /V 2>$null
            $code = $LASTEXITCODE
        } catch { $code = 1 }
        $ErrorActionPreference = $old
        if ($code -ne 0 -or -not $out) {
            Write-Warn "\NBot\${t}: 未创建"
            continue
        }
        $status = ''
        $lastRun = ''
        foreach ($line in @($out)) {
            if (-not $line) { continue }
            $s = [string]$line
            if ((-not $status) -and ($s -match '^\s*(Status|状态)\s*:\s*(.+)$')) { $status = $matches[2].Trim() }
            if ((-not $lastRun) -and ($s -match '^\s*(Last Run Time|上次运行时间)\s*:\s*(.+)$')) { $lastRun = $matches[2].Trim() }
        }
        if (-not $status) { $status = '未知' }
        $msg = "\NBot\${t}: $status"
        if ($lastRun) { $msg = $msg + "(上次运行: $lastRun)" }
        Write-Info $msg
    }

    Write-Bold '== 服务健康检查 =='
    $aPort = Get-Cfg 'ASTRBOT_PORT'
    if (-not $aPort) { $aPort = 6185 }
    $sPort = Get-Cfg 'NAPCAT_WEBUI_PORT'
    if (-not $sPort) { $sPort = 6099 }
    if (Test-HttpOk "http://127.0.0.1:$aPort/" 3000) {
        Write-Info "AstrBot WebUI (127.0.0.1:$aPort): 正常"
    } else {
        Write-Warn "AstrBot WebUI (127.0.0.1:$aPort): 无响应"
    }
    if (Test-TcpOk '127.0.0.1' $sPort 3000) {
        Write-Info "NapCat WebUI (127.0.0.1:$sPort): 正常"
    } else {
        Write-Warn "NapCat WebUI (127.0.0.1:$sPort): 无响应"
    }
    $qq = Get-Process -Name QQ -ErrorAction SilentlyContinue
    if ($qq) {
        Write-Info 'QQ.exe 进程: 运行中'
    } else {
        Write-Warn 'QQ.exe 进程: 未运行'
    }
}

function Repair-Stack {
    # schtasks /Create /F 会终止任务当前正在运行的实例,因此先记下哪些组件
    # 处于启用状态,重建任务后再把它们拉起来,避免「修复」把跑着的服务打断。
    $state = Get-StateDir
    $wasAstr = Test-Path -LiteralPath (Join-Path $state 'astrbot.enabled')
    $wasNap = Test-Path -LiteralPath (Join-Path $state 'napcat.enabled')

    Install-RuntimeAssets
    Install-Tasks
    $aRoot = Get-Cfg 'ASTRBOT_ROOT'
    if (-not $aRoot) { $aRoot = 'C:\AstrBot' }
    Ensure-Dir $aRoot
    Ensure-Dir (Join-Path $aRoot 'logs')
    Ensure-Dir (Join-Path $aRoot 'data')
    $sRoot = Get-Cfg 'NAPCAT_ROOT'
    if (-not $sRoot) { $sRoot = 'C:\NapCat' }
    foreach ($d in @('config', 'cache', 'data', 'logs', 'tmp', 'run')) {
        Ensure-Dir (Join-Path $sRoot $d)
    }
    if ($wasAstr) {
        $rc = Invoke-Schtasks @('/Run', '/TN', '\NBot\AstrBot')
        if ($rc -eq 0) { Write-Info '已重新拉起 AstrBot(修复前处于运行状态)。' }
        else { Write-Warn '重新拉起 AstrBot 失败,请点「启动全部」。' }
    }
    if ($wasNap) {
        $rc = Invoke-Schtasks @('/Run', '/TN', '\NBot\NapCat')
        if ($rc -eq 0) { Write-Info '已重新拉起 NapCat(修复前处于运行状态)。' }
        else { Write-Warn '重新拉起 NapCat 失败(该任务需用户已登录桌面),请点「启动全部」。' }
    }
    Write-Info '修复完成:运行资产、计划任务与目录结构已重建。'
}

function Uninstall-Core {
    # 卸载的必做部分:停服务、删计划任务、撤命令/快捷方式/托盘自启、清状态。
    # 不碰任何数据目录;QQ 程序本体也不动(需要卸载请走系统「应用」)。
    Stop-Stack
    $bin = Get-BinDir
    $state = Get-StateDir
    foreach ($t in @('AstrBot', 'NapCat', 'Watchdog')) {
        [void](Invoke-Schtasks @('/End', '/TN', "\NBot\$t"))
        [void](Invoke-Schtasks @('/Delete', '/F', '/TN', "\NBot\$t"))
    }
    Remove-BinFromMachinePath $bin
    Remove-DesktopShortcut
    # 撤掉「开机常驻托盘」的 HKCU Run 项
    try {
        $run = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run', $true)
        if ($run) { $run.DeleteValue('NBotTray', $false); $run.Close() }
    } catch { }
    foreach ($f in @('astrbot.enabled', 'napcat.enabled', 'autostart.disabled',
        'payload-current.txt', 'payload-previous.txt', 'panel.show-request')) {
        Remove-FileSafe (Join-Path $state $f)
    }
    Write-Info '已移除:计划任务、nbot 命令、桌面快捷方式、托盘自启。'
}

function Uninstall-Data {
    # 按选择删除数据目录。ProgramData 放最后:控制台里跑的 install.bat 就住在
    # 里面,自删可能残留少量文件,残留时提示手动清理。
    param([bool]$DeleteAstr, [bool]$DeleteNap, [bool]$DeleteProgData)
    if ($DeleteAstr) {
        $aRoot = Get-Cfg 'ASTRBOT_ROOT'
        if ($aRoot -and (Test-Path -LiteralPath $aRoot)) {
            Remove-DirSafe $aRoot
            if (Test-Path -LiteralPath $aRoot) { Write-Warn "$aRoot 有残留(可能被占用),请稍后手动删除。" }
            else { Write-Info "已删除 AstrBot 数据目录: $aRoot" }
        }
    }
    if ($DeleteNap) {
        $sRoot = Get-Cfg 'NAPCAT_ROOT'
        if ($sRoot -and (Test-Path -LiteralPath $sRoot)) {
            Remove-DirSafe $sRoot
            if (Test-Path -LiteralPath $sRoot) { Write-Warn "$sRoot 有残留(可能被占用),请稍后手动删除。" }
            else { Write-Info "已删除 NapCat 数据目录: $sRoot" }
        }
    }
    if ($DeleteProgData) {
        $base = Get-NBotDir
        Remove-DirSafe $base
        if (Test-Path -LiteralPath $base) { Write-Warn "$base 有残留(卸载脚本自身在使用),请稍后手动删除。" }
        else { Write-Info "已删除: $base" }
    }
    Write-Info 'QQ 程序本体未卸载;如需卸载请到系统「设置 -> 应用」中操作(登录态在 Documents\Tencent Files)。'
}

function Uninstall-Quiet {
    # 免交互卸载(GUI 卸载对话框调用):$Flags 为逗号分隔的删除范围,
    # 可含 data(AstrBot 目录)、napcat(NapCat 目录)、programdata。
    param([string]$Flags)
    $delAstr = $false; $delNap = $false; $delProg = $false
    if ($Flags) {
        foreach ($flag in ($Flags -split ',')) {
            $f = ([string]$flag).Trim().ToLower()
            if ($f -eq 'data') { $delAstr = $true }
            elseif ($f -eq 'napcat') { $delNap = $true }
            elseif ($f -eq 'programdata') { $delProg = $true }
        }
    }
    Write-Bold '开始卸载 nbot...'
    Uninstall-Core
    Uninstall-Data $delAstr $delNap $delProg
    Write-Info '卸载完成。'
}

function Uninstall-Stack {
    # 命令行/菜单交互式卸载:逐项询问删除范围,默认全部保留。
    if (-not (Confirm-Action '确定要卸载 nbot 吗?(接下来会逐项询问删除范围)' $false)) {
        Write-Info '已取消卸载。'
        return
    }
    Uninstall-Core
    $aRoot = Get-Cfg 'ASTRBOT_ROOT'
    $sRoot = Get-Cfg 'NAPCAT_ROOT'
    $delAstr = Confirm-Action "删除 AstrBot 数据目录 $aRoot(机器人配置、插件、聊天数据都会没)?" $false
    $delNap = Confirm-Action "删除 NapCat 数据目录 $sRoot(OneBot/WebUI 配置与日志)?" $false
    $delProg = Confirm-Action ("删除安装器与运行数据 " + (Get-NBotDir) + "?") $false
    Uninstall-Data $delAstr $delNap $delProg
}

function Open-QQLogin {
    $rc = Invoke-Schtasks @('/Run', '/TN', '\NBot\NapCat')
    if ($rc -ne 0) {
        Write-Warn '无法启动 \NBot\NapCat 计划任务,请先执行安装或修复。'
    }
    $bin = Get-BinDir
    Write-Info '请在弹出的 QQ 窗口中扫码或点击登录。'
    Write-Info "若窗口没有出现:请确认当前已登录 Windows 桌面,或直接运行 $bin\napcat-launch.bat。"
}
