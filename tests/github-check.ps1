# github-check.ps1
# 离线校验 lib\common.ps1 里「GitHub 国内下载」相关的新逻辑。
# 不依赖真实网络/显示器:纯解析函数用 mock 文本,下载路径用 file:// 协议
# (WebRequest 原生支持),连通性探针用必定拒绝的死地址验证「不挂死、返回 null」。
#
# 覆盖:
#   1. Parse-LatestReleaseJson(tag + 资产解析,含资产名不匹配)
#   2. Parse-TagFromRedirectUrl(从 302 跳转 URL 取 tag)
#   3. Parse-AssetUrlsFromHtml(从 releases 页面抠下载地址)
#   4. Test-LooksLikeJson(zip 字节 vs HTML 错误页)
#   5. Test-ValidZip(真 zip vs 假 zip)
#   6. Download-File(file:// 直连,验证落盘与 zip 校验)
#   7. GitHub-Fetch(-ExpectZip / -ExpectJson 通道校验,含「HTML 当 JSON 必失败」)
#   8. Test-Mirror(死地址返回 null,不挂死)
#   9. Get-OrderedMirrors(离线回退返回非空列表,不挂死)
#
# 退出码:0 全部通过,1 有失败。

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$commonPath = Join-Path $root 'lib\common.ps1'

$script:failCount = 0

function Pass { param([string]$Name) ; Write-Host ('[OK] ' + $Name) }
function Fail { param([string]$Name, [string]$Detail) ; $script:failCount++ ; Write-Host ('[FAIL] ' + $Name + ' - ' + $Detail) }

# 用独立配置文件,绝不碰真实 %ProgramData%
$env:NBOT_CONFIG = Join-Path $env:TEMP ('nbot-gh-' + [Guid]::NewGuid().ToString('N') + '.conf')
try {
    . $commonPath
    Initialize-NBot
    # 离线测试:本机 curl 可能不支持 file:// 协议,强制走托管 WebRequest 通道
    # (原生支持 file://),用来验证「下载 + 落盘 + zip/json 校验」逻辑本身。
    $script:CurlExe = $null
    Pass 'dot-source lib\common.ps1'
} catch {
    Fail 'dot-source lib\common.ps1' $_.Exception.Message
    Write-Host ('[FAIL] github-check: ' + $script:failCount + ' failure(s)')
    exit 1
}

$tmp = Join-Path $env:TEMP ('nbot-gh-work-' + [Guid]::NewGuid().ToString('N'))
Ensure-Dir $tmp

# ---------------------------------------------------------------------------
# 1. Parse-LatestReleaseJson
# ---------------------------------------------------------------------------
try {
    $json = '{"tag_name":"v1.2.3","assets":[{"browser_download_url":"https://github.com/x/y/releases/download/v1.2.3/NapCat.Shell.zip"}]}'
    $r = Parse-LatestReleaseJson $json @('/NapCat\.Shell\.zip$')
    if ($r['tag'] -ceq 'v1.2.3' -and $r['asset'] -match 'NapCat\.Shell\.zip$') {
        Pass 'case 1: Parse-LatestReleaseJson 解析 tag 与资产'
    } else {
        Fail 'case 1: Parse-LatestReleaseJson' ('tag=' + $r['tag'] + ' asset=' + $r['asset'])
    }
} catch {
    Fail 'case 1: Parse-LatestReleaseJson' $_.Exception.Message
}

