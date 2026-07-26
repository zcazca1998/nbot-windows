# =============================================================================
# nbot-installer-windows / build-single-exe.ps1
# 把整个安装器打包成单个自解压 exe(dist\NBotSetup.exe),双击即用。
#
# 实现方式:把所有文件打成一个自定义索引 + GZip 压缩的二进制块,作为嵌入资源
# 编译进一个极小的 C# 自解压器,用 Windows 自带的 csc.exe 编译(.NET Framework
# 组件,Win7 SP1 - Win11 均内置)。不依赖 iexpress、7z 或任何第三方工具。
# 生成的 exe 只用 .NET 2.0 API(GZipStream 自 2.0 起可用),裸 Win7 亦可运行。
#
# 运行时行为:
#   NBotSetup.exe                解压到临时目录并执行一键安装(install-all)
#   NBotSetup.exe /extract <dir> 只解压到指定目录,不安装(便于检查/离线分发)
#   NBotSetup.exe /panel         解压后直接打开图形面板
#
# 用法(开发机,普通权限即可):
#   powershell -NoProfile -ExecutionPolicy Bypass -File build-single-exe.ps1
# 可选:-IncludeOffline 把 offline\ 下的离线包一起打进 exe(体积变大,可完全离线装)。
# =============================================================================

param([switch]$IncludeOffline)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dist = Join-Path $root 'dist'
$work = Join-Path $env:TEMP ('botstack-build-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))

# --- 1. 收集要打包的文件 -----------------------------------------------------

$include = @(
    'install.bat', 'install-core.ps1', 'panel.bat', 'panel.vbs', 'gui.ps1',
    'setup.bat', 'setup.vbs', 'wizard.ps1', 'VERSION',
    'README.md', 'PITFALLS.md',
    'lib\common.ps1', 'lib\theme.ps1',
    'modules\astrbot.ps1', 'modules\napcat.ps1', 'modules\onebot.ps1', 'modules\tasks.ps1',
    'assets\bin\astrbot-launch.bat', 'assets\bin\napcat-launch.bat',
    'assets\bin\astrbot-prepare.py', 'assets\bin\watchdog.ps1', 'assets\bin\run-hidden.vbs',
    'assets\bin\tray-autostart.vbs', 'assets\bin\nbot.ico',
    'assets\bin\nbot.cmd', 'assets\bin\astrbotctl.cmd', 'assets\bin\napcatctl.cmd',
    'assets\bin\qqlogin.cmd',
    'tests\static-check.ps1', 'tests\common-check.ps1'
)
if ($IncludeOffline) {
    foreach ($f in @('python-setup.exe', 'qq-setup.exe', 'napcat-shell.zip', 'astrbot-src.zip')) {
        $p = Join-Path $root ('offline\' + $f)
        if (Test-Path -LiteralPath $p) { $include += ('offline\' + $f) }
    }
}

Write-Host '== 收集文件 =='
$entries = @()
foreach ($rel in $include) {
    $src = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $src)) { throw "缺少文件: $rel" }
    $entries += $rel
    Write-Host ('  + ' + $rel)
}

# --- 2. 打成「索引 + 数据」块并 GZip 压缩 ------------------------------------
# 格式(全部小端):
#   [int32 条目数]
#   每条: [int32 路径字节数][UTF8 路径][int32 内容字节数]
#   紧随其后:各条目内容按顺序拼接
Write-Host '== 组装载荷 =='
$rawStream = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter($rawStream)
$writer.Write([int]$entries.Count)
$blobs = @()
foreach ($rel in $entries) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $root $rel))
    $pathBytes = [Text.Encoding]::UTF8.GetBytes($rel)
    $writer.Write([int]$pathBytes.Length)
    $writer.Write($pathBytes)
    $writer.Write([int]$bytes.Length)
    $blobs += ,$bytes
}
foreach ($b in $blobs) { $writer.Write($b) }
$writer.Flush()
$rawBytes = $rawStream.ToArray()
$writer.Close()

