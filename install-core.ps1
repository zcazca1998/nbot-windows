# =============================================================================
# nbot-installer-windows / install-core.ps1
# nbot Windows 安装器主入口：菜单、命令分发、基础配置、环境诊断与日志查看。
# 由 install.bat 以管理员身份通过 Windows PowerShell 调用。
# 兼容范围：Windows 7 SP1 - Windows 11（PowerShell 2.0 及以上可解析、可运行）。
# 用法：
#   install.bat                  进入交互菜单
#   install.bat install-all      一键全自动安装
#   install.bat logs astrbot     查看 AstrBot 日志
# =============================================================================

param(
    [string]$Command = 'menu',
    [string]$SubArg = ''
)

$ErrorActionPreference = 'Stop'

# 输出被重定向到文件时(向导抓安装日志就是这种情况)统一写 UTF-8,和
# python / node 的输出编码一致,避免读日志时中文变乱码。交互式控制台
# 保持系统默认代码页,免得旧版 conhost 显示异常。
try {
    if ([Console]::IsOutputRedirected) {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
} catch { }

# PowerShell 2.0 没有 $PSScriptRoot，用 $MyInvocation 取脚本目录
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $ScriptDir 'lib\common.ps1')
. (Join-Path $ScriptDir 'modules\astrbot.ps1')
. (Join-Path $ScriptDir 'modules\qq.ps1')
. (Join-Path $ScriptDir 'modules\napcat.ps1')
. (Join-Path $ScriptDir 'modules\snowluma.ps1')
. (Join-Path $ScriptDir 'modules\onebot.ps1')
. (Join-Path $ScriptDir 'modules\tasks.ps1')

# -----------------------------------------------------------------------------
# 基础配置
# -----------------------------------------------------------------------------