# 资产名不匹配时资产应为空(不瞎填首个下载地址)
try {
    $json = '{"tag_name":"v9","assets":[{"browser_download_url":"https://github.com/x/y/releases/download/v9/other.zip"}]}'
    $r = Parse-LatestReleaseJson $json @('/NapCat\.Shell\.zip$')
    if ($r['tag'] -ceq 'v9' -and -not $r['asset']) {
        Pass 'case 1b: 资产名不匹配时资产留空'
    } else {
        Fail 'case 1b: 资产名不匹配' ('tag=' + $r['tag'] + ' asset=' + $r['asset'])
    }
} catch {
    Fail 'case 1b: 资产名不匹配' $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 2. Parse-TagFromRedirectUrl
# ---------------------------------------------------------------------------
try {
    $tag = Parse-TagFromRedirectUrl 'https://github.com/x/y/releases/tag/v4.5.6'
    if ($tag -ceq 'v4.5.6') { Pass 'case 2: Parse-TagFromRedirectUrl 取 tag' }
    else { Fail 'case 2: Parse-TagFromRedirectUrl' ('got ' + $tag) }
} catch {
    Fail 'case 2: Parse-TagFromRedirectUrl' $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 3. Parse-AssetUrlsFromHtml
# ---------------------------------------------------------------------------
try {
    # 真实 releases 页面把资产地址嵌在 JSON 里,形如 browser_download_url":"https://..."
    $html = 'var assets=[{"browser_download_url":"https://github.com/x/y/releases/download/v2/NapCat.Shell.zip"}]'
    $asset = Parse-AssetUrlsFromHtml $html @('/NapCat\.Shell\.zip$')
    if ($asset -match 'NapCat\.Shell\.zip$') { Pass 'case 3: Parse-AssetUrlsFromHtml 抠地址并补全域名' }
    else { Fail 'case 3: Parse-AssetUrlsFromHtml' ('got ' + $asset) }
} catch {
    Fail 'case 3: Parse-AssetUrlsFromHtml' $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 准备样本文件:真 zip / 假 zip(HTML) / 假 JSON(HTML)
# ---------------------------------------------------------------------------
$zipFile = Join-Path $tmp 'sample.zip'
$src = Join-Path $tmp 'hello.txt'
Set-Content -LiteralPath $src -Value 'hello zip' -Encoding Ascii
Compress-Archive -Path $src -DestinationPath $zipFile -Force

$htmlFile = Join-Path $tmp 'fake.html'
Set-Content -LiteralPath $htmlFile -Value '<!DOCTYPE html><html><body>error</body></html>' -Encoding Ascii

$jsonFile = Join-Path $tmp 'ok.json'
Set-Content -LiteralPath $jsonFile -Value '{"tag_name":"v0"}' -Encoding Ascii

# ---------------------------------------------------------------------------
# 4. Test-LooksLikeJson
# ---------------------------------------------------------------------------
try {
    if ((Test-LooksLikeJson $jsonFile) -and -not (Test-LooksLikeJson $htmlFile)) {
        Pass 'case 4: Test-LooksLikeJson 识别 JSON 与 HTML 错误页'
    } else {
        Fail 'case 4: Test-LooksLikeJson' 'json 应 true、html 应 false'
    }
} catch {
    Fail 'case 4: Test-LooksLikeJson' $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 5. Test-ValidZip
# ---------------------------------------------------------------------------
try {
    if ((Test-ValidZip $zipFile) -and -not (Test-ValidZip $htmlFile)) {
        Pass 'case 5: Test-ValidZip 识别真 zip 与假 zip'
    } else {
        Fail 'case 5: Test-ValidZip' 'zip 应 true、html 应 false'
    }
} catch {
    Fail 'case 5: Test-ValidZip' $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 6. Download-File(file:// 直连,离线)
# ---------------------------------------------------------------------------
try {
    $out = Join-Path $tmp 'dl.zip'
    Download-File ('file:///' + $zipFile.Replace('\', '/')) $out ''
    if ((Test-Path -LiteralPath $out) -and (Test-ValidZip $out)) {
        Pass 'case 6: Download-File file:// 直连落盘并过 zip 校验'
    } else {
        Fail 'case 6: Download-File' '文件未落盘或不是有效 zip'
    }
} catch {
    Fail 'case 6: Download-File' $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 7. GitHub-Fetch(-ExpectZip / -ExpectJson)
# ---------------------------------------------------------------------------
try {
    Set-Cfg 'GITHUB_ACCESS' 'direct'
    Set-Cfg 'GITHUB_MIRROR' ''          # 不进镜像分支,只走直连(file://)
    Set-Cfg 'GITHUB_PROXY' ''
    $out = Join-Path $tmp 'gh.zip'
    GitHub-Fetch ('file:///' + $zipFile.Replace('\', '/')) $out -ExpectZip
    if ((Test-Path -LiteralPath $out) -and (Test-ValidZip $out)) {
        Pass 'case 7a: GitHub-Fetch -ExpectZip 通过直连校验 zip'
    } else {
        Fail 'case 7a: GitHub-Fetch -ExpectZip' '未落盘或 zip 校验失败'
    }
} catch {
    Fail 'case 7a: GitHub-Fetch -ExpectZip' $_.Exception.Message
}

try {
    Set-Cfg 'GITHUB_ACCESS' 'direct'
    Set-Cfg 'GITHUB_MIRROR' ''
    $out = Join-Path $tmp 'gh.json'
    GitHub-Fetch ('file:///' + $jsonFile.Replace('\', '/')) $out -ExpectJson
    if ((Test-Path -LiteralPath $out)) {
        Pass 'case 7b: GitHub-Fetch -ExpectJson 通过直连校验 JSON'
    } else {
        Fail 'case 7b: GitHub-Fetch -ExpectJson' '未落盘'
    }
} catch {
    Fail 'case 7b: GitHub-Fetch -ExpectJson' $_.Exception.Message
}

# HTML 当 JSON 喂给 -ExpectJson 必须失败(镜像常返回 200 + 错误页)
try {
    Set-Cfg 'GITHUB_ACCESS' 'direct'
    Set-Cfg 'GITHUB_MIRROR' ''
    $out = Join-Path $tmp 'gh-bad.json'
    $threw = $false
    try {
        GitHub-Fetch ('file:///' + $htmlFile.Replace('\', '/')) $out -ExpectJson
    } catch {
        $threw = $true
    }
    if ($threw) {
        Pass 'case 7c: GitHub-Fetch -ExpectJson 遇 HTML 错误页正确抛错(触发下一通道)'
    } else {
        Fail 'case 7c: GitHub-Fetch -ExpectJson' 'HTML 被当成 JSON 而未抛错'
    }
} catch {
    Fail 'case 7c: GitHub-Fetch -ExpectJson' $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 8. Test-Mirror(死地址返回 null,不挂死)
# ---------------------------------------------------------------------------
try {
    $sw = New-Object System.Diagnostics.Stopwatch
    $sw.Start()
    $r = Test-Mirror 'http://127.0.0.1:1'   # 必然连接拒绝
    $sw.Stop()
    if ($null -eq $r -and $sw.ElapsedMilliseconds -lt 30000) {
        Pass ('case 8: Test-Mirror 死地址返回 null 且不挂死(' + $sw.ElapsedMilliseconds + 'ms)')
    } else {
        Fail 'case 8: Test-Mirror' ('r=' + $r + ' elapsed=' + $sw.ElapsedMilliseconds)
    }
} catch {
    Fail 'case 8: Test-Mirror' $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 9. Get-OrderedMirrors(离线回退返回非空,不挂死)
# ---------------------------------------------------------------------------
try {
    Set-Cfg 'GITHUB_MIRROR' ''   # 走候选池 + 探针回退
    $sw = New-Object System.Diagnostics.Stopwatch
    $sw.Start()
    $list = Get-OrderedMirrors -MaxKeep 5
    $sw.Stop()
    if ($list -and $list.Count -gt 0 -and $sw.ElapsedMilliseconds -lt 120000) {
        Pass ('case 9: Get-OrderedMirrors 离线回退返回 ' + $list.Count + ' 个镜像,不挂死(' + $sw.ElapsedMilliseconds + 'ms)')
    } else {
        Fail 'case 9: Get-OrderedMirrors' ('count=' + $list.Count + ' elapsed=' + $sw.ElapsedMilliseconds)
    }
} catch {
    Fail 'case 9: Get-OrderedMirrors' $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 清理
# ---------------------------------------------------------------------------
try {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    if ($env:NBOT_CONFIG -and (Test-Path -LiteralPath $env:NBOT_CONFIG)) { Remove-Item -LiteralPath $env:NBOT_CONFIG -Force }
    if (Test-Path Env:\NBOT_CONFIG) { Remove-Item Env:\NBOT_CONFIG -ErrorAction SilentlyContinue }
} catch { }

Write-Host ''
if ($script:failCount -gt 0) {
    Write-Host ('[FAIL] github-check: ' + $script:failCount + ' failure(s)')
    exit 1
}
Write-Host '[OK] github-check: 全部通过'
exit 0
