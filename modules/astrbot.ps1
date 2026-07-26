# modules\astrbot.ps1 - AstrBot 安装与升级(PowerShell 2.0 兼容)
# 由 install-core.ps1 dot-source;依赖 lib\common.ps1 与 modules\tasks.ps1。

function Invoke-PythonProbe {
    # 运行候选 Python 并返回其标准输出;失败(异常或退出码非 0)返回 $null。
    param([string]$Exe, $ArgList)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = $null
    try {
        $out = & $Exe $ArgList 2>$null
        if ($LASTEXITCODE -ne 0) { $out = $null }
    } catch {
        $out = $null
    }
    $ErrorActionPreference = $old
    if ($out -eq $null) { return $null }
    if ($out -is [array]) { $out = $out -join '' }
    return ([string]$out).Trim()
}

function Test-PyVersionOk {
    param([string]$V)
    if (-not $V) { return $false }
    if ($V -notmatch '^(\d+)\.(\d+)') { return $false }
    $maj = [int]$matches[1]
    $min = [int]$matches[2]
    if ($maj -gt 3) { return $true }
    return (($maj -eq 3) -and ($min -ge 12))
}

function Test-PythonUsable {
    # Microsoft Store 版 Python(WindowsApps)建出的 venv 无法被 SYSTEM
    # 计划任务执行(包 ACL 限制),会报 "Unable to create process";
    # 一律排除,宁可走托管 Python。
    param([string]$Exe)
    if (-not $Exe) { return $false }
    if ($Exe -match '\\WindowsApps\\') {
        Write-Info "跳过 Microsoft Store 版 Python(SYSTEM 服务无法使用): $Exe"
        return $false
    }
    return $true
}

function Find-Python {
    $script:PythonExe = $null
    $probe = "import sys;sys.stdout.write('%d.%d'%sys.version_info[:2])"
    $probeExe = 'import sys;sys.stdout.write(sys.executable)'

    # 1) 托管 Python
    $root = Get-Cfg 'ASTRBOT_ROOT'
    if (-not $root) { $root = 'C:\AstrBot' }
    $managed = Join-Path $root '.python\python.exe'
    if (Test-Path -LiteralPath $managed) {
        $v = Invoke-PythonProbe $managed @('-c', $probe)
        if (Test-PyVersionOk $v) {
            $script:PythonExe = $managed
            return $true
        }
    }

    # PYTHON_FORCE_MANAGED=1 时只认托管 Python,忽略系统里的其他解释器
    if ((Get-Cfg 'PYTHON_FORCE_MANAGED') -eq '1') {
        return $false
    }

    # 2) py.exe 启动器
    $pyCmd = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($pyCmd) {
        foreach ($sw in @('-3.13', '-3.12')) {
            $v = Invoke-PythonProbe 'py.exe' @($sw, '-c', $probe)
            if (Test-PyVersionOk $v) {
                $real = Invoke-PythonProbe 'py.exe' @($sw, '-c', $probeExe)
                if ($real -and (Test-Path -LiteralPath $real) -and (Test-PythonUsable $real)) {
                    $script:PythonExe = $real
                    return $true
                }
            }
        }
    }

    # 3) PATH 中的 python.exe(可能有多个,逐个尝试)
    $pathPy = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($pathPy) {
        foreach ($item in @($pathPy)) {
            $exe = [string]$item.Definition
            if (-not (Test-PythonUsable $exe)) { continue }
            $v = Invoke-PythonProbe $exe @('-c', $probe)
            if (Test-PyVersionOk $v) {
                # 解析真实路径,防止 PATH 上是转发器
                $real = Invoke-PythonProbe $exe @('-c', $probeExe)
                if ($real -and (Test-Path -LiteralPath $real)) {
                    if (-not (Test-PythonUsable $real)) { continue }
                    $script:PythonExe = $real
                } else {
                    $script:PythonExe = $exe
                }
                return $true
            }
        }
    }
    return $false
}

