# Windows 部署踩坑总结

## 兼容性

1. 核心脚本必须兼容 PowerShell 2.0（Win7 原生环境）。$PSScriptRoot、Get-Content -Raw、ConvertFrom-Json、Expand-Archive、Invoke-WebRequest、[pscustomobject]、[ordered]、::new() 都是 PS3+ 才有的，PS2 下直接报错或为空。路径要用 Split-Path $MyInvocation.MyCommand.Path 自己求，读文件用 [IO.File]::ReadAllText，解 JSON 和解压走 .NET 或自写实现。
2. ConvertFrom-Json 与 Expand-Archive 允许出现在 try 块中做「有则用、无则回退」的探测，但不能作为唯一路径。
3. Win7 的 PowerShell 2.0 跑在 .NET 2.0/3.5 上，ServicePointManager 没有 Tls12 枚举值，必须 try 强转数值（3072）设置，失败时给出打 TLS 补丁的提示，而不是让下载静默失败。
4. chcp 65001 在 Win7 的 cmd 下有一堆坑（批处理执行异常、字体缺字、重定向乱码），所以 .bat/.cmd 一律纯 ASCII；中文文案全部放在 .ps1 里，且 .ps1 必须带 UTF-8 BOM，否则旧版 PowerShell 按 ANSI 读取会乱码。
5. arm64 Windows 上 %PROCESSOR_ARCHITECTURE% 在 32 位进程里会撒谎，判断架构要同时看 PROCESSOR_ARCHITEW6432 或用 .NET 接口。

## 会话隔离

1. QQ 是 GUI 程序，不能注册成 SYSTEM 服务或跑在 Session 0：窗口渲染、托盘、扫码全都依赖交互桌面。NapCat+QQ 必须用「用户登录时触发」的计划任务，运行账户为交互用户本人。
2. schtasks /run 由 SYSTEM（比如 Watchdog 任务）发起时，会把交互任务投递到已登录用户的会话里执行；如果没有用户登录桌面，/run 直接失败。无人值守机器必须配自动登录，Watchdog 也要把「用户未登录」与「任务失败」区分开。
3. AstrBot 是纯后台进程，才可以放心用 onstart + SYSTEM 启动；不要把两类任务的运行账户写反。
4. RDP 注销（logoff）会结束桌面会话并杀掉 QQ；远程操作完只断开连接（disconnect），不要注销。

## 下载

1. GitHub API 必须带 User-Agent 头，否则直接 403；WebClient 默认不带，要显式设置。
2. ghproxy 类镜像只加速 github.com / raw.githubusercontent.com 的文件下载，不代理 api.github.com；查 Release 资产列表仍要走代理或直连，镜像前缀只拼在最终下载 URL 上。
3. .NET WebClient / HttpWebRequest 不支持 socks 代理，只认 http/https；socks5h 只有在系统有 curl.exe（Win10 1803+ 自带）时才可用，配置校验时要提示这个限制。
4. 腾讯 rainbow 配置（windowsDownloadUrl.js）里的 QQ 版本号可能滞后于官网页面，但这个 URL 本身长期有效、结构稳定，适合作为自动解析入口；不要去抓官网 HTML。实测无反爬，普通 GET 即可（HTTP 200、约 1.2 KB）。
4.1. 解析那份 JS 的正则别写成 `ntDownloadX64Url[^"']*["']([^"']+)["']` —— `[^"']*` 会把值起始的那个引号当成结束引号，抓到的是空串（表现为解析出一个 `:`）。要锚定冒号后的链接：`ntDownload(X64|ARM)Url"\s*:\s*"(https?://[^"]+)"`。这个 bug 让「自动下载 QQ」长期失效，而在已装 QQ 的机器上完全不会暴露——测试环境必须覆盖「没装过 QQ」的场景。
5. dldir1 域名下的旧版 QQ 直链会随版本下架失效，不能硬编码某个 9.9.2 直链当默认值；Win7 场景离线包（offline\qq-setup.exe）才是稳妥路径。**官方配置里给出的链接本身也可能已经 404**（实测 9.9.11 的 x64 直链就是），所以解析出 URL 后要先 HEAD 探测可用性，不可用时直接给出「放离线包 / 填 QQ_WIN_URL / 先手动装 QQ」三条出路，别等下载失败再报错。
6. 公共加速服务可能限流或过期，镜像、代理、PyPI 索引全部必须可配置，不能散落硬编码。

