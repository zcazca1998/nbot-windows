# modules\snowluma.ps1 - SnowLuma(Windows 版)安装(PowerShell 2.0 兼容)
# 由 install-core.ps1 dot-source;依赖 lib\common.ps1、modules\tasks.ps1
# 与 modules\qq.ps1(QQ 的探测/下载/安装函数在那边,两个后端共用)。
# 说明:SnowLuma 是独立的 Node 进程,自己不启动 QQ —— 它轮询系统里的
# QQ.exe,发现后把 native hook 注入进去。QQ 由 snowluma-launch.bat 负责拉起,
# 两者同属计划任务 \NBot\SnowLuma(该任务需要已登录的桌面会话)。

function Install-SnowLuma {
    $payload = Get-Cfg 'SL_PAYLOAD_ROOT'
    if (-not $payload) { $payload = 'C:\AstrBot\.nbot\snowluma' }
    $snowRoot = Get-Cfg 'SL_ROOT'
    if (-not $snowRoot) { $snowRoot = 'C:\SnowLuma' }
    Ensure-Dir $payload
    Ensure-Dir $snowRoot

    # 1. 前置条件:架构与磁盘空间。
    #    架构判断必须排在 Install-QQ 之前 —— 放在后面的话,ARM64 用户要等
    #    几百 MB 的 QQ 装完才被告知这条路根本走不通。
    #    官方只发布 win-x64,没有 arm64 包:注入用的 native DLL 必须与 QQ
    #    进程同架构,x64 包在 ARM64 上会卡在注入这一步。
    if ($script:SystemArch -ne 'x64') {
        Die ("SnowLuma 官方只发布 Windows x64 版本,当前系统架构为 $script:SystemArch。`n" +
            'hook 注入要求 native 组件与 QQ 进程架构一致,x64 包无法在 ARM64 上完成注入。')
    }
    $freeGB = Get-FreeGB $payload
    if ($freeGB -lt 4) {
        Die "磁盘剩余空间不足: $payload 所在分区仅剩 $freeGB GB,至少需要 4 GB。"
    }

    # 2. QQ(内部自行处理已安装情形)
    Install-QQ
    # 用户选择「不重新安装」时 Install-QQ 会直接返回,这里补一次探测,
    # 保证 QQ_EXE 一定写进配置(启动器要用)。
    $qqExe = Find-QQExe
    if ($qqExe) {
        Save-QQExePath $qqExe
    } else {
        Die '未检测到 QQ.exe。SnowLuma 需要本机已安装 QQ 才能注入,请先安装 QQ 后重试。'
    }

    # 3. 获取 SnowLuma 官方 Windows 包
    #    完整版自带 node.exe;lite 版体积小但需要系统 Node 22+。
    $launch = Get-Cfg 'SL_LAUNCH'
    if (-not $launch) { $launch = 'launcher.bat' }
    $offline = Join-Path (Get-ScriptRoot) 'offline\snowluma-win.zip'
    $zip = $null
    $tag = $null
    $source = $null
    if (Test-Path -LiteralPath $offline) {
        Write-Info "使用离线 SnowLuma 包: $offline"
        $zip = $offline
        $tag = 'offline'
        $source = 'offline'
    } else {
        $repo = Get-Cfg 'SL_REPO'
        if (-not $repo) { $repo = 'SnowLuma/SnowLuma' }
        $confAsset = Get-Cfg 'SL_ASSET'
        if ($confAsset) {
            $patterns = @($confAsset)
        } else {
            # 资产名形如 SnowLuma-v1.12.10-win-x64.zip / -win-x64-lite.zip。
            # 优先完整版：自带 node.exe,不需要用户另装 Node.js。
            # lite 版做兜底（体积小,但要求系统已有 Node 22+)。
            $patterns = @('(?i)win-x64\.zip$', '(?i)win-x64-lite\.zip$', '(?i)win.*\.zip$')
        }
        # 一次拉取 release JSON 同时取 tag 与资产地址
        $release = GitHub-LatestRelease $repo $patterns
        $tag = $release['tag']
        $url = $release['asset']
        if (-not $url) {
            Die '未找到 Windows 版 SnowLuma 发布包,请检查 SL_REPO / SL_ASSET 配置,或将 zip 放入 offline\snowluma-win.zip。'
        }
        Write-Info "下载 SnowLuma $tag ..."
        $zip = Join-Path $payload 'snowluma-win.zip'
        GitHub-Fetch $url $zip -ExpectZip
        $source = $url
    }
    Write-Info '正在解压 SnowLuma(约 10-30 秒)...'

    # 4. 解压到临时 release 目录并校验入口
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $releases = Join-Path $payload 'releases'
    Ensure-Dir $releases
    $release = Join-Path $releases "image-$tag-$stamp"
    $releaseNew = "$release.new"
    Remove-DirSafe $releaseNew
    Expand-Zip $zip $releaseNew
    Strip-TopLevel $releaseNew
    # launcher.bat 只有一行 `node ./index.mjs`,真正的入口是 index.mjs;
    # native\ 放注入用的 DLL 与 .node 插件,缺了它 hook 装不上。
    foreach ($required in @($launch, 'index.mjs', 'package.json', 'native')) {
        if (-not (Test-Path -LiteralPath (Join-Path $releaseNew $required))) {
            $names = @()
            Get-ChildItem -Path $releaseNew | ForEach-Object { $names += $_.Name }
            Write-Warn ('解压根目录内容: ' + ($names -join ', '))
            Remove-DirSafe $releaseNew
            Die "SnowLuma 包中未找到 $required,请确认下载的是官方 win-x64 发布包(入口可用配置项 SL_LAUNCH 调整)。"
        }
    }

    # 4.1 确定用哪个 node：完整版包内自带 node.exe;lite 版要用系统 Node 22+。
    $nodeName = Get-Cfg 'SL_NODE'
    if (-not $nodeName) { $nodeName = 'node.exe' }
    $bundledNode = Join-Path $releaseNew $nodeName
    if (Test-Path -LiteralPath $bundledNode) {
        Write-Info "使用 SnowLuma 包内自带的 Node: $nodeName"
    } else {
        $sysNode = $null
        try { $sysNode = Get-Command 'node.exe' -ErrorAction SilentlyContinue } catch { $sysNode = $null }
        if (-not $sysNode) {
            Remove-DirSafe $releaseNew
            Die ("这是 lite 版 SnowLuma 包(不含 node.exe),但系统 PATH 上找不到 node.exe。`n" +
                "请任选一种方式:`n" +
                "  1) 安装 Node.js 22 或更高版本后重试;`n" +
                '  2) 改用完整版发布包(资产名形如 SnowLuma-vX.Y.Z-win-x64.zip,不带 -lite)。')
        }
        Write-Warn 'SnowLuma 包内没有 node.exe(lite 版),将使用系统 PATH 上的 node。'
    }

    # 5. 记录来源并转正
    Write-TextFile (Join-Path $releaseNew '.image-source') $source
    Move-Item -LiteralPath $releaseNew -Destination $release -Force

    # 5.1 切换载荷前先把旧载荷里的配置和账号数据收回主目录。SnowLuma 是在
    #     载荷目录里读写配置(WebUI 改的设置、登录态记录、新生成的 token)和
    #     账号数据(data\<uin>\ 下的 SQLite 库)的,而载荷会被整个换掉——不
    #     先收回来,升级一次就全丢。
    #     数据库文件在进程存活期间会一直被打开,不像 config 的 json 只在
    #     读写瞬间碰一下——复制前必须先停旧实例,否则拷出来的库有腐坏风险。
    #     全新安装时 current 还不是真实目录(不存在),没有旧实例可停,跳过。
    $oldCurrentDir = Join-Path $payload 'current'
    $oldConfigDir = Join-Path $oldCurrentDir 'config'
    $oldDataDir = Join-Path $oldCurrentDir 'data'
    if (Test-Path -LiteralPath $oldCurrentDir) {
        [void](Invoke-Schtasks @('/End', '/TN', '\NBot\SnowLuma'))
        Stop-SnowlumaProcess
        Start-Sleep -Seconds 2
    }
    if (Test-Path -LiteralPath $oldConfigDir) {
        $masterCfgDir = Join-Path $snowRoot 'config'
        Ensure-Dir $masterCfgDir
        $harvested = 0
        # 不能用 -File:那是 PS 3.0 才有的参数,在 Win7 自带的 PS 2.0 上是
        # 参数绑定错误(终止性,-ErrorAction SilentlyContinue 也压不住)。
        Get-ChildItem -Path $oldConfigDir -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PSIsContainer) { return }
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $masterCfgDir $_.Name) -Force
            $harvested = $harvested + 1
        }
        if ($harvested -gt 0) {
            Write-Info ('已回收旧载荷中的 ' + $harvested + ' 个配置文件到 ' + $masterCfgDir)
        }
    }

    # 5.2 data\<uin>\ 是目录树(库文件在子目录里),不是平铺文件,不能照抄
    #     上面 config 的单层复制——要连子目录一起递归拷走。上面已经确认旧
    #     实例停了,这里复制不会碰到被占用的文件。
    if (Test-Path -LiteralPath $oldDataDir) {
        $masterDataDir = Join-Path $snowRoot 'data'
        Ensure-Dir $masterDataDir
        $harvestedData = 0
        Get-ChildItem -Path $oldDataDir -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $_.PSIsContainer) { return }
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $masterDataDir $_.Name) -Recurse -Force
            $harvestedData = $harvestedData + 1
        }
        if ($harvestedData -gt 0) {
            Write-Info ('已回收旧载荷中的 ' + $harvestedData + ' 个账号数据目录到 ' + $masterDataDir)
        }
    }

    # 6. 切换 current junction 并记录状态
    $state = Get-StateDir
    $curFile = Join-Path $state 'payload-current.txt'
    $prevFile = Join-Path $state 'payload-previous.txt'
    $oldCurrent = $null
    if (Test-Path -LiteralPath $curFile) {
        $oldCurrent = Read-TextFile $curFile
        if ($oldCurrent) { $oldCurrent = ([string]$oldCurrent).Trim() }
    }
    Set-Junction (Join-Path $payload 'current') $release
    Write-TextFile $curFile $release
    if ($oldCurrent) { Write-TextFile $prevFile $oldCurrent }

    # 7. SL_ROOT 主配置目录:载荷升级会整目录切换,配置的
    #    唯一真源放在 SL_ROOT\config,每次启动前由 snowluma-launch.bat
    #    同步进载荷的 config 目录,升级不丢配置。
    #    data(账号数据)没有这道每次启动都跑的同步——它只需要在这个函数
    #    切换载荷的前后各同步一次(见上面 5.2 和下面 7.1),日常运行期间
    #    SnowLuma 一直写同一个载荷目录,不存在中途失步的问题。
    foreach ($d in @('config', 'logs', 'data')) {
        Ensure-Dir (Join-Path $snowRoot $d)
    }
    $masterCfg = Join-Path $snowRoot 'config'
    $port = Get-Cfg 'SNOWLUMA_WEBUI_PORT'
    if (-not $port) { $port = 5099 }
    # webui.json 由 SnowLuma 自己在首次启动时生成:密码是 scrypt 哈希,
    # 明文只在启动日志里出现一次(Get-SnowlumaCred 负责取)。安装器不预置
    # 这个文件——写一个我们编的哈希既没必要,也会让 WebUI 的改密流程失真。
    # WebUI 端口与 hook 自动注入通过环境变量传给 SnowLuma(见 snowluma-launch.bat),
    # 所以 config\runtime.json 也不需要安装器插手。

    # 7.0 onebot.json 必须在第一次启动前就有,否则 SnowLuma 会用内置默认
    #     配置起两个适配器([http-default] 0.0.0.0:3000、[ws-default]
    #     0.0.0.0:3001),对外可达且没有鉴权(token 虽随机但外部先天不知道
    #     要带这个头,等于裸奔)。只在主配置里从来没有过这个文件时才补一份
    #     "四个 networks 数组全空"的默认——网络客户端/服务端都不开,SnowLuma
    #     就不会启用任何默认适配器。已经配过(不管是本安装器写的还是用户
    #     手工放的)的绝不覆盖,升级路径必须原样保留现有配置。
    $onebotMaster = Join-Path $masterCfg 'onebot.json'
    if (-not (Test-Path -LiteralPath $onebotMaster)) {
        $safeDefault = @"
{
  "networks": {
    "httpServers": [],
    "httpClients": [],
    "wsServers": [],
    "wsClients": []
  }
}
"@
        $onebotTmp = "$onebotMaster.tmp"
        Write-TextFile $onebotTmp $safeDefault
        Move-Item -LiteralPath $onebotTmp -Destination $onebotMaster -Force
        Write-Info '未发现 onebot.json,已写入不启用任何适配器的安全默认配置(避免内置默认在 0.0.0.0:3000/3001 开放无鉴权端口)。运行"配置 OneBot 对接"后会覆盖为真正的对接配置。'
    }

    # 立即把主配置同步进新载荷(启动脚本每次也会同步)。
    # 官方 zip 里**没有** config 目录(NapCat 包里有,别照抄):SnowLuma 是
    # 首次启动时自己建的。不先建好,下面第一次 Copy-Item 就会因目标父目录
    # 不存在而抛异常 —— 且只在「主配置非空」的升级/重装路径上触发,全新安装
    # 测不出来。
    Ensure-Dir (Join-Path $release 'config')
    Get-ChildItem -Path $masterCfg | ForEach-Object {
        if (-not $_.PSIsContainer) {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $release ('config\' + $_.Name)) -Force
        }
    }

    # 7.1 主目录里回收/累积的账号数据同步回新载荷,道理与上面的 config 同步
    #     一样——升级不能丢号。这里新载荷还没启动,不存在并发写入或文件被
    #     占用的问题,可以放心递归复制整个 uin 子目录。
    Ensure-Dir (Join-Path $release 'data')
    Get-ChildItem -Path (Join-Path $snowRoot 'data') -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSIsContainer) {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $release ('data\' + $_.Name)) -Recurse -Force
        }
    }

    # 8. 运行资产、计划任务与守护标记
    Install-RuntimeAssets
    Install-Tasks
    Write-TextFile (Join-Path $state 'snowluma.enabled') ''

    # 9. 重启 SnowLuma 任务并做健康检查。
    #    与 NapCat 不同,这里**不动 QQ**:SnowLuma 自己不启动 QQ,只是发现已在
    #    运行的 QQ.exe 并注入 hook。NapCat 版必须连 QQ 一起重启(QQ 是它启动器
    #    的子进程),照抄过来就会把用户正在用的 QQ 静默杀掉。QQ 缺席时由
    #    snowluma-launch.bat 负责拉起。
    #
    #    必须显式收掉旧的 node:schtasks /End 只结束任务直接启动的 wscript,
    #    node 是孙子进程会残留,继续占着 WebUI 端口 —— 那样下面的健康检查会
    #    连上**旧实例**的端口并误判为「新版本启动成功」。上面 5.1 为了安全
    #    拷贝 data 已经停过一次,这里再停一遍是保险(万一那次判定 current
    #    不存在而跳过了,或者 Install-Tasks 改动后任务被重新触发),不是
    #    重复劳动,不要删。
    [void](Invoke-Schtasks @('/End', '/TN', '\NBot\SnowLuma'))
    Stop-SnowlumaProcess
    Start-Sleep -Seconds 2
    [void](Invoke-Schtasks @('/Run', '/TN', '\NBot\SnowLuma'))
    # 健康检查看 WebUI 端口是否在监听(比 HTTP 状态码可靠:未同意协议时
    # 根路径会跳到同意页,状态码不固定)
    if (-not (Wait-Tcp '127.0.0.1' $port 40 (Join-Path $snowRoot 'logs\snowluma.log'))) {
        # 10. 回滚
        Write-Warn '新版本 SnowLuma 未能通过健康检查,正在回滚。'
        [void](Invoke-Schtasks @('/End', '/TN', '\NBot\SnowLuma'))
        Stop-SnowlumaProcess
        Start-Sleep -Seconds 2
        if ($oldCurrent -and (Test-Path -LiteralPath $oldCurrent)) {
            Set-Junction (Join-Path $payload 'current') $oldCurrent
            Write-TextFile $curFile $oldCurrent
            [void](Invoke-Schtasks @('/Run', '/TN', '\NBot\SnowLuma'))
        }
        $log = Join-Path $snowRoot 'logs\snowluma.log'
        if (Test-Path -LiteralPath $log) {
            Write-Warn "以下为 $log 最后 60 行:"
            Get-TailLines $log 60 | ForEach-Object { Write-Host $_ }
        }
        Die 'SnowLuma 启动失败,已尝试回滚。提示:\NBot\SnowLuma 任务仅在用户登录桌面时运行,若当前未登录 Windows 桌面,请保持桌面登录状态后重试。'
    }

    # 11. 清理旧 release(保留 current 与 previous 记录值)
    $prev = $null
    if (Test-Path -LiteralPath $prevFile) {
        $prev = Read-TextFile $prevFile
        if ($prev) { $prev = ([string]$prev).Trim() }
    }
    $keep = @()
    $keep += $release.TrimEnd('\').ToLower()
    if ($prev) { $keep += $prev.TrimEnd('\').ToLower() }
    Get-ChildItem -Path $releases | ForEach-Object {
        if (-not $_.PSIsContainer) { return }
        if ($_.Name -notlike 'image-*') { return }
        $full = $_.FullName.TrimEnd('\').ToLower()
        $isKeep = $false
        foreach ($k in $keep) {
            if ($full -eq $k) { $isKeep = $true }
        }
        if (-not $isKeep) { Remove-DirSafe $_.FullName }
    }
    if ($source -ne 'offline') { Remove-FileSafe $zip }

    Write-Info "SnowLuma ($tag) 已启动,WebUI: http://127.0.0.1:$port/(局域网访问请使用本机 IP)"
    # 升级场景:QQ 进程里还挂着上一版的 hook DLL,新版 SnowLuma 会接上它。
    # 大多数情况没问题,但跨版本的协议改动只有重启 QQ 才能真正换成新 hook。
    # 这里只提示,不替用户杀 QQ —— 那会打断正在进行的会话。
    if ($oldCurrent) {
        Write-Info '这是一次升级:QQ 进程内仍是旧版 hook。若消息收发出现异常,重启一次 QQ 即可换成新版。'
    }
    $cred = Get-SnowlumaCred
    if ($cred['found']) {
        Write-Info ('WebUI 初始登录: 用户名 ' + $cred['user'] + ',密码 ' + $cred['pass'])
        Write-Info '请尽快登录并修改密码 —— 未改密时每次重启都会重新生成一个新的随机初始密码。'
    } else {
        Write-Info '初始登录用户名为 admin,初始密码见 SnowLuma 日志(面板「SnowLuma 登录信息」也会显示)。'
    }
    if (-not (Get-Cfg 'SNOWLUMA_ACCEPT_EULA')) {
        Write-Info '首次打开 WebUI 需要先阅读并同意 SnowLuma 的 EULA 与隐私政策,面板才会解锁。'
    }
}
