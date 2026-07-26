# modules\onebot.ps1 - OneBot 连接配置(PowerShell 2.0 兼容)
# 由 install-core.ps1 dot-source;依赖 lib\common.ps1 与 modules\tasks.ps1。
# 按 BOT_BACKEND 整块分支(Test-SnowLuma,解析统一在 lib\common.ps1):
#   napcat   写 NapCat 的 onebot11_<QQ号>.json(per-uin,必须先有 QQ 号);
#   snowluma 写 SnowLuma 的全局 config\onebot.json(QQ 号可选,对所有账号生效)。
# 两个后端的 JSON 字段名完全不同,模板各自独立维护,禁止互相照抄。
# 主配置写在各自 ROOT\config(唯一真源),并同步到当前载荷 config 目录。

function Reset-AstrbotPassword {
    # 用 AstrBot 自带的哈希函数改 dashboard 密码(astrbot-setpass.py 调
    # AstrBot 自己的 _set_dashboard_password,版本匹配、不猜哈希)。
    # 密码通过 $PassFile(第一行用户名可空、第二行密码)传入,避免出现在
    # 命令行/进程列表里;用完即删。
    param([string]$PassFile)
    $root = Get-Cfg 'ASTRBOT_ROOT'
    if (-not $root) { Die '未配置 AstrBot 目录。' }
    $py = Join-Path $root '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $py)) { Die '未找到 AstrBot 的 Python,请先安装 AstrBot。' }
    if (-not $PassFile -or -not (Test-Path -LiteralPath $PassFile)) { Die '缺少新密码输入。' }

    $lines = Read-SharedTextLines $PassFile
    $newUser = ''
    $newPass = ''
    if ($lines.Count -ge 1) { $newUser = ([string]$lines[0]).Trim() }
    if ($lines.Count -ge 2) { $newPass = [string]$lines[1] }
    Remove-FileSafe $PassFile
    if (-not $newPass) { Die '新密码为空。' }

    $script = Join-Path (Get-BinDir) 'astrbot-setpass.py'
    if (-not (Test-Path -LiteralPath $script)) {
        Install-RuntimeAssets
        $script = Join-Path (Get-BinDir) 'astrbot-setpass.py'
    }

    Write-Info '正在停止 AstrBot 并写入新密码...'
    [void](Invoke-Schtasks @('/End', '/TN', '\BotStack\AstrBot'))
    [void](Invoke-Schtasks @('/End', '/TN', '\NBot\AstrBot'))
    Stop-AstrBotProcess

    $env:ASTRBOT_ROOT = $root
    $env:PYTHONPATH = (Join-Path $root 'app')
    if ($newUser) { $env:NBOT_NEW_USER = $newUser } else { $env:NBOT_NEW_USER = '' }
    $env:NBOT_NEW_PASS = $newPass
    $out = & $py $script 2>&1
    $code = $LASTEXITCODE
    $env:NBOT_NEW_PASS = ''
    $env:NBOT_NEW_USER = ''
    $env:PYTHONPATH = ''
    Write-Host ($out | Out-String)
    if ($code -ne 0) { Die 'AstrBot 改密失败(见上方输出)。' }

    Write-TextFile (Join-Path (Get-StateDir) 'astrbot.enabled') ''
    [void](Invoke-Schtasks @('/Run', '/TN', '\NBot\AstrBot'))
    $port = Get-Cfg 'ASTRBOT_PORT'
    if (-not $port) { $port = 6185 }
    [void](Wait-Http "http://127.0.0.1:$port/" 30 (Join-Path $root 'logs\astrbot.log'))
    $u = 'astrbot'
    if ($newUser) { $u = $newUser }
    Write-Info ('AstrBot 密码已重置。账号: ' + $u + ',用你刚设置的新密码登录 http://127.0.0.1:' + $port + '/')
}