## Python

1. python.org 官方安装包 3.9+ 不支持 Win7（缺 API），最高只到 3.8；AstrBot 需要 3.12+，Win7/8 只能用 adang1345/PythonWin7 修改版安装包。
2. embeddable zip 包没有 venv 和 pip（且 python._pth 锁死了 site），不能拿来创建 venv；必须用完整安装包。
3. 静默安装要用 /quiet InstallAllUsers=0 TargetDir=C:\AstrBot\.python 这类参数把安装位置钉死在数据目录，不要装进 %LocalAppData% 再去猜路径。
4. venv 的激活脚本和 pyvenv.cfg 对含空格路径处理很脆（shebang、引号问题），AstrBot 相关路径全部避免空格，调用时也统一用 venv 内 python.exe 的绝对路径而不是 activate。
5. Microsoft Store 版 Python（路径含 WindowsApps）建出来的 venv 在 SYSTEM 计划任务下起不来，报 "Unable to create process"（应用包 ACL 只对安装用户放行）。安装器已在 Find-Python 中一律排除 Store 版；也可设 PYTHON_FORCE_MANAGED=1 强制只用托管 Python（实测踩坑：py -3.13 恰好解析到 Store 版，venv 装完依赖后健康检查失败触发回滚）。

## 计划任务

1. onstart + SYSTEM 的任务读到的是 SYSTEM 账户的环境变量，用户级 PATH、%USERPROFILE% 全都不是你以为的值；所有路径必须在启动 bat 里写死或从 nbot.conf 读取。
2. schtasks /tr 的命令行有 261 字符限制，超长会被静默截断；长命令一律包一层 bat，任务里只写 bat 的短路径。
3. schtasks /end 只结束任务直接启动的那个进程，不管孙子进程；停止服务要用 taskkill /T /F 按进程树兜底，否则 QQ、python 残留。
4. /sc onlogon 的任务要配 /rl highest 与正确的 /ru 用户，否则 UAC 环境下起来的进程权限不对或压根不触发。
5. **第 3 条不是纸面规则,重启 NapCat 时必须真的执行**:QQ 是启动器拉起的孙子进程,`schtasks /end` 杀不到。残留的旧 QQ 一直占着登录态,新实例快速登录时被「当前账号(xxx)已登录,无法重复登录」挡下 → OneBot 网络根本不启动 → 端口不监听 → AstrBot 那边永远连不上,而配置文件看起来完全正确,极难排查。实测踩坑时机器上堆了 13 个 QQ 进程。`Restart-BotTask 'NapCat'` 必须先 `taskkill /im QQ.exe /t /f` 再 `/run`(登录态存在本地,会自动快速登录,不需要重新扫码)。
6. SYSTEM 任务(onstart/每分钟那类)在**非提权**进程里 `schtasks /query` 会返回「拒绝访问」而不是「找不到」。只看退出码会把它们误判成「任务不存在」,面板于是显示「计划任务不完整」,用户以为自启没装。判断存在性要看输出内容:出现 denied/拒绝 说明任务是存在的。
7. 承上:`schtasks` 把这类错误写进 stderr,在 `$ErrorActionPreference='Stop'` 下会抛异常;如果这段代码在 WinForms 事件(如 Shown/Timer)里跑,异常会直接崩掉整个窗口。要用 `cmd /c "... 2>&1"` 把 stderr 收进 stdout,别让它进 PowerShell 错误流。

## 打包与界面

