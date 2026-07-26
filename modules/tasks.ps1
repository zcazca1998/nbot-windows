# modules\tasks.ps1 - 计划任务 / 运行资产 / 生命周期管理(PowerShell 2.0 兼容)
# 由 install-core.ps1 dot-source;依赖 lib\common.ps1 提供的公共函数。
# 双后端:按 BOT_BACKEND(napcat/snowluma)分支,后端信息一律通过
# lib\common.ps1 的 Get-Backend/Test-SnowLuma/Get-BotName/Get-BotTaskPath
# 等函数取得,本文件不自己解析 BOT_BACKEND。

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
        $lnk.Description = ('nbot 图形控制面板 (AstrBot + ' + (Get-BotName) + ' + QQ)')
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
    $botName = Get-BotName
    $botTask = Get-BotTaskPath
    $bot = Join-Path $bin (Get-BotLaunchScript)
    $wd = Join-Path $bin 'watchdog.ps1'

    # AstrBot: 开机以 SYSTEM 运行
    & schtasks.exe /Create /F /TN '\NBot\AstrBot' /SC ONSTART /RU SYSTEM /RL HIGHEST /TR ('"' + $astr + '"') | Out-Null
    if ($LASTEXITCODE -ne 0) { Die '创建计划任务 \NBot\AstrBot 失败。' }

    # 机器人后端(NapCat / SnowLuma): 用户登录时以当前用户最高权限运行
    # (不加 /RU,仅登录时运行)。经 run-hidden.vbs 启动,隐藏启动脚本的
    # 控制台窗口(QQ 界面不受影响)。
    $hidden = Join-Path $bin 'run-hidden.vbs'
    $botTr = 'wscript.exe //B "' + $hidden + '" "' + $bot + '"'
    & schtasks.exe /Create /F /TN $botTask /SC ONLOGON /RL HIGHEST /TR $botTr | Out-Null
    if ($LASTEXITCODE -ne 0) { Die ('创建计划任务 ' + $botTask + ' 失败。') }

    # Watchdog: 每分钟以 SYSTEM 运行
    $wdTr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $wd + '"'
    & schtasks.exe /Create /F /TN '\NBot\Watchdog' /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST /TR $wdTr | Out-Null
    if ($LASTEXITCODE -ne 0) { Die '创建计划任务 \NBot\Watchdog 失败。' }

    Write-Info ('计划任务已创建: \NBot\AstrBot、' + $botTask + '、\NBot\Watchdog')
}

function Enable-Autostart {
    $botName = Get-BotName
    foreach ($t in @('AstrBot', $botName, 'Watchdog')) {
        [void](Invoke-Schtasks @('/Change', '/TN', "\NBot\$t", '/Enable'))
    }
    Remove-FileSafe (Join-Path (Get-StateDir) 'autostart.disabled')
    Write-Info ('开机自启已开启:AstrBot 开机自动运行,' + $botName + '+QQ 随用户登录桌面自动运行,看门狗恢复守护。')
}

function Disable-Autostart {
    foreach ($t in @('AstrBot', (Get-BotName), 'Watchdog')) {
        [void](Invoke-Schtasks @('/End', '/TN', "\NBot\$t"))
        [void](Invoke-Schtasks @('/Change', '/TN', "\NBot\$t", '/Disable'))
    }
    $state = Get-StateDir
    Remove-FileSafe (Join-Path $state 'astrbot.enabled')
    # 两个后端的守护标记都清:后端切换后残留的旧标记不能留给看门狗。
    Remove-FileSafe (Join-Path $state 'napcat.enabled')
    Remove-FileSafe (Join-Path $state 'snowluma.enabled')
    Write-TextFile (Join-Path $state 'autostart.disabled') ''
    Write-Info '开机自启已关闭:三个计划任务已禁用并停止,开机/登录不再自动运行(数据不受影响)。'
    Write-Info '重新使用请点「启动全部」(会自动恢复自启),或执行 nbot autostart-on。'
}

