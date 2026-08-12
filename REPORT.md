# nbot-windows 自动化无人值守 & 国内 GitHub 下载加固 — 测试与优化报告

> 日期：2026-08-13
> 目标仓库：`I:\wk\nbot-installer-windows`（NapCat 后端一键部署器，即用户说的 "nbot-windows"）
> 结论：**全部测试通过，核心痛点（国内连不上 GitHub）已修复，无人值守能力已加固。**

---

## 一、结论速览

| 测试 | 结果 | 说明 |
|------|------|------|
| `static-check` | ✅ PASS | 语法/BOM/编码/必含文件全过（2 条 `Expand-Archive` PS3+ 良性警告，已在 try 内兜底） |
| `common-check` | ✅ 7/7 | 配置往返、Expand-Zip、SnowLuma 模板等契约函数 |
| `github-check`（新增） | ✅ 9/9 | 国内下载重构后的纯逻辑离线验证 |
| `render-check` | ✅ PASS | 主题/gui/wizard 全部窗口绘制无异常，状态逻辑自检 OK |
| `unattended-check`（新增） | ✅ 3/3 | 无人值守机制 + `configure` 端到端离线跑通 |

---

## 二、关键改动

### 1. 解决国内机器连不上 GitHub（核心痛点）

根因：`GitHub-Fetch` 的镜像正则**漏掉了 `api.github.com`**，而版本号与资产地址的元数据全靠这个 API 拉取——API 被墙或踩 60 次/小时限额时，元数据通道完全没有镜像可用，只剩代理（未配则无）或直连（被墙），于是卡死/报错。

修复（`lib/common.ps1`）：
- **`api.github.com` 纳入镜像正则**：ghproxy 类镜像大多支持代理 `https://mirror/https://api.github.com`，现在走镜像通道。
- **连通性探针 `Test-Mirror` + `Get-OrderedMirrors`**：经每个镜像访问 `github.com/favicon.ico`（6s 超时，不挂死），按延迟升序排序，结果缓存 10 分钟（`$env:TEMP\nbot-mirror-rank.txt`）。用户配置的镜像永远排最前。
- **releases 页面 HTML 兜底**：`GitHub-LatestRelease` 先走 API（镜像/代理/直连），失败再退回 `releases/latest` 302 跳转取 tag + `expanded_assets` 页面解析资产地址（不受 API 限额影响，且能走镜像）。
- **`-ExpectJson` / `-ExpectZip` 校验**：镜像常返回 `200 + HTML 错误页`（`curl --fail` 拦不住），下载后在通道内用 `Test-LooksLikeJson` / `Test-ValidZip` 拦截，触发下一个通道重试，而不是把 HTML 喂给 JSON 解析导致 `Die`。
- **默认镜像改为空 `''` = 自动选最快**：`GITHUB_MIRROR` 默认从 `https://ghfast.top` 改为空，首次下载自动探针选最快；向导默认值已对齐（之前是 `gh-proxy.com`，与代码注释里"必须和 common.ps1 一致"对齐）。

### 2. 代码优化 / DEBUG（发现并修复的真实 bug）

- **`Download-File` 增加 WebRequest 兜底**：原来 curl 失败直接 `throw`。现在 curl 失败（被墙 / 不支持某协议）自动降级到托管 `WebRequest` 通道，国内网络波动时更扛造。
- **`Download-File` 的 `Timeout`/`ReadWriteTimeout` 包 `try/catch`**：`file://` 等协议返回的是 `FileWebRequest`，设置这两个属性会抛 `NotSupportedException`。包一层后，下载逻辑对 http/https 之外的协议（如离线测试用的 `file://`）也不再崩。
- **`Test-ValidZip` 误杀小 zip**：下限原来是 `65536` 字节，与其注释"设得很小"自相矛盾，还会误杀合法的较小 zip。改为 **64 字节**底线（远小于任何含内容的合法 zip，真正的拦截面是 PK 魔数）。
- **新增 `NBOT_TEST=1` 守卫**：`Install-Self` 在测试时跳过把整个项目 `robocopy` 到 `%ProgramData%\nbot\installer`，避免测试污染宿主机。

### 3. 界面 UI 优化

- **安装向导（`wizard.ps1`）**：GitHub 加速下拉默认项改为"GitHub 加速（自动选最快，推荐）"；新增"测试连通性"按钮（`Show-MirrorConnectivity`），点一下清缓存并实时显示各镜像延迟 / 全部不可达提示。
- **环境诊断（`install-core.ps1` `Invoke-Doctor`）**：新增 `-- GitHub 镜像连通性 --` 区块，实时显示当前可达镜像与延迟，全部不可达时明确提示"配置代理或用 offline\ 离线包"。

### 4. 无人值守加固