0. WinForms 的 Paint 事件里抛异常会直接崩掉整个窗口(弹 .NET 未处理异常对话框)。踩过的具体坑:`New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,$c1,$c2,90.0)` 在 PowerShell 里解析不出 4 参数重载(Rectangle/RectangleF 重载 + double 角度歧义),必须改用「两点」构造 `LinearGradientBrush(Point,Point,Color,Color)`。教训:①所有 Paint 处理器都要包 try/catch,②只构建窗体的无头测试抓不到绘制期错误,必须有把窗口画到屏幕外的真实渲染测试(tests\render-check.ps1)。
0.1. 用 .bat 做 GUI 的引导器,每次启动都会闪一下 cmd 控制台窗口。改用 wscript 跑 .vbs(wscript 没有控制台),在 vbs 里用 Shell.Application 的 ShellExecute "runas" 提权 + 隐藏窗口启动 PowerShell,全程无闪窗;桌面快捷方式也要指向 wscript.exe + .vbs 而不是 .bat。
0.2. 需要给子进程传环境变量时,不要用 `cmd /c set X=1 && start ...`(又是一次闪窗)。VBS 里直接 `shell.Environment("PROCESS").Item("X") = "1"`,再 `shell.Run`,子进程自然继承。
0.3. 无边框窗体(FormBorderStyle=None)在别的程序占焦点时可能开在后面,看起来像「没启动」。在 Shown 事件里做一次 TopMost 置前 + Activate 再取消 TopMost。
0.4. `[System.Drawing.Icon]::ExtractAssociatedIcon('...shell32.dll')` 经常返回一张空白图标(托盘上就是「白纸」)。自己用 GDI+ 画图标,并手写 ICO 容器(32bpp DIB + 空 AND 掩码,AND 掩码每行按 4 字节对齐)存成多尺寸 .ico;`Icon.Save` 对由 `Icon::FromHandle` 得到的图标不可靠,别指望它。
0.5. 即使设了 `Form.Icon`,任务栏按钮仍可能显示 powershell.exe 的图标——因为窗口按进程路径归组到任务栏上已固定的 PowerShell 按钮里。必须在建窗口前调 `SetCurrentProcessExplicitAppUserModelID('自己的AppID')`(shell32.dll)才能脱离归组、显示窗口自己的图标。
0.6. 托盘图标只绑 DoubleClick 不够用:用户习惯单击唤出。绑 MouseClick 判断左键即恢复窗口(右键交给 ContextMenu)。另外被强杀的进程会在托盘留下「幽灵图标」,直到鼠标划过才消失,排查时别误判成图标没生效。
0.7. AstrBot / NapCat 的日志是 UTF-8,`Get-Content` 默认按本地代码页(中文 Windows 为 GBK)解码,中文和 emoji 会变成 `鉁ㄢ湪鉁?` 这类乱码。要用 FileStream(FileShare::ReadWrite,日志正被写入)+ StreamReader(UTF8) 读;控制台输出前把 `[Console]::OutputEncoding` 切成 UTF-8;日志里还有 ANSI 颜色转义(`ESC[32m`),在窗口里显示前要用正则去掉。最省心的做法是像面板那样直接在 GUI 里看日志,绕开控制台代码页。
0.8. 光给窗口/托盘设图标还不够,exe 文件本身在资源管理器里会是一张空白「未知程序」图,一看就像三无软件。编译时必须用 `csc /win32icon:<.ico>` 把图标嵌进 exe。换了图标后资源管理器可能仍显示缓存的旧图,调 `SHChangeNotify(0x8000000, ...)`(shell32.dll)刷新图标缓存,或让用户 F5。窗口、托盘、任务栏、快捷方式、exe 五处最好共用同一个 .ico,视觉才统一。
0.9. 内嵌资源与显示的多处编码/BOM 教训汇总:所有 .ps1(含 scratchpad 里的临时脚本)必须存 UTF-8 带 BOM,否则 powershell.exe 按 ANSI 读中文——尤其是脚本里出现中文路径(如删除「nbot 面板.lnk」)时,路径被解成乱码导致 `Test-Path` 假阴性、`Remove-Item` 静默不删还误报「已删除」。凡是脚本里带中文,先确认 BOM。
0.9.1. 同一个 BOM 坑在 **GitHub Actions** 里会再咬一次:workflow 的 `run:` 块会被落成临时 `.ps1` 执行,而且**不带 BOM**,Windows PowerShell 按 ANSI 读——只要脚本里有中文就变乱码、直接 `The string is missing the terminator` 解析失败。`run:` 块一律只写 ASCII;要中文放到步骤的 `name:`(那是 YAML 字符串,由 runner 显示,不进 PowerShell 解析)。
0.10. 对**尚未 ShowDialog 的窗体**调 `Close()` 会直接释放它,随后 `ShowDialog()` 抛「无法访问已释放的对象」并崩窗。踩坑场景:给扫码窗加「登录成功自动关窗」,而打开时已经是登录状态 → 窗口还没显示就被关掉 → 崩。两条防线:①判断条件在**建窗之前**先跑一次,满足就别建窗;②真要在回调里关,先判 `$form.Visible`。
0.11. 渲染测试(把窗口画到屏幕外)抓不到「点了按钮才崩」的问题——那些代码路径只有真实调用才走到。要单独加一个自检模式,在**非提权**子进程里真跑一遍状态刷新和每个对话框的构建(NOSHOW 下不真显示)。这个自检当场抓出过两个必崩 bug:调用了改名后已不存在的函数、以及上面 0.10 的窗体释放。注意自检模式要绕过单实例互斥锁,否则已有面板在跑时它会静默退出、什么都测不到,还伪装成通过。
1. iexpress 是 GUI 子系统程序:`/N /Q` 静默构建时直接 `&` 调用不会等待,会在 exe 写完前就去检查产物而误判失败;而且构建失败没有任何日志。最终改用「载荷索引 + GZip 压缩 + csc.exe 编译 C# 自解压器」的方案,全程可控、可自测。
2. 自解压器只用 .NET 2.0 API(GZipStream 自 2.0 起可用),不要用 System.IO.Compression.ZipFile(4.5+),否则裸 Win7 跑不起来。
3. WinForms 面板必须用 `-STA` 启动,否则部分控件与托盘图标行为异常;PictureBox 直接 `FromFile` 会锁住文件导致 NapCat 无法覆盖二维码图片,要走 MemoryStream 加载。
4. 登录会话的计划任务直接 `/TR` 指向 .bat 会显示黑色控制台窗口。用 `wscript.exe //B run-hidden.vbs <bat>` 包一层可隐藏窗口,同时保留 GUI 程序(QQ)正常显示;`-WindowStyle Hidden` 只对 powershell.exe 有效,对 cmd 拉起的 bat 无效。
5. 关闭自启要用 `schtasks /change /disable`(而不是删除任务),这样保留任务定义便于一键恢复;但要记得禁用状态下 `schtasks /run` 会失败,「启动全部」需先自动 enable。

