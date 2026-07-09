#!/usr/bin/env python3
"""
Sidekey 电脑小助手 (server)
======================
接收手机端通过局域网发来的按键事件，注入到本机键盘。跨 Windows / macOS。

协议 (手机 -> 电脑, JSON over WebSocket):
  {"v":1,"type":"hello","name":"iPhone"}          # 连接后打个招呼
  {"v":1,"type":"ping"}                            # 心跳, 服务端回 {"type":"pong"}
  {"v":1,"type":"key","code":"enter"}             # 敲一个键 (按下+松开)
  {"v":1,"type":"key","code":"c","mods":["primary"]}  # 组合键, primary= mac的Cmd / 其它的Ctrl
  {"v":1,"type":"key","code":"shift","action":"down"} # 按住/松开 (action: down|up|tap)
  {"v":1,"type":"text","text":"hello"}            # 直接输入一段文字
  # 预留: {"v":1,"type":"audio",...} 无线麦克风 (Phase 3)

协议 (电脑 -> 手机):
  {"type":"agent_status","agents":{"claude":{"state":"ready"},"codex":{"state":"busy"}}}
  # state: busy(在忙) / ready(该你了) / error(卡住) / offline(没在跑) —— 给手机端做状态灯
"""
import argparse
import asyncio
import atexit
import configparser
import errno
import glob
import hashlib
import ipaddress
import json
import logging
import os
import platform
import re
import secrets
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

import pyperclip
import qrcode
import websockets
from pynput.keyboard import Controller, Key, Listener
from pynput.mouse import Button, Controller as MouseController
from zeroconf import ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

# ----- 配置 -------------------------------------------------------------
HOST = None        # 绑所有接口的 IPv4+IPv6 双栈: asyncio 会为每个可用协议族各开一个监听 socket(v6 缺失也不崩)。
# 之前写死 "0.0.0.0" 只监听 IPv4, 但 mDNS/配对码会广播 IPv6 地址 → IPv6-only 网络扫了却连不上 (审计: Codex M-3)。
AUTH_DEADLINE = 10.0   # 需令牌时, 未认证连接最多存活的秒数, 防止白占连接/pusher (审计: Codex M-3)
PORT = 8765
PORT_FALLBACK_TRIES = 20   # 请求端口被占时, 从它起逐个 +1 往上探这么多个空闲端口 (端口自动切换)
TOKEN = None       # 设成一个字符串可开启简单配对校验; None = 局域网内不校验(仅自用)

# 连接保护 (默认开; 阈值很宽松, 正常用绝不会触发, 只挡洪泛/暴力破解):
ALLOWED_NETS = None        # None=不限制来源(默认); --allowed-ips 设成 ipaddress 网络列表后只放行其中来源
_conn_history = {}         # ip -> [最近连接时刻]; 限制单 IP 连接频率, 防连接洪泛
_authfail = {}             # ip -> {"n":失败次数, "first":窗口起点, "until":封禁到期}; 防令牌暴力破解
CONN_WINDOW, CONN_MAX = 10.0, 12                                # 10s 内单 IP 最多 12 次新连接
AUTHFAIL_WINDOW, AUTHFAIL_MAX, AUTHFAIL_BLOCK = 60.0, 6, 60.0   # 60s 内 6 次坏令牌 → 封该 IP 60s

# 纯修饰键点按(如 Typeless=左Ctrl)的保持时长(秒): press 紧跟 release 的零保持事件常被 macOS
# 合成事件层丢弃/合并, 观察者(Typeless 等)收不到完整的"按下→松开"。给个人不可感知的真实保持。
MODIFIER_TAP_HOLD = 0.06
# 普通按键也给一个短保持。全局热键监听器(截图工具等)比文本输入控件更容易漏掉零保持的合成事件。
KEY_TAP_HOLD = 0.06
SNIPASTE_BIN = "/Applications/Snipaste.app/Contents/MacOS/Snipaste"
SNIPASTE_CONFIG = os.path.expanduser("~/.snipaste/config.ini")
# -----------------------------------------------------------------------

logging.basicConfig(level=logging.INFO, format="%(asctime)s  %(message)s", datefmt="%H:%M:%S")
log = logging.getLogger("sidekey")

IS_MAC = platform.system() == "Darwin"
kb = Controller()
mouse = MouseController()

# 语义键名 -> pynput 的特殊键
SPECIAL_KEYS = {
    "enter": Key.enter, "return": Key.enter,
    "esc": Key.esc, "escape": Key.esc,
    "space": Key.space,
    "tab": Key.tab,
    "backspace": Key.backspace,
    "delete": Key.delete, "del": Key.delete,
    "up": Key.up, "down": Key.down, "left": Key.left, "right": Key.right,
    "home": Key.home, "end": Key.end,
    "pageup": Key.page_up, "pagedown": Key.page_down,
    "caps": Key.caps_lock,
    "vol_up": Key.media_volume_up, "vol_down": Key.media_volume_down,
    "mute": Key.media_volume_mute, "play": Key.media_play_pause,
    "next_track": Key.media_next, "prev_track": Key.media_previous,
}
for _i in range(1, 13):
    SPECIAL_KEYS[f"f{_i}"] = getattr(Key, f"f{_i}")

MAC_FUNCTION_VK = {
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
    "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
}

# 语义修饰键名 -> pynput 修饰键
MODIFIERS = {
    # 通用 (不区分左右)
    "shift": Key.shift,
    "ctrl": Key.ctrl, "control": Key.ctrl,
    "alt": Key.alt, "option": Key.alt,
    "cmd": Key.cmd, "win": Key.cmd, "super": Key.cmd, "meta": Key.cmd,
    "primary": Key.cmd if IS_MAC else Key.ctrl,  # 跨平台主修饰键
    # 区分左右 (做 右Alt+右Shift 这类组合用)
    "lshift": Key.shift_l, "rshift": Key.shift_r,
    "lctrl": Key.ctrl_l, "rctrl": Key.ctrl_r,
    "lalt": Key.alt_l, "ralt": Key.alt_r, "alt_gr": Key.alt_gr,
    "lcmd": Key.cmd_l, "rcmd": Key.cmd_r,
}


def resolve_key(code):
    """把语义键名解析成 pynput 能用的 Key 或单个字符。"""
    if not code:
        return None
    c = code.lower()
    if c in SPECIAL_KEYS:
        return SPECIAL_KEYS[c]
    if c in MODIFIERS:
        return MODIFIERS[c]
    if len(code) == 1:        # 单个可打印字符, 原样发送
        return code
    return None


# ---- 捕获(学习)按键: pynput Key -> 我们的键名 反查 ----
MOD_REVERSE = {
    Key.shift: "shift", Key.shift_l: "lshift", Key.shift_r: "rshift",
    Key.ctrl: "ctrl", Key.ctrl_l: "lctrl", Key.ctrl_r: "rctrl",
    Key.alt: "alt", Key.alt_l: "lalt", Key.alt_r: "ralt", Key.alt_gr: "alt_gr",
    Key.cmd: "cmd", Key.cmd_l: "lcmd", Key.cmd_r: "rcmd",
}
KEY_REVERSE = {
    Key.enter: "enter", Key.esc: "esc", Key.space: "space", Key.tab: "tab",
    Key.backspace: "backspace", Key.delete: "delete",
    Key.up: "up", Key.down: "down", Key.left: "left", Key.right: "right",
    Key.home: "home", Key.end: "end", Key.page_up: "pageup", Key.page_down: "pagedown",
}
for _i in range(1, 13):
    KEY_REVERSE[getattr(Key, f"f{_i}")] = f"f{_i}"
