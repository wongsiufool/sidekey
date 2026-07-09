# 发布前打包验收（审计 H-5）

目的：确认**打包后的电脑端**（双击即用的 `.app` / `.exe`，不是开发用的 `python sidekey_server.py`）在干净机器上真的能跑——重点是 TLS 依赖 `cryptography` 有没有被打进去。漏了的话，用户双击会直接闪退。

> 已修：`SidekeyServer-mac.spec` 和 `SidekeyServer.spec` 现在都显式 `collect_all('cryptography')`（之前没有，是这次的根因）。

---

## ✅ macOS —— 已由开发侧验证通过（2026-06-25）

干净 venv 重新打包 + 跑打包版二进制 + wss 握手全过：
- 打包：`server/build_app.command`（双击）→ 产物在 `~/.sidekey-build/dist/Sidekey.app`
- 验证：启动后日志出现 `🔒 已启用 TLS(wss); 证书指纹 …` + `server listening` ＝ cryptography 打进去了
- wss 握手 + 令牌 + `ready` 全过

**你这边只需做一次首次设置**（不是打包问题，是正常授权）：
1. 双击 `Sidekey.app`（未签名首次：右键→打开）。
2. 系统会弹「辅助功能」请求 → 到 **系统设置 → 隐私与安全性 → 辅助功能**，把 **Sidekey** 打开（让它能注入按键）。
3. 手机 App **重新扫码配对**（打包版证书和开发版不同，指纹变了，要重扫一次）。
4. 把电脑光标放进「备忘录」，手机点一个键 → 备忘录里出现字 ＝ ✅ 通过。

> 发布给别人：证书就绪后双击 `sign_notarize_dmg.command` 做签名+公证+打 dmg（见 [[sidekey-appstore-submission]]）。

---

## ✅ Windows —— 打包 + TLS 启动已由开发侧验证通过（2026-06-25）

在本机（Windows 11 / Python 3.11.9，全新 `.buildenv` venv）重新装依赖 + 打包 + 跑打包版二进制：
- 打包：用 `build_exe.bat` 里那条 pyinstaller 命令打包 → 产物 `dist\SidekeyServer.exe`（onefile，自带依赖）。
- 用「修好的 `SidekeyServer.spec`」单独再打一次（`pyinstaller SidekeyServer.spec`）→ 同样成功。
- 两个产物跑起来都出现：`🔒 已启用 TLS(wss); 证书指纹 916f28815d21f7b6…` + `server listening on 0.0.0.0:8765` ＝ **cryptography 已打进去，TLS 正常**。

> 发现 / 注意（H-5 相关）：`build_exe.bat` 实际**没有用** `SidekeyServer.spec`，它是用命令行 `--collect-all` 直接打的，而且**没带** `--collect-all cryptography/cffi`。本次仍能跑通的原因是：① `requirements.txt` 已含 `cryptography`，venv 里装上了；② PyInstaller 的依赖分析能跟到 `sidekey_server.py` 里那几处惰性 import（800 行附近）并自动把 cryptography 的原生绑定打进去。也就是说**真正兜底的是 `requirements.txt` 里有 cryptography**，spec 里的 `collect_all` 是双保险但当前 bat 路径用不到它。建议（可选）把 `build_exe.bat` 改成 `pyinstaller SidekeyServer.spec`，让 bat 和 spec 一致、更稳。

剩下**手机端到端**那一步需要你拿手机扫码实测（我这边没手机，做不了），见下面第 3 步。

---

### （参考）干净机器从零跑的完整步骤

在一台 **Windows** 电脑上（最好是没装过 Python 的「干净」机器，或至少用全新 venv）：

### 第 1 步：打包
把整个 `server` 文件夹拷到 Windows，双击 **`build_exe.bat`**（它会自动建 venv、装依赖、用修好的 spec 打包）。
- 产物：`server\dist\SidekeyServer.exe`（或脚本提示的路径）。

### 第 2 步：跑打包版，看 TLS 有没有起来（**最关键**）
打开「命令提示符」，cd 到 exe 所在目录，运行：
```
SidekeyServer.exe
```
**通过标准**：窗口里出现这两行就说明 cryptography 打包成功、能监听——
```
🔒 已启用 TLS(wss); 证书指纹 ………
server listening on 0.0.0.0:8765
```
如果它**闪退**或报 `ModuleNotFoundError` / `cryptography` / `_cffi_backend` 相关错 → 说明还没打进去，把报错截图发我。

### 第 3 步：手机连上 + 打一个键（端到端）
1. 保持 `SidekeyServer.exe` 开着。
2. 手机 App **扫码配对**（扫窗口里的二维码）→ 显示「已连接 / 令牌通过」。
3. 电脑光标放进「记事本」，手机点一个键 → 记事本出现字 ＝ ✅ 通过。

> Windows 不需要「辅助功能」授权；防火墙可能弹一次「允许局域网访问」，点允许。

---

## 验收清单（两个平台都要打勾）—— ✅ 全部通过（用户 2026-06-25 实机验证）
- [x] macOS：干净打包 → 跑 → TLS 起来 → wss 握手过（开发侧验证）
- [x] macOS：实机首次设置（辅助功能授权 + 重新配对 + 打一个键进备忘录）— 用户实机通过
- [x] macOS：菜单栏图标显示 + 三项菜单（显示二维码/打开日志/退出）+ 无 Dock 图标 — 用户实机通过
- [x] Windows：打包成功（bat 的 pyinstaller 命令 + 修好的 spec 各打一次，均成功）
- [x] Windows：`SidekeyServer.exe` 跑起来见到 `已启用 TLS(wss)` + `server listening`（已验证）
- [x] Windows：手机扫码连上 + 打一个键进记事本 — 用户实机通过
- [x] Windows：右下角托盘图标 + 三项菜单 — 用户实机通过

**✅ H-5 发布门禁全部通过（两平台打包 + TLS + 手机端到端 + 托盘/菜单栏，均用户实机验证）。**

> 可选加分项：把版本号/git commit 写进产物（Mac spec 已带 `version='1.0.0'`；commit 可后续加）。