## 更新与回滚

1. Move-Item 只有同一个盘（同卷）才是原子改名，跨卷会退化成复制+删除；releases 目录和解压临时目录必须放在同一个盘上。
2. Windows 文件锁与 Linux 不同：运行中的 exe/pyd/dll 不能覆盖或删除。必须先停进程（taskkill /T 确认树上没有残留）再切换目录，否则更新中途报 Access denied 留下半成品。
3. current 是 junction，删除要用 rmdir（只删链接点），绝不能 rd /s——那会顺着 junction 把真实 release 目录里的文件全删掉。
4. 新版本先在新 release 目录里完整安装并通过 WebUI 启动检查，再切 junction；失败则把 junction 指回旧目录即回滚。配置、登录态永远不在版本目录里。
5. 更新成功后只保留当前和上一个 release，清理旧目录前先确认 junction 已指向新目录。
6. **「配置放在版本目录外」这句话，要确认被托管的程序真的照做**。NapCat 读写配置用的是它自己所在的目录（`<载荷>\current\config`）：WebUI 里改的设置、登录态记录、新生成的 token 全写在那儿。安装器只做「主目录 → 载荷」的单向同步是不够的——载荷整个换掉时，NapCat 自己写的东西就没了，表现为升级一次就要重配 OneBot、重新登录，而主目录看起来一直是空的（这正是识破问题的信号）。正确做法是双向：①启动前先从载荷**回收**到主目录，再推下去；②安装器切 junction **之前**必须先回收一次；③进程退出后再回收一次。判断标准很简单——主目录里如果长期没有文件，说明同步方向反了。

## OneBot 对接（AstrBot ↔ NapCat）