# macOS 虚拟键码 -> 字符 (US 布局; 让带修饰键的字母也能可靠识别)
MAC_VK = {0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
          11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2",
          20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "o",
          32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m"}


def _reverse_key(key):
    if key in KEY_REVERSE:
        return KEY_REVERSE[key]
    vk = getattr(key, "vk", None)
    if IS_MAC and vk in MAC_VK:
        return MAC_VK[vk]
    ch = getattr(key, "char", None)
    if ch and len(ch) == 1 and ch.isprintable():
        return ch.lower()
    return None


def capture_key(timeout=20):
    """阻塞监听, 捕获用户在电脑键盘上按下的一个键/组合, 返回 {'code','mods'} 或 None。"""
    held, maxheld, out, done = set(), set(), {}, threading.Event()

    def finish(code, mods):
        out["code"], out["mods"] = code, mods
        done.set()

    def on_press(key):
        if key in MOD_REVERSE:
            held.add(MOD_REVERSE[key])
            maxheld.update(held)
            return None
        code = _reverse_key(key)
        if code is not None:
            finish(code, sorted(held))
            return False
        return None

    def on_release(key):
        if key in MOD_REVERSE:
            held.discard(MOD_REVERSE[key])
            if not held and maxheld and not done.is_set():
                finish("", sorted(maxheld))   # 纯修饰键和弦
                return False
        return None

    listener = Listener(on_press=on_press, on_release=on_release)
    listener.start()
    ok = done.wait(timeout)
    listener.stop()
    return out if ok else None


def do_fn():
    """尽力合成一次 Fn 键 (仅 macOS, Quartz)。系统级 Fn 行为多半合成不出,
    但部分在事件层监听 Fn 的第三方程序可能能收到。"""
    if not IS_MAC:
        log.warning("Fn 键目前仅在 macOS 尝试")
        return
    try:
        import Quartz
        fn_flag = getattr(Quartz, "kCGEventFlagMaskSecondaryFn", 0x800000)
        for down in (True, False):
            ev = Quartz.CGEventCreateKeyboardEvent(None, 0x3F, down)  # 0x3F = kVK_Function
            if down:
                Quartz.CGEventSetFlags(ev, fn_flag)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)
        log.info("⌨️  Fn (尽力)")
    except Exception as e:  # noqa: BLE001
        log.error(f"Fn 注入失败: {e}")


def _snipaste_snip_hotkey_matches(code, mods):
    """Snipaste 的全局热键可能忽略合成键盘事件; 配置吻合时走它自己的 CLI。"""
    if not IS_MAC or mods or not code:
        return False
    vk = MAC_FUNCTION_VK.get(str(code).lower())
    if vk is None or not os.path.exists(SNIPASTE_BIN):
        return False
    cfg = configparser.ConfigParser()
    try:
        cfg.read(SNIPASTE_CONFIG, encoding="utf-8")
        value = cfg.get("Hotkey", "snip", fallback="")
    except Exception:  # noqa: BLE001
        return False
    return vk in [int(n) for n in re.findall(r"-?\d+", value)]


def try_snipaste_snip(code, mods):
    if not _snipaste_snip_hotkey_matches(code, mods):
        return False
    try:
        subprocess.Popen([SNIPASTE_BIN, "snip"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log.info(f"📸 Snipaste snip ({code})")
        return True
    except Exception as e:  # noqa: BLE001
        log.warning(f"Snipaste 触发失败, 退回按键注入: {e}")
        return False


def do_key(code, mods=None, action="tap"):
    if code and code.lower() == "fn":
        do_fn()
        return
    if action == "tap" and try_snipaste_snip(code, mods or []):
        return
    mod_keys = [MODIFIERS[m.lower()] for m in (mods or []) if m.lower() in MODIFIERS]
    key = resolve_key(code) if code else None         # 主键可选: 允许纯修饰键和弦
    if key is None and not mod_keys:
        log.warning(f"未知按键: {code!r}")
        return
    try:
        if action == "down":
            for m in mod_keys:
                kb.press(m)
            if key is not None:
                kb.press(key)
        elif action == "up":
            if key is not None:
                kb.release(key)
            for m in reversed(mod_keys):
                kb.release(m)
        else:  # tap: 按住修饰键 -> (按下+松开主键) -> 松开修饰键
            for m in mod_keys:
                kb.press(m)
            if key is not None:
                kb.press(key)
                time.sleep(KEY_TAP_HOLD)
                kb.release(key)
            elif mod_keys:
                # 纯修饰键和弦(如 Typeless=左Ctrl): 给一个真实保持时长, 否则零保持事件会被丢/合并。
                time.sleep(MODIFIER_TAP_HOLD)
            for m in reversed(mod_keys):
                kb.release(m)
        label = "+".join((mods or []) + ([code] if code else []))
        log.info("⌨️  " + label + (f" [{action}]" if action != "tap" else ""))
    except Exception as e:  # noqa: BLE001
        log.error(f"注入失败 ({code}): {e}")
        if IS_MAC:
            log.error("  → macOS 需要在「系统设置 > 隐私与安全性 > 辅助功能」给运行它的终端 (或 Python) 授权后重试。")


def do_text(text):
    try:
        kb.type(text)
        log.info(f"⌨️  text ({len(text)} 字)")   # 不记录正文, 避免日志泄露输入内容 (审计【高】)
    except Exception as e:  # noqa: BLE001
        log.error(f"输入文本失败: {e}")


def _mouse_button(name):
    return Button.right if str(name).lower() == "right" else Button.left


# 平滑滚动: macOS 用 Quartz 像素级滚轮事件 (比 pynput 整数"格"顺滑得多, 像真触控板); 非 mac 退回 pynput。
_SMOOTH_SCROLL = False
if IS_MAC:
    try:
        import Quartz  # pyobjc, 已随 AX 依赖装上
        _SMOOTH_SCROLL = True
    except Exception:  # noqa: BLE001
        _SMOOTH_SCROLL = False
_SCROLL_PX_PER_CLICK = 8        # 非 mac: 每 8 像素累积成 pynput 一"格"
_scroll_acc_x = 0.0
_scroll_acc_y = 0.0


def do_scroll(dx, dy):
    """滚动。dx,dy = 像素级增量 (符号同 pynput.mouse.scroll: 正 dy=向上)。
    macOS: Quartz 像素级平滑滚动; 其它平台: 把像素攒成整数"格"喂给 pynput。"""
    global _scroll_acc_x, _scroll_acc_y
    if _SMOOTH_SCROLL:
        try:
            # wheel1=纵向(dy)、wheel2=横向(dx); 正 dy=向上, 与 pynput.mouse.scroll 同号 —— 轴顺序与符号都不可乱改。
            ev = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitPixel, 2, int(dy), int(dx))
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)
            return
        except Exception as e:  # noqa: BLE001
            log.error(f"平滑滚动失败, 退回 pynput: {e}")
    # 非 mac / Quartz 不可用: pynput 是整数"格", 把像素攒够一格再发
    _scroll_acc_x += dx; _scroll_acc_y += dy
    cx = int(_scroll_acc_x / _SCROLL_PX_PER_CLICK)
    cy = int(_scroll_acc_y / _SCROLL_PX_PER_CLICK)
    if cx or cy:
        _scroll_acc_x -= cx * _SCROLL_PX_PER_CLICK
        _scroll_acc_y -= cy * _SCROLL_PX_PER_CLICK
        mouse.scroll(cx, cy)