function Install-ManagedPython {
    $root = Get-Cfg 'ASTRBOT_ROOT'
    if (-not $root) { $root = 'C:\AstrBot' }
    Ensure-Dir $root
    $target = Join-Path $root '.python'

    $offline = Join-Path (Get-ScriptRoot) 'offline\python-setup.exe'
    $setup = $null
    $downloaded = $false
    if (Test-Path -LiteralPath $offline) {
        Write-Info "使用离线 Python 安装包: $offline"
        $setup = $offline
    } else {
        $ver = Get-Cfg 'PYTHON_VERSION'
        if (-not $ver) { $ver = '3.13.5' }
        $url = $null
        if ($script:OsProfile -eq 'legacy') {
            $url = Get-Cfg 'PYTHON_WIN7_URL'
            if (-not $url) {
                Die ("当前系统为 Windows 7/8(legacy),官方 Python 安装包最高只支持 3.8,无法满足 AstrBot 需要的 Python >= 3.12。`n" +
                    "请使用 adang1345/PythonWin7 项目提供的修改版安装包,示例 URL:`n" +
                    "  https://github.com/adang1345/PythonWin7/raw/master/3.13.5/python-3.13.5-amd64-full.exe`n" +
                    "将其填入配置项 PYTHON_WIN7_URL,或将安装包保存为 offline\python-setup.exe 后重试。")
            }
        } else {
            $url = Get-Cfg 'PYTHON_URL'
            if (-not $url) {
                $suffix = '-amd64.exe'
                if ($script:SystemArch -eq 'arm64') { $suffix = '-arm64.exe' }
                $url = "https://www.python.org/ftp/python/$ver/python-$ver$suffix"
            }
        }
        $setup = Join-Path $root '.python-setup.exe'
        Write-Info "下载 Python 安装包: $url"
        Download-File $url $setup
        $downloaded = $true
    }

    Write-Info "正在静默安装 Python 到 $target(可能需要几分钟)..."
    $argLine = '/quiet InstallAllUsers=1 TargetDir="' + $target + '" AssociateFiles=0 Shortcuts=0 Include_launcher=0 Include_test=0 Include_doc=0'
    $proc = Start-Process -FilePath $setup -ArgumentList $argLine -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Die "Python 安装程序退出码为 $($proc.ExitCode),安装失败。"
    }
    $py = Join-Path $target 'python.exe'
    if (-not (Test-Path -LiteralPath $py)) {
        Die "Python 安装结束后未找到 $py,请检查安装日志。"
    }
    $v = Invoke-PythonProbe $py @('-c', "import sys;sys.stdout.write('%d.%d'%sys.version_info[:2])")
    if (-not (Test-PyVersionOk $v)) {
        Die '托管 Python 校验失败(需要 Python >= 3.12)。'
    }
    if ($downloaded) { Remove-FileSafe $setup }
    $script:PythonExe = $py
    Write-Info "托管 Python 已就绪: $py"
}

function Stop-AstrBotProcess {
    $root = Get-Cfg 'ASTRBOT_ROOT'
    if (-not $root) { $root = 'C:\AstrBot' }
    $needle = (Join-Path $root 'app\main.py').ToLower()
    try {
        $procs = Get-WmiObject Win32_Process
        foreach ($p in @($procs)) {
            if (-not $p) { continue }
            if ($p.CommandLine -and $p.CommandLine.ToLower().Contains($needle)) {
                try { [void]$p.Terminate() } catch { }
            }
        }
    } catch { }
}