1. **两边都要配,只配一半等于没配**。NapCat 侧写 `onebot11_<QQ号>.json`(HTTP 服务 + 反向 WS 客户端),AstrBot 侧还必须有 aiocqhttp 平台适配器,且 **token 两边必须完全一致**——不一致时反向 WS 握手被拒,现象是「配置文件看起来都对,就是连不上」,日志里也不一定有明显报错。安装器要自动把同一个 token 写进两边,别指望用户手工抄。
2. AstrBot 的 `data\cmd_config.json` **带 UTF-8 BOM**,Python 用 `encoding="utf-8"` 读会抛 `Unexpected UTF-8 BOM`,必须用 `utf-8-sig`。踩坑时表现为「配置脚本静默失败,AstrBot 那半永远是空的」。
3. 改 AstrBot 配置优先调它自己的函数(如 `cmd_conf._set_dashboard_password`、按 `default.py` 的模板结构写 platform 条目),别自己猜哈希算法和字段名——版本一升就错。
4. 判断对接是否真的成功,不能只看配置文件写对了。硬指标两个:`netstat` 里 AstrBot 的 WS 端口出现 **ESTABLISHED** 连接;AstrBot 日志出现 `[平台id(aiocqhttp)]` 的消息流水。NapCat 的 OneBot HTTP 端口**只有登录成功后才监听**,可以用它判断 QQ 是否已登录。
5. 平台适配器的 `id` 会显示在 AstrBot 的平台列表里,默认模板是 `default`,辨识度太低;安装器写入时改成 `QQ` 之类的名字,但**只在 id 还是默认值时改**,用户自己起过名的要尊重。另外 UI 上这个平台叫「OneBot v11」,内部 `type` 是 `aiocqhttp`,是同一个东西。

## 凭据与状态显示

1. **别把日志当配置读**。AstrBot 的初始账号密码只在首次启动时打进 `astrbot.log`,那是历史快照:用户在网页里改了用户名/密码之后,日志里的值就过期了,面板照着显示会误导人。用户名要读当前配置 `dashboard.username`;密码是哈希存储、改后无法还原,用 `password_change_required` 判断那个初始密码是否还有效,失效就别显示,改为提供「重置密码」入口。
2. AstrBot 的 `password` CLI 用 `getpass` 直接读控制台,管道喂不进去,自动化会**永久卡住**。要改密码就自己调它的哈希函数写配置文件,别试图驱动那个交互命令。
3. 看门狗「没日志」不等于没工作:它可能只是没有需要守护的目标(标记文件被「停止全部」删掉了)。守护进程要能自证——状态切换时记一行,长期空闲时按小时打一次心跳,内容写清楚为什么闲着,否则用户只会觉得它坏了。
4. 守护逻辑要区分三种「进程不在」,不能一律拉起:①**用户主动停止**——删掉守护标记即可,看门狗不动(注意这只影响本次运行,计划任务仍会在下次开机/登录时自启,这是对的,别去改启动脚本);②**根本起不来**——反复拉只会刷屏,对 QQ 还可能触发风控,必须有上限;③**假死/被 OOM 杀/意外退出**——这才该拉。
5. 承上,「只重启一次」的标记不足以防崩溃循环:标记通常在「看到进程存在」时清除,于是「起来几十秒又崩」会变成无限重启。要再加一层滚动窗口计数(如 30 分钟内 3 次仍未稳定存活就放弃并记明原因),并规定「稳定存活 N 分钟」才算恢复、清零计数;放弃状态只能由用户明确介入(点启动/修复)来解除。
6. 面板的状态刷新跑在 UI 线程上,**每一次外部调用都是卡顿**。踩坑实测:每 5 秒刷新里有 3 次 `cmd.exe` 起进程查计划任务 + 2 次会阻塞到超时的 TCP 连接探测,单轮耗时 **1357 ms**,表现为拖动窗口发飘、点按钮不跟手。改成「任务存在性缓存 60 秒(改动任务的操作主动失效)+ 用 `IPGlobalProperties.GetActiveTcpListeners()` 直接读系统监听表」后降到 **10 ms**。经验:UI 定时器里禁止起进程、禁止做会阻塞的网络连接;这类问题静态检查和渲染测试都发现不了,只有真人用起来才觉得「不跟手」。

## QQ 风控