function Reset-NapcatToken {
    # 重置 NapCat WebUI token。留空则随机生成 16 位。
    param([string]$NewToken)
    $napRoot = Get-Cfg 'NAPCAT_ROOT'
    if (-not $napRoot) { Die '未配置 NapCat 目录。' }
    $payload = Get-Cfg 'NAPCAT_PAYLOAD_ROOT'
    $masterCfg = Join-Path $napRoot 'config'
    Ensure-Dir $masterCfg
    $webui = Join-Path $masterCfg 'webui.json'
    $port = Get-Cfg 'NAPCAT_WEBUI_PORT'
    if (-not $port) { $port = 6099 }

    $tok = $NewToken
    if (-not $tok) { $tok = (New-RandomToken).Substring(0, 16) }

    if (Test-Path -LiteralPath $webui) {
        $text = Read-TextFile $webui
        if ($text -match '"token"\s*:\s*"[^"]*"') {
            $text = [regex]::Replace($text, '"token"\s*:\s*"[^"]*"', '"token": "' + $tok + '"')
        } else {
            $text = $text -replace '\}\s*$', (',' + "`r`n" + '  "token": "' + $tok + '"' + "`r`n" + '}')
        }
    } else {
        $text = '{' + "`r`n" +
            '  "host": "0.0.0.0",' + "`r`n" +
            '  "port": ' + $port + ',' + "`r`n" +
            '  "token": "' + $tok + '",' + "`r`n" +
            '  "loginRate": 3' + "`r`n" + '}' + "`r`n"
    }
    $tmp = "$webui.tmp"
    Write-TextFile $tmp $text
    Move-Item -LiteralPath $tmp -Destination $webui -Force
    # 同步进当前载荷
    $curCfg = Join-Path $payload 'current\config'
    if (Test-Path -LiteralPath $curCfg) {
        Copy-Item -LiteralPath $webui -Destination (Join-Path $curCfg 'webui.json') -Force
    }
    Restart-BotTask 'NapCat'
    Write-Info ('NapCat WebUI Token 已重置为: ' + $tok)
}

function Reset-SnowlumaPassword {
    # 重置 SnowLuma WebUI 登录密码。
    #
    # SnowLuma 不像 NapCat 那样用明文 token —— 密码以 scrypt 哈希存在
    # config\webui.json 里,安装器既算不出也不该去伪造这个哈希。它自己的
    # 规则是:webui.json 不存在时,启动会生成一份新的随机初始密码并打印
    # 到日志。所以「重置」= 删掉 webui.json 再重启,然后从日志里取新密码。
    # (用户在 WebUI 里改过的强密码同样会被这一步清掉,属于预期行为。)
    $slRoot = Get-Cfg 'SL_ROOT'
    if (-not $slRoot) { Die '未配置 SnowLuma 目录。' }
    $payload = Get-Cfg 'SL_PAYLOAD_ROOT'
    $masterCfg = Join-Path $slRoot 'config'
    Ensure-Dir $masterCfg

    Write-Info '正在停止 SnowLuma 并清除现有 WebUI 登录凭据...'
    [void](Invoke-Schtasks @('/End', '/TN', '\NBot\SnowLuma'))
    # schtasks /End 只杀得到任务直接起的 wscript,node 是 wscript -> cmd -> node
    # 链条末端的孙进程,run-hidden.vbs 用 shell.Run(...,0,False) 不等待,wscript
    # 瞬间退出、任务"已完成",node 完全不受影响——不额外杀掉的话,旧实例还占着
    # WebUI 端口、内存里的旧凭据继续有效,后面整套重置流程就是在跟幽灵较劲。
    Stop-SnowlumaProcess
    Start-Sleep -Seconds 2

    # 主副本与载荷副本都要删,否则启动时 xcopy 又把旧的同步回去。
    Remove-FileSafe (Join-Path $masterCfg 'webui.json')
    if ($payload) {
        Remove-FileSafe (Join-Path $payload 'current\config\webui.json')
    }

    # 记下当前日志长度,只在新增的部分里找新密码,避免读到上一次的。
    $log = Join-Path $slRoot 'logs\snowluma.log'
    $before = [long]0
    if (Test-Path -LiteralPath $log) { $before = (Get-Item -LiteralPath $log).Length }

    [void](Invoke-Schtasks @('/Run', '/TN', '\NBot\SnowLuma'))
    $port = Get-Cfg 'SNOWLUMA_WEBUI_PORT'
    if (-not $port) { $port = 5099 }
    if (-not (Wait-Tcp '127.0.0.1' $port 30 $log)) {
        Die 'SnowLuma 重启后未监听 WebUI 端口,密码重置可能未完成,请查看日志。'
    }

    # WebUI 端口起来后凭据行已经打印过了,但文件写入可能稍滞后,给几秒。
    # 传 $before 让 Get-SnowlumaCred 只在这次重启新增的日志内容里找密码——
    # 不传的话,端口探测万一连上的是没被真正杀掉的旧实例,读到的会是上一轮
    # 启动打印的旧密码,而且不会有任何报错提示这是错的。
    $cred = $null
    for ($i = 0; $i -lt 10; $i++) {
        $cred = Get-SnowlumaCred $before
        if ($cred['found']) { break }
        Start-Sleep -Seconds 1
    }
    if ($cred -and $cred['found']) {
        Write-Info ('SnowLuma WebUI 登录凭据已重置。用户名: ' + $cred['user'] + ',密码: ' + $cred['pass'])
        Write-Info '请立即登录并设置自己的密码 —— 未改密时每次重启都会重新生成新的随机密码。'
    } else {
        Write-Warn "已重启 SnowLuma,但未能从日志中读到新的初始密码,请手动查看: $log"
    }
}