function Install-AstrBot {
    if (-not (Find-Python)) {
        Write-Info '未找到 Python >= 3.12,将安装托管 Python 运行时。'
        Install-ManagedPython
    }

    $repo = Get-Cfg 'ASTRBOT_REPO'
    if (-not $repo) { $repo = 'AstrBotDevs/AstrBot' }
    $tag = Get-Cfg 'ASTRBOT_TAG'
    if (-not $tag) { $tag = GitHub-LatestTag $repo }
    if (-not $tag) { Die '无法获取 AstrBot 最新版本号,请检查网络,或在配置中指定 ASTRBOT_TAG。' }

    $root = Get-Cfg 'ASTRBOT_ROOT'
    if (-not $root) { $root = 'C:\AstrBot' }
    Ensure-Dir $root

    Write-Bold "安装 AstrBot $tag(Python: $($script:PythonExe))"
    $freeGB = Get-FreeGB $root
    if ($freeGB -lt 3) {
        Die "磁盘剩余空间不足: $root 所在分区仅剩 $freeGB GB,至少需要 3 GB。"
    }

    $build = Join-Path $root ('.build-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    Ensure-Dir $build
    $srcDir = Join-Path $build 'src'
    $venvDir = Join-Path $build 'venv'

    $offline = Join-Path (Get-ScriptRoot) 'offline\astrbot-src.zip'
    $zip = $null
    if (Test-Path -LiteralPath $offline) {
        Write-Info "使用离线 AstrBot 源码包: $offline"
        $zip = $offline
    } else {
        $zip = Join-Path $build 'astrbot-src.zip'
        GitHub-Fetch "https://github.com/$repo/archive/refs/tags/$tag.zip" $zip
    }
    Expand-Zip $zip $srcDir
    Strip-TopLevel $srcDir
    if (-not (Test-Path -LiteralPath (Join-Path $srcDir 'requirements.txt'))) {
        Remove-DirSafe $build
        Die '源码包中未找到 requirements.txt,解压结果异常。'
    }

    Write-Info '正在创建 Python 虚拟环境(约 10-30 秒,无输出属正常)...'
    & $script:PythonExe @('-m', 'venv', $venvDir)
    if ($LASTEXITCODE -ne 0) {
        Remove-DirSafe $build
        Die '创建 Python 虚拟环境失败。'
    }
    Write-Info '虚拟环境已创建,开始安装依赖(pip 输出会实时滚动,包较多请耐心)...'
    $venvPy = Join-Path $venvDir 'Scripts\python.exe'
    $pipIndex = Get-Cfg 'PIP_INDEX_URL'
    $pipUp = @('-m', 'pip', 'install', '--upgrade', 'pip', 'setuptools', 'wheel')
    $pipReq = @('-m', 'pip', 'install', '-r', (Join-Path $srcDir 'requirements.txt'))
    if ($pipIndex) {
        $pipUp = $pipUp + @('-i', $pipIndex)
        $pipReq = $pipReq + @('-i', $pipIndex)
    }
    & $venvPy $pipUp
    if ($LASTEXITCODE -ne 0) {
        Remove-DirSafe $build
        Die '升级 pip/setuptools/wheel 失败。'
    }
    & $venvPy $pipReq
    if ($LASTEXITCODE -ne 0) {
        Remove-DirSafe $build
        Die '安装 AstrBot 依赖失败(requirements.txt)。'
    }

    Write-TextFile (Join-Path $srcDir '.nbot-version') $tag

    Install-RuntimeAssets
    Install-Tasks

    # 停止旧实例(忽略错误)+ WMI 兜底
    [void](Invoke-Schtasks @('/End', '/TN', '\NBot\AstrBot'))
    Stop-AstrBotProcess

    $appDir = Join-Path $root 'app'
    $venvCur = Join-Path $root '.venv'
    $appRb = Join-Path $root '.app.rollback'
    $venvRb = Join-Path $root '.venv.rollback'
    Swap-Directory $appDir $srcDir $appRb
    Swap-Directory $venvCur $venvDir $venvRb

    Write-TextFile (Join-Path (Get-StateDir) 'astrbot.enabled') ''
    [void](Invoke-Schtasks @('/Run', '/TN', '\NBot\AstrBot'))

    $port = Get-Cfg 'ASTRBOT_PORT'
    if (-not $port) { $port = 6185 }
    if (-not (Wait-Http "http://127.0.0.1:$port/" 45 (Join-Path $root 'logs\astrbot.log'))) {
        Write-Warn '新版本未能通过健康检查,正在回滚到旧版本。'
        [void](Invoke-Schtasks @('/End', '/TN', '\NBot\AstrBot'))
        Stop-AstrBotProcess
        Remove-DirSafe $appDir
        Remove-DirSafe $venvCur
        if (Test-Path -LiteralPath $appRb) { Move-Item -LiteralPath $appRb -Destination $appDir -Force }
        if (Test-Path -LiteralPath $venvRb) { Move-Item -LiteralPath $venvRb -Destination $venvCur -Force }
        [void](Invoke-Schtasks @('/Run', '/TN', '\NBot\AstrBot'))
        $log = Join-Path $root 'logs\astrbot.log'
        if (Test-Path -LiteralPath $log) {
            Write-Warn "以下为 $log 最后 60 行:"
            Get-TailLines $log 60 | ForEach-Object { Write-Host $_ }
        }
        Remove-DirSafe $build
        Die 'AstrBot 新版本启动失败,已尝试恢复旧版本。'
    }

    Remove-DirSafe $appRb
    Remove-DirSafe $venvRb
    Remove-DirSafe $build
    Write-Info "AstrBot $tag 已启动,WebUI: http://127.0.0.1:$port/(局域网访问请使用本机 IP)"
}