def do_mouse(msg):
    """触控板/鼠标事件。action: move(dx,dy 相对) / click(button) / scroll(dx,dy) / down(button) / up(button)。"""
    action = (msg.get("action") or "").lower()
    try:
        if action == "move":
            dx = int(msg.get("dx", 0)); dy = int(msg.get("dy", 0))
            # 保险丝: 客户端已合并位移, 单条仍钳到 ±300px, 防极端 burst 把光标甩飞屏。
            dx = max(-300, min(300, dx)); dy = max(-300, min(300, dy))
            if dx or dy:
                mouse.move(dx, dy)
        elif action == "click":
            mouse.click(_mouse_button(msg.get("button", "left")), 1)
            log.info(f"🖱  click {msg.get('button', 'left')}")
        elif action == "scroll":
            dx = int(msg.get("dx", 0)); dy = int(msg.get("dy", 0))
            dx = max(-800, min(800, dx)); dy = max(-800, min(800, dy))   # 保险丝, 防极端 burst
            if dx or dy:
                do_scroll(dx, dy)
        elif action == "down":
            mouse.press(_mouse_button(msg.get("button", "left")))
            log.info(f"🖱  down {msg.get('button', 'left')}")
        elif action == "up":
            mouse.release(_mouse_button(msg.get("button", "left")))
            log.info(f"🖱  up {msg.get('button', 'left')}")
        else:
            log.warning(f"未知鼠标动作: {action!r}")
    except Exception as e:  # noqa: BLE001
        log.error(f"鼠标注入失败 ({action}): {e}")


async def do_paste(text):
    """把文字放进剪贴板再发「粘贴」快捷键, 可靠插入任意文字(含中文), 绕过输入法。
    返回 (ok, error): ok=False 时 error 是安全的简短原因码 (ax/clipboard/inject), 供手机端回执判断 (审计 M-5)。"""
    if not text:
        return True, None
    # macOS 未授权辅助功能时粘贴必然无效(pynput 静默失败, 不抛异常)→ 提前判定失败, 别让手机以为送达了。
    if IS_MAC and not accessibility_ok():
        log.error("粘贴失败: 未授权辅助功能")
        return False, "ax"
    previous = None    # None = 没读到(区别于「读到的是空」), 避免还原时把剪贴板清空 (审计复审 #6)
    try:
        previous = pyperclip.paste()
    except Exception:  # noqa: BLE001
        pass
    try:
        pyperclip.copy(text)
    except Exception as e:  # noqa: BLE001
        log.error(f"粘贴失败(剪贴板不可用): {e}")
        return False, "clipboard"
    try:
        await asyncio.sleep(0.05)
        mod = Key.cmd if IS_MAC else Key.ctrl
        kb.press(mod); kb.press("v"); kb.release("v"); kb.release(mod)
        log.info(f"📋 粘贴 ({len(text)} 字)")   # 不记录正文 (审计【高】)
        await asyncio.sleep(0.3)
        if previous is not None:   # 只有真读到了才还原; 读失败就别用空串覆盖用户剪贴板
            try:
                pyperclip.copy(previous)   # 尽量还原原来的剪贴板内容
            except Exception:  # noqa: BLE001
                pass
        return True, None
    except Exception as e:  # noqa: BLE001
        log.error(f"粘贴失败: {e}")
        if IS_MAC:
            log.error("  → 需要在「系统设置 > 隐私与安全性 > 辅助功能」给运行它的终端授权。")
        return False, "inject"


# ----- Agent 状态跟踪 ------------------------------------------------------
# 读本机 Claude Code / Codex 的会话文件, 推断每个 agent 是 busy(在忙)/ready(该你了)/error(卡住)/offline,
# 周期推给手机做状态灯。纯读本机自己 home 目录, 不需要系统授权。
# 隐私(审计【中】): 默认「仅元数据」—— 只看文件改动时间 mtime, **不读对话正文**;
# 只有手机端开「深度检测」(hello 带 statusDeep) 才会读会话尾部去判断 卡住/出错/项目名。
ENABLE_STATUS = True
CLAUDE_PROJECTS = os.path.expanduser("~/.claude/projects")
CODEX_SESSIONS = os.path.expanduser("~/.codex/sessions")
STATUS_INTERVAL = 3.0          # 多久推一次
BUSY_WINDOW = 10.0             # 会话文件这么多秒内被写过 = 还在忙
OFFLINE_WINDOW = 20 * 60       # 这么久没动静 = 没在跑(灯灭)
CODEX_ERROR_EVENTS = {"error", "stream_error", "turn_aborted"}
_status_cache = {}     # 按 "meta"/"deep" 分别缓存


def _newest_jsonl(root):
    """找 root 下最近被修改的 .jsonl (代表当前活跃的那个会话)。"""
    newest, newest_m = None, 0.0
    try:
        for dirpath, _dirs, files in os.walk(root):
            for fn in files:
                if not fn.endswith(".jsonl"):
                    continue
                p = os.path.join(dirpath, fn)
                try:
                    m = os.path.getmtime(p)
                except OSError:
                    continue
                if m > newest_m:
                    newest, newest_m = p, m
    except OSError:
        pass
    return newest, newest_m


def _tail_objects(path, max_bytes=65536):
    """读文件尾部 ~64KB 解析成 JSON 行 (丢掉可能被截断的首行)。"""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            data = f.read()
    except OSError:
        return []
    lines = data.decode("utf-8", "ignore").splitlines()
    if size > max_bytes and lines:
        lines = lines[1:]
    out = []
    for ln in lines:
        ln = ln.strip()
        if ln:
            try:
                out.append(json.loads(ln))
            except ValueError:
                continue
    return out


def _basename_of(cwd):
    return os.path.basename(str(cwd).rstrip("/\\")) if cwd else None


def _codex_status(deep=False):
    """Codex: deep 时看事件流 task_started/complete/报错/撞限额; 非 deep 只看 mtime (不读正文)。"""
    path, mtime = _newest_jsonl(CODEX_SESSIONS)
    if not path:
        return {"state": "offline"}
    if time.time() - mtime > OFFLINE_WINDOW:
        return {"state": "offline"}
    if not deep:                       # 隐私: 只看 mtime, 不打开会话内容
        return {"state": "busy" if time.time() - mtime < BUSY_WINDOW else "ready", "mtime": mtime}
    last_task, err, project = None, False, None
    for o in _tail_objects(path):
        t = o.get("type")
        if t == "session_meta":
            project = _basename_of((o.get("payload") or {}).get("cwd") or o.get("cwd")) or project
        elif t == "event_msg":
            p = o.get("payload") or {}
            pt = p.get("type")
            if pt == "task_started":
                last_task, err = "busy", False
            elif pt == "task_complete":
                last_task, err = "ready", False
            elif pt in CODEX_ERROR_EVENTS:
                err = True
            rl = p.get("rate_limits") or (p.get("info") or {}).get("rate_limits")
            if rl and (rl.get("primary") or {}).get("used_percent", 0) >= 100:
                err = True
    if err:
        state = "error"
    elif last_task:
        state = last_task
    else:
        state = "busy" if time.time() - mtime < BUSY_WINDOW else "ready"
    return {"state": state, "project": project, "mtime": mtime}


