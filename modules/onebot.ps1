# modules\onebot.ps1 - OneBot 连接配置(PowerShell 2.0 兼容)
# 由 install-core.ps1 dot-source;依赖 lib\common.ps1 与 modules\tasks.ps1。
# 写出 NapCat 的 onebot11_<QQ号>.json:HTTP 服务 + 反向 WS 连接 AstrBot。
# 主配置写在 NAPCAT_ROOT\config(唯一真源),并同步到当前载荷 config 目录。

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

function Configure-OneBot {
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
