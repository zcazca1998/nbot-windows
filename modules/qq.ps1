# modules\qq.ps1 - QQ(NT 版)探测/下载/安装,两个后端共用(PowerShell 2.0 兼容)
# 由 install-core.ps1 dot-source;依赖 lib\common.ps1 与 modules\tasks.ps1。
# NapCat 与 SnowLuma 都要求本机装有 QQ NT:NapCat 的启动器自带拉起 QQ,
# SnowLuma 则只注入不拉起(QQ 由 snowluma-launch.bat 负责,路径记在 QQ_EXE)。

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
        # 安装包落到当前后端的载荷目录(napcat / snowluma 各自独立)
        $payload = Get-BotPayloadRoot
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
    if (Test-SnowLuma) {
        # SnowLuma 后端:启动器要靠 QQ_EXE 拉起 QQ,装完立即落配置。
        Save-QQExePath $exe
    }
    Write-Info "QQ 已安装: $exe"
}

function Save-QQExePath {
    # 把 QQ.exe 的路径落进配置:snowluma-launch.bat 要靠它启动 QQ
    # (SnowLuma 只注入,不负责拉起 QQ)。
    param([string]$Exe)
    if (-not $Exe) { return }
    if ((Get-Cfg 'QQ_EXE') -eq $Exe) { return }
    Set-Cfg 'QQ_EXE' $Exe
    Write-Config
}