def _claude_status(deep=False):
    """Claude Code: deep 时看最后一条记录类型判断 busy/error; 非 deep 只看 mtime (不读正文)。"""
    path, mtime = _newest_jsonl(CLAUDE_PROJECTS)
    if not path:
        return {"state": "offline"}
    age = time.time() - mtime
    if age > OFFLINE_WINDOW:
        return {"state": "offline"}
    if not deep:                       # 隐私: 只看 mtime, 不打开会话内容
        return {"state": "busy" if age < BUSY_WINDOW else "ready", "mtime": mtime}
    last, project = None, None
    for o in _tail_objects(path):
        last = o
        project = _basename_of(o.get("cwd")) or project
    if last and (last.get("isApiErrorMessage") or last.get("type") == "error"):
        state = "error"
    elif (last or {}).get("type") == "user":
        state = "busy"                 # 你/工具结果刚回, 还没等到 Claude 回答 = 它在忙
    else:
        state = "busy" if age < BUSY_WINDOW else "ready"
    return {"state": state, "project": project, "mtime": mtime}


def compute_all_status(deep=False):
    """两个 agent 的状态; 2 秒内共享缓存 (按 deep 分桶), 避免每个连接各扫一遍文件。"""
    now = time.time()
    key = "deep" if deep else "meta"
    cached = _status_cache.get(key)
    if cached and now - cached["ts"] < 2.0:
        return cached["data"]
    agents = {"claude": _claude_status(deep), "codex": _codex_status(deep)}
    # 「当前活跃 agent」= 最近有动静(mtime 最新)的那个, 都没动静则 None。手机据此自动切显示。
    cand = [(a, d["mtime"]) for a, d in agents.items() if d.get("mtime")]
    active = max(cand, key=lambda x: x[1])[0] if cand else None
    data = {"agents": agents, "active": active}
    _status_cache[key] = {"ts": now, "data": data}
    return data


async def status_pusher(websocket, gate):
    """周期性把 agent 状态推给已认证的手机端 (电脑 -> 手机)。"""
    loop = asyncio.get_running_loop()
    while True:
        if ENABLE_STATUS and gate["authed"]:
            try:
                result = await loop.run_in_executor(None, compute_all_status, gate.get("deep", False))
                await websocket.send(json.dumps({
                    "type": "agent_status", "ts": int(time.time() * 1000),
                    "agents": result["agents"], "active": result["active"],
                    # 顺带把当前辅助功能授权状态推给手机: 运行中被撤销授权也能在 ~3s 内提示(不必等重连)。
                    "ax": accessibility_ok(),
                }))
            except websockets.ConnectionClosed:
                return
            except Exception as e:  # noqa: BLE001
                log.debug(f"状态推送失败: {e}")
        await asyncio.sleep(STATUS_INTERVAL)


def _parse_allowed_ips(spec):
    """把 "192.168.1.50,192.168.1.0/24" 解析成 ipaddress 网络列表; 全空/无效则 None(不限制)。"""
    nets = []
    for part in (spec or "").split(","):
        part = part.strip()
        if not part:
            continue
        try:
            nets.append(ipaddress.ip_network(part, strict=False))
        except ValueError:
            log.warning(f"--allowed-ips 忽略无法解析的项: {part!r}")
    return nets or None


def _peer_ip(peer):
    try:
        return str(ipaddress.ip_address(peer[0]))
    except (ValueError, TypeError, IndexError):
        return peer[0] if peer else ""


def _ip_allowed(ip):
    if ALLOWED_NETS is None:
        return True
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr in net for net in ALLOWED_NETS)


def _record_connection(ip, now):
    """记一次连接; 返回 True 表示该 IP 连接过于频繁(应拒绝)。"""
    hist = [t for t in _conn_history.get(ip, []) if now - t < CONN_WINDOW]
    hist.append(now)
    _conn_history[ip] = hist
    return len(hist) > CONN_MAX


def _auth_blocked(ip, now):
    info = _authfail.get(ip)
    return bool(info and info.get("until", 0) > now)


def _record_auth_fail(ip, now):
    info = _authfail.get(ip)
    if not info or now - info.get("first", now) > AUTHFAIL_WINDOW:
        info = {"n": 0, "first": now, "until": 0}
    info["n"] += 1
    if info["n"] >= AUTHFAIL_MAX:
        info["until"] = now + AUTHFAIL_BLOCK
        log.warning(f"🔒 {ip} 连续坏令牌 {info['n']} 次 → 封禁 {AUTHFAIL_BLOCK:.0f}s")
    _authfail[ip] = info


