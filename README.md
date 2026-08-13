## **本项目代码 100% 由 AI 编写，人类负责需求、设计决策与验收。**

# nbot-windows

[![CI](https://github.com/zcazca1998/nbot-windows/actions/workflows/ci.yml/badge.svg)](https://github.com/zcazca1998/nbot-windows/actions/workflows/ci.yml)

Windows 上的 **AstrBot + QQ 机器人**一键部署器，[nbot](https://github.com/zcazca1998/nbot)（Linux 版）的 Windows 移植。
OneBot 后端二选一，安装向导里点一下就行：

- **NapCat**（默认）：官方启动器拉起 QQ 并注入，面板内嵌扫码窗，成熟稳妥。
- **SnowLuma**：与 Linux 版同款框架。注入你已在跑的 QQ，重启机器人**不动 QQ**；
  对接时 QQ 号可留空，装完即自动完成 OneBot 配置。

双击一个 exe 走完全程：选后端与安装位置 → 装托管 Python 与 AstrBot → 装机器人后端与 QQ →
注册自启与看门狗 → 登录 QQ → **自动完成 OneBot 对接**（两侧 token 自动同步，不用手抄）。

装完有一个图形控制面板：状态一览、扫码登录、日志查看、启停守护、重置密码、一键卸载。

支持 Windows 10 / 11（NapCat 后端 x64 / arm64；SnowLuma 官方只发 win-x64）；
Win7 SP1 与 Win8 见文末[说明](#windows-78-特别说明)。

---

## 快速开始

到 [Releases](https://github.com/zcazca1998/nbot-windows/releases) 下载 `NBotSetup.exe`，双击即可
（会自动请求管理员权限，全程无黑窗）。

想自己从源码打包：

~~~bat
powershell -NoProfile -ExecutionPolicy Bypass -File build-single-exe.ps1
~~~

产物在 `dist\NBotSetup.exe`，约 150 KB，不依赖任何第三方打包工具。

装好后从桌面「nbot 面板」进入日常管理，或在新开的终端里用 `nbot` 命令。

---

## 它和 Linux 版的关系

交互菜单、命令行子命令、OneBot 对接配置与守护语义都与 Linux 版同构，
Linux 专属机制则换成 Windows 原生方案：

| 项目 | Linux 版 | 本项目 |
| --- | --- | --- |
| 服务托管 | systemd unit | 计划任务（`\NBot\AstrBot` / `NapCat` / `Watchdog`） |
| QQ 运行环境 | Xvfb 虚拟桌面 + D-Bus + ptrace | 真实桌面会话（登录触发的任务） |
| 远程看画面 | noVNC + Caddy 反代 | RDP 远程桌面，无需额外组件 |
| QQ 登录 | 截图解码 + 终端二维码 | 面板内嵌二维码，登录成功自动关窗 |
| QQ / 框架来源 | 拆官方 OCI 镜像 | 官方 QQ 安装包 + NapCat 官方 Release |
| 配置文件 | `/etc/nbot.conf` | `%ProgramData%\nbot\nbot.conf` |
| 原子切换 | 符号链接 | 目录 junction |

## 部署方式

- 入口为 install.bat，双击自动请求管理员权限（UAC）；核心逻辑为 PowerShell 2.0 兼容脚本，Win7 原生 PowerShell 也能运行。
- AstrBot 使用普通 Python venv，不使用 uv。
- 若系统缺少 Python 3.12+，安装器会把托管 Python 3.13 静默安装到 C:\AstrBot\.python：Win10/11 使用 python.org 官方安装包；Win7/8 使用 adang1345/PythonWin7 修改版安装包（官方 Python 最高只支持到 3.8）。
- Windows 版 QQ 为官方 QQ NT 安装包静默安装：Win10/11 自动从腾讯 rainbow 配置解析当前官方直链（x64/arm64 自动匹配）；Win7/8 需自备旧版安装包。
- 机器人后端来自各自官方 GitHub Release 的 Windows zip 包（NapCat 默认仓库 NapNeko/NapCatQQ；SnowLuma 默认仓库 SnowLuma/SnowLuma，完整版优先、lite 兜底），不涉及 Docker，也不拆 OCI 镜像。
- 两种后端与 QQ 的关系不同：**NapCat** 由官方启动器拉起 QQ 并注入（QQ 归启动器管，停止/重启会收掉 QQ）；**SnowLuma** 注入你已在跑的 QQ（QQ 是你自己的软件，停止/重启机器人都不动 QQ，重启后 hook 经命名管道重连）。
- SnowLuma 的运行时：完整版 zip 自带 node.exe；lite 版需要系统已装 Node 22+。官方只发 win-x64。
- 服务托管使用 Windows 计划任务（schtasks）：AstrBot 开机以 SYSTEM 后台启动；机器人后端在用户登录桌面时启动（QQ 是 GUI 程序，必须运行在桌面会话）；Watchdog 每分钟做一次健康检查。
- 所有更新均手动触发，不启用定时自动更新。
- SnowLuma 有自己的 EULA 与隐私政策：安装器**绝不替你同意**——向导里有默认不勾选的同意项（附全文链接），不勾则 SnowLuma 首次打开 WebUI 时会要求你亲自确认。

**安装位置**：向导里只需选一个「安装根目录」（默认自动挑可用空间最大的盘，如 `F:\nbot`），
三个组件自动分类放进去：

~~~text
<安装根目录>\
├─ AstrBot\     AstrBot 程序与数据（app、.venv、.python、data、logs）
├─ NapCat\      或 SnowLuma\ —— 所选后端的主配置与日志（config 是唯一真源，升级不丢）
└─ payload\     后端/QQ 程序载荷（releases\image-<版本>-<时间戳> + current junction 原子切换）
~~~

QQ 的登录态在 QQ 自己的目录（`Documents\Tencent Files` 等），更新和卸载都不受影响。
SnowLuma 后端还会把账号数据（`data\<QQ号>\`）在升级换载荷时自动回收带走，不丢失。

**托管数据**（固定位置）：

- 全局配置：`%ProgramData%\nbot\nbot.conf`（后端由其中的 `BOT_BACKEND` 决定）
- 控制脚本：`%ProgramData%\nbot\bin`（`nbot`、`astrbotctl`、`napcatctl`/`snowlumactl`、`qqlogin`）
- 安装器自拷贝：`%ProgramData%\nbot\installer`

**默认端口**：AstrBot WebUI 6185、AstrBot OneBot WS 6199、OneBot HTTP 3005、
后端 WebUI —— NapCat 6099（路径 `/webui`，token 明文存于 `<NapCat 目录>\config\webui.json`）
或 SnowLuma 5099（路径 `/`，初始密码打印在日志里，未改密前每次重启换新的，面板「登录信息」随时可查）。
四个端口都可在向导里改。

## 使用

### 单文件安装包(分发首选)

在开发机执行下面命令,生成单个自解压 exe(`dist\NBotSetup.exe`),拷到目标机器双击即可:

~~~bat
powershell -NoProfile -ExecutionPolicy Bypass -File build-single-exe.ps1
~~~

双击后弹出**图形安装向导**(无控制台闪窗):选择机器人后端(NapCat / SnowLuma)、安装根目录(带目录浏览与磁盘空间提示)、GitHub 加速与 PyPI 镜像、四个端口(选 SnowLuma 时还有默认不勾选的协议同意项),点「开始安装」后实时显示安装日志,完成页可直接打开控制面板或登录 QQ。

- 打包器只用 Windows 自带的 csc.exe(.NET Framework 编译器),不依赖 7z、iexpress 等外部工具;生成的 exe 主体只用 .NET 2.0 API,裸 Win7 SP1 也能运行。
- `-IncludeOffline` 会把 `offline\` 下的离线包一并打进 exe,做成完全离线的一体化安装包。
- 其他用法:`/console` 走纯文本一键安装;`/extract <目录>` 只解压不安装;`/panel` 直接打开控制面板;`/?` 查看帮助。

也可以在项目目录里直接双击 `setup.vbs` 打开同一个图形向导(不打包 exe 时用)。

> 全部图形入口(exe 双击、`setup.vbs`、`panel.vbs`、桌面快捷方式、登录常驻托盘)都经 wscript 引导,**不会闪出黑色控制台窗口**;`setup.bat` / `panel.bat` 作为命令行环境下的等价入口保留。

### 图形面板(推荐)

双击 panel.vbs(或安装后桌面上的「nbot 面板」快捷方式)打开图形控制台,不需要敲任何命令:

- 状态仪表盘:AstrBot / 机器人后端 / QQ / 计划任务四项状态(含自启开关状态),每 5 秒自动刷新;
- 最小化后收进系统托盘,双击托盘图标恢复;关闭面板不影响后台服务运行;
- 一键安装、启动/停止、修复、卸载、**关闭/开启开机自启**按钮;安装类操作弹出独立命令行窗口实时显示进度;
- QQ 登录:NapCat 后端在窗口里直接显示二维码图片(可一键重启刷新);SnowLuma 后端把你的 QQ 窗口拉到前台扫码,面板轮询登录状态、成功自动关窗;
- 「配置 OneBot 对接」弹窗输入 QQ 号(SnowLuma 后端可留空),token 自动生成并在结果窗口显示;
- 一键打开 AstrBot / 后端管理页、查看三类日志、登录信息随时可查、忘记密码可重置。

面板基于 Windows 自带的 PowerShell + WinForms 实现,Win7 SP1 到 Win11 无需安装任何运行时。

### 命令行

双击 install.bat（自动弹出 UAC 提权），或在管理员命令行中运行：

~~~bat
cd nbot-installer-windows
install.bat
~~~

无参数进入中文菜单：

~~~text
 1) 一键全自动安装
 2) 基础配置
 3) 安装/更新 AstrBot
 4) 安装/更新 机器人后端+QQ(NapCat 或 SnowLuma,按 BOT_BACKEND)
 5) 配置 OneBot 对接
 6) 安装/修复自启与守护任务
 7) 打开 QQ 登录
 8) 运行状态
 9) 环境诊断
10) 启动全部
11) 停止全部
12) 查看日志
13) 卸载
 0) 退出
~~~

完整非交互命令：

~~~bat
install.bat install-all
install.bat install-astrbot
install.bat install-napcat
install.bat install-snowluma
install.bat configure-onebot
install.bat repair
install.bat status
install.bat doctor
install.bat restart-astrbot
install.bat restart-bot
install.bat reset-napcat <新token>
install.bat reset-snowluma
install.bat logs astrbot
install.bat logs bot
install.bat logs watchdog
install.bat start
install.bat stop
install.bat autostart-off
install.bat autostart-on
install.bat panel
install.bat qqlogin
install.bat uninstall
~~~

## nbot 常用命令

安装器注册全局命令 nbot（新开终端可用），以及 astrbotctl / napcatctl / snowlumactl / qqlogin 控制脚本：

~~~bat
nbot status
nbot doctor
nbot logs astrbot
nbot logs bot
nbot logs watchdog
nbot start
nbot stop
nbot configure-onebot

astrbotctl status
astrbotctl restart
astrbotctl logs
napcatctl status      rem NapCat 后端(snowlumactl 为 SnowLuma 后端等价物)
napcatctl restart
napcatctl logs
qqlogin
~~~

## QQ 登录与无人值守

- Windows 有真实桌面，QQ 登录直接在 QQ 窗口内扫码即可（菜单 7 或 qqlogin 会把 QQ 窗口带到前台）；不需要 Linux 版的截图解码、qrencode、noVNC 等机制。
- 远程服务器请使用 RDP 远程桌面登录后扫码，无需安装任何远程画面组件。
- NapCat+QQ 计划任务在「用户登录桌面时」触发：QQ 是 GUI 程序，无法在 SYSTEM 服务 / Session 0 中运行。
- 无人值守服务器需要设置 Windows 自动登录：运行 netplwiz，取消勾选「要使用本计算机，用户必须输入用户名和密码」，输入一次密码保存；重启后系统自动登录桌面，NapCat+QQ 随之自动启动。
- **无人值守安装**（v1.6.1+）：设置环境变量 `NBOT_ASSUME_DEFAULTS=1`（或 `NBOT_NONINTERACTIVE=1`、CI 环境 `CI=true`）后运行 `install.bat install-all`，所有交互提示自动采用默认值，不卡 `Read-Host`；非交互环境（无终端、Read-Host 抛异常）也会安全回退默认值而非挂死。适用于自动化部署 / Ansible / SCCM / CI 等场景。
- 注意：RDP 断开时保持会话（不要注销），注销会结束桌面会话并终止 QQ。

## 下载策略

GitHub 支持三种模式（GITHUB_ACCESS）：

- **auto**（默认）：自动探针选最快镜像，按「用户配置镜像 → 探针排序后的可用镜像 → 代理 → 直连」顺序回退；首次使用时自动探测各镜像延迟并缓存 10 分钟，后续复用缓存结果。
- **proxy**：仅使用代理。
- **direct**：仅直连。

国内网络优化（v1.6.1+）：

- `api.github.com` 已纳入镜像通道，版本号与资产地址的元数据获取也能走加速镜像（此前只有文件下载走镜像，元数据 API 被墙或限流时会直接卡死）。
- 当 API 被墙或踩到 60 次/小时限额时，自动降级到 GitHub Releases 页面 HTML 解析（302 跳转取 tag + expanded_assets 页面抠资产地址），不受 API 限额影响。
- 镜像常返回 `200 + HTML 错误页`（如 Cloudflare 拦截页），下载后用 JSON/ZIP 格式校验拦截，自动切换下一个通道重试，不会把错误页当合法内容处理。
- 安装向导的 GitHub 加速下拉默认为**「自动选最快（推荐）」**，旁边有「测试连通性」按钮可实时查看各镜像延迟。

相关配置项：

- GITHUB_PROXY：http/https 代理均可；socks5h 代理仅在系统带 curl.exe 时可用（Win10 1803+ 自带）。
- GITHUB_MIRROR：ghproxy 风格加速前缀；留空（默认）则启用自动探针选最快；设为具体 URL 则固定使用该镜像。
- PIP_INDEX_URL：PyPI 镜像，国内建议 https://pypi.tuna.tsinghua.edu.cn/simple。
- NAPCAT_REPO / NAPCAT_ASSET / NAPCAT_LAUNCH：NapCat 的 Release 仓库（默认 NapNeko/NapCatQQ，资产 NapCat.Shell.zip）、zip 资产名正则、包内入口（默认 launcher-win10.bat，与 launcher.bat 等价但提权回退不依赖 Windows Terminal）。
- SL_REPO / SL_ASSET / SL_LAUNCH / SL_NODE：SnowLuma 的 Release 仓库（默认 SnowLuma/SnowLuma，win-x64 完整版优先、lite 兜底）、资产名正则、包内入口（默认 launcher.bat）、包内 Node 可执行名（默认 node.exe，lite 包回落系统 Node 22+）。
- PYTHON_WIN7_URL / QQ_WIN_URL_LEGACY：Win7/8 专用的 Python、QQ 安装包直链。

全部组件支持离线安装：把文件放入安装器目录下的 offline\ 即可跳过对应下载。

| 文件名 | 用途 |
| --- | --- |
| offline\python-setup.exe | Python 安装包（Win7/8 用 adang1345/PythonWin7 修改版） |
| offline\qq-setup.exe | QQ NT 安装包（Win7/8 需 Electron ≤ 22 旧版，约 9.9.2 及更早） |
| offline\napcat-shell.zip | NapCat 官方 NapCat.Shell.zip（GitHub Release 资产） |
| offline\snowluma-win.zip | SnowLuma 官方 win-x64 zip（GitHub Release 资产，完整版或 lite 均可） |
| offline\astrbot-src.zip | AstrBot 源码 zip（GitHub archive） |

## Windows 7/8 特别说明

Win7 前置条件（nbot doctor 会逐项检测并提示）：

- 必须为 SP1。
- .NET Framework 4.5.2 或更高。
- 建议安装 WMF 5.1（PowerShell 5.1），体验更好；安装器最低兼容自带的 PowerShell 2.0。
- TLS 1.2 系统更新：KB3140245 + Easy Fix，或按微软文档启用注册表项；否则无法从任何 HTTPS 源下载。

组件限制：

- Python：官方安装包最高支持到 3.8，无法满足 AstrBot 的 3.12+ 要求；需使用 adang1345/PythonWin7 修改版安装包（配置 PYTHON_WIN7_URL 或放 offline\python-setup.exe）。
- QQ：新版 QQ NT 基于 Electron 23+，已放弃 Win7；必须自备 Electron ≤ 22 时代的旧版安装包（约 9.9.2 及更早，配置 QQ_WIN_URL_LEGACY 或放 offline\qq-setup.exe）。
- NapCat：官方 NapCat.Shell 只适配较新版本的 QQ NT（qqnt.json 锁定版本范围），而这些版本不支持 Win7。实际结论：Win7/8 上 AstrBot 部分可完整运行，NapCat+QQ 部分需要自行寻找适配旧版 NTQQ 的历史版本 NapCat（放 offline\napcat-shell.zip），成功率不保证。
- SnowLuma：自带 Node 22 运行时，Node 22 不支持 Win7/8，doctor 会直接给出警告；Win7/8 请选 NapCat 后端。
- 以上全部组件都可走离线包，前置更新无法打齐时可整机离线安装。

## 守护策略

与 Linux 版语义一致：

- 进程仍在但 WebUI 连续 3 次检查失败（Watchdog 每分钟一次）才判定假死并重启，单次波动不触发。
- 启动宽限期：AstrBot 120 秒、后端 90 秒，宽限期内不做假死判定。
- 意外消失自动拉起；30 分钟内 3 次拉起仍站不稳则放弃并记明原因（防崩溃循环刷屏、防反复重启登录窗口触发 QQ 风控），点「启动全部」即恢复守护;稳定存活 5 分钟计数清零。
- 用户主动「停止全部」后看门狗不再动作;重启机器后计划任务照常自启。
- SnowLuma 后端的看门狗只认「命令行里带本安装载荷路径的 node 进程」,配置缺失时宁可拒绝守护也不乱杀——不会误杀你自己开的其他 node 程序;QQ 由独立检查项守护(SnowLuma 不动 QQ)。
- QQ 掉线需要重新登录时，等待人工运行 qqlogin。
- 后端启动脚本经 run-hidden.vbs 拉起，控制台窗口不显示（QQ 界面正常显示）；日志完整写入 <后端目录>\logs 下的 napcat.log / snowluma.log。
- 不想开机自动运行时，点面板「关闭开机自启」（或 nbot autostart-off）：三个计划任务会被停止并禁用，数据不动；点「启动全部」或「开启开机自启」即可恢复。

## 存储与升级

- 程序载荷通过 junction（current）原子切换到 releases\image-<版本>-<时间戳>，配置、缓存和 QQ 登录态不放在版本目录。
- 更新流程：新版本在新目录安装完成并通过 WebUI 启动检查后才切换 junction；失败自动回滚到旧版本。
- 更新成功后只保留当前和上一个 release 目录。
- 更新前请确认磁盘空间充足（新旧两个版本会短暂并存）：

~~~bat
dir <安装根目录>\payload\releases
fsutil volume diskfree <安装盘>:
~~~

脚本不会格式化磁盘，也不会修改分区。

## 与 Linux 版的差异

| 项目 | Linux 版 | Windows 版 |
| --- | --- | --- |
| 入口 | sudo ./install.sh | 双击 install.bat（自动 UAC 提权） |
| 服务托管 | systemd unit | Windows 计划任务（\NBot\AstrBot、\NBot\<后端>、\NBot\Watchdog） |
| QQ 运行环境 | Xvfb 虚拟桌面 + D-Bus + ptrace capability | 真实桌面会话（登录触发的计划任务） |
| 远程看画面 | noVNC + websockify + Caddy 反代 | RDP 远程桌面（无需额外组件） |
| QQ 登录 | 截图解码 + 终端二维码 | NapCat：面板内嵌二维码；SnowLuma：直接在 QQ 窗口扫码 |
| 后端/QQ 来源 | 拆官方 OCI 镜像 | 官方 QQ 安装包 + 各自官方 GitHub Release zip |
| 自动重启 | Restart=on-abnormal + watchdog | 计划任务 + Watchdog（3 次假死判定、崩溃循环防护） |
| 配置文件 | /etc/nbot.conf | %ProgramData%\nbot\nbot.conf |
| 数据目录 | /AstrBot、/snowluma | <安装根>\AstrBot、<安装根>\NapCat 或 \SnowLuma |
| Hook 框架 | SnowLuma | NapCat（默认）或 SnowLuma 官方 Windows 构建，装机可选 |
| 原子切换 | 软链接 symlink | 目录 junction |
| 托管 Python | python-build-standalone | python.org 官方安装包（Win7/8 用 PythonWin7） |
