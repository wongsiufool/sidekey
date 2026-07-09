#!/usr/bin/env python3
"""
Sidekey 服务端自动化测试 (审计「测试覆盖盲区」补)。
跑: server/.venv/bin/python -m pytest test_sidekey_server.py   (或 python -m unittest test_sidekey_server)

覆盖: 连接保护(白名单/限速/封禁)、按键/文本/鼠标注入(mock controller, 不真注入)、
粘贴回执分类(ax/clipboard/success)、IPv6 地址筛选+排序(M-6)、令牌与密钥文件权限。
不依赖真实 WebSocket/网络/系统注入。
"""
import importlib.util
import os
import stat
import tempfile
import unittest
from unittest import mock


def _load():
    spec = importlib.util.spec_from_file_location("sks_under_test", os.path.join(os.path.dirname(__file__), "sidekey_server.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


m = _load()


class _RecKb:
    """记录 press/release/type 调用的假键盘控制器。"""
    def __init__(self): self.events = []
    def press(self, k): self.events.append(("press", k))
    def release(self, k): self.events.append(("release", k))
    def type(self, t): self.events.append(("type", t))


class _RecMouse:
    def __init__(self): self.events = []
    def move(self, dx, dy): self.events.append(("move", dx, dy))
    def click(self, b, n): self.events.append(("click", b, n))
    def press(self, b): self.events.append(("press", b))
    def release(self, b): self.events.append(("release", b))
    def scroll(self, dx, dy): self.events.append(("scroll", dx, dy))


class ConnectionProtectionTests(unittest.TestCase):
    def setUp(self):
        m._conn_history.clear()
        m._authfail.clear()
        m.ALLOWED_NETS = None

    def test_allowlist_parse_and_match(self):
        self.assertIsNone(m._parse_allowed_ips(None))
        self.assertIsNone(m._parse_allowed_ips("   "))
        nets = m._parse_allowed_ips("192.168.1.50,10.0.0.0/24")
        self.assertEqual(len(nets), 2)
        m.ALLOWED_NETS = nets
        self.assertTrue(m._ip_allowed("192.168.1.50"))
        self.assertTrue(m._ip_allowed("10.0.0.7"))
        self.assertFalse(m._ip_allowed("192.168.1.51"))
        self.assertFalse(m._ip_allowed("8.8.8.8"))
        self.assertFalse(m._ip_allowed("not-an-ip"))

    def test_allowlist_none_allows_all(self):
        m.ALLOWED_NETS = None
        self.assertTrue(m._ip_allowed("8.8.8.8"))

    def test_connection_rate_limit(self):
        ip, now = "1.2.3.4", 1000.0
        blocked = False
        for i in range(m.CONN_MAX + 1):
            blocked = m._record_connection(ip, now + i * 0.01)
        self.assertTrue(blocked, "超过 CONN_MAX 应判为过于频繁")
        # 窗口过去后清零
        self.assertFalse(m._record_connection(ip, now + m.CONN_WINDOW + 100))

    def test_auth_bruteforce_block(self):
        ip, now = "5.6.7.8", 2000.0
        for i in range(m.AUTHFAIL_MAX):
            self.assertFalse(m._auth_blocked(ip, now + i))
            m._record_auth_fail(ip, now + i)
        self.assertTrue(m._auth_blocked(ip, now + m.AUTHFAIL_MAX), "达到 AUTHFAIL_MAX 应封禁")
        # 封禁期满解除
        self.assertFalse(m._auth_blocked(ip, now + m.AUTHFAIL_MAX + m.AUTHFAIL_BLOCK + 1))


class KeyInjectionTests(unittest.TestCase):
    def setUp(self):
        self.kb = _RecKb()
        m.kb = self.kb
        self.sleep_patcher = mock.patch.object(m.time, "sleep")
        self.sleep = self.sleep_patcher.start()
        self.addCleanup(self.sleep_patcher.stop)

    def test_normal_key(self):
        m.do_key("a", None, "tap")
        kinds = [e[0] for e in self.kb.events]
        self.assertIn("press", kinds)
        self.assertIn("release", kinds)
        self.sleep.assert_called_once_with(m.KEY_TAP_HOLD)

    def test_modifier_combo(self):
        m.do_key("c", ["primary"], "tap")
        # 至少有一次按下修饰键、一次按下主键
        self.assertGreaterEqual(len([e for e in self.kb.events if e[0] == "press"]), 2)

    def test_pure_modifier_holds(self):
        # 纯修饰键(无主键)应被接受并按下/松开修饰键 (Typeless=左Ctrl)
        m.do_key("", ["lctrl"], "tap")
        self.assertTrue(any(e[0] == "press" for e in self.kb.events))
        self.assertTrue(any(e[0] == "release" for e in self.kb.events))
        self.sleep.assert_called_once_with(m.MODIFIER_TAP_HOLD)

    def test_snipaste_hotkey_uses_cli_when_configured(self):
        with tempfile.TemporaryDirectory() as d:
            snipaste_bin = os.path.join(d, "Snipaste")
            snipaste_cfg = os.path.join(d, "config.ini")
            open(snipaste_bin, "w", encoding="utf-8").close()
            with open(snipaste_cfg, "w", encoding="utf-8") as f:
                f.write('[Hotkey]\nsnip="16777264, 122"\n')
            with (
                mock.patch.object(m, "IS_MAC", True),
                mock.patch.object(m, "SNIPASTE_BIN", snipaste_bin),
                mock.patch.object(m, "SNIPASTE_CONFIG", snipaste_cfg),
                mock.patch.object(m.subprocess, "Popen") as popen,
            ):
                m.do_key("f1", [], "tap")
        popen.assert_called_once()
        self.assertEqual(self.kb.events, [])
        self.sleep.assert_not_called()

    def test_unknown_key_no_crash(self):
        m.do_key("totally_not_a_key", None, "tap")  # 不应抛异常
        # 未知键且无修饰 → 不发任何事件
        self.assertEqual(self.kb.events, [])

    def test_text(self):
        m.do_text("hello")
        self.assertIn(("type", "hello"), self.kb.events)


class MouseInjectionTests(unittest.TestCase):
    def setUp(self):
        self.mouse = _RecMouse()
        m.mouse = self.mouse

    def test_move_clamped(self):
        m.do_mouse({"action": "move", "dx": 9999, "dy": -9999})
        moves = [e for e in self.mouse.events if e[0] == "move"]
        self.assertEqual(moves, [("move", 300, -300)])

    def test_click_down_up(self):
        m.do_mouse({"action": "click", "button": "right"})
        m.do_mouse({"action": "down", "button": "left"})
        m.do_mouse({"action": "up", "button": "left"})
        kinds = [e[0] for e in self.mouse.events]
        self.assertEqual(kinds, ["click", "press", "release"])

    def test_unknown_action_no_crash(self):
        m.do_mouse({"action": "frobnicate"})  # 不应抛异常
        self.assertEqual(self.mouse.events, [])

    def test_scroll_pynput_path(self):
        # 强制走非 mac 的 pynput 累积路径, 验证攒够像素后调用 mouse.scroll
        old = m._SMOOTH_SCROLL
        m._SMOOTH_SCROLL = False
        m._scroll_acc_x = 0.0
        m._scroll_acc_y = 0.0
        try:
            m.do_mouse({"action": "scroll", "dx": 0, "dy": 80})
            self.assertTrue(any(e[0] == "scroll" for e in self.mouse.events))
        finally:
            m._SMOOTH_SCROLL = old


class PasteReceiptTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.kb = _RecKb()
        m.kb = self.kb

    async def test_ax_denied(self):
        m.IS_MAC = True
        m.accessibility_ok = lambda: False
        ok, err = await m.do_paste("hi")
        self.assertEqual((ok, err), (False, "ax"))

    async def test_clipboard_failure(self):
        m.IS_MAC = False  # 跳过 AX 预检
        class Clip:
            @staticmethod
            def paste(): return ""
            @staticmethod
            def copy(t): raise RuntimeError("no clipboard")
        m.pyperclip = Clip
        ok, err = await m.do_paste("hi")
        self.assertEqual((ok, err), (False, "clipboard"))

    async def test_success(self):
        m.IS_MAC = False
        copied = []
        class Clip:
            @staticmethod
            def paste(): return "prev"
            @staticmethod
            def copy(t): copied.append(t)
        m.pyperclip = Clip
        ok, err = await m.do_paste("hello")
        self.assertEqual((ok, err), (True, None))
        self.assertIn("hello", copied)         # 注入了文字
        self.assertEqual(copied[-1], "prev")   # 之后还原了旧剪贴板

    async def test_empty_is_noop_success(self):
        ok, err = await m.do_paste("")
        self.assertEqual((ok, err), (True, None))


class IPv6Tests(unittest.TestCase):
    def test_usable_v4(self):
        self.assertTrue(m._usable_v4("192.168.1.5"))
        self.assertFalse(m._usable_v4("127.0.0.1"))
        self.assertFalse(m._usable_v4("169.254.1.1"))

    def test_usable_v6(self):
        self.assertTrue(m._usable_v6("fd00::1"))            # ULA
        self.assertTrue(m._usable_v6("2001:db8::1"))        # 全局
        self.assertFalse(m._usable_v6("::1"))               # 回环
        self.assertFalse(m._usable_v6("fe80::1"))           # 链路本地
        self.assertFalse(m._usable_v6("fe80::1%en0"))       # 链路本地带 zone

    def test_ip_rank_v4_before_v6(self):
        self.assertLess(m._ip_rank("192.168.1.5"), m._ip_rank("fd00::1"))
        self.assertLess(m._ip_rank("fd00::1"), m._ip_rank("2001:db8::1"))  # ULA 先于全局


class SecretFileTests(unittest.TestCase):
    def test_write_secret_0600(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, ".tok")
        m._write_secret(p, b"secret")
        with open(p) as f:
            self.assertEqual(f.read(), "secret")
        self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o600)
        # 覆盖写并收紧旧的宽松权限
        os.chmod(p, 0o644)
        m._write_secret(p, b"new")
        self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o600)

    def test_cleanup_qr_pngs(self):
        for n in ("sidekey_pair_aaa.png", "sidekey_pair_bbb.png"):
            open(os.path.join(tempfile.gettempdir(), n), "w").close()
        m._cleanup_qr_pngs()
        import glob
        self.assertEqual(glob.glob(os.path.join(tempfile.gettempdir(), "sidekey_pair_*.png")), [])