$gzStream = New-Object System.IO.MemoryStream
$gz = New-Object System.IO.Compression.GZipStream($gzStream, [System.IO.Compression.CompressionMode]::Compress, $true)
$gz.Write($rawBytes, 0, $rawBytes.Length)
$gz.Close()
$packed = $gzStream.ToArray()
$gzStream.Close()
Write-Host ('  原始 ' + [math]::Round($rawBytes.Length / 1KB, 1) + ' KB -> 压缩 ' + [math]::Round($packed.Length / 1KB, 1) + ' KB')

if (-not (Test-Path -LiteralPath $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
$payloadFile = Join-Path $work 'payload.bin'
[IO.File]::WriteAllBytes($payloadFile, $packed)

# --- 3. 生成自解压器 C# 源码(只用 .NET 2.0 API)-----------------------------

$csharp = @'
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

static class NBotSetup
{
    // Built as a windowed app so a double-click shows no console flash; the
    // text modes (/console, /extract) attach to the launching console instead.
    [DllImport("kernel32.dll")]
    static extern bool AttachConsole(int processId);

    static bool consoleAttached = false;

    static void Say(string message)
    {
        if (consoleAttached) Console.WriteLine(message);
    }

    static void Fail(string message)
    {
        if (consoleAttached) Console.WriteLine(message);
        else MessageBox.Show(message, "nbot Setup",
            MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    static int Main(string[] args)
    {
        try
        {
            // Default: graphical setup wizard (pick install location, ports, mirrors).
            string mode = "wizard";
            string target = null;
            if (args.Length > 0)
            {
                string a0 = args[0].ToLowerInvariant();
                if (a0 == "/extract" || a0 == "-extract") mode = "extract";
                else if (a0 == "/panel" || a0 == "-panel") mode = "panel";
                else if (a0 == "/console" || a0 == "-console") mode = "install";
                else if (a0 == "/?" || a0 == "-h" || a0 == "--help") mode = "help";
            }
            if (mode != "wizard" && mode != "panel")
            {
                consoleAttached = AttachConsole(-1);
            }
            if (mode == "help")
            {
                Say("NBotSetup.exe                open the graphical setup wizard");
                Say("NBotSetup.exe /console       run the text-mode one-click install");
                Say("NBotSetup.exe /extract <dir> extract files only");
                Say("NBotSetup.exe /panel         open the control panel");
                return 0;
            }
            if (mode == "extract")
            {
                if (args.Length > 1) target = args[1];
                else { Fail("Usage: NBotSetup.exe /extract <dir>"); return 2; }
            }

            if (target == null)
            {
                target = Path.Combine(Path.GetTempPath(),
                    "nbot-setup-" + DateTime.Now.ToString("yyyyMMddHHmmss"));
            }
            if (!Directory.Exists(target)) Directory.CreateDirectory(target);

            Say("Extracting to: " + target);
            int count = Extract(target);
            Say("Extracted " + count + " file(s).");

            if (mode == "extract") return 0;

            string runner;
            if (mode == "panel") runner = Path.Combine(target, "panel.vbs");
            else if (mode == "wizard") runner = Path.Combine(target, "setup.vbs");
            else runner = Path.Combine(target, "install.bat");
            if (!File.Exists(runner))
            {
                Fail("ERROR: missing " + runner);
                return 3;
            }

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.WorkingDirectory = target;
            if (mode == "panel" || mode == "wizard")
            {
                // Hand off to wscript: a .bat bootstrap would blink a console
                // window. The .vbs elevates and starts the hidden GUI host.
                psi.FileName = "wscript.exe";
                psi.Arguments = "\"" + runner + "\"";
                psi.UseShellExecute = true;
                Process.Start(psi);
                return 0;
            }

            psi.FileName = "cmd.exe";
            psi.Arguments = "/c \"\"" + runner + "\" install-all\"";
            psi.UseShellExecute = false;
            Process p = Process.Start(psi);
            p.WaitForExit();
            Say("");
            Say("Setup finished with exit code " + p.ExitCode + ".");
            Say("Use the \"nbot\" shortcut on your desktop to manage it.");
            return p.ExitCode;
        }
        catch (Exception ex)
        {
            Fail("ERROR: " + ex.Message);
            return 1;
        }
    }

    static int Extract(string target)
    {
        Assembly asm = Assembly.GetExecutingAssembly();
        Stream res = asm.GetManifestResourceStream("payload.bin");
        if (res == null) throw new Exception("embedded payload not found");

        MemoryStream raw = new MemoryStream();
        using (GZipStream gz = new GZipStream(res, CompressionMode.Decompress))
        {
            byte[] buf = new byte[81920];
            int n;
            while ((n = gz.Read(buf, 0, buf.Length)) > 0) raw.Write(buf, 0, n);
        }
        raw.Position = 0;

        BinaryReader br = new BinaryReader(raw);
        int count = br.ReadInt32();
        string[] paths = new string[count];
        int[] sizes = new int[count];
        for (int i = 0; i < count; i++)
        {
            int pathLen = br.ReadInt32();
            paths[i] = Encoding.UTF8.GetString(br.ReadBytes(pathLen));
            sizes[i] = br.ReadInt32();
        }
        for (int i = 0; i < count; i++)
        {
            string full = Path.Combine(target, paths[i]);
            string dir = Path.GetDirectoryName(full);
            if (dir.Length > 0 && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
            File.WriteAllBytes(full, br.ReadBytes(sizes[i]));
        }
        return count;
    }
}
'@

$csFile = Join-Path $work 'NBotSetup.cs'
[IO.File]::WriteAllText($csFile, $csharp, (New-Object Text.UTF8Encoding($false)))

# --- 4. 用系统自带 csc.exe 编译 ---------------------------------------------

Write-Host '== 编译自解压器 =='
$cscCandidates = @(
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v3.5\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v3.5\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v2.0.50727\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v2.0.50727\csc.exe')
)
$csc = $null
foreach ($c in $cscCandidates) {
    if (Test-Path -LiteralPath $c) { $csc = $c; break }
}
if (-not $csc) { throw '未找到 csc.exe(.NET Framework 编译器),无法生成单文件 exe。' }
Write-Host ('  编译器: ' + $csc)

if (-not (Test-Path -LiteralPath $dist)) { New-Item -ItemType Directory -Path $dist -Force | Out-Null }
$exeOut = Join-Path $dist 'NBotSetup.exe'
if (Test-Path -LiteralPath $exeOut) { Remove-Item -LiteralPath $exeOut -Force }

$cscArgs = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/reference:System.Windows.Forms.dll',
    ('/out:' + $exeOut),
    ('/resource:' + $payloadFile + ',payload.bin')
)
# 给 exe 嵌入猫头图标,否则资源管理器里是一张空白「未知程序」图标
$icoFile = Join-Path $root 'assets\bin\nbot.ico'
if (Test-Path -LiteralPath $icoFile) {
    $cscArgs += ('/win32icon:' + $icoFile)
} else {
    Write-Host '  警告: 未找到 assets\bin\nbot.ico,exe 将没有图标'
}
$cscArgs += $csFile
$out = & $csc $cscArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host ($out | Out-String)
    throw ('csc 编译失败,退出码 ' + $LASTEXITCODE)
}
if (-not (Test-Path -LiteralPath $exeOut)) { throw '编译完成但未找到输出 exe。' }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

$sizeMB = [math]::Round((Get-Item $exeOut).Length / 1MB, 2)
Write-Host ''
Write-Host ('[OK] 单文件安装包已生成: ' + $exeOut + ' (' + $sizeMB + ' MB)')
Write-Host '     双击 = 打开图形安装向导(可选安装位置/端口/镜像,自动请求管理员权限);'
Write-Host '     /console 纯文本一键安装,/extract <目录> 只解压,/panel 直接开控制面板。'
