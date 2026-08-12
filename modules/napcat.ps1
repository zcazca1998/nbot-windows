# modules\napcat.ps1 - NapCat(Windows 版)安装(PowerShell 2.0 兼容)
# 由 install-core.ps1 dot-source;依赖 lib\common.ps1、modules\tasks.ps1
# 与 modules\qq.ps1(QQ 的探测/下载/安装函数在那边,两个后端共用)。
# 说明:Windows 版 NapCat 启动器自带拉起 QQ(NapCat Shell 模式),
# QQ 与 NapCat 由同一个计划任务 \NBot\NapCat 管理,与 Linux 版不同。

function Install-NapCat {
    $payload = Get-Cfg 'NAPCAT_PAYLOAD_ROOT'
    if (-not $payload) { $payload = 'C:\AstrBot\.nbot\napcat' }
    $snowRoot = Get-Cfg 'NAPCAT_ROOT'
    if (-not $snowRoot) { $snowRoot = 'C:\NapCat' }
    Ensure-Dir $payload
    Ensure-Dir $snowRoot

    # 1. 磁盘空间检查
    $freeGB = Get-FreeGB $payload
    if ($freeGB -lt 4) {
        Die "磁盘剩余空间不足: $payload 所在分区仅剩 $freeGB GB,至少需要 4 GB。"
    }

    # 2. QQ(内部自行处理已安装情形)
    Install-QQ

    # 3. 获取 NapCat 官方 Windows 包(NapCat.Shell.zip)
    $launch = Get-Cfg 'NAPCAT_LAUNCH'
    if (-not $launch) { $launch = 'launcher-win10.bat' }
    $offline = Join-Path (Get-ScriptRoot) 'offline\napcat-shell.zip'
    $zip = $null
    $tag = $null
    $source = $null
    if (Test-Path -LiteralPath $offline) {
        Write-Info "使用离线 NapCat 包: $offline"
        $zip = $offline
        $tag = 'offline'
        $source = 'offline'
    } else {
        $repo = Get-Cfg 'NAPCAT_REPO'
        if (-not $repo) { $repo = 'NapNeko/NapCatQQ' }
        $confAsset = Get-Cfg 'NAPCAT_ASSET'
        if ($confAsset) {
            $patterns = @($confAsset)
        } else {
            # 官方资产名固定为 NapCat.Shell.zip;宽松模式兜底
            $patterns = @('/NapCat\.Shell\.zip$', '(?i)shell.*\.zip$')
        }
        # 一次拉取 release JSON 同时取 tag 与资产地址(原 GitHub-LatestTag +
        # GitHub-AssetUrl 各打一次 api.github.com,反复重试易踩 60 次/小时限额)。
        $release = GitHub-LatestRelease $repo $patterns
        $tag = $release['tag']
        $url = $release['asset']
        if (-not $url) {
            Die '未找到 Windows 版 NapCat 发布包,请检查 NAPCAT_REPO / NAPCAT_ASSET 配置,或将 zip 放入 offline\napcat-shell.zip。'
        }
        Write-Info "下载 NapCat $tag ..."
        $zip = Join-Path $payload 'napcat-shell.zip'
        GitHub-Fetch $url $zip -ExpectZip
        $source = $url
    }
    Write-Info '正在解压 NapCat(约 10 秒)...'

    # 4. 解压到临时 release 目录并校验入口脚本
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $releases = Join-Path $payload 'releases'
    Ensure-Dir $releases
    $release = Join-Path $releases "image-$tag-$stamp"
    $releaseNew = "$release.new"
    Remove-DirSafe $releaseNew
    Expand-Zip $zip $releaseNew
    Strip-TopLevel $releaseNew
    foreach ($required in @($launch, 'napcat.mjs', 'NapCatWinBootMain.exe', 'NapCatWinBootHook.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $releaseNew $required))) {
            $names = @()
            Get-ChildItem -Path $releaseNew | ForEach-Object { $names += $_.Name }
            Write-Warn ('解压根目录内容: ' + ($names -join ', '))
            Remove-DirSafe $releaseNew
            Die "NapCat 包中未找到 $required,请确认下载的是 NapCat.Shell.zip(入口脚本可用配置项 NAPCAT_LAUNCH 调整)。"
        }
    }

    # 5. 记录来源并转正
    Write-TextFile (Join-Path $releaseNew '.image-source') $source
    Move-Item -LiteralPath $releaseNew -Destination $release -Force

    # 5.1 切换载荷前先把旧载荷里的配置收回主目录。NapCat 是在载荷目录里读写
    #     配置的(WebUI 改的设置、登录态记录、新生成的 token 都写在那儿),
    #     而载荷会被整个换掉——不先收回来,升级一次就全丢。
    $oldConfigDir = Join-Path $payload 'current\config'
    if (Test-Path -LiteralPath $oldConfigDir) {
        $masterCfgDir = Join-Path $snowRoot 'config'
        Ensure-Dir $masterCfgDir
        $harvested = 0
        Get-ChildItem -Path $oldConfigDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $masterCfgDir $_.Name) -Force
            $harvested = $harvested + 1
        }
        if ($harvested -gt 0) {
            Write-Info ('已回收旧载荷中的 ' + $harvested + ' 个配置文件到 ' + $masterCfgDir)
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

    # 7. NAPCAT_ROOT 主配置目录:载荷升级会整目录切换,配置的
    #    唯一真源放在 NAPCAT_ROOT\config,每次启动前由 napcat-launch.bat
    #    同步进载荷的 config 目录,升级不丢配置。
    foreach ($d in @('config', 'logs')) {
        Ensure-Dir (Join-Path $snowRoot $d)
    }
    $masterCfg = Join-Path $snowRoot 'config'
    $port = Get-Cfg 'NAPCAT_WEBUI_PORT'
    if (-not $port) { $port = 6099 }
    $webuiJson = Join-Path $masterCfg 'webui.json'
    if (-not (Test-Path -LiteralPath $webuiJson)) {
        $webuiToken = (New-RandomToken).Substring(0, 16)
        $webuiContent = '{' + "`r`n" +
            '  "host": "0.0.0.0",' + "`r`n" +
            '  "port": ' + $port + ',' + "`r`n" +
            '  "token": "' + $webuiToken + '",' + "`r`n" +
            '  "loginRate": 3' + "`r`n" +
            '}' + "`r`n"
        Write-TextFile $webuiJson $webuiContent
        Write-Info "已生成 NapCat WebUI 配置,访问令牌(token): $webuiToken(保存在 $webuiJson)"
    }
    # 首次安装时把包内默认 napcat.json 收编为主配置
    $masterNapcatJson = Join-Path $masterCfg 'napcat.json'
    $releaseNapcatJson = Join-Path $release 'config\napcat.json'
    if ((-not (Test-Path -LiteralPath $masterNapcatJson)) -and (Test-Path -LiteralPath $releaseNapcatJson)) {
        Copy-Item -LiteralPath $releaseNapcatJson -Destination $masterNapcatJson -Force
    }
    # 立即把主配置同步进新载荷(启动脚本每次也会同步)
    Get-ChildItem -Path $masterCfg | ForEach-Object {
        if (-not $_.PSIsContainer) {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $release ('config\' + $_.Name)) -Force
        }
    }

    # 8. 运行资产、计划任务与守护标记
    Install-RuntimeAssets
    Install-Tasks
    Write-TextFile (Join-Path $state 'napcat.enabled') ''

    # 9. 重启 NapCat 任务(启动器会自带拉起 QQ)并做健康检查
    [void](Invoke-Schtasks @('/End', '/TN', '\NBot\NapCat'))
    Stop-QQProcess
    [void](Invoke-Schtasks @('/Run', '/TN', '\NBot\NapCat'))
    # NapCat WebUI 根路径可能返回 404,健康检查用 TCP 端口连通性
    if (-not (Wait-Tcp '127.0.0.1' $port 40 (Join-Path $snowRoot 'logs\napcat.log'))) {
        # 10. 回滚
        Write-Warn '新版本 NapCat 未能通过健康检查,正在回滚。'
        [void](Invoke-Schtasks @('/End', '/TN', '\NBot\NapCat'))
        Stop-QQProcess
        if ($oldCurrent -and (Test-Path -LiteralPath $oldCurrent)) {
            Set-Junction (Join-Path $payload 'current') $oldCurrent
            Write-TextFile $curFile $oldCurrent
            [void](Invoke-Schtasks @('/Run', '/TN', '\NBot\NapCat'))
        }
        $log = Join-Path $snowRoot 'logs\napcat.log'
        if (Test-Path -LiteralPath $log) {
            Write-Warn "以下为 $log 最后 60 行:"
            Get-TailLines $log 60 | ForEach-Object { Write-Host $_ }
        }
        Die 'NapCat 启动失败,已尝试回滚。提示:\NBot\NapCat 任务仅在用户登录桌面时运行,若当前未登录 Windows 桌面,请保持桌面登录状态后重试。'
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

    Write-Info "NapCat ($tag) 已启动,WebUI: http://127.0.0.1:$port/webui(局域网访问请使用本机 IP;token 见 $webuiJson)"
}