function Configure-Base {
    param($DefaultsOnly)

    if ($DefaultsOnly) {
        Write-Config
        Write-Info ('已按默认值写入配置：' + (Get-ConfigPath))
        return
    }

    Write-Bold '基础配置（直接回车保留默认值，可清空的项输入 - 表示清空）'

    # 机器人后端：决定装 NapCat 还是 SnowLuma（AstrBot 两边共用）。默认 napcat。
    $backend = ''
    while ($true) {
        $backend = Prompt-Default '机器人后端（napcat / snowluma）' (Get-Backend)
        if ($null -ne $backend) { $backend = ([string]$backend).Trim().ToLower() }
        if ($backend -eq 'napcat' -or $backend -eq 'snowluma') { break }
        Write-Warn '只能填 napcat 或 snowluma。'
    }
    Set-Cfg 'BOT_BACKEND' $backend

    Set-Cfg 'ASTRBOT_ROOT' (Prompt-Default 'AstrBot 数据目录' (Get-Cfg 'ASTRBOT_ROOT'))
    if ($backend -eq 'snowluma') {
        Set-Cfg 'SL_ROOT' (Prompt-Default 'SnowLuma 数据目录' (Get-Cfg 'SL_ROOT'))
        Set-Cfg 'SL_PAYLOAD_ROOT' (Prompt-Default 'SnowLuma/QQ 程序载荷目录' (Get-Cfg 'SL_PAYLOAD_ROOT'))
    } else {
        Set-Cfg 'NAPCAT_ROOT' (Prompt-Default 'NapCat 数据目录' (Get-Cfg 'NAPCAT_ROOT'))
        Set-Cfg 'NAPCAT_PAYLOAD_ROOT' (Prompt-Default 'NapCat/QQ 程序载荷目录' (Get-Cfg 'NAPCAT_PAYLOAD_ROOT'))
    }
    Set-Cfg 'ASTRBOT_PORT' (Prompt-Default 'AstrBot WebUI 端口' (Get-Cfg 'ASTRBOT_PORT'))
    Set-Cfg 'ASTRBOT_WS_PORT' (Prompt-Default 'AstrBot OneBot WS 端口' (Get-Cfg 'ASTRBOT_WS_PORT'))
    if ($backend -eq 'snowluma') {
        Set-Cfg 'SNOWLUMA_WEBUI_PORT' (Prompt-Default 'SnowLuma WebUI 端口' (Get-Cfg 'SNOWLUMA_WEBUI_PORT'))
        Set-Cfg 'ONEBOT_HTTP_PORT' (Prompt-Default 'SnowLuma OneBot HTTP 端口' (Get-Cfg 'ONEBOT_HTTP_PORT'))
    } else {
        Set-Cfg 'NAPCAT_WEBUI_PORT' (Prompt-Default 'NapCat WebUI 端口' (Get-Cfg 'NAPCAT_WEBUI_PORT'))
        Set-Cfg 'ONEBOT_HTTP_PORT' (Prompt-Default 'NapCat OneBot HTTP 端口' (Get-Cfg 'ONEBOT_HTTP_PORT'))
    }

    # GITHUB_ACCESS 只能是 auto / proxy / direct；proxy 模式必须填代理地址
    while ($true) {
        $access = Prompt-Default 'GitHub 访问方式（auto=自动回退 / proxy=仅代理 / direct=仅直连）' (Get-Cfg 'GITHUB_ACCESS')
        if ($access -ne 'auto' -and $access -ne 'proxy' -and $access -ne 'direct') {
            Write-Warn '只能填 auto、proxy 或 direct。'
            continue
        }
        Set-Cfg 'GITHUB_ACCESS' $access

        if ($access -eq 'direct') {
            Set-Cfg 'GITHUB_PROXY' ''
            break
        }

        $proxy = Prompt-Default 'GitHub 代理地址（如 http://127.0.0.1:7890；socks5h:// 仅在有 curl.exe 时可用；输入 - 清空）' (Get-Cfg 'GITHUB_PROXY')
        if ($proxy -eq '-') { $proxy = '' }
        if ($access -eq 'proxy' -and $proxy -eq '') {
            Write-Warn 'proxy 模式必须填写代理地址。'
            continue
        }
        Set-Cfg 'GITHUB_PROXY' $proxy
        break
    }

    $mirror = Prompt-Default 'GitHub 镜像前缀（ghproxy 风格，如 https://ghfast.top；输入 - 清空）' (Get-Cfg 'GITHUB_MIRROR')
    if ($mirror -eq '-') { $mirror = '' }
    Set-Cfg 'GITHUB_MIRROR' $mirror

    $pipIndex = Prompt-Default 'pip 镜像源 PIP_INDEX_URL（如 https://pypi.tuna.tsinghua.edu.cn/simple；输入 - 清空）' (Get-Cfg 'PIP_INDEX_URL')
    if ($pipIndex -eq '-') { $pipIndex = '' }
    Set-Cfg 'PIP_INDEX_URL' $pipIndex

    if ($backend -eq 'snowluma') {
        Set-Cfg 'SL_REPO' (Prompt-Default 'SnowLuma Windows 版仓库（默认 SnowLuma/SnowLuma）' (Get-Cfg 'SL_REPO'))

        # 默认必须是"否"——协议同意与否只能由用户自己确认，装不装都不能替他答。
        # 不同意也能装，SnowLuma 首次打开 WebUI 时自己还会再问一遍、锁住面板功能。
        if (Confirm-Action '是否已阅读并同意 SnowLuma 的 EULA 与隐私政策？（默认否；不同意也能装，首次打开 WebUI 时再自行确认）' $false) {
            Set-Cfg 'SNOWLUMA_ACCEPT_EULA' '1'
            Set-Cfg 'SNOWLUMA_ACCEPT_PRIVACY' '1'
        } else {
            Set-Cfg 'SNOWLUMA_ACCEPT_EULA' ''
            Set-Cfg 'SNOWLUMA_ACCEPT_PRIVACY' ''
        }
    } else {
        Set-Cfg 'NAPCAT_REPO' (Prompt-Default 'NapCat Windows 版仓库' (Get-Cfg 'NAPCAT_REPO'))
    }

    $qqUrl = Prompt-Default 'QQ 安装包下载地址 QQ_WIN_URL（留空自动获取；输入 - 清空）' (Get-Cfg 'QQ_WIN_URL')
    if ($qqUrl -eq '-') { $qqUrl = '' }
    Set-Cfg 'QQ_WIN_URL' $qqUrl

    if ($script:OsProfile -eq 'legacy') {
        Write-Info '检测到旧系统（Win7/8/8.1）：新版 QQ NT 基于新版 Electron，无法在此系统运行；需要使用基于 Electron 22 及以下版本的旧版 QQ NT 安装包。'
        $qqLegacy = Prompt-Default '旧系统 QQ 安装包地址 QQ_WIN_URL_LEGACY（输入 - 清空）' (Get-Cfg 'QQ_WIN_URL_LEGACY')
        if ($qqLegacy -eq '-') { $qqLegacy = '' }
        Set-Cfg 'QQ_WIN_URL_LEGACY' $qqLegacy
    }

    Write-Config
    Write-Info ('配置已写入：' + (Get-ConfigPath))
}

