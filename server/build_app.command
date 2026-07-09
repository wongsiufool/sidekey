#!/bin/bash
# 一键把 Sidekey 电脑端打包成 macOS 的 Sidekey.app (无终端窗口, 双击即用)。
# 本机需装 Python 3 (仅打包用; 打出来的 .app 给别人时对方不需要 Python)。双击本文件即可。
#
# 注意: 构建产物放到本地盘 ~/.sidekey-build。因为本项目可能在 NAS/外接卷上, 那种盘会给文件
#       加扩展属性, 让 macOS 的 codesign 报 "resource fork ... detritus not allowed" 而失败。
set -e
cd "$(dirname "$0")"
BUILD_DIR="$HOME/.sidekey-build"

echo "============================================"
echo "   Sidekey 电脑端  --  打包成 macOS .app"
echo "============================================"
echo

if ! command -v python3 >/dev/null 2>&1; then
  echo "[错误] 没找到 python3。请先装 Python 3 (brew install python, 或 python.org 下载)。"
  read -r -p "按回车关闭" _ </dev/tty 2>/dev/null || true; exit 1
fi

echo "[1/4] 生成应用图标 sidekey.icns ..."
ICON_SRC="../ios/Sidekey/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
if [ -f "$ICON_SRC" ]; then
  WORK="$(mktemp -d)"; ICONSET="$WORK/sidekey.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null 2>&1 || true
    d=$((s * 2))
    sips -z "$d" "$d" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || true
  done
  iconutil -c icns "$ICONSET" -o sidekey.icns >/dev/null 2>&1 && echo "      图标 OK" || echo "      (图标生成失败, 用默认图标)"
  rm -rf "$WORK"
else
  echo "      (没找到源图标, 用默认图标)"
fi

echo "[2/4] 创建打包用临时环境 .buildenv-mac ..."
python3 -m venv .buildenv-mac
./.buildenv-mac/bin/python -m pip install --upgrade pip >/dev/null

echo "[3/4] 安装依赖 + PyInstaller (首次较慢, 需联网, 请耐心等) ..."
./.buildenv-mac/bin/pip install -r requirements.txt pyinstaller >/dev/null

echo "[4/4] 打包中 (约 1-3 分钟; 产物放本地盘 $BUILD_DIR) ..."
rm -rf "$BUILD_DIR/build" "$BUILD_DIR/dist"
./.buildenv-mac/bin/pyinstaller --noconfirm --clean \
  --workpath "$BUILD_DIR/build" --distpath "$BUILD_DIR/dist" \
  SidekeyServer-mac.spec

echo
if [ -d "$BUILD_DIR/dist/Sidekey.app" ]; then
  rm -rf dist/Sidekey.app; mkdir -p dist
  cp -R "$BUILD_DIR/dist/Sidekey.app" dist/Sidekey.app 2>/dev/null || true
  echo "============================================"
  echo " [完成] 已生成 Sidekey.app:"
  echo "   · 本地盘(干净, 给签名用):  $BUILD_DIR/dist/Sidekey.app"
  echo "   · 项目内(方便自用):        ./dist/Sidekey.app"
  echo
  echo " 自己用: 右键 ./dist/Sidekey.app → 打开 (未签名只需这一次)。"
  echo " 发布给别人: 证书就绪后双击 sign_notarize_dmg.command 做签名+公证+打 dmg。"
  echo "============================================"
else
  echo " [失败] 没生成 Sidekey.app, 请把上面的报错截图发给开发者。"
  read -r -p "按回车关闭" _ </dev/tty 2>/dev/null || true; exit 1
fi
read -r -p "按回车关闭" _ </dev/tty 2>/dev/null || true
