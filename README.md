<div align="center">

# Sidekey

**口袋里的快捷键盘 · The shortcut deck in your pocket**

把 iPhone 变成电脑的无线快捷键盘、触控板与麦克风,全程走本地 Wi‑Fi。
Turn your iPhone into a wireless shortcut keyboard, trackpad, and mic for your own computer — all over your local Wi‑Fi.

[![Download](https://img.shields.io/badge/⬇_下载-Releases-2ea44f?style=for-the-badge)](../../releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](LICENSE.txt)

</div>

---

## 这是什么 · What it is

Sidekey 是一个**伴侣 App**,由两部分组成:

- **iPhone 端**(SwiftUI App,App Store 上架)—— 你自己设计的按键 / 快捷键面板、触控板、语音输入。
- **电脑端小助手**(Python,**本仓库,开源**)—— 收到手机发来的按键并注入到你的电脑。支持 **macOS / Windows**。

两台设备连同一个 Wi‑Fi,扫一次二维码配对即可。按键只在你自己的局域网里传输,**不经过任何服务器**。

```
┌──────────────────┐      WiFi 局域网        ┌────────────────────────────┐
│ iPhone (SwiftUI) │ ─ WebSocket(wss) ───▶ │  电脑小助手 (Python)         │
│ · 自定义键位/多模式 │   JSON keycode         │  · pynput 注入按键/鼠标      │
│ · 触控板 · 语音输入 │                        │  · 令牌校验 + TLS 加密       │
└──────────────────┘                        └────────────────────────────┘
```

## 下载 · Download

| 平台 Platform | 获取 Get it |
|---|---|
| **iPhone App** | App Store — 搜索 “Sidekey” / search **Sidekey** |
| **macOS 小助手** | [Releases](../../releases/latest) → `Sidekey-macOS.dmg`(已签名公证 signed & notarized) |
| **Windows 小助手** | [Releases](../../releases/latest) → `SidekeyServer-Windows.exe` |

> macOS 首次运行需在「系统设置 → 隐私与安全性 → 辅助功能」授权,才能注入按键/鼠标。
> On macOS, grant Accessibility on first run (System Settings → Privacy & Security → Accessibility).

## 为什么开源 · Open source & trust

电脑端小助手跑在**你自己的电脑上、能模拟键盘和鼠标**。它是开源的(**MIT**),你可以自己读代码、确认它只做该做的事 —— **没有隐藏的键盘记录,不向任何人回传数据**。想更放心,直接从源码构建运行。

The desktop helper can type and move the mouse on your computer, so it's open source (MIT): read the code, confirm there's no hidden keylogging or phone‑home, and build it yourself if you prefer.

## 从源码构建 · Build from source

### 电脑端小助手 · Desktop helper (Python)

**macOS**
```bash
cd server
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt
./.venv/bin/python sidekey_server.py
```

**Windows**
```bat
cd server
py -m venv .venv
.venv\Scripts\pip install -r requirements.txt
.venv\Scripts\python sidekey_server.py
```

启动后会弹出一个**二维码**,手机端「扫码」即可配对。常用参数:`--reset-token` 重置令牌+证书、`--no-auth` 关闭令牌校验(仅自用,仍 TLS 加密)、`--port` 改端口。

不用手机先自测(把光标放进任意文本框):
```bash
cd server && ./.venv/bin/python test_client.py wss://127.0.0.1:8765
```

### iPhone App (Xcode)

需要 **Xcode** 和一台 iPhone。
```bash
cd ios
brew install xcodegen      # 只需一次 · one‑time
xcodegen generate          # 由 project.yml 生成 Sidekey.xcodeproj
open Sidekey.xcodeproj
```
在 Xcode 里选 **Sidekey** target → **Signing & Capabilities** → **选你自己的 Apple 开发团队,并把 Bundle ID 改成你自己的**(默认 `com.kaihongchen.sidekey` 属原作者,不能直接用你签名),然后选中你的 iPhone 点 ▶️ 运行。

## 协议 · Protocol (iPhone → 电脑, WebSocket JSON)

| 消息 Message | 作用 |
|---|---|
| `{"type":"key","code":"enter"}` | 敲一个键 · one key |
| `{"type":"key","code":"c","mods":["primary"]}` | 组合键(primary = mac Cmd / 其它 Ctrl)|
| `{"type":"key","mods":["ralt","rshift"]}` | 纯修饰键组合,支持左右区分 `ralt/rshift/rctrl/…` |
| `{"type":"key","code":"shift","action":"down"}` | 按住/松开(action: down\|up\|tap)|
| `{"type":"paste","text":"你好"}` | 剪贴板粘贴(可靠插入中英文,绕过输入法)|

键名表见 `server/sidekey_server.py` 顶部。

## 安全 · Security

服务端**默认开启令牌校验 + TLS 加密**:启动自动生成并记住一个 128‑bit 令牌和一张自签名证书,通过 `wss://` 传输;配对码里带证书指纹(SHA‑256),手机扫码后据此 **pin** 校验服务端,防局域网中间人。手填连接首连为 TOFU(首用即信,之后转严格 pin)。令牌/私钥以 `0600` 存于用户数据目录、默认不写日志。公网/不可信网络仍请谨慎。

## 许可 · License

**MIT** —— 见 [LICENSE.txt](LICENSE.txt)。

---

© 2026 Kaihong Chen