- 已有机制：`NBOT_ASSUME_DEFAULTS=1` 时 `Prompt-Default` / `Confirm-Action` 直接采用默认值，`Read-Host` 在非交互环境抛异常时也回退默认值（双保险，不会卡死）。
- 新增 **`tests/unattended-check.ps1`**：离线、快速、确定性地验证 (A) `NBOT_ASSUME_DEFAULTS=1` 不碰 `Read-Host`；(B) 非交互回退默认值不挂死；(C) 真实 `install-core.ps1 configure` 端到端退出 0 并写出配置。

---

## 三、测试怎么跑（PowerShell 5.1 / 管理员可选）

```powershell
cd I:\wk\nbot-installer-windows
tests\static-check.ps1      # 语法/编码/必含文件
tests\common-check.ps1      # 契约函数
tests\github-check.ps1      # 国内下载逻辑（离线，file:// 模拟）
tests\render-check.ps1      # GUI 绘制（需 -STA，自动拉起子进程）
tests\unattended-check.ps1  # 无人值守机制 + configure
```

> 说明：`install-all` 一键全自动需要**外网 + 管理员**（下载 AstrBot/NapCat/QQ/受管 Python 并写计划任务），不在本沙箱离线范围；`doctor` 的镜像探针依赖外网，已手动确认离线 `exit 0`（约 25s，正确报"全部镜像不可达→回退直连"）。

---

## 四、文件改动清单

**修改**
- `lib/common.ps1`：`Get-MirrorPool`/`Get-OrderedMirrors`/`Test-Mirror`/`GitHub-Fetch`/`GitHub-LatestRelease`/`GitHub-LatestTag`/`GitHub-LatestReleaseFromHtml`/`Parse-*` 重构；`Download-File` 兜底 + 超时保护；`Test-ValidZip` 下限修正；`GITHUB_MIRROR` 默认值改为空。
- `install-core.ps1`：`Invoke-Doctor` 新增 GitHub 镜像诊断；`Install-Self` 增加 `NBOT_TEST` 守卫。
- `wizard.ps1`：GitHub 默认项对齐 + "测试连通性"按钮与 `Show-MirrorConnectivity`。

**新增**
- `tests/github-check.ps1`：9 个离线用例覆盖解析/校验/下载/探针/回退。
- `tests/unattended-check.ps1`：无人值守机制 + configure 端到端。

---

## 五、已知 / 待办

- `static-check` 的 2 条 `Expand-Archive` PS3+ 警告为良性（已在 `try` 内，失败回退 .NET 解压）。如需清零可在测试里加白名单，但非必须。
- 建议在 README/PITFALLS 里补充：`offline\` 离线包的制作与回退流程（当前代码已支持直连失败提示离线包，但缺文档）。
- 完整 `install-all` 真机无人值守跑通建议在有外网+管理员的 Win10/11 上做一次端到端验证（本加固已确保"不卡交互、不崩"，下载通道也已多兜底）。

---

## 六、CI 接入与测试稳定性（补充）

### 1. 两个新测试已接入 GitHub Actions
项目本身就在用 GitHub 提供的 **Windows Runner**（`windows-latest`，自带 curl + PowerShell 5.1）跑 CI。本次把两个新增离线测试补进 `.github/workflows/ci.yml`，每次 push/PR 在真实 Windows 上回归：
- `GitHub 下载逻辑离线测试` → `tests/github-check.ps1`
- `无人值守命令分发离线测试` → `tests/unattended-check.ps1`

`github-check` 强制走托管 `WebRequest` 兜底（`$script:CurlExe=$null`），因此在自带 curl 的 Runner 上也能确定性覆盖"无 curl（Win7）"降级路径；`unattended-check` 的 `configure` 命令离线安全、不触发 GitHub 探针，不会在 Runner 上超时。

### 2. 修复测试偶发失败（env 清理守卫）
排查中发现 `tests/*.ps1` 里 `Remove-Item Env:\NBOT_CONFIG` 在本机 PowerShell 环境的"safe-delete"安全钩子下，当该环境变量不存在时会**终止性抛错**，导致 `unattended-check` 偶发失败（变量存在时正常、不存在时抛错，故呈随机性）。

改为**守卫式清理**（存在才删），三处测试统一修正：
```powershell
if (Test-Path Env:\NBOT_CONFIG) { Remove-Item Env:\NBOT_CONFIG -ErrorAction SilentlyContinue }
```
该写法在标准 Windows / GitHub Actions 上本就无害，只是顺手写得更稳，也让测试在本沙箱可复现。生产脚本（`lib/`、`install-core.ps1`）不含裸 `Remove-Item Env:`，不受此钩子影响。

### 3. 文件改动清单补充
**修改**
- `.github/workflows/ci.yml`：新增两步，回归 `github-check` 与 `unattended-check`。
- `.gitignore`：忽略测试临时产物（`tests/.unattended-results.txt`、`tests/.log-*`、`tests/.diag*`、`tests/.unattended-debug.ps1`）。
- `tests/github-check.ps1`、`tests/common-check.ps1`、`tests/unattended-check.ps1`：env 清理改为守卫式。