class PortFallbackTests(unittest.IsolatedAsyncioTestCase):
    """端口被占用时自动顺延到下一个空闲端口(端口自动切换), 空闲时用请求端口本身。"""

    async def test_falls_back_when_port_busy(self):
        import socket as _sock
        busy = _sock.socket(_sock.AF_INET, _sock.SOCK_STREAM)
        busy.bind(("", 0))          # 让 OS 给一个空闲端口
        busy.listen()
        busy_port = busy.getsockname()[1]
        try:
            server, actual = await m._serve_with_port_fallback(None, busy_port)
            try:
                self.assertNotEqual(actual, busy_port)   # 没用被占的那个
                self.assertGreater(actual, busy_port)     # 顺延向上找到空闲端口
            finally:
                server.close()
                await server.wait_closed()
        finally:
            busy.close()

    async def test_uses_requested_port_when_free(self):
        import socket as _sock
        probe = _sock.socket(_sock.AF_INET, _sock.SOCK_STREAM)
        probe.bind(("", 0))
        free_port = probe.getsockname()[1]
        probe.close()                # 端口空出来, 期望服务就绑在它上面
        server, actual = await m._serve_with_port_fallback(None, free_port)
        try:
            self.assertEqual(actual, free_port)
        finally:
            server.close()
            await server.wait_closed()


if __name__ == "__main__":
    unittest.main(verbosity=2)