async def handler(websocket, path=None):
    peer = websocket.remote_address
    loop = asyncio.get_running_loop()
    t0 = loop.time()
    ip = _peer_ip(peer)
    now = loop.time()
    # 连接保护(白名单 / 暴力封禁 / 频率限制): 命中即在握手前关掉, 不进消息循环。
    if not _ip_allowed(ip):
        log.warning(f"⛔ 拒绝 {ip}: 不在 --allowed-ips 白名单")
        await websocket.close(code=1008, reason="not allowed"); return
    if _auth_blocked(ip, now):
        log.warning(f"⛔ 拒绝 {ip}: 失败认证过多, 暂时封禁中")
        await websocket.close(code=1008, reason="too many attempts"); return
    if _record_connection(ip, now):
        log.warning(f"⛔ 拒绝 {ip}: 连接过于频繁")
        await websocket.close(code=1013, reason="rate limited"); return
    log.info(f"📱 已连接: {peer}")
    gate = {"authed": TOKEN is None}
    pusher = None
    auth_timer = None
    try:
        await websocket.send(json.dumps({
            "type": "hello_ack", "ok": True,
            "platform": platform.system(), "needAuth": TOKEN is not None,
        }))
        pusher = asyncio.create_task(status_pusher(websocket, gate))
        if not gate["authed"]:
            # 未认证连接最多存活 AUTH_DEADLINE 秒就关掉, 别让没发/发不出 hello 的连接白占资源 (审计: Codex M-3)
            async def _auth_deadline():
                await asyncio.sleep(AUTH_DEADLINE)
                if not gate["authed"]:
                    log.warning(f"⛔ {ip}: {AUTH_DEADLINE:.0f}s 内未认证 → 关闭")
                    await websocket.close(code=1008, reason="auth timeout")
            auth_timer = asyncio.create_task(_auth_deadline())
        async for raw in websocket:
            try:
                msg = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                continue
            if not isinstance(msg, dict):   # 非 JSON object(数组/字符串/数字) → 忽略, 否则下面 msg.get 抛 AttributeError 崩掉本连接 (审计: Codex M-3)
                continue
            mtype = msg.get("type")
            if mtype == "hello":
                if TOKEN is not None and msg.get("token") != TOKEN:
                    _record_auth_fail(ip, loop.time())   # 计入暴力破解封禁
                    log.info("   🔒 令牌不符 → 拒绝")   # 不记录令牌值 (审计【高】)
                    await websocket.send(json.dumps({"type": "error", "message": "bad token"}))
                    await websocket.close()
                    return
                log.info("   ✅ 令牌通过")
                _authfail.pop(ip, None)                  # 认证成功 → 清掉该 IP 的失败计数
                gate["authed"] = True
                if auth_timer:
                    auth_timer.cancel()                  # 已认证, 撤掉未认证超时 (审计: Codex M-3)
                gate["deep"] = bool(msg.get("statusDeep"))   # 手机端「深度检测」开关: 默认 False=只读 mtime 不读正文
                # 鉴权后告诉手机「真正就绪」+ 能力(辅助功能是否已授权), 否则手机以为连上了其实按键全废。
                await websocket.send(json.dumps({
                    "type": "ready", "ax": accessibility_ok(), "platform": platform.system(),
                }))
            elif mtype == "ping":
                await websocket.send(json.dumps({"type": "pong"}))
            elif not gate["authed"]:
                await websocket.send(json.dumps({"type": "error", "message": "auth required"}))
            elif mtype == "key":
                do_key(msg.get("code"), msg.get("mods"), msg.get("action", "tap"))
            elif mtype == "text":
                do_text(msg.get("text", ""))
            elif mtype == "paste":
                ok, err = await do_paste(msg.get("text", ""))
                rid = msg.get("reqId")
                if rid is not None:   # 手机端要回执时才回 (审计 M-5: 失败让手机保留听写文本)
                    await websocket.send(json.dumps({"type": "result", "reqId": rid, "ok": ok, "error": err}))
            elif mtype == "mouse":
                do_mouse(msg)
            elif mtype == "capture_start":
                log.info("🎯 等待你在电脑键盘上按下要学习的键…(20秒内)")
                loop = asyncio.get_running_loop()
                result = await loop.run_in_executor(None, capture_key, 20)
                if result:
                    await websocket.send(json.dumps({
                        "type": "captured", "code": result["code"], "mods": result["mods"],
                    }))
                    combo = "+".join(result["mods"] + ([result["code"]] if result["code"] else []))
                    log.info(f"🎯 学到: {combo}")
                else:
                    await websocket.send(json.dumps({"type": "capture_failed"}))
                    log.info("🎯 捕获超时, 没抓到")
            # elif mtype == "audio": ...  # Phase 3: 写入虚拟声卡
    except websockets.ConnectionClosed:
        pass
    finally:
        if auth_timer:
            auth_timer.cancel()
        if pusher:
            pusher.cancel()
        # 兜底: 断开时释放可能还按着的鼠标键, 防止「按住左键拖动」中途断连导致电脑端左键卡死。
        for _btn in (Button.left, Button.right):
            try:
                mouse.release(_btn)
            except Exception:  # noqa: BLE001
                pass
        # 兜底: 同理释放所有可能仍按着的键盘修饰键 (key down/up 协议下, 按住 Shift/Ctrl/Cmd
        # 中途断连会污染电脑后续所有输入)。释放全部修饰键是幂等的, 没按下也无副作用。
        for _mod in set(MODIFIERS.values()):
            try:
                kb.release(_mod)
            except Exception:  # noqa: BLE001
                pass
        dt = loop.time() - t0
        log.info(f"❌ 断开: {peer}  存活 {dt:.2f}s  "
                 f"(close_code={websocket.close_code} reason={websocket.close_reason!r})")


def _ip_rank(ip):
    """越小越靠前: 真·私有 IPv4 优先 → 其它 v4 → IPv6(ULA→全局)→ VPN/基准段靠后。
    v4 排在 v6 前(更普遍可连); IPv6-only 网络下 v6 自然成为首选。"""
    if ":" in ip:                                  # IPv6
        return 6 if ip.lower().startswith(("fd", "fc")) else 7   # ULA 比全局略前
    if ip.startswith("192.168."):
        return 0
    if ip.startswith("10."):
        return 1
    octs = ip.split(".")
    if ip.startswith("172.") and len(octs) > 1 and octs[1].isdigit() and 16 <= int(octs[1]) <= 31:
        return 2
    if ip.startswith(("198.18.", "198.19.")):  # 基准测试段, 常是 VPN/虚拟网卡
        return 9
    return 5


def _usable_v4(ip):
    return not ip.startswith(("127.", "169.254."))


def _usable_v6(ip):
    """ULA / 全局 IPv6 可跨设备连; 排除回环 ::1、未指定 ::、链路本地 fe80::(需 zone id, 跨设备不可靠)。"""
    ip = ip.split("%")[0].lower()
    if ip in ("::1", "::") or ip.startswith("fe80"):
        return False
    return ":" in ip


def lan_ips():
    """收集本机可被手机连接的局域网地址 (IPv4 + IPv6, 审计 M-6)。"""
    v4, v6 = set(), set()
    # 方法1: 拿本机出口 IP (连一下外网地址, 不真正发包) —— v4 / v6 各试一次
    for fam, probe in ((socket.AF_INET, "8.8.8.8"), (socket.AF_INET6, "2001:4860:4860::8888")):
        try:
            s = socket.socket(fam, socket.SOCK_DGRAM)
            s.connect((probe, 80))
            (v4 if fam == socket.AF_INET else v6).add(s.getsockname()[0].split("%")[0])
            s.close()
        except OSError:
            pass
    # 方法2: 主机名解析 (通常能拿到真正的 Wi-Fi 地址), 两个地址族都要
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None):
            addr = info[4][0]
            if info[0] == socket.AF_INET:
                v4.add(addr)
            elif info[0] == socket.AF_INET6:
                v6.add(addr.split("%")[0])
    except OSError:
        pass
    usable = [ip for ip in v4 if _usable_v4(ip)] + [ip for ip in v6 if _usable_v6(ip)]
    return sorted(set(usable), key=lambda ip: (_ip_rank(ip), ip))


def _app_data_dir():
    """打包成 .app/.exe 后, 用一个稳定的用户目录存配对令牌。
    否则脚本目录是临时解压目录, 每次启动都会换令牌 -> 手机得反复重新配对。
    源码直接运行时仍用脚本所在目录, 方便开发。"""
    frozen = getattr(sys, "frozen", False)
    if frozen:
        if IS_MAC:
            base = os.path.expanduser("~/Library/Application Support/Sidekey")
        elif platform.system() == "Windows":
            base = os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "Sidekey")
        else:
            base = os.path.expanduser("~/.local/share/sidekey")
    else:
        base = os.path.dirname(os.path.abspath(__file__))
    try:
        os.makedirs(base, exist_ok=True)
    except OSError:
        base = tempfile.gettempdir()
        frozen = True   # 临时目录是我们专用的, 可以收紧
    # 只收紧「我们专用的数据目录」(打包后的 ~/.../Sidekey 或回退的临时目录)到 0700;
    # 源码运行时 base = 源码目录, 不去动用户的工程目录权限 (令牌/私钥本身仍各自 0600)。审计 H-4。
    if frozen:
        try:
            os.chmod(base, 0o700)
        except OSError:
            pass
    return base