1. QQ 掉线只自动拉起一次（标记文件防循环）：反复重启会不停弹登录窗口、频繁触发风控甚至冻结；再次掉线一律等人工 qqlogin。
2. 更新 QQ（卸载旧版装新版）不会动登录态——登录数据在 Documents\Tencent Files 下，与安装目录分离；但清理脚本绝不能碰这个目录。
3. Watchdog 的假死判定必须是「进程在 + WebUI 连续 3 次无响应」，启动宽限期内（AstrBot 120 秒、NapCat 90 秒）不判定；否则冷启动慢一点就被误杀，等同变相反复登录。

## SnowLuma 后端专属(双后端合并后新增,全部来自变种实测)

1. **重启 SnowLuma 不需要杀 QQ——这一条与 NapCat 的结论恰好相反,是双后端仓库里最容易抄错的地方。**
   NapCat 自己就是 QQ 进程(hook 随启动器注入在里面),重启必须连 QQ 进程树一起杀,否则旧 QQ 占着登录态,新实例被「已登录无法重复登录」挡住;
   SnowLuma 的 hook 是运行期注入的,和 SnowLuma 的 node 进程没有绑定关系——杀掉 node,hook 留在 QQ 里继续跑,新实例起来后经命名管道(mojo.<pid>.control)直接重连,登录态不受影响。
   照抄 NapCat 逻辑顺手杀 QQ 纯属负优化,还多一次登录等待和异常退出记录。
2. **SnowLuma 不启动 QQ**,它只是独立 node 进程,轮询发现已在跑的 QQ.exe 再注入。启动脚本必须自己探测 QQ 不在则用配置里的 QQ_EXE 拉起,否则 SnowLuma 永远等在轮询循环里,WebUI 起来了但对接是空的。QQ_EXE 要在安装和修复时探测落盘。
3. 看门狗发现 QQ 消失时**不能从 SYSTEM 会话 Start-Process 起 QQ**(GUI 进 Session 0 没桌面),只能重跑 ONLOGON 的后端任务让启动脚本在用户会话里拉;重跑前先按命令行杀掉自家 node,否则新旧实例撞 WebUI 端口。
4. `\NBot\SnowLuma` 任务链路是 wscript → bat → node,`schtasks /End` 只能带走 wscript,**node 是孙进程收不掉**,必须显式按命令行终止。
5. 识别「自己的 node」不能只按进程名(用户可能跑着别的 Node 程序):启动脚本故意用**绝对路径**起 index.mjs,让载荷路径出现在命令行里,看门狗按「node* + index.mjs + 载荷路径」三重匹配;配置读不到载荷路径时**宁可拒绝守护也不降级匹配**,否则会误杀用户的 Vite/Next 进程。
6. SnowLuma 官方**只发 win-x64**:native 注入模块必须与 QQ 同架构,arm64 上解压、node、WebUI 全正常,只在注入命名管道那步失败,位置极具迷惑性。装机前置检查直接拦 arm64,且必须排在装 QQ 之前。
7. Release 资产完整版(win-x64.zip,自带 node.exe)与 lite 版(win-x64-lite.zip,要系统 Node 22+)前缀相同,匹配正则必须让完整版优先命中。
8. **WebUI 端口被占时 SnowLuma 会自己漂到下一个空闲端口**,只留一条 WARN 日志,不崩不报错。后果:①别的程序占了端口→实际跑在 5100 而探测 5099,永远「未运行」→反复重启死循环(所以假死重启必须有滚动窗口上限);②旧实例没死透就拉新的→健康检查连上的是旧实例,升级被误报成功。重启前必须确认旧 node 真退出;排查状态异常先搜日志里的 `is in use, using`。
9. EULA/隐私未同意时 WebUI 面板锁定但**端口照样监听**:健康检查只能用纯 TCP 连通性判活,不能解析 HTTP 内容。安装器绝不替用户同意协议。
10. OneBot 配置字段名与 NapCat 完全不同,且 SnowLuma `rejectUnknownKeys`——多写一个 NapCat 时代的字段直接拒绝加载而不是忽略:network→networks、websocketClients→wsClients、token→accessToken、enable→enabled、messagePostFormat→messageFormat、reconnectInterval(30000)→reconnectIntervalMs(5000)、enableWebsocket→enableWebSocket(大写 S);httpServers/wsServers 缺省 host 是 0.0.0.0,必须显式写。JSON 模板必须整块按后端分支,静态检查有专项门禁。
11. SnowLuma 首次为某账号加载配置会写 per-uin 快照(onebot_<uin>.json)盖过全局配置,改全局配置时要把快照删掉才生效;首启前主配置没有 onebot.json 时要先写一份四个空数组的安全默认,避免内置默认在 0.0.0.0:3000/3001 开无鉴权端口。
12. 密码是 scrypt 哈希,重置只能删 webui.json 让它重新生成,不能像 NapCat 那样改明文 token;webui.json 主目录和载荷**两处都有副本**(双向同步的一部分),只删一处会被 xcopy 盖回来,必须两处都删→停任务→重启→等端口→从日志**新增部分**取新密码(未改密前每次重启都换新的,取最后一条)。
13. `SNOWLUMA_*` 配置键是刻意与 SnowLuma 自身支持的环境变量同名的,启动脚本把 conf 逐行 set 成环境变量、SnowLuma 启动即采纳;新增这类键之前必须确认 SnowLuma 真支持同名变量,否则做出来的是设置了却无效、自己骗自己的配置项。
14. 升级换载荷时除了 config 单层回收,还要**递归**回收 data\<uin>\(账号 SQLite 库在载荷里);回收前先停任务并杀 node,否则拷到打开中的库。官方 zip 不含 config 目录(NapCat 包含),同步前必须先建目录。
15. SnowLuma 与 QQ 是**分开守护的两个目标**:QQ 在但 SnowLuma 死(bot 离线没人管)、SnowLuma 在但 QQ 没了(没东西可注入)是两种都要能识别的故障,按 NapCat「只看一个进程」的思路会漏一半。

