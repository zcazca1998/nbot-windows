# =============================================================================
# nbot-installer-windows / lib/common.ps1
# 公共函数库：日志输出、配置读写、系统探测、下载与解压等基础能力。
# 兼容范围：Windows 7 SP1 - Windows 11（PowerShell 2.0 及以上可解析、可运行）。
# 本文件由 install-core.ps1 dot-source 加载，不可单独执行。
# =============================================================================

$ErrorActionPreference = 'Stop'

# 记录本文件路径，供 Get-ScriptRoot 使用（PowerShell 2.0 没有 $PSScriptRoot）。
$script:CommonPs1Path = $MyInvocation.MyCommand.Path

# -----------------------------------------------------------------------------
# 输出函数
# -----------------------------------------------------------------------------

function Write-Bold {
    param($Message)
    Write-Host $Message -ForegroundColor White
}

function Write-Info {
    param($Message)
    Write-Host '[INFO] ' -ForegroundColor Blue -NoNewline
    Write-Host $Message
}

function Write-Warn {
    param($Message)
    Write-Host '[WARN] ' -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Die {
    param($Message)
    Write-Host ('[ERROR] ' + $Message) -ForegroundColor Red
    throw $Message
}

# -----------------------------------------------------------------------------
# 目录相关
# -----------------------------------------------------------------------------

function Ensure-Dir {
    param($Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-ScriptRoot {
    # common.ps1 位于 <安装器根目录>\lib\，根目录即上上级。
    return (Split-Path -Parent (Split-Path -Parent $script:CommonPs1Path))
}

function Get-NBotDir {
    $dir = Join-Path $env:ProgramData 'nbot'
    Ensure-Dir $dir
    return $dir
}

function Get-InstallerDir {
    $dir = Join-Path (Get-NBotDir) 'installer'
    Ensure-Dir $dir
    return $dir
}

function Get-BinDir {
    $dir = Join-Path (Get-NBotDir) 'bin'
    Ensure-Dir $dir
    return $dir
}

function Get-StateDir {
    $dir = Join-Path (Get-NBotDir) 'state'
    Ensure-Dir $dir
    return $dir
}

function Get-NBotLogDir {
    $dir = Join-Path (Get-NBotDir) 'logs'
    Ensure-Dir $dir
    return $dir
}

# -----------------------------------------------------------------------------
# 文本文件读写（UTF-8，写入不带 BOM）
# -----------------------------------------------------------------------------

function Read-TextFile {
    param($Path)
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path (Get-Location).Path $Path
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    return [IO.File]::ReadAllText($Path, $encoding)
}

function Write-TextFile {
    param($Path, $Content)
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path (Get-Location).Path $Path
    }
    $parent = Split-Path -Parent $Path
    if ($parent) { Ensure-Dir $parent }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

# -----------------------------------------------------------------------------
# 配置管理
# 配置文件：$env:NBOT_CONFIG 优先，否则 %ProgramData%\nbot\nbot.conf
# 格式：每行 KEY=value（无引号，值可含空格）
# -----------------------------------------------------------------------------

function Get-ConfigPath {
    if ($env:NBOT_CONFIG) {
        return $env:NBOT_CONFIG
    }
    return (Join-Path (Get-NBotDir) 'nbot.conf')
}

function Load-Config {
    # 默认键顺序（写配置文件时按此顺序全部写出）
    # 键分三类：
    #   NAPCAT_* / SL_*  安装器自己的配置，只有本项目读。
    #   SNOWLUMA_*  与 SnowLuma 自己的环境变量同名，由 snowluma-launch.bat
    #               原样 export，SnowLuma 启动时直接采纳（它的 env 优先级高于
    #               config\runtime.json，且不会被写回该文件），所以配置真源
    #               始终是 nbot.conf。新增此类键前请先确认 SnowLuma 确实
    #               支持同名环境变量。
    $script:CfgKeys = @(
        'BOT_BACKEND',
        'ASTRBOT_ROOT', 'NAPCAT_ROOT', 'NAPCAT_PAYLOAD_ROOT', 'SL_ROOT', 'SL_PAYLOAD_ROOT',
        'ASTRBOT_PORT', 'ASTRBOT_WS_PORT', 'NAPCAT_WEBUI_PORT', 'SNOWLUMA_WEBUI_PORT', 'ONEBOT_HTTP_PORT',
        'GITHUB_ACCESS', 'GITHUB_PROXY', 'GITHUB_MIRROR', 'PIP_INDEX_URL',
        'PYTHON_VERSION', 'PYTHON_URL', 'PYTHON_WIN7_URL', 'PYTHON_FORCE_MANAGED',
        'ASTRBOT_REPO', 'ASTRBOT_TAG',
        'NAPCAT_REPO', 'NAPCAT_ASSET', 'NAPCAT_LAUNCH',
        'SL_REPO', 'SL_ASSET', 'SL_LAUNCH', 'SL_NODE',
        'SNOWLUMA_HOOK_AUTOLOAD', 'SNOWLUMA_ACCEPT_EULA', 'SNOWLUMA_ACCEPT_PRIVACY',
        'QQ_WIN_URL', 'QQ_WIN_URL_LEGACY', 'QQ_INSTALL_DIR', 'QQ_EXE', 'QQ_UIN'
    )

    $script:Cfg = @{}
    # 机器人后端：napcat(默认)| snowluma。解析统一走 Get-Backend。
    $script:Cfg['BOT_BACKEND'] = 'napcat'
    $script:Cfg['ASTRBOT_ROOT'] = 'C:\AstrBot'
    $script:Cfg['NAPCAT_ROOT'] = 'C:\NapCat'
    $script:Cfg['NAPCAT_PAYLOAD_ROOT'] = 'C:\AstrBot\.nbot\napcat'
    $script:Cfg['SL_ROOT'] = 'C:\SnowLuma'
    $script:Cfg['SL_PAYLOAD_ROOT'] = 'C:\AstrBot\.nbot\snowluma'
    $script:Cfg['ASTRBOT_PORT'] = '6185'
    $script:Cfg['ASTRBOT_WS_PORT'] = '6199'
    $script:Cfg['NAPCAT_WEBUI_PORT'] = '6099'
    # SnowLuma 自己的默认 WebUI 端口就是 5099
    $script:Cfg['SNOWLUMA_WEBUI_PORT'] = '5099'
    $script:Cfg['ONEBOT_HTTP_PORT'] = '3005'
    $script:Cfg['GITHUB_ACCESS'] = 'auto'
    $script:Cfg['GITHUB_PROXY'] = ''
    # 默认空:不写死单个镜像,交给 Get-OrderedMirrors 在下载前做一次连通性
    # 探针、按延迟自动选最快的可用镜像(ghfast.top 等仍在候选池首位)。
    # 好处:国内不同网络对各个 ghproxy 镜像的可用性差异很大,写死一个反而
    # 容易踩到抽风的那个;空配置 + auto 模式等于「多镜像自动择优」。
    # 与 wizard.ps1 的 $GhValues 首项(空字符串 = 自动选最快)保持一致。
    $script:Cfg['GITHUB_MIRROR'] = ''
    $script:Cfg['PIP_INDEX_URL'] = ''
    $script:Cfg['PYTHON_VERSION'] = '3.13.5'
    $script:Cfg['PYTHON_URL'] = ''
    $script:Cfg['PYTHON_WIN7_URL'] = ''
    $script:Cfg['PYTHON_FORCE_MANAGED'] = ''
    $script:Cfg['ASTRBOT_REPO'] = 'AstrBotDevs/AstrBot'
    $script:Cfg['ASTRBOT_TAG'] = ''
    $script:Cfg['NAPCAT_REPO'] = 'NapNeko/NapCatQQ'
    $script:Cfg['NAPCAT_ASSET'] = ''
    # launcher-win10.bat 与 launcher.bat 内容一致，仅提权回退不依赖 wt.exe
    $script:Cfg['NAPCAT_LAUNCH'] = 'launcher-win10.bat'
    $script:Cfg['SL_REPO'] = 'SnowLuma/SnowLuma'
    $script:Cfg['SL_ASSET'] = ''
    $script:Cfg['SL_LAUNCH'] = 'launcher.bat'
    # 载荷内自带的 Node（完整版 zip 带 node.exe）。留空则用 PATH 上的 node。
    $script:Cfg['SL_NODE'] = 'node.exe'
    # SnowLuma 发现 QQ.exe 后自动注入 hook —— 无人值守必需
    $script:Cfg['SNOWLUMA_HOOK_AUTOLOAD'] = '1'
    # 协议同意：留空表示未同意，首次打开 WebUI 时由用户本人在页面上确认。
    # 只有用户在向导里勾选后才写 1（详见 README「协议同意」一节）。
    $script:Cfg['SNOWLUMA_ACCEPT_EULA'] = ''
    $script:Cfg['SNOWLUMA_ACCEPT_PRIVACY'] = ''
    $script:Cfg['QQ_WIN_URL'] = ''
    $script:Cfg['QQ_WIN_URL_LEGACY'] = ''
    $script:Cfg['QQ_INSTALL_DIR'] = ''
    # QQ.exe 的完整路径。SnowLuma 自己不启动 QQ,由 snowluma-launch.bat 拉起,
    # 所以这个路径必须落到配置里(安装/修复时自动探测填入)。NapCat 后端不用它。
    $script:Cfg['QQ_EXE'] = ''
    $script:Cfg['QQ_UIN'] = ''

    $file = Get-ConfigPath
    if (Test-Path -LiteralPath $file) {
        $text = Read-TextFile $file
        $lines = $text -split "`r?`n"
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -eq '') { continue }
            if ($trimmed.StartsWith('#')) { continue }
            $idx = $trimmed.IndexOf('=')
            if ($idx -lt 1) { continue }
            $key = $trimmed.Substring(0, $idx).Trim()
            $value = $trimmed.Substring($idx + 1).Trim()
            $script:Cfg[$key] = $value
            if ($script:CfgKeys -notcontains $key) {
                $script:CfgKeys += $key
            }
        }
    }
}

function Get-Cfg {
    param($Key)
    if ($null -eq $script:Cfg) { Load-Config }
    return $script:Cfg[$Key]
}

function Set-Cfg {
    param($Key, $Value)
    if ($null -eq $script:Cfg) { Load-Config }
    $script:Cfg[$Key] = $Value
    if ($script:CfgKeys -notcontains $Key) {
        $script:CfgKeys += $Key
    }
}

function Write-Config {
    if ($null -eq $script:Cfg) { Load-Config }
    $file = Get-ConfigPath
    $parent = Split-Path -Parent $file
    if ($parent) { Ensure-Dir $parent }
    $sb = New-Object System.Text.StringBuilder
    # 注释行保持纯 ASCII：启动 .bat 用 cmd 按本地代码页读取本文件，
    # 中文注释在 GBK 控制台下会被误读（值本身也建议使用纯 ASCII 路径）。
    [void]$sb.AppendLine('# nbot config (generated by the installer; format: KEY=value)')
    foreach ($key in $script:CfgKeys) {
        $value = $script:Cfg[$key]
        if ($null -eq $value) { $value = '' }
        [void]$sb.AppendLine($key + '=' + $value)
    }
    # 原子写入：先写临时文件再替换
    $temp = $file + '.tmp'
    Write-TextFile $temp $sb.ToString()
    Move-Item -Path $temp -Destination $file -Force
}

# -----------------------------------------------------------------------------
# 后端选择(napcat / snowluma)
# 这里是 BOT_BACKEND 的唯一解析点:其他文件一律调下面这些函数,禁止自己
# if BOT_BACKEND 分支,避免各处解析口径不一致。
# -----------------------------------------------------------------------------

function Get-Backend {
    # 读配置键 BOT_BACKEND;空/非法一律回落 napcat。
    $backend = Get-Cfg 'BOT_BACKEND'
    if ($backend) { $backend = ([string]$backend).Trim().ToLower() }
    if ($backend -eq 'snowluma') { return 'snowluma' }
    return 'napcat'
}

function Test-SnowLuma {
    return ((Get-Backend) -eq 'snowluma')
}

function Get-BotName {
    # 显示名,同时也是计划任务叶名(\NBot\<名>)。
    if (Test-SnowLuma) { return 'SnowLuma' }
    return 'NapCat'
}

function Get-BotTaskPath {
    return ('\NBot\' + (Get-BotName))
}

function Get-BotRoot {
    if (Test-SnowLuma) {
        $root = Get-Cfg 'SL_ROOT'
        if (-not $root) { $root = 'C:\SnowLuma' }
        return $root
    }
    $root = Get-Cfg 'NAPCAT_ROOT'
    if (-not $root) { $root = 'C:\NapCat' }
    return $root
}

function Get-BotPayloadRoot {
    if (Test-SnowLuma) {
        $payload = Get-Cfg 'SL_PAYLOAD_ROOT'
        if (-not $payload) { $payload = 'C:\AstrBot\.nbot\snowluma' }
        return $payload
    }
    $payload = Get-Cfg 'NAPCAT_PAYLOAD_ROOT'
    if (-not $payload) { $payload = 'C:\AstrBot\.nbot\napcat' }
    return $payload
}

function Get-BotWebuiPort {
    if (Test-SnowLuma) {
        $port = Get-Cfg 'SNOWLUMA_WEBUI_PORT'
        if (-not $port) { $port = '5099' }
        return $port
    }
    $port = Get-Cfg 'NAPCAT_WEBUI_PORT'
    if (-not $port) { $port = '6099' }
    return $port
}

function Get-BotWebuiUrl {
    $port = Get-BotWebuiPort
    if (Test-SnowLuma) {
        return ('http://127.0.0.1:' + $port + '/')
    }
    return ('http://127.0.0.1:' + $port + '/webui')
}

function Get-BotLaunchScript {
    if (Test-SnowLuma) { return 'snowluma-launch.bat' }
    return 'napcat-launch.bat'
}

function Get-BotMarker {
    # 状态标记文件(state\<marker>.enabled)与 giveup 键的前缀。
    if (Test-SnowLuma) { return 'snowluma' }
    return 'napcat'
}

function Get-BotLogFile {
    return (Join-Path (Get-BotRoot) ('logs\' + (Get-BotMarker) + '.log'))
}

# -----------------------------------------------------------------------------
# 系统探测
# -----------------------------------------------------------------------------

function Detect-OS {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $props = Get-ItemProperty -Path $key
    $build = 0
    try { $build = [int]$props.CurrentBuild } catch { $build = 0 }
    $script:OsBuild = $build

    if ($null -ne $props.CurrentMajorVersionNumber) {
        # Windows 10 / 11
        if ($build -ge 22000) {
            $script:OsName = 'Windows 11'
        } else {
            $script:OsName = 'Windows 10'
        }
        $script:OsProfile = 'modern'
    } else {
        $version = [string]$props.CurrentVersion
        if ($version -eq '6.1') {
            $script:OsName = 'Windows 7'
            $script:OsProfile = 'legacy'
        } elseif ($version -eq '6.2') {
            $script:OsName = 'Windows 8'
            $script:OsProfile = 'legacy'
        } elseif ($version -eq '6.3') {
            $script:OsName = 'Windows 8.1'
            $script:OsProfile = 'legacy'
        } else {
            Die ('不支持的 Windows 版本（NT ' + $version + '）。最低要求 Windows 7 SP1。')
        }
    }
}

function Detect-Arch {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    if ($arch -eq 'AMD64') {
        $script:SystemArch = 'x64'
    } elseif ($arch -eq 'ARM64') {
        $script:SystemArch = 'arm64'
    } else {
        Die ('不支持的系统架构：' + $arch + '。仅支持 64 位系统（x64 / ARM64）。')
    }
}

function Enable-Tls {
    $script:TlsOk = $false
    try {
        # 3072 = Tls12（用数字以兼容旧 .NET 枚举缺失的情况）
        $current = [int][System.Net.ServicePointManager]::SecurityProtocol
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]($current -bor 3072)
        $script:TlsOk = $true
    } catch {
        Write-Warn '无法启用 TLS 1.2。Windows 7 需要先安装 .NET Framework 4.5 及以上版本，并安装系统更新（如 KB3140245）后重试，否则 HTTPS 下载将失败。'
    }
    try {
        # 12288 = Tls13（部分系统不支持，单独尝试）
        $current = [int][System.Net.ServicePointManager]::SecurityProtocol
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]($current -bor 12288)
    } catch { }
}

function Find-CurlExe {
    $script:CurlExe = $null
    $candidates = @()
    $sysCurl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $sysCurl) { $candidates += $sysCurl }
    $cmdInfo = $null
    try { $cmdInfo = Get-Command 'curl.exe' -ErrorAction SilentlyContinue } catch { $cmdInfo = $null }
    if ($null -ne $cmdInfo) {
        foreach ($item in @($cmdInfo)) {
            $path = $null
            try { $path = $item.Path } catch { $path = $null }
            if (-not $path) { try { $path = $item.Definition } catch { $path = $null } }
            if ($path -and ($candidates -notcontains $path)) { $candidates += $path }
        }
    }
    foreach ($candidate in $candidates) {
        try {
            $output = & $candidate --version | Out-String
            if ($LASTEXITCODE -eq 0 -and $output -match 'curl') {
                $script:CurlExe = $candidate
                break
            }
        } catch { }
    }
    return $script:CurlExe
}

# -----------------------------------------------------------------------------
# 下载
# -----------------------------------------------------------------------------

function Download-File {
    param($Url, $OutFile, $Proxy)
    $parent = Split-Path -Parent $OutFile
    if ($parent) { Ensure-Dir $parent }
    Write-Info ('下载：' + $Url)

    if ($script:CurlExe) {
        # --connect-timeout 只管「连不上」。被墙的连接经常是连得上、传输阶段被
        # 掐死——没有停滞检测的话 curl 会永远挂着,重试也永远轮不到。
        # --speed-time/--speed-limit:30 秒内平均速度低于 1KB/s 视为死链,断掉
        # 交给下一个通道;大文件慢速下载只要还在动就不受影响。
        $curlArgs = @('-L', '--fail', '--retry', '3', '--retry-delay', '2', '--connect-timeout', '20', '--speed-limit', '1024', '--speed-time', '30', '-o', $OutFile)
        if ($Proxy) { $curlArgs += @('-x', $Proxy) }
        $curlArgs += $Url
        & $script:CurlExe @curlArgs
        if ($LASTEXITCODE -eq 0) {
            return
        }
        # curl 失败(被墙/不支持该协议如 file:// 等)不要立刻放弃——降级到下面的
        # 托管 WebRequest 通道再试一次,多一层兜底,国内网络波动时更扛造。
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
        Write-Warn ('curl 下载失败（退出码 ' + $LASTEXITCODE + '），改用系统 WebRequest 兜底：' + $Url)
    } elseif ($Proxy -and $Proxy -match '^socks') {
        Die '配置了 socks 代理，但系统中没有可用的 curl.exe；socks 代理仅在有 curl.exe 时可用。请改用 http/https 代理，或安装 curl。'
    }

    # WebClient.DownloadFile 没有任何超时,被墙的连接会永远挂死。改用
    # HttpWebRequest + 手动流拷贝:Timeout 管连接/响应头,ReadWriteTimeout 管
    # 每一次 Read——传输停滞超过 60 秒即抛异常交给上层回退,而不是挂住整个安装。
    $part = $OutFile + '.part'
    $resp = $null
    $inStream = $null
    $outStream = $null
    try {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
        $req = [System.Net.WebRequest]::Create($Url)
        # Timeout/ReadWriteTimeout 仅 HttpWebRequest 等子类支持;file:// 等其他
        # 协议返回的请求类型会抛 NotSupportedException,包一层避免殃及整个下载。
        try { $req.Timeout = 30000 } catch { }
        try { $req.ReadWriteTimeout = 60000 } catch { }
        try { $req.UserAgent = 'nbot-installer' } catch { }
        if ($Proxy) {
            $req.Proxy = New-Object System.Net.WebProxy($Proxy)
        }
        $resp = $req.GetResponse()
        $inStream = $resp.GetResponseStream()
        $outStream = New-Object System.IO.FileStream($part, [System.IO.FileMode]::Create)
        $buf = New-Object byte[] 65536
        while ($true) {
            $n = $inStream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $outStream.Write($buf, 0, $n)
        }
        $outStream.Close()
        $outStream = $null
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
        Move-Item -Path $part -Destination $OutFile
    } catch {
        if ($outStream) { try { $outStream.Close() } catch { } ; $outStream = $null }
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
        throw
    } finally {
        if ($outStream) { try { $outStream.Close() } catch { } }
        if ($inStream) { try { $inStream.Close() } catch { } }
        if ($resp) { try { $resp.Close() } catch { } }
    }
}

function Test-ValidZip {
    # 下载完成后校验文件确实是 zip(而不是镜像/代理返回的错误 HTML 页)。
    # 镜像常返回 200 + 错误页,导致 curl 的 --fail 拦不住,后续解压才报一个
    # 很迷惑的「未找到 launcher」;这里在下载通道内就拦截,触发下一通道重试。
    # 真正确定性的判据是 ZIP 魔数 PK\x03\x04;MinBytes 仅作极低底线(挡住空响应
    # /截断的极小文件)。设为 64 字节——远小于任何含内容的合法 zip,避免误杀
    # 体积不大但合法的包;真正的拦截面是上面的 PK 魔数检查。
    param($Path, [long]$MinBytes = 64)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path
        if ($item.Length -lt $MinBytes) { return $false }
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sig = New-Object 'System.Byte[]' 4
        $n = $stream.Read($sig, 0, 4)
        $stream.Close()
        if ($n -lt 4) { return $false }
        # ZIP 本地文件头 PK\x03\x04;空归档 PK\x05\x06;跨卷 PK\x07\x08
        if ($sig[0] -eq 0x50 -and $sig[1] -eq 0x4B -and $sig[3] -eq 0x04 -and ($sig[2] -eq 0x03 -or $sig[2] -eq 0x05 -or $sig[2] -eq 0x07)) {
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

function Get-MirrorPool {
    # 候选镜像池:国内访问 GitHub 经常超时/被墙,ghproxy 类镜像能显著提速。
    # 这份列表只是「候选」——真正下载前会由 Get-OrderedMirrors 做一次连通性
    # 探针(访问 github.com/favicon.ico),只保留能用的、并按延迟排序,死镜像
    # 不会拖慢安装。镜像地址可能随时失效,多列几个提高兜底命中率;最终顺序
    # 由探针延迟决定,这里写的先后只是「偏好」,不影响结果。
    #
    # 用户配置(GITHUB_MIRROR)始终排在最前,且不受探针结果影响——那是用户
    # 自己指定的,必须尊重。
    $pool = New-Object System.Collections.ArrayList
    foreach ($m in @(
        'https://ghfast.top',
        'https://ghproxy.net',
        'https://ghproxy.com',
        'https://mirror.ghproxy.com',
        'https://gh.api.99988866.xyz',
        'https://ghproxy.1888866.xyz',
        'https://ghdl.f4team.xyz',
        'https://github.moeyy.xyz',
        'https://ghproxy.ygxz.in',
        'https://slink.ltd'
    )) {
        if (-not $pool.Contains($m)) { [void]$pool.Add($m) }
    }
    return $pool.ToArray()
}

function Get-MirrorList {
    # 用户配置(GITHUB_MIRROR,支持 ; | , 分隔)放最前,再追加候选池。
    # 这里不做连通性过滤——过滤交给 Get-OrderedMirrors(带缓存 + 排序)。
    $cfg = Get-Cfg 'GITHUB_MIRROR'
    $list = New-Object System.Collections.ArrayList
    if ($cfg) {
        foreach ($m in $cfg.Split(@(';', '|', ','), [StringSplitOptions]::RemoveEmptyEntries)) {
            $m = $m.Trim()
            if ($m -and -not $list.Contains($m)) { [void]$list.Add($m) }
        }
    }
    foreach ($m in (Get-MirrorPool)) {
        if (-not $list.Contains($m)) { [void]$list.Add($m) }
    }
    return $list.ToArray()
}

function Get-MirrorCachePath {
    # 探针结果缓存到一个普通用户可写的位置(ProgramData 需要管理员权限,
    # 而探针也可能在普通权限下跑,比如面板里点「测试连通性」)。
    return (Join-Path $env:TEMP 'nbot-mirror-rank.txt')
}

function Test-LooksLikeJson {
    # 镜像常返回 200 + HTML 错误页(curl --fail 拦不住),必须拦在通道内,
    # 否则下游 JSON 解析会拿一段 HTML 去匹配 tag_name 然后 Die。
    # 轻量判据:非空、且不像 HTML(<html / <!doctype 大小写不敏感)。
    param($Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path
        if ($item.Length -lt 2) { return $false }
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $buf = New-Object 'System.Byte[]' 4096
        $n = $stream.Read($buf, 0, [math]::Min($buf.Length, $item.Length))
        $stream.Close()
        if ($n -le 0) { return $false }
        $head = ([Text.Encoding]::ASCII).GetString($buf, 0, [math]::Min($n, 512))
        if ($head -match '(?i)<!doctype|<html') { return $false }
        return $true
    } catch {
        return $false
    }
}

function Test-Mirror {
    # 探针:经镜像访问 github.com/favicon.ico,连通且返回真图片才算可用。
    # 返回延迟(毫秒)或 $null(不可用)。超时 6s,不会无限挂。
    param([string]$Mirror)
    if (-not $Mirror) { return $null }
    $url = $Mirror.TrimEnd('/') + '/https://github.com/favicon.ico'
    $req = $null
    try {
        $req = [System.Net.WebRequest]::Create($url)
        $req.Method = 'GET'
        $req.Timeout = 6000
        $req.ReadWriteTimeout = 6000
        $req.AllowAutoRedirect = $true
        try { $req.UserAgent = 'nbot-installer' } catch { }
        $sw = New-Object System.Diagnostics.Stopwatch
        $sw.Start()
        $resp = $req.GetResponse()
        $sw.Stop()
        $ok = $false
        try {
            if ([int]$resp.StatusCode -eq 200) {
                $ct = $null
                try { $ct = $resp.ContentType } catch { }
                if ($null -eq $ct -or $ct -match '(?i)image') { $ok = $true }
            }
        } catch { }
        if ($resp) { try { $resp.Close() } catch { } }
        if ($ok) { return $sw.ElapsedMilliseconds }
        return $null
    } catch {
        if ($req) { try { $req.Abort() } catch { } }
        return $null
    }
}

function Get-OrderedMirrors {
    # 返回「经过连通性筛选、按延迟升序」的镜像列表,用户配置永远在最前。
    # 结果缓存在 $env:TEMP\nbot-mirror-rank.txt(10 分钟内有效),避免每次
    # 下载都重探;探针本身也有 6s 超时,不会无限挂。
    # 若全部探针失败,退回未筛选的完整列表(至少还能试,网络也许只是瞬时抖动)。
    param([int]$MaxKeep = 5)
    $userMirrors = New-Object System.Collections.ArrayList
    $cfg = Get-Cfg 'GITHUB_MIRROR'
    if ($cfg) {
        foreach ($m in $cfg.Split(@(';', '|', ','), [StringSplitOptions]::RemoveEmptyEntries)) {
            $m = $m.Trim()
            if ($m -and -not $userMirrors.Contains($m)) { [void]$userMirrors.Add($m) }
        }
    }

    # 读缓存:格式每行 "<url>\t<latencyMs>",只认 10 分钟内的。
    $cachePath = Get-MirrorCachePath
    $cached = @{}
    $cacheFresh = $false
    if (Test-Path -LiteralPath $cachePath) {
        try {
            $lines = (Read-TextFile $cachePath) -split "`r?`n"
            foreach ($l in $lines) {
                if ($l -match '^#ts=(\d+)') {
                    $age = [long]([DateTime]::Now.ToString('yyyyMMddHHmm')) - [long]$Matches[1]
                    if ($age -ge 0 -and $age -lt 10) { $cacheFresh = $true }
                }
                if ($l -match '^#') { continue }
                $parts = $l -split "`t"
                if ($parts.Count -ge 2) { $cached[$parts[0]] = [int]$parts[1] }
            }
        } catch { $cacheFresh = $false }
    }

    $pool = Get-MirrorPool
    $ordered = New-Object System.Collections.ArrayList

    # 1) 用户配置永远优先(不参与延迟排序,尊重用户选择)
    foreach ($m in $userMirrors) { if (-not $ordered.Contains($m)) { [void]$ordered.Add($m) } }

    # 2) 候选池:缓存新鲜则用缓存延迟;否则从头探针并写回缓存
    $probed = @{}
    if (-not $cacheFresh) {
        foreach ($m in $pool) {
            $lat = Test-Mirror $m
            if ($null -ne $lat) { $probed[$m] = $lat }
        }
        try {
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine('# nbot mirror rank cache (ts=' + ([DateTime]::Now.ToString('yyyyMMddHHmm')) + ')')
            foreach ($kv in $probed.GetEnumerator()) {
                [void]$sb.AppendLine($kv.Key + "`t" + $kv.Value)
            }
            Write-TextFile $cachePath $sb.ToString()
        } catch { }
    } else {
        $probed = $cached
    }

    # 按延迟升序追加候选池中可用的镜像(限量,避免列表过长)
    $sorted = @($probed.Keys | Sort-Object { $probed[$_] }) | Select-Object -First $MaxKeep
    foreach ($m in $sorted) {
        if (-not $ordered.Contains($m)) { [void]$ordered.Add($m) }
    }
    # 兜底:哪怕探针全挂,也把候选池补上,但限量(user 数 + MaxKeep + 2),
    # 避免完全无网时 GitHub-Fetch 把每个镜像都耗满 20s 连接超时才放弃。
    if ($ordered.Count -le $userMirrors.Count) {
        $cap = $userMirrors.Count + $MaxKeep + 2
        foreach ($m in $pool) {
            if ($ordered.Count -ge $cap) { break }
            if (-not $ordered.Contains($m)) { [void]$ordered.Add($m) }
        }
    }
    return $ordered.ToArray()
}

function GitHub-Fetch {
    param($Url, $OutFile, [switch]$ExpectZip, [switch]$ExpectJson)
    $access = Get-Cfg 'GITHUB_ACCESS'
    if (-not $access) { $access = 'auto' }
    $proxy = Get-Cfg 'GITHUB_PROXY'
    # api.github.com 也纳入镜像范围:国内机器常被墙 API 或踩 60 次/小时限额,
    # 而 ghproxy 类镜像大多支持代理 api.github.com(https://mirror/https://api...)。
    $githubPattern = '^https://(github\.com|raw\.githubusercontent\.com|codeload\.github\.com|objects\.githubusercontent\.com|api\.github\.com)/'

    # 1) 镜像通道(经连通性探针筛选、按延迟排序的镜像逐个尝试;镜像不使用代理)
    if ($Url -match $githubPattern) {
        foreach ($mirror in (Get-OrderedMirrors)) {
            $mirrorUrl = $mirror.TrimEnd('/') + '/' + $Url
            Write-Info ('尝试 GitHub 镜像通道：' + $mirrorUrl)
            try {
                Download-File $mirrorUrl $OutFile ''
                if ($ExpectZip -and -not (Test-ValidZip $OutFile)) {
                    throw '下载到的不是有效的 zip 包(可能是镜像返回的错误页)'
                }
                if ($ExpectJson -and -not (Test-LooksLikeJson $OutFile)) {
                    throw '下载到的不是有效的 JSON(可能是镜像返回的错误页)'
                }
                return
            } catch {
                Write-Warn ('镜像通道失败(' + $mirror + ')：' + $_.Exception.Message)
                if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    # 2) 代理通道
    if (($access -eq 'auto' -or $access -eq 'proxy') -and $proxy) {
        Write-Info ('尝试通过代理访问 GitHub：' + $Url + '（代理 ' + $proxy + '）')
        try {
            Download-File $Url $OutFile $proxy
            if ($ExpectZip -and -not (Test-ValidZip $OutFile)) {
                throw '下载到的不是有效的 zip 包(可能是代理返回的错误页)'
            }
            if ($ExpectJson -and -not (Test-LooksLikeJson $OutFile)) {
                throw '下载到的不是有效的 JSON(可能是代理返回的错误页)'
            }
            return
        } catch {
            Write-Warn ('代理通道失败：' + $_.Exception.Message)
            if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        }
    }

    # 3) 直连通道
    if ($access -eq 'auto' -or $access -eq 'direct') {
        Write-Info ('尝试直连 GitHub：' + $Url)
        try {
            Download-File $Url $OutFile ''
            if ($ExpectZip -and -not (Test-ValidZip $OutFile)) {
                throw '下载到的不是有效的 zip 包(可能是站点返回的错误页)'
            }
            if ($ExpectJson -and -not (Test-LooksLikeJson $OutFile)) {
                throw '下载到的不是有效的 JSON(可能是站点返回的错误页)'
            }
            return
        } catch {
            Write-Warn ('直连通道失败：' + $_.Exception.Message)
            if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        }
    }

    throw ('GitHub 下载失败（所有通道均不可用）：' + $Url)
}

function GitHub-ApiGet {
    param($Url)
    # api.github.com 现在也走镜像通道(GitHub-Fetch 的镜像正则已包含它);
    # -ExpectJson 确保镜像返回的错误 HTML 页(200)被识别为失败,触发下一个通道,
    # 而不是直接把 HTML 喂给下游 JSON 解析导致 Die。
    $temp = Join-Path $env:TEMP ('nbot-api-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        GitHub-Fetch $Url $temp -ExpectJson
        return (Read-TextFile $temp)
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Parse-LatestReleaseJson {
    # 从 GitHub Release API 的 JSON 文本里解析 tag 与资产下载地址。
    # 抽成纯函数便于离线单元测试(喂 mock JSON)。
    param([string]$Json, $AssetPatterns)
    $tag = $null
    if ($Json -match '"tag_name"\s*:\s*"([^"]+)"') { $tag = $Matches[1] }
    if (-not $AssetPatterns -or $AssetPatterns.Count -eq 0) {
        $AssetPatterns = @('/NapCat\.Shell\.zip$', '(?i)shell.*\.zip$')
    }
    $assetUrl = $null
    $found = [regex]::Matches($Json, '"browser_download_url"\s*:\s*"([^"]+)"')
    foreach ($pat in $AssetPatterns) {
        foreach ($match in $found) {
            $u = $match.Groups[1].Value
            if ($u -match $pat) { $assetUrl = $u; break }
        }
        if ($assetUrl) { break }
    }
    $r = @{}
    $r['tag'] = $tag
    $r['asset'] = $assetUrl
    return $r
}

function Parse-TagFromRedirectUrl {
    # releases/latest 会 302 跳转到 .../releases/tag/<TAG>,从跳转后的 URL 取 tag。
    param([string]$Url)
    if ($Url -match '/releases/tag/([^/?#]+)') { return $Matches[1] }
    return $null
}

function Parse-AssetUrlsFromHtml {
    # 从 releases 页面 HTML 里抠下载地址(GitHub 页面里用 browser_download_url
    # 这个 data 属性名)。抽成纯函数便于离线测试。
    param([string]$Html, $AssetPatterns)
    if (-not $AssetPatterns -or $AssetPatterns.Count -eq 0) {
        $AssetPatterns = @('/NapCat\.Shell\.zip$', '(?i)shell.*\.zip$')
    }
    $assetUrl = $null
    $found = [regex]::Matches($Html, 'browser_download_url["'']?\s*[:=]\s*["'']([^"'']+)')
    if ($found.Count -eq 0) {
        # 兜底:直接找 /releases/download/<tag>/<file> 形式的链接
        $found = [regex]::Matches($Html, 'href=["''](/[^"'']*?/releases/download/[^"'']+)["'']')
    }
    foreach ($pat in $AssetPatterns) {
        foreach ($match in $found) {
            $u = $match.Groups[1].Value
            if ($u -match $pat) { $assetUrl = $u; break }
        }
        if ($assetUrl) { break }
    }
    if ($assetUrl -and $assetUrl.StartsWith('/')) {
        $assetUrl = 'https://github.com' + $assetUrl
    }
    return $assetUrl
}

function Get-RedirectedUrl {
    # 取 URL 302 跳转后的最终地址(AllowAutoRedirect=false,手动拿 Location)。
    param([string]$Url)
    $req = $null
    try {
        $req = [System.Net.WebRequest]::Create($Url)
        $req.Method = 'HEAD'
        $req.AllowAutoRedirect = $false
        $req.Timeout = 15000
        try { $req.UserAgent = 'nbot-installer' } catch { }
        $resp = $req.GetResponse()
        $loc = $null
        try { $loc = $resp.Headers['Location'] } catch { }
        if ($resp) { try { $resp.Close() } catch { } }
        if ($loc) { return $loc }
    } catch {
        if ($req) { try { $req.Abort() } catch { } }
    }
    return $null
}

function GitHub-LatestReleaseFromHtml {
    # API 被墙/触发 60 次/小时限额时的兜底:走 releases 页面(不受 API 限额
    # 影响,且能通过镜像访问)。先抓 releases/latest 拿 302 跳转里的 tag,
    # 再抓 expanded_assets 页面解析资产下载地址。
    param($Repo, $AssetPatterns)
    $tag = $null
    $asset = $null
    $finalUrl = Get-RedirectedUrl ('https://github.com/' + $Repo + '/releases/latest')
    if ($finalUrl) { $tag = Parse-TagFromRedirectUrl $finalUrl }
    if (-not $tag) { return $null }
    try {
        $expandedUrl = ('https://github.com/' + $Repo + '/releases/expanded_assets/' + $tag)
        $tempExp = Join-Path $env:TEMP ('nbot-exp-' + [Guid]::NewGuid().ToString('N') + '.html')
        GitHub-Fetch $expandedUrl $tempExp
        if (Test-Path -LiteralPath $tempExp) {
            $html = Read-TextFile $tempExp
            $asset = Parse-AssetUrlsFromHtml $html $AssetPatterns
        }
    } catch { }
    $r = @{}
    $r['tag'] = $tag
    $r['asset'] = $asset
    return $r
}

function GitHub-LatestRelease {
    # 一次拉取 release 元数据:优先 API(镜像/代理/直连),全部失败再退回
    # releases 页面 HTML 解析(国内机器常被墙 API 或踩 60 次/小时限额)。
    param($Repo, $AssetPatterns)
    $tag = $null
    $asset = $null
    try {
        $json = GitHub-ApiGet ('https://api.github.com/repos/' + $Repo + '/releases/latest')
        $r = Parse-LatestReleaseJson $json $AssetPatterns
        $tag = $r['tag']
        $asset = $r['asset']
    } catch {
        Write-Warn ('GitHub API 获取 ' + $Repo + ' 失败，改用 releases 页面解析：' + $_.Exception.Message)
    }
    if (-not $tag -or -not $asset) {
        try {
            $r2 = GitHub-LatestReleaseFromHtml $Repo $AssetPatterns
            if ($r2) {
                if (-not $tag) { $tag = $r2['tag'] }
                if (-not $asset) { $asset = $r2['asset'] }
            }
        } catch {
            Write-Warn ('releases 页面解析也失败：' + $_.Exception.Message)
        }
    }
    if (-not $tag) { Die ('无法获取 ' + $Repo + ' 的最新版本(tag)。') }
    if (-not $asset) { Die ('无法获取 ' + $Repo + ' 的适用资产下载地址(资产名不匹配)。') }
    $r = @{}
    $r['tag'] = $tag
    $r['asset'] = $asset
    return $r
}

function GitHub-LatestTag {
    # 兼容旧调用方:只取 tag,同样享受「API + releases 页面」双层兜底。
    param($Repo)
    try {
        $json = GitHub-ApiGet ('https://api.github.com/repos/' + $Repo + '/releases/latest')
        if ($json -match '"tag_name"\s*:\s*"([^"]+)"') { return $Matches[1] }
    } catch { }
    $finalUrl = Get-RedirectedUrl ('https://github.com/' + $Repo + '/releases/latest')
    if ($finalUrl) {
        $tag = Parse-TagFromRedirectUrl $finalUrl
        if ($tag) { return $tag }
    }
    Die ('无法获取 ' + $Repo + ' 的最新版本(tag)。')
}

# -----------------------------------------------------------------------------
# 解压与目录操作
# -----------------------------------------------------------------------------

function Expand-Zip {
    param($ZipFile, $DestDir)
    Ensure-Dir $DestDir
    $zipFull = (Resolve-Path -LiteralPath $ZipFile).Path
    $destFull = (Resolve-Path -LiteralPath $DestDir).Path

    # 1) Expand-Archive（PowerShell 5.0+ 才有，放在 try 中）
    try {
        Expand-Archive -LiteralPath $zipFull -DestinationPath $destFull -Force -ErrorAction Stop
        return
    } catch {
        Write-Warn ('Expand-Archive 不可用或失败，改用 .NET 解压：' + $_.Exception.Message)
    }

    # 2) .NET ZipFile
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipFull, $destFull)
        return
    } catch {
        Write-Warn ('.NET 解压不可用或失败，回退到 Shell.Application：' + $_.Exception.Message)
    }

    # 3) Shell.Application COM（0x14 = 覆盖且不弹进度框）
    $shell = New-Object -ComObject Shell.Application
    $zipNs = $shell.NameSpace($zipFull)
    if ($null -eq $zipNs) { throw ('无法打开压缩包：' + $zipFull) }
    $destNs = $shell.NameSpace($destFull)
    if ($null -eq $destNs) { throw ('无法打开目标目录：' + $destFull) }
    $expected = $zipNs.Items().Count
    $destNs.CopyHere($zipNs.Items(), 0x14)

    # 轮询等待目标目录条目数稳定
    $previous = -1
    $stable = 0
    for ($i = 0; $i -lt 720; $i++) {
        Start-Sleep -Milliseconds 500
        $count = @(Get-ChildItem -LiteralPath $destFull -Force).Count
        if ($count -eq $previous) {
            $stable = $stable + 1
            if ($count -ge $expected -and $stable -ge 4) { return }
        } else {
            $stable = 0
            $previous = $count
        }
    }
    throw ('Shell.Application 解压超时：' + $ZipFile)
}

function Strip-TopLevel {
    param($Dir)
    $items = @(Get-ChildItem -LiteralPath $Dir -Force)
    $dirs = @($items | Where-Object { $_.PSIsContainer })
    $files = @($items | Where-Object { -not $_.PSIsContainer })
    if ($dirs.Count -ne 1 -or $files.Count -ne 0) { return }

    # 先把唯一子目录改成临时名字，避免其内部存在同名条目导致上移冲突
    $tempName = '.strip-' + [Guid]::NewGuid().ToString('N')
    $tempPath = Join-Path $Dir $tempName
    Move-Item -Path $dirs[0].FullName -Destination $tempPath
    $children = @(Get-ChildItem -LiteralPath $tempPath -Force)
    foreach ($child in $children) {
        Move-Item -Path $child.FullName -Destination $Dir
    }
    Remove-Item -LiteralPath $tempPath -Force
}

function Set-Junction {
    param($Link, $Target)
    if (Test-Path -LiteralPath $Link) {
        # rmdir 只移除链接本身，不会删除目标内容
        & cmd.exe /c rmdir "$Link"
        if ($LASTEXITCODE -ne 0) {
            throw ('无法移除已存在的链接（可能是普通目录）：' + $Link)
        }
    }
    & cmd.exe /c mklink /J "$Link" "$Target" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ('创建目录联接失败：' + $Link + ' -> ' + $Target)
    }
}

function Swap-Directory {
    param($Current, $New, $Rollback)
    if (Test-Path -LiteralPath $Rollback) {
        Remove-Item -LiteralPath $Rollback -Recurse -Force
    }
    if (Test-Path -LiteralPath $Current) {
        Move-Item -Path $Current -Destination $Rollback
    }
    Move-Item -Path $New -Destination $Current
}

# -----------------------------------------------------------------------------
# HTTP 探测
# -----------------------------------------------------------------------------

function Test-HttpOk {
    param($Url, $TimeoutMs)
    if (-not $TimeoutMs) { $TimeoutMs = 5000 }
    $response = $null
    try {
        $request = [Net.WebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutMs
        $response = $request.GetResponse()
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $response) { $response.Close() }
    }
}

function Show-NewLogLines {
    # 把 $Path 中 $Offset 之后新增的内容实时转播到控制台(去掉 ANSI 转义,
    # 每行加前缀以区分是被装组件自己的日志)。返回新的读取偏移。
    param($Path, [long]$Offset)
    if (-not $Path) { return $Offset }
    if (-not (Test-Path -LiteralPath $Path)) { return $Offset }
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        if ($stream.Length -lt $Offset) { $Offset = 0 }   # 日志被轮转/清空,从头跟
        if ($stream.Length -eq $Offset) { $stream.Close(); return $Offset }
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object 'System.Byte[]' ($stream.Length - $Offset)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $newOffset = $Offset + $read
        $stream.Close(); $stream = $null
        $text = ([Text.Encoding]::UTF8).GetString($buffer, 0, $read)
        foreach ($line in ($text -split "`r?`n")) {
            $clean = (Remove-AnsiEscapes $line).TrimEnd()
            if ($clean -ne '') { Write-Host ('  │ ' + $clean) }
        }
        return $newOffset
    } catch {
        if ($null -ne $stream) { try { $stream.Close() } catch { } }
        return $Offset
    }
}

function Wait-Http {
    # 健康检查期间实时转播 $TailFile(被装组件自己的日志)的新增行,让人
    # 一眼看到它在动;日志也没动静时才用心跳行兜底。
    param($Url, $Attempts, $TailFile)
    if (-not $Attempts) { $Attempts = 30 }
    Write-Info ('开始健康检查: ' + $Url + '(最长约 ' + ($Attempts * 2) + ' 秒;下面滚动的是服务自己的启动日志)')
    $offset = [long]0
    if ($TailFile -and (Test-Path -LiteralPath $TailFile)) {
        $offset = (Get-Item -LiteralPath $TailFile).Length   # 只看本次启动的新增
    }
    $quiet = 0
    for ($i = 0; $i -lt $Attempts; $i++) {
        if (Test-HttpOk $Url 5000) {
            [void](Show-NewLogLines $TailFile $offset)
            Write-Info ('健康检查通过(第 ' + ($i + 1) + ' 次探测)。')
            return $true
        }
        $newOffset = Show-NewLogLines $TailFile $offset
        if ($newOffset -ne $offset) { $quiet = 0 } else { $quiet = $quiet + 1 }
        $offset = $newOffset
        if ($quiet -ge 5) {
            Write-Host ('  ...服务尚未就绪,继续等待 ' + ($i + 1) + '/' + $Attempts + '(' + (Get-Date -Format 'HH:mm:ss') + ')')
            $quiet = 0
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Test-UrlAvailable {
    # 只发 HEAD 探测下载链接是否还在(腾讯会下架旧版本 → 404)。
    # 有 curl.exe 就用 curl -I(对 CDN 兼容性最好),否则退回 WebRequest。
    param([string]$Url, [int]$TimeoutSec)
    if (-not $Url) { return $false }
    if (-not $TimeoutSec) { $TimeoutSec = 20 }
    if ($script:CurlExe) {
        $code = & $script:CurlExe '-sI' '-o' 'NUL' '-w' '%{http_code}' '--max-time' ([string]$TimeoutSec) $Url
        $codeText = ([string]$code).Trim()
        return ($codeText -eq '200' -or $codeText -eq '302' -or $codeText -eq '301')
    }
    $response = $null
    try {
        $request = [Net.WebRequest]::Create($Url)
        $request.Method = 'HEAD'
        $request.Timeout = $TimeoutSec * 1000
        $response = $request.GetResponse()
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $response) { $response.Close() }
    }
}

function Test-TcpOk {
    # 纯端口连通性检查：NapCat WebUI 根路径可能返回 404/重定向，
    # HTTP 状态码不可靠，健康检查只看端口是否有服务在听。
    param($TcpHost, $Port, $TimeoutMs)
    if (-not $TimeoutMs) { $TimeoutMs = 5000 }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TcpHost, [int]$Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-PortListening {
    # 面板刷新专用:不建连接,直接查系统的 TCP 监听表。比 TcpClient 快一个
    # 数量级,而且端口没开时不会阻塞到超时(那正是面板「不跟手」的元凶)。
    param([int]$Port)
    try {
        $props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        foreach ($ep in $props.GetActiveTcpListeners()) {
            if ($ep.Port -eq $Port) { return $true }
        }
    } catch {
        # 拿不到监听表就退回连接探测(超时给短一点)
        return (Test-TcpOk '127.0.0.1' $Port 300)
    }
    return $false
}

function Wait-Tcp {
    # 同 Wait-Http:实时转播组件日志,静默时才心跳。
    param($TcpHost, $Port, $Attempts, $TailFile)
    if (-not $Attempts) { $Attempts = 30 }
    Write-Info ('开始健康检查: ' + $TcpHost + ':' + $Port + '(最长约 ' + ($Attempts * 2) + ' 秒;下面滚动的是服务自己的启动日志)')
    $offset = [long]0
    if ($TailFile -and (Test-Path -LiteralPath $TailFile)) {
        $offset = (Get-Item -LiteralPath $TailFile).Length
    }
    $quiet = 0
    for ($i = 0; $i -lt $Attempts; $i++) {
        if (Test-TcpOk $TcpHost $Port 5000) {
            [void](Show-NewLogLines $TailFile $offset)
            Write-Info ('健康检查通过(第 ' + ($i + 1) + ' 次探测)。')
            return $true
        }
        $newOffset = Show-NewLogLines $TailFile $offset
        if ($newOffset -ne $offset) { $quiet = 0 } else { $quiet = $quiet + 1 }
        $offset = $newOffset
        if ($quiet -ge 5) {
            Write-Host ('  ...服务尚未就绪,继续等待 ' + ($i + 1) + '/' + $Attempts + '(' + (Get-Date -Format 'HH:mm:ss') + ')')
            $quiet = 0
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

# -----------------------------------------------------------------------------
# 登录凭据读取(AstrBot 初始账号密码 / NapCat WebUI token / SnowLuma WebUI 凭据)
# -----------------------------------------------------------------------------

function Get-AstrbotCred {
    # 用户名取「当前配置」(data\cmd_config.json 的 dashboard.username)——
    # 用户在网页里改过用户名后,日志里的初始值就过期了,不能拿来显示。
    # 初始密码只能从日志取(密码是哈希存储,改过之后无法还原);并用配置里的
    # password_change_required 判断这个初始密码是否还有效。
    # 返回 hashtable: user / pass / found。
    $r = @{}
    $r['user'] = 'astrbot'
    $r['pass'] = $null
    $r['found'] = $false
    $root = Get-Cfg 'ASTRBOT_ROOT'
    if (-not $root) { return $r }

    $changed = $false
    $configPath = Join-Path $root 'data\cmd_config.json'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $stream = New-Object System.IO.FileStream(
                $configPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)), $true)
            $configText = $reader.ReadToEnd()
            $reader.Close()
            $head = [regex]::Match($configText, '"dashboard"\s*:\s*\{')
            if ($head.Success) {
                $tail = $configText.Substring($head.Index)
                $mu = [regex]::Match($tail, '"username"\s*:\s*"([^"]*)"')
                if ($mu.Success -and $mu.Groups[1].Value) { $r['user'] = $mu.Groups[1].Value }
                # password_change_required=false 说明用户已经改过密码,
                # 日志里那个初始密码已失效,不该再展示。
                $mc = [regex]::Match($tail, '"password_change_required"\s*:\s*(true|false)')
                if ($mc.Success -and $mc.Groups[1].Value -eq 'false') { $changed = $true }
            }
        } catch { }
    }

    if ($changed) { return $r }

    $log = Join-Path $root 'logs\astrbot.log'
    $lines = Read-SharedTextLines $log
    if ($lines.Count -eq 0) { return $r }
    $text = ($lines -join "`n")
    $mp = [regex]::Match($text, 'Initial password:\s*(\S+)')
    if ($mp.Success) { $r['pass'] = $mp.Groups[1].Value; $r['found'] = $true }
    return $r
}

function Get-NapcatToken {
    # 从 NAPCAT_ROOT\config\webui.json 读出 WebUI token。
    $root = Get-Cfg 'NAPCAT_ROOT'
    if (-not $root) { return $null }
    $wj = Join-Path $root 'config\webui.json'
    if (-not (Test-Path -LiteralPath $wj)) { return $null }
    try {
        $text = [IO.File]::ReadAllText($wj, (New-Object System.Text.UTF8Encoding($false)))
    } catch { return $null }
    $m = [regex]::Match($text, '"token"\s*:\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-SnowlumaCred {
    # SnowLuma 的 WebUI 用「用户名 + 密码」登录，不是 NapCat 那种明文 token：
    # 密码以 scrypt 哈希存在 config\webui.json，磁盘上无法还原成明文，
    # 初始密码只在启动日志里出现一次（[WebUI] initial credentials: ...）。
    # 因此这里从日志取初始密码，再用 webui.json 的 mustChangePassword 判断
    # 它是否还有效（用户改过密码后该字段为 false，旧的初始密码不该再展示）。
    # 返回 hashtable: user / pass / found / mustChange。
    #
    # $SinceOffset：可选，只在日志这个字节偏移之后的新增内容里找密码行；
    # 重置密码时旧实例可能还没退干净，日志里会留着上一轮的初始密码，不传
    # 偏移量就可能把那一条当成新密码报出去。默认 -1 表示读整份日志，与
    # 这个参数加入之前完全一致——gui.ps1 / wizard.ps1 / modules\snowluma.ps1
    # 都是无参调用，不能改它们，所以默认值必须保证旧行为不变。
    param([long]$SinceOffset = -1)
    $r = @{}
    $r['user'] = 'admin'
    $r['pass'] = $null
    $r['found'] = $false
    $r['mustChange'] = $true
    $root = Get-Cfg 'SL_ROOT'
    if (-not $root) { return $r }

    # SnowLuma 进程的工作目录是载荷 current 目录，它实际读写的 webui.json
    # 在那里，不在 SL_ROOT\config；主副本只在下次启动 harvest 时才会追上。
    # 所以载荷副本优先，SL_ROOT 主副本只作兜底（全新安装、主副本还没生成时）。
    $payload = Get-Cfg 'SL_PAYLOAD_ROOT'
    $wj = $null
    if ($payload) {
        $candidate = Join-Path $payload 'current\config\webui.json'
        if (Test-Path -LiteralPath $candidate) { $wj = $candidate }
    }
    if (-not $wj) {
        $candidate = Join-Path $root 'config\webui.json'
        if (Test-Path -LiteralPath $candidate) { $wj = $candidate }
    }
    if ($wj) {
        try {
            $text = [IO.File]::ReadAllText($wj, (New-Object System.Text.UTF8Encoding($false)))
            $m = [regex]::Match($text, '"mustChangePassword"\s*:\s*(true|false)')
            if ($m.Success -and $m.Groups[1].Value -eq 'false') { $r['mustChange'] = $false }
        } catch { }
    }
    # 已经改过密码：初始密码作废，不再从日志里翻出来显示。
    if (-not $r['mustChange']) { return $r }

    $log = Join-Path $root 'logs\snowluma.log'
    $text = $null
    if ($SinceOffset -ge 0) {
        # 只读偏移量之后新增的字节，旧内容(包括上一轮的初始密码行)一律
        # 看不见——见上面参数说明。
        if (Test-Path -LiteralPath $log) {
            $stream = $null
            try {
                $stream = New-Object System.IO.FileStream(
                    $log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite)
                $offset = $SinceOffset
                if ($stream.Length -lt $offset) { $offset = 0 }   # 日志被轮转/清空,从头读
                if ($stream.Length -gt $offset) {
                    [void]$stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
                    $buffer = New-Object 'System.Byte[]' ($stream.Length - $offset)
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    $text = ([Text.Encoding]::UTF8).GetString($buffer, 0, $read)
                }
            } catch {
                $text = $null
            } finally {
                if ($null -ne $stream) { $stream.Close() }
            }
        }
        if (-not $text) { return $r }
    } else {
        $lines = Read-SharedTextLines $log
        if ($lines.Count -eq 0) { return $r }
        # 每次重启若密码仍未轮换，SnowLuma 会重新生成一个，取最后一次出现的。
        $text = ($lines -join "`n")
    }
    $matchList = [regex]::Matches($text, 'initial credentials:\s*user=(\S+)\s+password=(\S+)')
    if ($matchList.Count -gt 0) {
        $last = $matchList[$matchList.Count - 1]
        $r['user'] = $last.Groups[1].Value
        $r['pass'] = $last.Groups[2].Value
        $r['found'] = $true
    }
    return $r
}

# -----------------------------------------------------------------------------
# 交互
# -----------------------------------------------------------------------------

function Prompt-Default {
    param($Message, $Default)
    # 与 Confirm-Action 同理:无人值守/非交互环境直接采用默认值,不挂死。
    if ($env:NBOT_ASSUME_DEFAULTS -eq '1') {
        Write-Info ($Message + ' -> 无人值守,采用默认值 [' + $Default + ']')
        return $Default
    }
    $answer = $null
    try {
        $answer = Read-Host ($Message + ' [' + $Default + ']')
    } catch {
        Write-Info ($Message + ' -> 非交互环境,采用默认值 [' + $Default + ']')
        return $Default
    }
    if ($null -eq $answer) { return $Default }
    $answer = $answer.Trim()
    if ($answer -eq '') { return $Default }
    return $answer
}

function Confirm-Action {
    param($Message, $DefaultYes)
    # 无人值守(NBOT_ASSUME_DEFAULTS=1,或 -NonInteractive 下 Read-Host 抛异常)
    # 一律走默认值并把选择写进日志——交互提示在没人的控制台上会永远等下去,
    # 整条安装流水线跟着挂死,而且没有任何报错。
    if ($env:NBOT_ASSUME_DEFAULTS -eq '1') {
        if ($DefaultYes) { $pick = 'Y' } else { $pick = 'N' }
        Write-Info ($Message + ' -> 无人值守,自动选择默认值 ' + $pick)
        return [bool]$DefaultYes
    }
    if ($DefaultYes) { $suffix = '[Y/n]' } else { $suffix = '[y/N]' }
    $answer = $null
    try {
        $answer = Read-Host ($Message + ' ' + $suffix)
    } catch {
        if ($DefaultYes) { $pick = 'Y' } else { $pick = 'N' }
        Write-Info ($Message + ' -> 非交互环境,自动选择默认值 ' + $pick)
        return [bool]$DefaultYes
    }
    if ($null -eq $answer) { $answer = '' }
    $answer = $answer.Trim().ToLower()
    if ($answer -eq '') { return [bool]$DefaultYes }
    return ($answer -eq 'y' -or $answer -eq 'yes')
}

# -----------------------------------------------------------------------------
# 杂项
# -----------------------------------------------------------------------------

function New-RandomToken {
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object 'System.Byte[]' 24
    $rng.GetBytes($bytes)
    $hex = ''
    foreach ($b in $bytes) { $hex += $b.ToString('x2') }
    return $hex
}

function Get-FreeGB {
    param($Path)
    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { }
    $root = [System.IO.Path]::GetPathRoot($full)
    $drive = New-Object System.IO.DriveInfo($root)
    return [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
}

function Read-SharedTextLines {
    # 以共享方式按 UTF-8 读取整个文本文件(日志正在被写入时也能读)。
    # AstrBot / NapCat 的日志都是 UTF-8;用 Get-Content 默认编码会按本地
    # 代码页(中文 Windows 是 GBK)解码,中文和符号会变成乱码。
    param($Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $stream = $null
    $reader = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        # detectEncodingFromByteOrderMarks=$true:有 BOM 时按 BOM,没有就按 UTF-8
        $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)), $true)
        $text = $reader.ReadToEnd()
    } catch {
        return @()
    } finally {
        if ($null -ne $reader) { $reader.Close() }
        elseif ($null -ne $stream) { $stream.Close() }
    }
    return @($text -split "`r?`n")
}

function Remove-AnsiEscapes {
    # 去掉终端着色转义序列(AstrBot 日志里带 ESC[32m 之类),便于在窗口里显示。
    param([string]$Text)
    if (-not $Text) { return '' }
    $esc = [char]27
    return ([regex]::Replace($Text, ($esc + '\[[0-9;]*[A-Za-z]'), ''))
}

function Get-TailLines {
    param($Path, $Count)
    if (-not $Count) { $Count = 200 }
    $lines = Read-SharedTextLines $Path
    if ($lines.Count -eq 0) { return @() }
    return @($lines | Select-Object -Last $Count)
}

# -----------------------------------------------------------------------------
# 初始化入口
# -----------------------------------------------------------------------------

function Initialize-NBot {
    Detect-OS
    Detect-Arch
    Enable-Tls
    Find-CurlExe | Out-Null
    Load-Config
}