function Configure-OneBot {
    # 统一入口,按后端整块分支(判定只走 Test-SnowLuma,不自己读 BOT_BACKEND):
    #   napcat   $Uin 必填(交互模式会询问);
    #   snowluma $Uin 可选,只作记录。
    param([string]$Uin)
    if (Test-SnowLuma) {
        Configure-OneBotSnowluma $Uin
    } else {
        Configure-OneBotNapcat $Uin
    }
}

function Configure-OneBotNapcat {
    # $Uin 非空时免交互(供 GUI 面板与命令行 configure-onebot <QQ号> 使用):
    # 直接采用传入的 QQ 号,token 自动生成。
    param([string]$Uin)
    $payload = Get-Cfg 'NAPCAT_PAYLOAD_ROOT'
    if (-not $payload) { $payload = 'C:\AstrBot\.nbot\napcat' }
    $napRoot = Get-Cfg 'NAPCAT_ROOT'
    if (-not $napRoot) { $napRoot = 'C:\NapCat' }

    # 1. 前置校验:NapCat 必须已安装
    $current = Join-Path $payload 'current'
    $marker = Join-Path (Get-StateDir) 'napcat.enabled'
    $hasCurrent = Test-Path -LiteralPath $current
    $hasMarker = Test-Path -LiteralPath $marker
    if ((-not $hasCurrent) -and (-not $hasMarker)) {
        Die '请先安装 NapCat(菜单第 4 项)。'
    }

    # 2. QQ 号(传参优先,否则交互询问)
    $uin = $Uin
    if (-not $uin) { $uin = Prompt-Default 'QQ 号 (UIN)' (Get-Cfg 'QQ_UIN') }
    if ($uin) { $uin = ([string]$uin).Trim() }
    if (-not $uin) { Die '未提供 QQ 号,无法配置 OneBot。' }
    if ($uin -notmatch '^\d+$') { Die "QQ 号必须是纯数字: $uin" }

    # 3. Token(免交互模式直接自动生成)
    $token = ''
    if (-not $Uin) {
        $token = Prompt-Default 'OneBot Token(留空自动生成)' ''
        if ($token) { $token = ([string]$token).Trim() }
    }
    if (-not $token) { $token = New-RandomToken }

    # 4. 保存配置
    Set-Cfg 'QQ_UIN' $uin
    Write-Config

    $httpPort = Get-Cfg 'ONEBOT_HTTP_PORT'
    if (-not $httpPort) { $httpPort = 3005 }
    $wsPort = Get-Cfg 'ASTRBOT_WS_PORT'
    if (-not $wsPort) { $wsPort = 6199 }

    # 5. 生成 NapCat OneBot 11 配置(字段名与 NapCat v4 对齐)
    $json = @"
{
  "network": {
    "httpServers": [
      {
        "name": "local-http",
        "enable": true,
        "port": $httpPort,
        "host": "127.0.0.1",
        "enableCors": true,
        "enableWebsocket": true,
        "messagePostFormat": "array",
        "token": "$token",
        "debug": false
      }
    ],
    "httpClients": [],
    "websocketServers": [],
    "websocketClients": [
      {
        "name": "AstrBot",
        "enable": true,
        "url": "ws://127.0.0.1:$wsPort/ws",
        "messagePostFormat": "array",
        "reportSelfMessage": true,
        "reconnectInterval": 30000,
        "token": "$token",
        "debug": false,
        "heartInterval": 30000
      }
    ]
  },
  "musicSignUrl": "",
  "enableLocalFile2Url": false,
  "parseMultMsg": false
}
"@

    # 6. 写主配置(先写 .tmp 再覆盖),并同步到当前载荷
    $masterCfg = Join-Path $napRoot 'config'
    Ensure-Dir $masterCfg
    $target = Join-Path $masterCfg "onebot11_$uin.json"
    $tmp = "$target.tmp"
    Write-TextFile $tmp $json
    Move-Item -LiteralPath $tmp -Destination $target -Force
    if (Test-Path -LiteralPath (Join-Path $current 'config')) {
        Copy-Item -LiteralPath $target -Destination (Join-Path $current "config\onebot11_$uin.json") -Force
    }

    # 7. 配置 AstrBot 那一半:平台适配器 aiocqhttp + 同一个 token。
    #    只配 NapCat 是连不上的——两边 token 必须一致,否则反向 WS 握手被拒。
    Set-AstrbotPlatform $token $wsPort

    # 8. 重启两边使配置生效(AstrBot 要重载 platform,NapCat 要重连)
    Restart-BotTask 'AstrBot'
    Restart-BotTask 'NapCat'

    Write-Info "OneBot 已配置: HTTP 服务 127.0.0.1:$httpPort;反向 WS -> ws://127.0.0.1:$wsPort/ws"
    Write-Info "Token: $token(两边已自动同步,无需手动填写)"
    Write-Info "NapCat 侧: $target"
    Write-Info "AstrBot 侧: 平台适配器 aiocqhttp 已自动创建/更新并启用。"
    Write-Info '约十几秒后可在 AstrBot 管理页「配置平台机器人」看到该适配器,状态为已连接。'
}