# -----------------------------------------------------------------------------
# 安装器自拷贝
# -----------------------------------------------------------------------------

function Install-Self {
    # NBOT_TEST=1（测试/离线 smoke）时跳过自拷贝：避免测试把整个项目 robocopy
    # 到 %ProgramData%\nbot\installer，污染宿主机又拖慢测试。生产路径不受影响。
    if ($env:NBOT_TEST -eq '1') { return }
    $source = (Get-ScriptRoot).TrimEnd('\')
    $target = (Get-InstallerDir).TrimEnd('\')
    if ($source -eq $target) { return }

    Write-Info ('把安装器复制到：' + $target)
    & robocopy.exe $source $target /MIR /XD offline /NFL /NDL /NJH /NJS /NP | Out-Null
    # robocopy 退出码 0-7 都表示成功（含有拷贝、无拷贝等情况），>=8 才是失败
    if ($LASTEXITCODE -ge 8) {
        Die ('安装器自拷贝失败（robocopy 退出码 ' + $LASTEXITCODE + '）。')
    }
}

# -----------------------------------------------------------------------------
# 一键全自动安装
# -----------------------------------------------------------------------------

function Install-All {
    Write-Bold '一键全自动安装'
    if (Confirm-Action '是否全部使用默认配置？' $true) {
        Configure-Base $true
    } else {
        Configure-Base $false
    }
    Install-AstrBot
    if (Test-SnowLuma) {
        Install-SnowLuma
        Install-RuntimeAssets
        Install-Tasks
        # 和 NapCat 后端不同：OneBot 对接读的是 SnowLuma 的全局配置，不需要先
        # 登录拿 QQ 号，所以装完就能直接配，不用再等用户扫码后手动跑一遍。
        Configure-OneBot
        Open-QQLogin
        Write-Info '已打开 QQ 登录窗口，扫码登录即可直接使用（OneBot 对接已自动完成，无需再手动配置）。'
    } else {
        Install-NapCat
        Install-RuntimeAssets
        Install-Tasks
        Open-QQLogin
        Write-Info '已打开 QQ 登录窗口，请在窗口中扫码登录。'
        Write-Info '登录完成后，请运行菜单第 5 项，或执行命令：install.bat configure-onebot，以完成 OneBot 对接。'
    }
}

# -----------------------------------------------------------------------------
# 环境诊断
# -----------------------------------------------------------------------------

function Get-TaskInstallState {
    param($TaskName)
    # 用 cmd 内部重定向，避免 PowerShell 2.0 下 2>$null 包装 stderr 的问题
    & cmd.exe /c ('schtasks /query /tn "' + $TaskName + '" >nul 2>nul')
    if ($LASTEXITCODE -eq 0) { return '已安装' }
    return '未安装'
}

function Invoke-Doctor {
    Write-Bold '==== 环境诊断 ===='

    Write-Host ('操作系统       : ' + $script:OsName + '（build ' + $script:OsBuild + '，profile: ' + $script:OsProfile + '）')
    Write-Host ('系统架构       : ' + $script:SystemArch)
    if ((Test-SnowLuma) -and $script:SystemArch -eq 'arm64') {
        Write-Warn 'SnowLuma 官方只发布 win-x64 资产，没有 win-arm64；本机架构下 SnowLuma 部分无法安装（AstrBot 不受影响）。'
    }
    $psVersion = '1.0'
    if ($null -ne $PSVersionTable) { $psVersion = $PSVersionTable.PSVersion.ToString() }
    Write-Host ('PowerShell     : ' + $psVersion)
    if ($script:TlsOk) {
        Write-Host 'TLS 1.2        : 可用'
    } else {
        Write-Warn 'TLS 1.2        : 不可用（HTTPS 下载将失败）'
    }
    if ($script:CurlExe) {
        Write-Host ('curl.exe       : ' + $script:CurlExe)
    } else {
        Write-Host 'curl.exe       : 未找到（将使用 WebClient 下载，不支持 socks 代理）'
    }

    Write-Bold '-- 磁盘空间 --'
    $diskKeys = @('ASTRBOT_ROOT', 'NAPCAT_ROOT', 'NAPCAT_PAYLOAD_ROOT')
    if (Test-SnowLuma) { $diskKeys = @('ASTRBOT_ROOT', 'SL_ROOT', 'SL_PAYLOAD_ROOT') }
    foreach ($key in $diskKeys) {
        $path = Get-Cfg $key
        try {
            Write-Host ($key + ' = ' + $path + '（所在盘剩余 ' + (Get-FreeGB $path) + ' GB）')
        } catch {
            Write-Warn ($key + ' = ' + $path + '（无法获取所在盘剩余空间）')
        }
    }

    Write-Bold '-- 依赖检测 --'
    try {
        $python = Find-Python
        if ($python) {
            Write-Host ('Python         : ' + $script:PythonExe)
        } else {
            Write-Warn 'Python         : 未检测到（安装 AstrBot 时会自动安装受管 Python）'
        }
    } catch {
        Write-Warn ('Python         : 检测失败：' + $_.Exception.Message)
    }
    try {
        $qqExe = Find-QQExe
        if ($qqExe) {
            Write-Host ('QQ             : ' + $qqExe)
        } else {
            Write-Warn 'QQ             : 未检测到（可通过菜单第 4 项安装）'
        }
    } catch {
        Write-Warn ('QQ             : 检测失败：' + $_.Exception.Message)
    }
    if (Test-SnowLuma) {
        # 光有 QQ.exe 不够：启动器靠配置里记的这个路径去拉起 QQ，路径失效
        # （QQ 被卸载重装、挪了目录）的话 SnowLuma 会永远等不到 QQ 进程。
        $qqCfgExe = Get-Cfg 'QQ_EXE'
        if ($qqCfgExe -and (Test-Path -LiteralPath $qqCfgExe)) {
            Write-Host ('QQ_EXE 配置    : ' + $qqCfgExe)
        } elseif ($qqCfgExe) {
            Write-Warn ('QQ_EXE 配置    : ' + $qqCfgExe + '（路径已不存在，启动器拉不起 QQ，请重装/修复菜单第 4 项）')
        } else {
            Write-Warn 'QQ_EXE 配置    : 未写入（启动器不知道去哪拉起 QQ，请安装/修复菜单第 4 项）'
        }
    }

    Write-Bold '-- GitHub 镜像连通性 --'
    try {
        # 清掉探针缓存强制重测,让用户看到当前真实可达的镜像与延迟;
        # 这正是国内「连不上 GitHub」的第一手诊断信息。
        $cp = Get-MirrorCachePath
        if (Test-Path -LiteralPath $cp) { Remove-Item -LiteralPath $cp -Force }
        $ordered = Get-OrderedMirrors -MaxKeep 8
        $lat = @{}
        if (Test-Path -LiteralPath $cp) {
            foreach ($l in ((Read-TextFile $cp) -split "`r?`n")) {
                if ($l -match '^#') { continue }
                $parts = $l -split "`t"
                if ($parts.Count -ge 2) { $lat[$parts[0]] = $parts[1] }
            }
        }
        if ($lat.Count -gt 0) {
            foreach ($k in $lat.Keys) {
                Write-Host ($k + ' : 可用，延迟 ' + $lat[$k] + ' ms')
            }
            Write-Info '下载将按以上顺序自动选最快的可用镜像；若全部不可用则回退直连。'
        } else {
            Write-Warn '所有候选镜像均不可达（可能无外网，或被墙/运营商拦截）。'
            Write-Warn '下载将尝试直连 GitHub；若仍失败，请配置全局代理（GITHUB_PROXY）或使用 offline\ 离线包。'
        }
    } catch {
        Write-Warn ('镜像连通性检测失败：' + $_.Exception.Message)
    }

    Write-Bold '-- 计划任务 --'
    foreach ($taskName in @('\NBot\AstrBot', (Get-BotTaskPath), '\NBot\Watchdog')) {
        Write-Host ($taskName + ' : ' + (Get-TaskInstallState $taskName))
    }

    if (Test-SnowLuma) {
        # SnowLuma 与 QQ 是两个独立进程（SnowLuma 退出不影响 QQ，反之亦然），
        # 分开报才能看出到底是哪一半没起来。QQ 用 tasklist 按镜像名找即可；
        # SnowLuma 得按命令行匹配，因为跑的都是同一个 node.exe，得靠
        # index.mjs + 载荷路径（启动器故意传绝对路径）把它和别的 node 进程分开。
        Write-Bold '-- 进程状态 --'
        try {
            $qqRunning = $false
            & cmd.exe /c ('tasklist /FI "IMAGENAME eq QQ.exe" 2>nul | findstr /I "QQ.exe" >nul 2>nul')
            if ($LASTEXITCODE -eq 0) { $qqRunning = $true }
            if ($qqRunning) {
                Write-Host 'QQ 进程        : 运行中'
            } else {
                Write-Warn 'QQ 进程        : 未运行'
            }
        } catch {
            Write-Warn ('QQ 进程        : 检测失败：' + $_.Exception.Message)
        }
        try {
            $payload = Get-Cfg 'SL_PAYLOAD_ROOT'
            $needles = @('index.mjs')
            if ($payload) { $needles += $payload }
            $slFound = $false
            $procs = Get-WmiObject -Class Win32_Process -ErrorAction SilentlyContinue
            foreach ($p in $procs) {
                if ($p.Name -notlike 'node*') { continue }
                $cl = $p.CommandLine
                if ($null -eq $cl) { continue }
                $clLower = $cl.ToLower()
                $ok = $true
                foreach ($n in $needles) {
                    if ($clLower.IndexOf($n.ToLower()) -lt 0) { $ok = $false; break }
                }
                if ($ok) { $slFound = $true; break }
            }
            if ($slFound) {
                Write-Host 'SnowLuma 进程  : 运行中（node.exe，命令行含 index.mjs）'
            } else {
                Write-Warn 'SnowLuma 进程  : 未运行'
            }
        } catch {
            Write-Warn ('SnowLuma 进程  : 检测失败：' + $_.Exception.Message)
        }
    }

    Write-Bold '-- 服务端口 --'
    $astrPort = Get-Cfg 'ASTRBOT_PORT'
    if (Test-HttpOk ('http://127.0.0.1:' + $astrPort + '/') 5000) {
        Write-Host ('AstrBot WebUI（端口 ' + $astrPort + '） : 可访问')
    } else {
        Write-Warn ('AstrBot WebUI（端口 ' + $astrPort + '） : 未响应（可能未启动）')
    }
    $botName = Get-BotName
    $botPort = Get-BotWebuiPort
    if (Test-TcpOk '127.0.0.1' $botPort 5000) {
        Write-Host ($botName + ' WebUI（端口 ' + $botPort + '） : 可访问')
    } else {
        Write-Warn ($botName + ' WebUI（端口 ' + $botPort + '） : 未响应（可能未启动）')
    }

    if ($script:OsProfile -eq 'legacy') {
        Write-Bold '-- Win7/8 专项提示 --'
        Write-Warn 'Windows 7 必须升级到 SP1，并安装 .NET Framework 4.5.2 或更高版本。'
        Write-Warn '建议安装 WMF 5.1（PowerShell 5.1）以获得更好的脚本兼容性。'
        Write-Warn '若 TLS 1.2 不可用，请安装系统更新 KB3140245 并启用默认 TLS 1.2，否则无法从 GitHub 下载。'
        Write-Warn '旧系统需使用 Electron 22 及以下的旧版 QQ NT 安装包（配置项 QQ_WIN_URL_LEGACY）。'
        if (Test-SnowLuma) {
            Write-Warn 'SnowLuma 自带 Node.js 22，而 Node 22 不支持 Win7/8：SnowLuma 部分需要 Win10 及以上才能运行，AstrBot 部分不受影响。'
        }
    }
}

# -----------------------------------------------------------------------------
# 日志查看
# -----------------------------------------------------------------------------

function Show-Logs {
    param($Which)
    # 机器人日志名按后端接受对应名（napcat / snowluma），也接受 'bot' 别名。
    $botKey = Get-BotMarker
    if ($Which -eq 'bot') { $Which = $botKey }
    $path = $null
    switch ($Which) {
        'astrbot'  { $path = Join-Path (Get-Cfg 'ASTRBOT_ROOT') 'logs\astrbot.log' }
        'watchdog' { $path = Join-Path (Get-NBotLogDir) 'watchdog.log' }
        default    {
            if ($Which -eq $botKey) {
                $path = Get-BotLogFile
            } else {
                Die ('用法：logs {astrbot|' + $botKey + '|watchdog}')
            }
        }
    }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warn ('日志文件不存在：' + $path)
        return
    }
    # 日志是 UTF-8;控制台默认是本地代码页(中文 Windows 为 GBK),不切成
    # UTF-8 输出的话中文会变乱码。切换失败(极旧终端)就照原样输出。
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    Write-Bold ('==== ' + $path + '（最后 200 行）====')
    $lines = Get-TailLines $path 200
    foreach ($line in $lines) { Write-Host (Remove-AnsiEscapes $line) }
}

function Show-LogsMenu {
    $botKey = Get-BotMarker
    Write-Host ('  1. astrbot   2. ' + $botKey + '   3. watchdog')
    $pick = Read-Host '请选择要查看的日志'
    if ($null -eq $pick) { $pick = '' }
    switch ($pick.Trim()) {
        '1'        { Show-Logs 'astrbot' }
        'astrbot'  { Show-Logs 'astrbot' }
        '2'        { Show-Logs $botKey }
        'napcat'   { Show-Logs 'napcat' }
        'snowluma' { Show-Logs 'snowluma' }
        'bot'      { Show-Logs $botKey }
        '3'        { Show-Logs 'watchdog' }
        'watchdog' { Show-Logs 'watchdog' }
        default    { Write-Warn '无效选择。' }
    }
}

# -----------------------------------------------------------------------------
# 交互菜单
# -----------------------------------------------------------------------------

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Bold '=============== nbot Windows 安装器 ==============='
        Write-Host ' 1. 一键全自动安装（推荐新手）'
        Write-Host ' 2. 基础配置'
        Write-Host ' 3. 安装/更新 AstrBot'
        Write-Host (' 4. 安装/更新 ' + (Get-BotName) + ' + QQ')
        if (Test-SnowLuma) {
            Write-Host ' 5. 配置 OneBot 对接（无需登录 QQ，全局配置可提前做）'
        } else {
            Write-Host ' 5. 配置 OneBot 对接'
        }
        Write-Host ' 6. 安装/修复自启与守护任务'
        if (Test-SnowLuma) {
            Write-Host ' 7. 打开 QQ 登录（启动器会先拉起 QQ，再启动 SnowLuma）'
        } else {
            Write-Host ' 7. 打开 QQ 登录'
        }
        Write-Host ' 8. 运行状态'
        Write-Host ' 9. 环境诊断'
        Write-Host '10. 启动全部'
        Write-Host '11. 停止全部'
        Write-Host '12. 查看日志'
        Write-Host '13. 卸载'
        Write-Host '14. 关闭开机自启'
        Write-Host '15. 开启开机自启'
        Write-Host ' 0. 退出'
        $choice = Read-Host '请选择'
        if ($null -eq $choice) { $choice = '' }
        $choice = $choice.Trim()
        if ($choice -eq '0') { return }

        try {
            switch ($choice) {
                '1'  { Install-All }
                '2'  { Configure-Base $false }
                '3'  { Install-AstrBot }
                '4'  { if (Test-SnowLuma) { Install-SnowLuma } else { Install-NapCat } }
                '5'  { Configure-OneBot }
                '6'  { Install-RuntimeAssets; Install-Tasks }
                '7'  { Open-QQLogin }
                '8'  { Show-Status }
                '9'  { Invoke-Doctor }
                '10' { Start-Stack }
                '11' { Stop-Stack }
                '12' { Show-LogsMenu }
                '13' {
                    if (Confirm-Action '确定要卸载 nbot 吗？' $false) {
                        Uninstall-Stack
                    } else {
                        Write-Info '已取消卸载。'
                    }
                }
                '14' { Disable-Autostart }
                '15' { Enable-Autostart }
                default { Write-Warn '无效选择，请重新输入。' }
            }
        } catch {
            Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
        }
    }
}