function Get-SnowlumaProcess {
    # 找出属于本安装的 SnowLuma node 进程。
    #
    # 不能只按进程名 node.exe 认 —— 用户机器上很可能跑着别的 Node 程序,
    # 误杀会很难查。这里要求命令行里同时出现 index.mjs 和我们的载荷路径。
    # 载荷经 junction 挂在 <payload>\current,node 的工作目录就是那里,
    # 命令行往往写成相对路径 ./index.mjs,所以两种形态都认:
    # 命令行里带载荷绝对路径,或者可执行文件本身位于载荷目录下。
    $payload = Get-Cfg 'SL_PAYLOAD_ROOT'
    $payLower = ''
    if ($payload) { $payLower = ([string]$payload).ToLower() }
    $result = @()
    try {
        $procs = Get-WmiObject Win32_Process -Filter "Name='node.exe'"
        foreach ($p in @($procs)) {
            if (-not $p) { continue }
            $cl = $p.CommandLine
            if (-not $cl) { continue }
            $clLower = ([string]$cl).ToLower()
            if (-not $clLower.Contains('index.mjs')) { continue }
            if ($payLower -and (-not $clLower.Contains($payLower))) { continue }
            $result += $p
        }
    } catch { }
    return $result
}

function Stop-SnowlumaProcess {
    # 结束 SnowLuma 的 node 进程。
    #
    # schtasks /End 只结束任务直接启动的进程(wscript),node 是它的孙子进程,
    # 不会被带走 —— 残留的旧实例还占着 WebUI 端口,新实例起不来。
    foreach ($p in @(Get-SnowlumaProcess)) {
        try { [void]$p.Terminate() } catch { }
    }
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
    if ($Name -eq 'SnowLuma') {
        # 只收掉 SnowLuma 自己的 node 进程,QQ 保持运行。
        # SnowLuma 是注入型的:它退出后 hook 仍留在 QQ 进程里,新实例启动时
        # 会通过命名管道重新接上同一个 QQ。杀 QQ 既没必要,还会打断登录态。
        Stop-SnowlumaProcess
        Start-Sleep -Seconds 2
    }
    if ($Name -eq 'AstrBot') {
        Stop-AstrBotProcess
    }
    $rc = Invoke-Schtasks @('/Run', '/TN', "\NBot\$Name")
    if ($rc -ne 0) {
        Write-Warn ("启动计划任务 \NBot\$Name 失败,请检查任务是否已创建(" + (Get-BotName) + " 需要用户已登录桌面)。")
    }
}

function Start-Stack {
    $state = Get-StateDir
    # 若此前关闭过自启,启动时自动恢复(禁用状态下 schtasks /run 会失败)
    if (Test-Path -LiteralPath (Join-Path $state 'autostart.disabled')) {
        Enable-Autostart
    }
    Write-TextFile (Join-Path $state 'astrbot.enabled') ''
    Write-TextFile (Join-Path $state ((Get-BotMarker) + '.enabled')) ''
    # 用户主动启动 = 明确表示「现在该跑了」:清掉看门狗因反复启动失败而
    # 设下的放弃标记与重启计数,让守护重新生效。
    if (Test-SnowLuma) {
        $giveupNames = @('astrbot', 'snowluma', 'qq')
    } else {
        $giveupNames = @('astrbot', 'napcat')
    }
    foreach ($n in $giveupNames) {
        Remove-FileSafe (Join-Path $state ($n + '.giveup'))
        Remove-FileSafe (Join-Path $state ($n + '.restart-history'))
        Remove-FileSafe (Join-Path $state ($n + '.dead-restarted'))
    }
    $rc = Invoke-Schtasks @('/Run', '/TN', '\NBot\AstrBot')
    if ($rc -ne 0) { Write-Warn '启动 AstrBot 计划任务失败,请先执行安装或修复。' }
    if (Test-SnowLuma) {
        # run-hidden.vbs 不等 node 退出就返回,任务状态早早显示"已完成";不先收掉
        # 旧 node 就 /Run,会在旧实例还占着 WebUI 端口时再拉起一整套 cmd -> node,
        # 新实例撞端口失败,用户以为点了「启动全部」却什么也没发生。
        [void](Invoke-Schtasks @('/End', '/TN', '\NBot\SnowLuma'))
        Stop-SnowlumaProcess
        Start-Sleep -Seconds 2
        $rc = Invoke-Schtasks @('/Run', '/TN', '\NBot\SnowLuma')
        if ($rc -ne 0) { Write-Warn '启动 SnowLuma 计划任务失败:该任务仅在用户登录 Windows 桌面时可运行。' }
    } else {
        $rc = Invoke-Schtasks @('/Run', '/TN', '\NBot\NapCat')
        if ($rc -ne 0) { Write-Warn '启动 NapCat 计划任务失败:该任务仅在用户登录 Windows 桌面时可运行。' }
    }
    Write-Info ('已请求启动 AstrBot 与 ' + (Get-BotName) + ',看门狗将持续守护。')
}