function Configure-OneBotSnowluma {
    # 与 NapCat 版最大的差别:不需要 QQ 号。
    #
    # NapCat 的 OneBot 配置是 per-uin 的(onebot11_<QQ号>.json),所以必须先
    # 登录拿到号码才能配置。SnowLuma 读的是 config\onebot.json —— 一份全局
    # 配置,对任何登录的账号都生效(per-uin 的 onebot_<uin>.json 只是叠加在
    # 它上面的覆盖层)。于是对接可以在扫码登录之前就完成。
    #
    # $Uin 参数保留只为兼容旧的调用方(命令行 configure-onebot <QQ号>),
    # 传了也只是记进配置备查,不影响生成的文件。
    param([string]$Uin)
    $payload = Get-Cfg 'SL_PAYLOAD_ROOT'
    if (-not $payload) { $payload = 'C:\AstrBot\.nbot\snowluma' }
    $slRoot = Get-Cfg 'SL_ROOT'
    if (-not $slRoot) { $slRoot = 'C:\SnowLuma' }

    # 1. 前置校验:SnowLuma 必须已安装
    $current = Join-Path $payload 'current'
    $marker = Join-Path (Get-StateDir) 'snowluma.enabled'
    $hasCurrent = Test-Path -LiteralPath $current
    $hasMarker = Test-Path -LiteralPath $marker
    if ((-not $hasCurrent) -and (-not $hasMarker)) {
        Die '请先安装 SnowLuma(菜单第 4 项)。'
    }

    # 2. QQ 号:可选,只作记录(全局配置对所有账号生效)
    $uin = $Uin
    if ($uin) {
        $uin = ([string]$uin).Trim()
        if ($uin -notmatch '^\d+$') { Die "QQ 号必须是纯数字: $uin" }
        Set-Cfg 'QQ_UIN' $uin
    }

    # 3. Token 自动生成(两边共用,不需要用户手抄)
    $token = New-RandomToken
    Write-Config

    $httpPort = Get-Cfg 'ONEBOT_HTTP_PORT'
    if (-not $httpPort) { $httpPort = 3005 }
    $wsPort = Get-Cfg 'ASTRBOT_WS_PORT'
    if (-not $wsPort) { $wsPort = 6199 }

    # 4. 生成 SnowLuma 的 OneBot 配置。
    #    字段名与 NapCat 不同,别照抄:
    #      networks(复数)      NapCat 是 network
    #      wsClients            NapCat 是 websocketClients
    #      accessToken          NapCat 是 token
    #      reconnectIntervalMs  NapCat 是 reconnectInterval
    #      enableWebSocket      NapCat 是 enableWebsocket(小写 s)
    #    另外 SnowLuma 会拒绝未知字段(rejectUnknownKeys),多写反而报错。
    $json = @"
{
  "networks": {
    "httpServers": [
      {
        "name": "local-http",
        "enabled": true,
        "host": "127.0.0.1",
        "port": $httpPort,
        "path": "/",
        "enableWebSocket": true,
        "accessToken": "$token",
        "messageFormat": "array",
        "reportSelfMessage": false
      }
    ],
    "httpClients": [],
    "wsServers": [],
    "wsClients": [
      {
        "name": "AstrBot",
        "enabled": true,
        "url": "ws://127.0.0.1:$wsPort/ws",
        "role": "Universal",
        "reconnectIntervalMs": 5000,
        "accessToken": "$token",
        "messageFormat": "array",
        "reportSelfMessage": false
      }
    ]
  }
}
"@

    # 5. 写主配置(先写 .tmp 再覆盖),并同步到当前载荷
    $masterCfg = Join-Path $slRoot 'config'
    Ensure-Dir $masterCfg
    $target = Join-Path $masterCfg 'onebot.json'
    $tmp = "$target.tmp"
    Write-TextFile $tmp $json
    Move-Item -LiteralPath $tmp -Destination $target -Force
    if (Test-Path -LiteralPath (Join-Path $current 'config')) {
        Copy-Item -LiteralPath $target -Destination (Join-Path $current 'config\onebot.json') -Force
    }

    # 5.1 清掉可能存在的 per-uin 覆盖层。SnowLuma 首次为某个账号加载配置时会
    #     写一份 onebot_<uin>.json 快照(mode=snapshot),那份快照会完全盖过
    #     全局 onebot.json —— 不删的话这次改的 token 对已登录过的账号不生效。
    $stale = 0
    foreach ($dir in @($masterCfg, (Join-Path $current 'config'))) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -Path $dir -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.PSIsContainer) { return }
            if ($_.Name -match '^onebot_\d+\.json$') {
                Remove-FileSafe $_.FullName
                $stale = $stale + 1
            }
        }
    }
    if ($stale -gt 0) {
        Write-Info ('已清除 ' + $stale + ' 份旧的 per-uin OneBot 覆盖配置,使全局配置生效。')
    }

    # 6. 配置 AstrBot 那一半:平台适配器 aiocqhttp + 同一个 token。
    #    只配 SnowLuma 是连不上的——两边 token 必须一致,否则反向 WS 握手被拒。
    Set-AstrbotPlatform $token $wsPort

    # 7. 重启两边使配置生效(AstrBot 要重载 platform,SnowLuma 要重连)
    Restart-BotTask 'AstrBot'
    Restart-BotTask 'SnowLuma'

    Write-Info "OneBot 已配置: HTTP 服务 127.0.0.1:$httpPort;反向 WS -> ws://127.0.0.1:$wsPort/ws"
    Write-Info "Token: $token(两边已自动同步,无需手动填写)"
    Write-Info "SnowLuma 侧: $target(全局配置,对任何登录的 QQ 账号都生效)"
    Write-Info 'AstrBot 侧: 平台适配器 aiocqhttp 已自动创建/更新并启用。'
    Write-Info '扫码登录 QQ 后,约十几秒即可在 AstrBot 管理页「配置平台机器人」看到该适配器为已连接。'
}