def _write_secret(path, data: bytes):
    """把敏感内容(令牌/私钥)原子写入, 且文件权限 0600 —— 只有本人能读 (审计 H-4)。
    已存在的旧文件也顺手收紧权限, 修复早期版本留下的宽松权限。"""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


TOKEN_FILE = os.path.join(_app_data_dir(), ".sidekey_token")


def load_or_create_token(reset=False):
    """读取已记住的配对令牌; 没有或要求重置时生成一个新的并存下来。"""
    if not reset and os.path.exists(TOKEN_FILE):
        try:
            t = open(TOKEN_FILE, encoding="utf-8").read().strip()
            if t:
                try:
                    os.chmod(TOKEN_FILE, 0o600)   # 修复早期版本留下的宽松权限 (审计 H-4)
                except OSError:
                    pass
                return t
        except OSError:
            pass
    t = secrets.token_hex(16)  # 128-bit (32 位十六进制), 防暴力猜测 (审计【高】)
    try:
        _write_secret(TOKEN_FILE, t.encode("utf-8"))   # 0600, 别让同机其他账号读到令牌 (审计 H-4)
    except OSError:
        pass
    return t


CERT_FILE = os.path.join(_app_data_dir(), ".sidekey_cert.pem")
KEY_FILE = os.path.join(_app_data_dir(), ".sidekey_key.pem")
LOG_FILE = os.path.join(_app_data_dir(), "sidekey.log")   # 托盘(无控制台)模式把日志写这里


def _generate_self_signed(cert_path, key_path):
    """生成一张自签名证书 (P-256) 写到 cert_path/key_path。iOS 按指纹校验, 不靠域名。"""
    import datetime
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Sidekey")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder()
            .subject_name(name).issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=3650))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("sidekey.local")]), critical=False)
            .sign(key, hashes.SHA256()))
    # 私钥 0600: 泄露会削弱 TLS 身份保证, 只让本人可读 (审计 H-4)。证书是公开的, 普通写即可。
    _write_secret(key_path, key.private_bytes(serialization.Encoding.PEM,
                  serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))


def load_or_create_tls(reset=False):
    """读取/生成自签名 TLS 证书 (持久化 → 指纹稳定, 重启不用重配)。返回 (ssl_context, 指纹hex)。
    指纹 = 证书 DER 的 SHA-256, 放进配对码, iOS 据此 pin 校验服务端 (审计【高】wss)。"""
    if reset or not (os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE)):
        _generate_self_signed(CERT_FILE, KEY_FILE)
    else:
        try:
            os.chmod(KEY_FILE, 0o600)   # 修复早期版本留下的宽松私钥权限 (审计 H-4)
        except OSError:
            pass
    from cryptography import x509
    from cryptography.hazmat.primitives import serialization
    with open(CERT_FILE, "rb") as f:
        cert = x509.load_pem_x509_certificate(f.read())
    fp = hashlib.sha256(cert.public_bytes(serialization.Encoding.DER)).hexdigest()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(CERT_FILE, KEY_FILE)
    return ctx, fp


def _cleanup_qr_pngs():
    """删掉临时目录里遗留的配对二维码 PNG(含令牌)。启动时清旧的、退出时清本次的 —— 别让带令牌的图长期躺在 /tmp (审计复审 #5)。"""
    for p in glob.glob(os.path.join(tempfile.gettempdir(), "sidekey_pair_*.png")):
        try:
            os.unlink(p)
        except OSError:
            pass


_LAST_QR_PNG = None   # 最近一次生成的配对二维码 PNG 路径; 托盘菜单「显示二维码」据此重开


def show_qr(data):
    """终端打印二维码, 同时生成 PNG 并用系统看图打开(更好扫)。"""
    global _LAST_QR_PNG
    try:
        _cleanup_qr_pngs()    # 先清掉上次(可能被强杀)留下的带令牌图
        qr = qrcode.QRCode(border=2)
        qr.add_data(data)
        qr.make(fit=True)
        if sys.stdout is not None:    # 托盘(windowed)模式无控制台 → 跳过终端二维码, 只生成 PNG
            try:
                qr.print_ascii(invert=True)   # 终端里的二维码
            except Exception:  # noqa: BLE001
                pass
        img = qr.make_image(fill_color="black", back_color="white")
        # 二维码图含令牌: 用随机私有临时文件名 + 0600, 不再用固定可预测路径 (审计 H-4)。
        fd, path = tempfile.mkstemp(prefix="sidekey_pair_", suffix=".png")
        os.close(fd)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        img.save(path)
        _LAST_QR_PNG = path                 # 记下来, 托盘菜单可重新打开
        atexit.register(_cleanup_qr_pngs)   # 正常退出时也清掉本次的图(含令牌)
        if os.environ.get("SIDEKEY_NO_QR_OPEN"):
            log.info(f" 二维码图片已生成: {path}")
            return
        if IS_MAC:
            subprocess.Popen(["open", path])
        elif platform.system() == "Windows":
            os.startfile(path)  # type: ignore[attr-defined]  # noqa: S606
        else:
            subprocess.Popen(["xdg-open", path])
        log.info(f" 二维码图片已打开: {path}")
    except Exception as e:  # noqa: BLE001
        log.warning(f" 生成二维码图片失败(用上面终端里的二维码/手动配对码即可): {e}")


async def advertise(ips, port):
    """用 Bonjour/mDNS 在局域网广播本服务, 手机端就能自动发现。返回 AsyncZeroconf(需保活)。"""
    good = [ip for ip in ips if not ip.startswith(("198.18.", "198.19."))] or ips
    if not good:
        return None
    # 按地址族打包 (v4=4字节 / v6=16字节); zeroconf 据长度区分。坏地址跳过。审计 M-6。
    packed = []
    for ip in good:
        try:
            fam = socket.AF_INET6 if ":" in ip else socket.AF_INET
            packed.append(socket.inet_pton(fam, ip))
        except OSError:
            pass
    if not packed:
        return None
    try:
        host = socket.gethostname()
        safe = host.replace(".", "-")
        info = ServiceInfo(
            "_sidekey._tcp.local.",
            f"Sidekey-{safe}._sidekey._tcp.local.",
            addresses=packed,
            port=port,
            properties={"name": host},
            server=f"sidekey-{safe}.local.",
        )
        azc = AsyncZeroconf()
        await asyncio.wait_for(azc.async_register_service(info), timeout=10)
        log.info(f" 已在局域网广播 (mDNS): {host}  —— 手机可自动发现")
        return azc
    except Exception as e:  # noqa: BLE001
        log.warning(f" mDNS 广播失败(不影响手动/扫码连接): {e}")
        return None


def accessibility_ok():
    """macOS: 当前是否已获『辅助功能』授权 (只查询、不弹窗)。非 mac 恒 True。
    握手时报给手机, 让 iOS 在「已连接但没授权 → 按键全废」时给出阻断式提示 (审计【阻断】#2)。"""
    if not IS_MAC:
        return True
    if os.environ.get("SIDEKEY_FAKE_NO_AX"):   # 测试钩子: 强制报告未授权, 用来验证 iOS 阻断提示
        return False
    try:
        from ApplicationServices import AXIsProcessTrusted
        return bool(AXIsProcessTrusted())
    except Exception:  # noqa: BLE001
        return True


