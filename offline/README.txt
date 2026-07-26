offline 离线包目录说明
======================

把下列文件放进本目录（nbot-installer-windows\offline\），
安装器会直接使用本地文件并跳过对应的网络下载。
文件名必须完全一致。

1. python-setup.exe
   Python 完整安装包（不能用 embeddable zip 包）。
   - Windows 10/11：python.org 官方 3.12+ 安装包（建议 3.13，x64/arm64 按机器选择）。
   - Windows 7/8：官方安装包不支持，请使用 adang1345/PythonWin7 修改版安装包。

2. qq-setup.exe
   QQ NT 官方安装包。
   - Windows 10/11：可从 im.qq.com 下载当前版本（不放离线包时安装器也会自动解析官方直链）。
   - Windows 7/8：新版 QQ NT（Electron 23+）已放弃 Win7，必须使用
     Electron ≤ 22 时代的旧版安装包（约 9.9.2 及更早）。

3. napcat-shell.zip
   NapCat 官方 Windows 发布包，即 GitHub Release 中的 NapCat.Shell.zip
   （默认仓库 NapNeko/NapCatQQ）。包内必须含 launcher-win10.bat、
   napcat.mjs、NapCatWinBootMain.exe、NapCatWinBootHook.dll。

4. astrbot-src.zip
   AstrBot 源码 zip，对应 GitHub 的 archive 下载
   （https://github.com/AstrBotDevs/AstrBot 仓库页面 Code -> Download ZIP，
   或 Release 页面的 Source code (zip)）。

提示：
- 四个文件相互独立，缺哪个就在线下载哪个；全放齐即可完全离线安装。
- Windows 7 如未安装 TLS 1.2 更新将无法从 HTTPS 下载，离线包是最稳妥的方式。