function Set-AstrbotPlatform {
    # 写 AstrBot 的 aiocqhttp 平台适配器(反向 WS 端口 + 共享 token)。
    # 调 astrbot-setplatform.py,借 AstrBot 自己的配置文件结构,幂等更新。
    param([string]$Token, [string]$WsPort)
    $root = Get-Cfg 'ASTRBOT_ROOT'
    if (-not $root) { Write-Warn '未配置 AstrBot 目录,跳过 AstrBot 侧配置。'; return }
    $py = Join-Path $root '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $py)) {
        Write-Warn '未找到 AstrBot 的 Python,跳过 AstrBot 侧配置(请先安装 AstrBot)。'
        return
    }
    $script = Join-Path (Get-BinDir) 'astrbot-setplatform.py'
    if (-not (Test-Path -LiteralPath $script)) {
        Install-RuntimeAssets
        $script = Join-Path (Get-BinDir) 'astrbot-setplatform.py'
    }
    if (-not (Test-Path -LiteralPath $script)) {
        Write-Warn '缺少 astrbot-setplatform.py,跳过 AstrBot 侧配置。'
        return
    }
    $cfgFile = Join-Path $root 'data\cmd_config.json'
    if (-not (Test-Path -LiteralPath $cfgFile)) {
        Write-Warn 'AstrBot 尚未生成配置文件(需先成功启动一次),跳过 AstrBot 侧配置。'
        return
    }

    Write-Info '正在配置 AstrBot 的 OneBot 平台适配器...'
    $env:ASTRBOT_ROOT = $root
    $env:PYTHONPATH = (Join-Path $root 'app')
    $env:NBOT_WS_PORT = [string]$WsPort
    $env:NBOT_WS_TOKEN = $Token
    $out = & $py $script 2>&1
    $code = $LASTEXITCODE
    $env:NBOT_WS_TOKEN = ''
    $env:NBOT_WS_PORT = ''
    $env:PYTHONPATH = ''
    Write-Host ($out | Out-String)
    if ($code -ne 0) { Write-Warn 'AstrBot 平台适配器配置失败(见上方输出),请手动在管理页添加 aiocqhttp。' }
}