def ensure_macos_accessibility():
    """macOS: 注入按键需要『辅助功能』授权, 没授权会静默失败(打包后无终端, 用户毫无提示)。
    这里检查一次; 没授权就弹出系统标准提示, 并打开对应的设置面板。返回是否已授权。
    非 macOS 直接返回 True; 设环境变量 SIDEKEY_NO_AX_PROMPT 可跳过(测试/无人值守时用)。"""
    if not IS_MAC or os.environ.get("SIDEKEY_NO_AX_PROMPT"):
        return True
    try:
        from ApplicationServices import (
            AXIsProcessTrustedWithOptions,
            kAXTrustedCheckOptionPrompt,
        )
        trusted = bool(AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: True}))
        if not trusted:
            log.warning(" ⚠️  还没获得『辅助功能』授权 —— 已弹出系统提示。")
            log.warning("    打开『系统设置 > 隐私与安全性 > 辅助功能』, 把 Sidekey 的开关打开, 然后重启本应用。")
            try:
                subprocess.Popen([
                    "open",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                ])
            except Exception:  # noqa: BLE001
                pass
        return trusted
    except Exception as e:  # noqa: BLE001
        log.debug(f"辅助功能检查跳过: {e}")
        return True


def _is_addr_in_use(err):
    """跨平台判断「端口已被占用」: POSIX=EADDRINUSE, Windows=WSAEADDRINUSE(10048)。
    仅用于日志措辞 —— 判错也不影响行为(回退逻辑对任何 OSError 都会试下一个端口)。"""
    return err.errno == errno.EADDRINUSE or getattr(err, "winerror", None) == 10048


async def _serve_with_port_fallback(ssl_ctx, requested_port):
    """从 requested_port 起逐个尝试绑定 WebSocket 服务, 跳过被占用/不可用的端口。
    返回 (server, 实际绑定的端口)。连续 PORT_FALLBACK_TRIES 个端口都失败才抛 OSError。

    直接「真绑」而非「先探测再绑」: 绑成功就返回那个仍持有的监听 socket, 避免「探测时空闲、
    正式绑定时已被别人抢走」的竞态。调用方拿到真实端口后再去出二维码/广播 mDNS, 确保对外
    公布的端口和真正在监听的端口一致(修: 旧版先公布端口、最后才绑, 绑失败时静默挂个连不上的码)。"""
    last_err = None
    for i in range(PORT_FALLBACK_TRIES):
        candidate = requested_port + i
        if candidate > 65535:
            break
        try:
            server = await websockets.serve(handler, HOST, candidate, ssl=ssl_ctx, compression=None,
                                            ping_interval=20, ping_timeout=20, max_size=8 << 20)
            return server, candidate
        except OSError as e:
            last_err = e
            reason = "端口被占用" if _is_addr_in_use(e) else (e.strerror or str(e))
            log.warning(f" 端口 {candidate} 不可用({reason}); 自动试下一个…")
    raise OSError(f"从 {requested_port} 起连续 {PORT_FALLBACK_TRIES} 个端口都无法绑定") from last_err


async def main():
    global TOKEN, ENABLE_STATUS, ALLOWED_NETS
    parser = argparse.ArgumentParser(description="Sidekey 电脑小助手")
    parser.add_argument("--port", type=int, default=PORT, help=f"端口 (默认 {PORT})")
    parser.add_argument("--token", help="指定配对令牌 (默认自动生成并记住)")
    parser.add_argument("--reset-token", action="store_true", help="重置配对令牌 (手机需重新扫码)")
    parser.add_argument("--no-auth", action="store_true",
                        help="关闭配对校验 —— 危险! 同网任何人都能控制本机, 仅供隔离实验。需同时加 --i-understand-no-auth 才会启动")
    parser.add_argument("--i-understand-no-auth", action="store_true",
                        help="确认你明白 --no-auth 的风险 (二次确认, 防误开)")
    parser.add_argument("--show-pairing-code", action="store_true",
                        help="在日志里额外打印明文配对码与令牌 (默认不打印, 避免被日志/录屏收集; 需手动粘贴配对时才用)")
    parser.add_argument("--allowed-ips", default=None,
                        help="只允许这些来源连接 (逗号分隔, 支持 CIDR; 如 192.168.1.50,192.168.1.0/24)。默认不限制。")
    parser.add_argument("--no-status", action="store_true",
                        help="关闭 Agent 状态灯 (默认开; 读本机 Claude Code/Codex 会话状态推给手机)")
    parser.add_argument("--tray", action="store_true",
                        help="(Windows) 以右下角托盘图标运行, 不弹控制台窗口")
    parser.add_argument("--no-tray", action="store_true",
                        help="(Windows) 强制用普通控制台模式, 即使是 windowed 打包")
    args, _ = parser.parse_known_args()
    port = args.port

    if args.no_auth and not args.i_understand_no_auth:
        # 二次确认门 (审计危险开关): 防止误开「无配对」模式。需显式再加一个标志才放行。
        log.error("=" * 56)
        log.error(" ✋ 拒绝以 --no-auth 启动: 这会让同一局域网内任何人都能控制本机键盘/鼠标。")
        log.error("    如果你确实要在隔离/测试网络里这么做, 请改成:")
        log.error("       sidekey_server  --no-auth  --i-understand-no-auth   [--allowed-ips <白名单>]")
        log.error("    日常使用请直接启动(默认就有令牌+TLS, 不要加 --no-auth)。")
        log.error("=" * 56)
        sys.exit(2)

    if args.no_auth:
        TOKEN = None
    elif args.token:
        TOKEN = args.token
    else:
        TOKEN = load_or_create_token(reset=args.reset_token)
    ENABLE_STATUS = not args.no_status
    ALLOWED_NETS = _parse_allowed_ips(args.allowed_ips)
    ssl_ctx, cert_fp = load_or_create_tls(reset=args.reset_token)

    # 先把端口绑起来(被占就自动顺延到下一个空闲端口), 再用「真正绑上的端口」去出二维码/广播 mDNS。
    # 否则端口被占时会先公布一个其实没绑成功的端口、手机连了个寂寞(本次端口冲突 bug 的根因)。
    try:
        server, port = await _serve_with_port_fallback(ssl_ctx, port)
    except OSError as e:
        log.error("=" * 56)
        log.error(f" ✋ 启动失败: {e}")
        log.error("    端口都被占用了。请关掉占用这些端口的程序, 或用 --port 指定一个空闲端口后重启。")
        log.error("=" * 56)
        return

    ips = lan_ips()
    log.info("=" * 56)
    log.info(" Sidekey 电脑小助手已启动")
    log.info(f" 系统: {platform.system()}    端口: {port}")
    if port != args.port:
        log.info(f" ℹ️ 端口 {args.port} 被占用, 已自动改用 {port}(手机扫码/自动发现会带上新端口, 你无需手动改)")
    if TOKEN is None:
        log.warning(" ⚠️  未启用配对(--no-auth): 同一局域网内任何人都能控制本机键盘/鼠标!")
        log.warning("    强烈建议同时加 --allowed-ips 限定只放行你的手机 IP。仅在隔离/测试网络这样用。")
        for ip in ips:
            log.info(f"   手动填地址 →  {ip} : {port}")
    else:
        payload = json.dumps({"v": 1, "hosts": ips, "port": port, "token": TOKEN, "fp": cert_fp}, ensure_ascii=False)
        log.info(" 用手机 App 的「扫码配对」扫下面的二维码 ↓")
        show_qr(payload)
        # 默认不把明文配对码/令牌写进日志(会被日志采集、终端录屏、history 收走 → 等于泄露远控能力, 审计 H-4)。
        if args.show_pairing_code:
            log.info(f" 配对码(也可手动粘贴): {payload}")
            log.info(f" 令牌: {TOKEN}   (重置: 加 --reset-token 重启)")
        else:
            log.info(" (需要手动粘贴配对码? 用 --show-pairing-code 重启可显示明文令牌 —— 注意别外泄)")
    if ENABLE_STATUS:
        c_ok = "✓" if os.path.isdir(CLAUDE_PROJECTS) else "—"
        x_ok = "✓" if os.path.isdir(CODEX_SESSIONS) else "—"
        log.info(f" 🚦 Agent 状态灯: 开  (Claude {c_ok} / Codex {x_ok})  每 {STATUS_INTERVAL:.0f}s 推给手机")
    else:
        log.info(" 🚦 Agent 状态灯: 关 (--no-status)")
    log.info(f" 🔒 已启用 TLS(wss); 证书指纹 {cert_fp[:16]}…  (配对码已带, iOS 据此校验服务端)")
    if ALLOWED_NETS is None:
        log.info(" 🛡  来源限制: 关 (同一局域网内、持令牌的设备均可连; --allowed-ips 可加白名单)")
    else:
        log.info(f" 🛡  来源限制: 仅放行 {', '.join(str(n) for n in ALLOWED_NETS)}")
    log.info(" ⚠️  注意: 已配对(持令牌)的设备可完全控制本机键盘/鼠标 —— 只在你信任的网络/设备上配对。")
    log.info("=" * 56)
    ensure_macos_accessibility()        # macOS 没授权辅助功能就提示用户(打包后尤其重要)
    _azc = await advertise(ips, port)   # 保活: 局部变量在 main 一直运行期间不被回收
    # 服务已在 _serve_with_port_fallback 里绑好并开始监听(连接参数: compression=None 关 permessage-deflate
    # 让小 JSON 更顺; ping_interval/timeout 协议级心跳回收半死连接; max_size 8MB 给粘贴大段文本留足又防爆内存)。
    try:
        await asyncio.Future()  # 一直运行
    finally:
        server.close()
        await server.wait_closed()