## 多代理/移植脚本的坑

1. PowerShell 哈希字面量的键**不区分大小写**:@{'napcat'=..;'NAPCAT'=..} 是 duplicate key 解析错误;要大小写变体就用有序键值对数组。
2. .NET Framework 的 String.Replace 没有带 StringComparison 的三参数重载(.NET Core 才有);两参数版本本来就是 ordinal 区分大小写的,够用。
3. GitHub Actions 的 run: 块落成临时 .ps1 **不带 BOM**,Windows PowerShell 按 ANSI 读,中文直接解析失败;run: 只写 ASCII,中文放 name:。
4. 多个代理/会话并行改同一目录时,谁最后落盘谁赢:开工前必须固定基线提交,分工按**文件级**互斥,谁也不许碰别人的文件;被中断的会话留下的半成品要先 git diff 甄别再决定采用或还原。
5. **curl 没有 --max-time / --speed-time 时,被墙的连接会永远挂死**:`--connect-timeout` 只管「连不上」,而被墙的典型形态是 TCP 连得上、传输阶段被掐——连接超时不触发、`--retry` 永远轮不到,安装流程无限卡住且没有任何报错。加 `--speed-limit 1024 --speed-time 30`(30 秒平均低于 1KB/s 判死)既能斩断挂死又不误伤慢速大文件。WebClient.DownloadFile 同病且无药,要换 HttpWebRequest(Timeout + ReadWriteTimeout)手动流拷贝。这个雷从 v1.0 一直埋到 v1.6 才在一次夜间无人值守安装里炸出来——**直连侥幸成功过≠通道可靠**。
6. **无人值守流水线里的交互提示是二号挂死源**:「检测到已装 QQ,是否重新安装?[y/N]」在没人的控制台上会永远等下去——不报错、不超时、CPU 为零,和网络挂死的表象几乎一样,极难区分(这次就是先误诊成下载挂死,修完 curl 才发现真凶是 Read-Host)。所有 Confirm/Prompt 类函数必须内建无人值守出口:环境变量开关(NBOT_ASSUME_DEFAULTS=1)走默认值,-NonInteractive 下 Read-Host 抛异常也走默认值,两条路都要记日志说明「自动选了什么」。诊断这类挂死的正确姿势:看子进程的**最后一行输出是什么**,而不是猜下一步是什么。