function Stop-Stack {
    $state = Get-StateDir
    Remove-FileSafe (Join-Path $state 'astrbot.enabled')
    # 两个后端的守护标记都清:后端切换后残留的旧标记不能留给看门狗。
    Remove-FileSafe (Join-Path $state 'napcat.enabled')
    Remove-FileSafe (Join-Path $state 'snowluma.enabled')
    [void](Invoke-Schtasks @('/End', '/TN', '\NBot\AstrBot'))
    [void](Invoke-Schtasks @('/End', '/TN', (Get-BotTaskPath)))

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
    if (Test-SnowLuma) {
        # 收掉 SnowLuma 的 node 进程(schtasks /End 带不走孙子进程)
        Stop-SnowlumaProcess

        # 到此为止,不动 QQ。
        #
        # NapCat 版在这里会一并杀掉 QQ,因为那边 QQ 是它的启动器拉起的子进程,
        # 「停止全部」当然连它一起停。SnowLuma 版不成立:QQ 是用户自己的聊天
        # 软件,很可能在本项目安装之前就一直开着(实测这台机器就是如此)。
        # 用户点「停止全部」要停的是机器人,不是自己正在用的 QQ —— 顺手关掉
        # 别人的聊天窗口是不可接受的越权。
        # 启动器只在 QQ 不在跑时才拉起它,所以不停 QQ 也不影响下次启动。
        $qq = @(Get-Process -Name QQ -ErrorAction SilentlyContinue)
        Write-Info '已停止 AstrBot 与 SnowLuma(已移除守护标记,看门狗不会再拉起)。'
        if ($qq.Count -gt 0) {
            Write-Info 'QQ 未被关闭(它是你自己的聊天软件,不归本程序管);需要的话请自行退出 QQ。'
        }
    } else {
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
}

function Show-Status {
    $botName = Get-BotName
    Write-Bold '== 计划任务状态 =='
    foreach ($t in @('AstrBot', $botName, 'Watchdog')) {
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
    $sPort = Get-BotWebuiPort
    if (Test-HttpOk "http://127.0.0.1:$aPort/" 3000) {
        Write-Info "AstrBot WebUI (127.0.0.1:$aPort): 正常"
    } else {
        Write-Warn "AstrBot WebUI (127.0.0.1:$aPort): 无响应"
    }
    if (Test-TcpOk '127.0.0.1' $sPort 3000) {
        Write-Info "$botName WebUI (127.0.0.1:$sPort): 正常"
    } else {
        Write-Warn "$botName WebUI (127.0.0.1:$sPort): 无响应"
    }
    if (Test-SnowLuma) {
        # SnowLuma 与 QQ 是两个独立进程(SnowLuma 注入 QQ,不负责启动它),
        # 所以两个都要单独报状态:只有 QQ 在跑不等于 hook 已经装上。
        $node = @(Get-SnowlumaProcess)
        if ($node.Count -gt 0) {
            Write-Info 'SnowLuma 进程: 运行中'
        } else {
            Write-Warn 'SnowLuma 进程: 未运行'
        }
        $qq = Get-Process -Name QQ -ErrorAction SilentlyContinue
        if ($qq) {
            Write-Info 'QQ.exe 进程: 运行中'
        } else {
            Write-Warn 'QQ.exe 进程: 未运行(SnowLuma 需要 QQ 在跑才能注入)'
        }
    } else {
        $qq = Get-Process -Name QQ -ErrorAction SilentlyContinue
        if ($qq) {
            Write-Info 'QQ.exe 进程: 运行中'
        } else {
            Write-Warn 'QQ.exe 进程: 未运行'
        }
    }
}

function Repair-Stack {
    # schtasks /Create /F 会终止任务当前正在运行的实例,因此先记下哪些组件
    # 处于启用状态,重建任务后再把它们拉起来,避免「修复」把跑着的服务打断。
    $state = Get-StateDir
    $wasAstr = Test-Path -LiteralPath (Join-Path $state 'astrbot.enabled')
    $wasBot = Test-Path -LiteralPath (Join-Path $state ((Get-BotMarker) + '.enabled'))

    Install-RuntimeAssets
    Install-Tasks
    $aRoot = Get-Cfg 'ASTRBOT_ROOT'
    if (-not $aRoot) { $aRoot = 'C:\AstrBot' }
    Ensure-Dir $aRoot
    Ensure-Dir (Join-Path $aRoot 'logs')
    Ensure-Dir (Join-Path $aRoot 'data')
    if (Test-SnowLuma) {
        $sRoot = Get-Cfg 'SL_ROOT'
        if (-not $sRoot) { $sRoot = 'C:\SnowLuma' }
        foreach ($d in @('config', 'logs')) {
            Ensure-Dir (Join-Path $sRoot $d)
        }
        # QQ 的安装路径可能变了(用户重装/升级过 QQ)。启动器要靠 QQ_EXE 拉起 QQ,
        # 路径失效会导致 SnowLuma 起来了却永远等不到 QQ,所以修复时重新探测。
        $qqExe = Find-QQExe
        if ($qqExe) {
            if ((Get-Cfg 'QQ_EXE') -ne $qqExe) {
                Save-QQExePath $qqExe
                Write-Info "已更新 QQ 路径: $qqExe"
            }
        } else {
            Write-Warn '未检测到 QQ.exe,SnowLuma 将无法注入。请安装 QQ 后再次执行修复。'
        }
    } else {
        $sRoot = Get-Cfg 'NAPCAT_ROOT'
        if (-not $sRoot) { $sRoot = 'C:\NapCat' }
        foreach ($d in @('config', 'cache', 'data', 'logs', 'tmp', 'run')) {
            Ensure-Dir (Join-Path $sRoot $d)
        }
    }
    if ($wasAstr) {
        $rc = Invoke-Schtasks @('/Run', '/TN', '\NBot\AstrBot')
        if ($rc -eq 0) { Write-Info '已重新拉起 AstrBot(修复前处于运行状态)。' }
        else { Write-Warn '重新拉起 AstrBot 失败,请点「启动全部」。' }
    }
    if ($wasBot) {
        if (Test-SnowLuma) {
            # 同上:先收掉旧 node 再 /Run,否则「修复」重建的运行资产根本不会被
            # 用上 —— 旧实例继续占着端口,新实例起不来,用户以为修复生效了。
            [void](Invoke-Schtasks @('/End', '/TN', '\NBot\SnowLuma'))
            Stop-SnowlumaProcess
            Start-Sleep -Seconds 2
            $rc = Invoke-Schtasks @('/Run', '/TN', '\NBot\SnowLuma')
            if ($rc -eq 0) { Write-Info '已重新拉起 SnowLuma(修复前处于运行状态)。' }
            else { Write-Warn '重新拉起 SnowLuma 失败(该任务需用户已登录桌面),请点「启动全部」。' }
        } else {
            $rc = Invoke-Schtasks @('/Run', '/TN', '\NBot\NapCat')
            if ($rc -eq 0) { Write-Info '已重新拉起 NapCat(修复前处于运行状态)。' }
            else { Write-Warn '重新拉起 NapCat 失败(该任务需用户已登录桌面),请点「启动全部」。' }
        }
    }
    Write-Info '修复完成:运行资产、计划任务与目录结构已重建。'
}

function Uninstall-Core {
    # 卸载的必做部分:停服务、删计划任务、撤命令/快捷方式/托盘自启、清状态。
    # 不碰任何数据目录;QQ 程序本体也不动(需要卸载请走系统「应用」)。
    Stop-Stack
    $bin = Get-BinDir
    $state = Get-StateDir
    # 四个任务全删(NapCat 与 SnowLuma 都尝试):后端切换后另一个后端的任务
    # 可能还留着;Invoke-Schtasks 对不存在的任务本身就容错。
    foreach ($t in @('AstrBot', 'NapCat', 'SnowLuma', 'Watchdog')) {
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
    foreach ($f in @('astrbot.enabled', 'napcat.enabled', 'snowluma.enabled', 'autostart.disabled',
        'payload-current.txt', 'payload-previous.txt', 'panel.show-request')) {
        Remove-FileSafe (Join-Path $state $f)
    }
    Write-Info '已移除:计划任务、nbot 命令、桌面快捷方式、托盘自启。'
}

function Uninstall-Data {
    # 按选择删除数据目录。ProgramData 放最后:控制台里跑的 install.bat 就住在
    # 里面,自删可能残留少量文件,残留时提示手动清理。
    param([bool]$DeleteAstr, [bool]$DeleteBot, [bool]$DeleteProgData)
    if ($DeleteAstr) {
        $aRoot = Get-Cfg 'ASTRBOT_ROOT'
        if ($aRoot -and (Test-Path -LiteralPath $aRoot)) {
            Remove-DirSafe $aRoot
            if (Test-Path -LiteralPath $aRoot) { Write-Warn "$aRoot 有残留(可能被占用),请稍后手动删除。" }
            else { Write-Info "已删除 AstrBot 数据目录: $aRoot" }
        }
    }
    if ($DeleteBot) {
        if (Test-SnowLuma) {
            $sRoot = Get-Cfg 'SL_ROOT'
            if ($sRoot -and (Test-Path -LiteralPath $sRoot)) {
                Remove-DirSafe $sRoot
                if (Test-Path -LiteralPath $sRoot) { Write-Warn "$sRoot 有残留(可能被占用),请稍后手动删除。" }
                else { Write-Info "已删除 SnowLuma 数据目录: $sRoot" }
            }
            # 载荷目录跟着 SnowLuma 一起删。
            #
            # 它以前是藏在 AstrBot 目录里的(<AstrBot> 下的隐藏子目录),删 AstrBot
            # 就顺手带走了;但向导让用户选「安装根目录」之后,载荷是 <root>\payload,
            # 和 AstrBot 平级 —— 谁都删不到它,几百 MB 的 release 全留在盘上。
            $payload = Get-Cfg 'SL_PAYLOAD_ROOT'
            if ($payload -and (Test-Path -LiteralPath $payload)) {
                # 先摘掉 current 这个目录联接再删目录树:Remove-Item -Recurse 遇到
                # reparse point 的行为不值得赌,显式 rmdir 只摘链接、不动目标。
                $cur = Join-Path $payload 'current'
                if (Test-Path -LiteralPath $cur) { & cmd.exe /c "rmdir `"$cur`"" 2>$null | Out-Null }
                Remove-DirSafe $payload
                if (Test-Path -LiteralPath $payload) { Write-Warn "$payload 有残留(可能被占用),请稍后手动删除。" }
                else { Write-Info "已删除 SnowLuma 载荷目录: $payload" }
            }
        } else {
            $sRoot = Get-Cfg 'NAPCAT_ROOT'
            if ($sRoot -and (Test-Path -LiteralPath $sRoot)) {
                Remove-DirSafe $sRoot
                if (Test-Path -LiteralPath $sRoot) { Write-Warn "$sRoot 有残留(可能被占用),请稍后手动删除。" }
                else { Write-Info "已删除 NapCat 数据目录: $sRoot" }
            }
            # 载荷目录跟着 NapCat 一起删,理由同上面的 SnowLuma 分支:向导把载荷
            # 放在 <root>\payload,和数据目录平级,不显式删就永远留在盘上。
            $payload = Get-Cfg 'NAPCAT_PAYLOAD_ROOT'
            if ($payload -and (Test-Path -LiteralPath $payload)) {
                # 先摘掉 current 这个目录联接再删目录树:Remove-Item -Recurse 遇到
                # reparse point 的行为不值得赌,显式 rmdir 只摘链接、不动目标。
                $cur = Join-Path $payload 'current'
                if (Test-Path -LiteralPath $cur) { & cmd.exe /c "rmdir `"$cur`"" 2>$null | Out-Null }
                Remove-DirSafe $payload
                if (Test-Path -LiteralPath $payload) { Write-Warn "$payload 有残留(可能被占用),请稍后手动删除。" }
                else { Write-Info "已删除 NapCat 载荷目录: $payload" }
            }
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
    # 可含 data(AstrBot 目录)、napcat 或 snowluma(机器人数据目录,
    # 两个写法都接受,实际删除范围按 BOT_BACKEND)、programdata。
    param([string]$Flags)
    $delAstr = $false; $delBot = $false; $delProg = $false
    if ($Flags) {
        foreach ($flag in ($Flags -split ',')) {
            $f = ([string]$flag).Trim().ToLower()
            if ($f -eq 'data') { $delAstr = $true }
            elseif ($f -eq 'napcat') { $delBot = $true }
            elseif ($f -eq 'snowluma') { $delBot = $true }
            elseif ($f -eq 'programdata') { $delProg = $true }
        }
    }
    Write-Bold '开始卸载 nbot...'
    Uninstall-Core
    Uninstall-Data $delAstr $delBot $delProg
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
    $sRoot = Get-BotRoot
    $botName = Get-BotName
    $delAstr = Confirm-Action "删除 AstrBot 数据目录 $aRoot(机器人配置、插件、聊天数据都会没)?" $false
    $delBot = Confirm-Action "删除 $botName 数据目录 $sRoot(OneBot/WebUI 配置与日志)?" $false
    $delProg = Confirm-Action ("删除安装器与运行数据 " + (Get-NBotDir) + "?") $false
    Uninstall-Data $delAstr $delBot $delProg
}

function Open-QQLogin {
    if (Test-SnowLuma) {
        # QQ 已经在跑时不要重启整套:SnowLuma 的 hook 已经注入进去了,
        # 重启只会白白打断会话。直接把已有的 QQ 窗口叫到前台即可。
        $qq = @(Get-Process -Name QQ -ErrorAction SilentlyContinue)
        if ($qq.Count -gt 0) {
            Show-QQWindow
            Write-Info '请在 QQ 窗口中扫码或点击登录。'
            return
        }
        # 走到这里说明 QQ 没在跑,需要拉起整套。SnowLuma 的 node 有可能仍残留
        # (它和 QQ 是两个独立进程,QQ 没了不代表 node 也没了) —— 不先收掉就
        # /Run 会撞端口起不来,而这个分支恰恰是要靠新实例里的启动脚本去拉 QQ。
        [void](Invoke-Schtasks @('/End', '/TN', '\NBot\SnowLuma'))
        Stop-SnowlumaProcess
        Start-Sleep -Seconds 2
        $rc = Invoke-Schtasks @('/Run', '/TN', '\NBot\SnowLuma')
        if ($rc -ne 0) {
            Write-Warn '无法启动 \NBot\SnowLuma 计划任务,请先执行安装或修复。'
            return
        }
        # 启动器先拉 QQ 再拉 SnowLuma,QQ 窗口通常几秒内出现。
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 1
            if (@(Get-Process -Name QQ -ErrorAction SilentlyContinue).Count -gt 0) { break }
        }
        Show-QQWindow
        $bin = Get-BinDir
        Write-Info '请在弹出的 QQ 窗口中扫码或点击登录。'
        Write-Info "若窗口没有出现:请确认当前已登录 Windows 桌面,或直接运行 $bin\snowluma-launch.bat。"
        return
    }
    $rc = Invoke-Schtasks @('/Run', '/TN', '\NBot\NapCat')
    if ($rc -ne 0) {
        Write-Warn '无法启动 \NBot\NapCat 计划任务,请先执行安装或修复。'
    }
    $bin = Get-BinDir
    Write-Info '请在弹出的 QQ 窗口中扫码或点击登录。'
    Write-Info "若窗口没有出现:请确认当前已登录 Windows 桌面,或直接运行 $bin\napcat-launch.bat。"
}

function Show-QQWindow {
    # 把 QQ 主窗口切到前台。QQ 常常最小化到托盘启动,登录框藏在后面。
    try {
        $sig = @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
        Add-Type -MemberDefinition $sig -Name 'NBotWin' -Namespace 'NBot' -ErrorAction Stop
        foreach ($p in @(Get-Process -Name QQ -ErrorAction SilentlyContinue)) {
            if ($p.MainWindowHandle -eq 0) { continue }
            # 9 = SW_RESTORE
            [void][NBot.NBotWin]::ShowWindow($p.MainWindowHandle, 9)
            [void][NBot.NBotWin]::SetForegroundWindow($p.MainWindowHandle)
        }
    } catch {
        # 老系统上 Add-Type 可能不可用,失败就让用户自己点任务栏。
        Write-Warn '无法自动把 QQ 窗口切到前台,请手动点击任务栏上的 QQ 图标。'
    }
}