# -----------------------------------------------------------------------------
# 命令分发
# -----------------------------------------------------------------------------

function Invoke-Dispatch {
    param($Cmd, $Arg)
    switch ($Cmd) {
        'menu'             { Show-Menu }
        'configure'        { Configure-Base $false }
        'install-all'      { Install-All }
        'install-astrbot'  { Install-AstrBot }
        'update-astrbot'   { Install-AstrBot }
        'install-napcat'   { Install-NapCat }
        'update-napcat'    { Install-NapCat }
        'install-snowluma' { Install-SnowLuma }
        'update-snowluma'  { Install-SnowLuma }
        'install-qq'       { Install-QQ }
        'update-qq'        { Install-QQ }
        'configure-onebot' { Configure-OneBot $Arg }
        'reset-astrbot'    { Reset-AstrbotPassword $Arg }
        'reset-napcat'     { Reset-NapcatToken $Arg }
        # 不接受参数：SnowLuma 密码是 scrypt 哈希，装不了外部指定的明文。
        'reset-snowluma'   { Reset-SnowlumaPassword }
        # 面板「单独重启」按钮走这里，而不是自己 schtasks /End+/Run：任务链是
        # wscript -> 启动 bat -> node/python，/End 只收得到 wscript，孙进程
        # (真正占端口的解释器)纹丝不动。Restart-BotTask 按命令行精确终止
        # 孙进程后再 /Run，语义已在 modules\tasks.ps1 验证过。
        'restart-astrbot'  { Restart-BotTask 'AstrBot' }
        # 统一的「重启机器人」命令：按当前后端重启 NapCat 或 SnowLuma 任务。
        'restart-bot'      { Restart-BotTask (Get-BotName) }
        'panel'            {
            Start-Process -FilePath (Join-Path (Get-ScriptRoot) 'panel.bat')
            Write-Info '图形面板已启动。'
        }
        'repair'           { Repair-Stack }
        'status'           { Show-Status }
        'doctor'           { Invoke-Doctor }
        'logs'             { Show-Logs $Arg }
        'start'            { Start-Stack }
        'stop'             { Stop-Stack }
        'autostart-on'     { Enable-Autostart }
        'autostart-off'    { Disable-Autostart }
        'qqlogin'          { Open-QQLogin }
        'uninstall'        { Uninstall-Stack }
        'uninstall-quiet'  { Uninstall-Quiet $Arg }
        default {
            Die ('未知命令：' + $Cmd + '。可用命令：menu configure install-all install-astrbot update-astrbot install-napcat update-napcat install-snowluma update-snowluma install-qq update-qq configure-onebot reset-astrbot reset-napcat reset-snowluma restart-astrbot restart-bot repair status doctor logs {astrbot|napcat|snowluma|watchdog} start stop autostart-on autostart-off qqlogin uninstall')
        }
    }
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------

try {
    Initialize-NBot
    Install-Self
    Invoke-Dispatch $Command $SubArg
} catch {
    Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