# ----- 托盘 / 菜单栏模式 (Windows 右下角托盘 / macOS 右上角菜单栏, 都用 pystray) -----
def _setup_file_logging():
    """无控制台(托盘)时把日志写进 LOG_FILE —— 否则 stderr 为 None, 日志全丢、出错没法查。"""
    root = logging.getLogger()
    for h in list(root.handlers):   # 去掉 basicConfig 装的 StreamHandler(指向不存在的 stderr)
        root.removeHandler(h)
    try:
        fh = logging.FileHandler(LOG_FILE, encoding="utf-8")
        fh.setFormatter(logging.Formatter("%(asctime)s  %(message)s", datefmt="%H:%M:%S"))
        root.addHandler(fh)
    except OSError:
        pass
    root.setLevel(logging.INFO)


def _tray_icon_image():
    """用 Pillow(已是依赖)画一个简单的托盘图标: 蓝底圆角 + 白色钥匙形。"""
    from PIL import Image, ImageDraw
    size = 64
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([3, 3, size - 3, size - 3], radius=14, fill=(34, 102, 221, 255))
    # 钥匙: 一个圆环 + 一根柄
    d.ellipse([16, 16, 36, 36], outline=(255, 255, 255, 255), width=5)
    d.rectangle([24, 33, 29, 50], fill=(255, 255, 255, 255))
    d.rectangle([29, 44, 38, 49], fill=(255, 255, 255, 255))
    return img


def run_with_tray():
    """托盘/菜单栏模式: 后台线程跑 asyncio 服务, 主线程显示托盘(Win 右下角)/状态栏(mac 右上角)图标。
    没有窗口可关 → 服务只在点「退出」时才停, 满足"关窗口不丢服务"。pystray 在两个平台都用同一套菜单代码。"""
    import pystray

    def _server_thread():
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            loop.run_until_complete(main())
        except Exception as e:  # noqa: BLE001
            log.error(f"服务线程异常退出: {e}")

    threading.Thread(target=_server_thread, daemon=True, name="sidekey-server").start()

    def _open_path(path):
        """跨平台「用系统默认程序打开文件」: macOS=open / Windows=startfile / 其它=xdg-open。"""
        if not (path and os.path.exists(path)):
            return
        if IS_MAC:
            subprocess.Popen(["open", path])
        elif platform.system() == "Windows":
            os.startfile(path)  # type: ignore[attr-defined]  # noqa: S606
        else:
            subprocess.Popen(["xdg-open", path])

    def _show_qr(icon, item):
        _open_path(_LAST_QR_PNG)

    def _open_log(icon, item):
        _open_path(LOG_FILE)

    def _quit(icon, item):
        icon.stop()   # 主线程的 icon.run() 随之返回, 进程退出(守护线程一并结束)

    menu = pystray.Menu(
        pystray.MenuItem("显示配对二维码", _show_qr, default=True),
        pystray.MenuItem("打开日志", _open_log),
        pystray.MenuItem("退出 Sidekey", _quit),
    )
    icon = pystray.Icon("sidekey", _tray_icon_image(), "Sidekey 电脑小助手", menu)
    icon.run()   # 阻塞主线程直到 _quit


def _no_usable_console():
    """windowed(无终端)打包判定。不能再用 `sys.stdout is None` —— PyInstaller 6.x 在
    macOS noconsole 下把 sys.stdout 指向 /dev/null 的非 tty 流(不是 None), 旧判断会漏判成
    「有控制台」→ 不进菜单栏、不写日志(就是本次的 bug)。改判「没有可用的 tty 控制台」:
    stdout 为 None 或不是 tty 都算无控制台。源码从终端跑时 stdout 是 tty → False(配合下面
    frozen 一起, 源码运行永不自动托盘, 仍要 --tray)。"""
    out = sys.stdout
    if out is None:
        return True
    try:
        return not out.isatty()
    except Exception:  # noqa: BLE001  个别被替换的流对象没有 isatty
        return True


def _want_tray():
    """是否走托盘/菜单栏: Windows 右下角托盘 + macOS 右上角菜单栏(都用 pystray)。
    --no-tray 强制关, --tray 强制开; 否则在 windowed 打包(无可用控制台)时自动开。"""
    if platform.system() not in ("Windows", "Darwin"):
        return False
    if "--no-tray" in sys.argv:
        return False
    if "--tray" in sys.argv:
        return True
    return getattr(sys, "frozen", False) and _no_usable_console()


if __name__ == "__main__":
    if _want_tray():
        _setup_file_logging()
        try:
            run_with_tray()
        except Exception as e:  # noqa: BLE001  托盘起不来就退回普通模式, 不至于完全打不开
            log.error(f"托盘启动失败, 回退普通模式: {e}")
            try:
                asyncio.run(main())
            except KeyboardInterrupt:
                pass
    else:
        try:
            asyncio.run(main())
        except KeyboardInterrupt:
            print("\n再见 👋")
