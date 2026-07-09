# -*- mode: python ; coding: utf-8 -*-
# 把 Sidekey 电脑端打包成 macOS 的 Sidekey.app (windowed, 无终端窗口, 双击即用)。
# 用法: pyinstaller --noconfirm --clean SidekeyServer-mac.spec   (一般由 build_app.command 调用)
import os
from PyInstaller.utils.hooks import collect_all

datas, binaries = [], []
# 这些 pyobjc 框架是 pynput 注入按键 / 我们检查辅助功能权限时动态加载的, 显式声明免得被漏打。
hiddenimports = ['pyperclip', 'objc', 'CoreFoundation', 'Foundation',
                 'AppKit', 'Quartz', 'ApplicationServices']
# cryptography 显式收: 它的 import 都在函数里(惰性), 且自带 Rust/原生绑定 —— 不显式 collect 容易漏打,
# 导致打包后的 .app 在干净机器上启动到 load_or_create_tls 时崩(审计 H-5)。cffi 一并带上稳妥。
for _pkg in ('zeroconf', 'pynput', 'qrcode', 'PIL', 'cryptography', 'cffi', 'pystray'):
    _d, _b, _h = collect_all(_pkg)
    datas += _d
    binaries += _b
    hiddenimports += _h
hiddenimports += ['_cffi_backend']

_icon = 'sidekey.icns' if os.path.exists('sidekey.icns') else None

a = Analysis(
    ['sidekey_server.py'],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='Sidekey',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,                 # macOS 上别用 UPX, 会破坏签名/公证
    console=False,             # 无终端窗口, 双击即用
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,          # 跟随本机架构 (Apple Silicon = arm64)
    codesign_identity=None,    # 签名/公证在 sign_notarize_dmg.command 里单独做
    entitlements_file=None,
    icon=_icon,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='Sidekey',
)
app = BUNDLE(
    coll,
    name='Sidekey.app',
    icon=_icon,
    bundle_identifier='com.kaihongchen.sidekey.server',
    version='1.0.0',
    info_plist={
        'CFBundleName': 'Sidekey',
        'CFBundleDisplayName': 'Sidekey',
        'CFBundleShortVersionString': '1.0.0',
        'CFBundleVersion': '1',
        'LSMinimumSystemVersion': '12.0',
        'NSHighResolutionCapable': True,
        # 只在右上角菜单栏显示图标, 不进 Dock、不抢前台 (后台小助手, 双击即驻留菜单栏)。
        'LSUIElement': True,
        'LSApplicationCategoryType': 'public.app-category.utilities',
        # 近几年 macOS 也有"本地网络"隐私提示; 声明一下让提示清楚、mDNS 不被静默拦。
        'NSLocalNetworkUsageDescription': 'Sidekey 在局域网内接收手机 App 发来的按键。',
        'NSBonjourServices': ['_sidekey._tcp'],
    },
)
