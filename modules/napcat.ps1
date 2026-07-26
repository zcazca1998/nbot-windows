# modules\napcat.ps1 - NapCat(Windows 版)与 QQ 安装(PowerShell 2.0 兼容)
# 由 install-core.ps1 dot-source;依赖 lib\common.ps1 与 modules\tasks.ps1。
# 说明:Windows 版 NapCat 启动器自带拉起 QQ(NapCat Shell 模式),
# QQ 与 NapCat 由同一个计划任务 \NBot\NapCat 管理,与 Linux 版不同。

function Find-QQExe {
    $cand = @()

    # 1) 配置指定的安装目录
    $confDir = Get-Cfg 'QQ_INSTALL_DIR'
    if ($confDir) { $cand += (Join-Path $confDir 'QQ.exe') }

    # 2) 注册表卸载信息
    $regKeys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\QQ',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\QQ'
    )
    foreach ($rk in $regKeys) {
        try {
            $props = Get-ItemProperty -Path $rk -ErrorAction Stop
            $un = [string]$props.UninstallString
            if ($un) {
                if ($un -match '^\s*"([^"]+)"') {
                    $un = $matches[1]
                } else {
                    $un = $un.Trim()
                }
                $dir = $null
                try { $dir = Split-Path -Parent $un } catch { }
                if ($dir) { $cand += (Join-Path $dir 'QQ.exe') }
            }
        } catch { }
    }

    # 3) 默认安装位置
    if ($env:ProgramFiles) {
        $cand += (Join-Path $env:ProgramFiles 'Tencent\QQNT\QQ.exe')
    }
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) {
        $cand += (Join-Path $pf86 'Tencent\QQNT\QQ.exe')
    }

    foreach ($c in $cand) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Resolve-QQUrl {
    # 返回值:本地文件路径(离线安装包)或 http(s) URL;调用方按前缀区分。
    $offline = Join-Path (Get-ScriptRoot) 'offline\qq-setup.exe'
    if (Test-Path -LiteralPath $offline) { return $offline }

    $conf = Get-Cfg 'QQ_WIN_URL'
    if ($conf) { return $conf }

    if ($script:OsProfile -eq 'legacy') {
        $legacy = Get-Cfg 'QQ_WIN_URL_LEGACY'
        if ($legacy) { return $legacy }
        Die ("当前系统为 Windows 7/8(legacy),只能运行基于 Electron 22 及以下版本构建的旧版 QQ NT,官方已不再提供其下载。`n" +
            "请自行找到可用的旧版 QQ NT 安装包下载地址,填入配置项 QQ_WIN_URL_LEGACY,`n" +
            "或将安装包保存为 offline\qq-setup.exe 后重试。")
    }

    # modern 系统:从官方 CDN 解析最新下载地址(直连,不走 GitHub 代理)
    $tmp = Join-Path $env:TEMP ('qq-dl-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.js')
    $jsUrl = 'https://cdn-go.cn/qq-web/im.qq.com_new/latest/rainbow/windowsDownloadUrl.js'
    try {
        Download-File $jsUrl $tmp
    } catch {
        Die "获取 QQ 官方下载地址失败: $($_.Exception.Message)`n可手动将 QQ 安装包 URL 填入配置项 QQ_WIN_URL 后重试。"
    }
    $text = Read-TextFile $tmp
    Remove-FileSafe $tmp

    $want = 'X64'
    if ($script:SystemArch -eq 'arm64') { $want = 'ARM' }
    # 实际内容是一行 JSON:"ntDownloadX64Url":"https://dldir1.qq.com/..."
    # 不能用 [^"']* 去跳过冒号——那会把值开头的引号当成结束引号,抓到空串。
    # 直接锚定冒号后的 http 链接最稳。
    $pattern = 'ntDownload(X64|ARM)Url"\s*:\s*"(https?://[^"]+)"'
    $result = $null
    foreach ($m in [regex]::Matches([string]$text, $pattern)) {
        if ($m.Groups[1].Value -eq $want) {
            $result = $m.Groups[2].Value
            break
        }
    }
    # 兜底:X64 没匹配到时退回通用 ntDownloadUrl(32 位安装包也能装)
    if (-not $result) {
        $fallback = [regex]::Match([string]$text, 'ntDownloadUrl"\s*:\s*"(https?://[^"]+)"')
        if ($fallback.Success) { $result = $fallback.Groups[1].Value }
    }
    if (-not $result) {
        Die '未能从官方页面解析出 QQ 下载地址,可手动将安装包 URL 填入配置项 QQ_WIN_URL 后重试。'
    }
    Write-Info ('已解析到 QQ 官方安装包: ' + $result)
    # 官方这份配置里的版本可能已被下架(实测出现过 404),先探一下再下载,
    # 免得等下载失败才报错。不可用时给出可操作的三条出路。
    if (-not (Test-UrlAvailable $result)) {
        Die ("解析到的 QQ 安装包链接已失效(服务器返回非 200): $result`n" +
            "腾讯会下架旧版本,而官方那份下载配置有时更新滞后。请任选一种方式:`n" +
            "  1) 到 im.qq.com 下载 QQ 安装包,放到安装器目录的 offline\qq-setup.exe;`n" +
            "  2) 把可用的安装包直链填入配置项 QQ_WIN_URL;`n" +
            "  3) 先手动装好 QQ,安装器会自动探测到已安装的 QQ 并跳过下载。")
    }
    return $result
}

function Stop-QQProcess {
    try {
        $procs = Get-WmiObject Win32_Process -Filter "Name='QQ.exe'"
        foreach ($p in @($procs)) {
            if (-not $p) { continue }
            try { [void]$p.Terminate() } catch { }
        }
    } catch { }
}

function Install-QQ {
    $existing = Find-QQExe
    if ($existing) {
        Write-Info "检测到已安装的 QQ: $existing"
        if (-not (Confirm-Action '是否重新安装/升级 QQ?' $false)) {
            return
        }
    }

    $src = Resolve-QQUrl
    $setup = $null
    if ($src -notmatch '^https?://') {
        Write-Info "使用离线 QQ 安装包: $src"
        $setup = $src
    } else {
        $payload = Get-Cfg 'NAPCAT_PAYLOAD_ROOT'
        if (-not $payload) { $payload = 'C:\AstrBot\.nbot\napcat' }
        Ensure-Dir $payload
        $setup = Join-Path $payload 'qq-setup.exe'
        Write-Info "下载 QQ 安装包: $src"
        Download-File $src $setup
    }

    Write-Info '开始静默安装 QQ(通常 1-2 分钟无输出;若弹出了安装向导窗口,请按提示手动点完)...'
    try {
        Start-Process -FilePath $setup -ArgumentList '/s' -Wait
    } catch {
        Write-Warn "运行 QQ 安装程序失败: $($_.Exception.Message)"
    }

    $exe = Find-QQExe
    if (-not $exe) {
        Write-Warn "静默安装后仍未检测到 QQ.exe,请手动运行安装包完成安装后重试: $setup"
        Die 'QQ 安装未完成,安装 QQ 后请重新运行本安装器。'
    }
    Write-Info "QQ 已安装: $exe"
}

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
        $tag = GitHub-LatestTag $repo
        if (-not $tag) { Die "无法获取 $repo 的最新版本号,请检查网络配置。" }
        $confAsset = Get-Cfg 'NAPCAT_ASSET'
        $patterns = $null
        if ($confAsset) {
            $patterns = @($confAsset)
        } else {
            # 官方资产名固定为 NapCat.Shell.zip;宽松模式兜底
            $patterns = @('/NapCat\.Shell\.zip$', '(?i)shell.*\.zip$')
        }
        $url = $null
        foreach ($pat in $patterns) {
            $url = GitHub-AssetUrl $repo $pat
            if ($url) { break }
        }
        if (-not $url) {
            Die '未找到 Windows 版 NapCat 发布包,请检查 NAPCAT_REPO / NAPCAT_ASSET 配置,或将 zip 放入 offline\napcat-shell.zip。'
        }
        Write-Info "下载 NapCat $tag ..."
        $zip = Join-Path $payload 'napcat-shell.zip'
        GitHub-Fetch $url $zip
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
