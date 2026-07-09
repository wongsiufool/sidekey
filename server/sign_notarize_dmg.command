#!/bin/bash
# 给 Sidekey.app 做: 代码签名(Developer ID) + 硬化运行时 + 公证 + 打成 Sidekey.dmg。
# 别人下载 dmg 双击即用, 不会被 Gatekeeper 拦。双击本文件即可运行。
#
# 一次性前提 (详见 README_macOS.txt 末尾):
#   1) 钥匙串已安装 "Developer ID Application: 你的名字 (TEAMID)" 证书。
#   2) 跑过一次 (把公证凭据存进钥匙串):
#        xcrun notarytool store-credentials sidekey-notary \
#          --apple-id 你的AppleID --team-id 你的TEAMID --password App专用密码
set -e
cd "$(dirname "$0")"

PROFILE="sidekey-notary"                    # 与上面 store-credentials 用的名字一致
ENT="$(pwd)/entitlements-mac.plist"
STAGE="$HOME/.sidekey-build/sign"

# 源 .app: 优先用本地盘 build 出来的(最干净), 否则用项目 ./dist 里的
SRC="$HOME/.sidekey-build/dist/Sidekey.app"
[ -d "$SRC" ] || SRC="dist/Sidekey.app"
[ -d "$SRC" ] || { echo "[错误] 找不到 Sidekey.app, 请先双击 build_app.command。"; read -r -p 按回车关闭 _ </dev/tty 2>/dev/null||true; exit 1; }

# 自动从钥匙串找 Developer ID 证书; 也可手动: export DEVID="完整证书名"
DEVID="${DEVID:-$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/')}"
if [ -z "$DEVID" ]; then
  echo "[错误] 钥匙串里没有 'Developer ID Application' 证书。"
  echo "       加入付费计划后到 developer.apple.com → Certificates 申请并安装该证书再重试。"
  read -r -p 按回车关闭 _ </dev/tty 2>/dev/null||true; exit 1
fi
echo "使用证书: $DEVID"
echo "源 app:   $SRC"

# 关键: 放到本地盘并清扩展属性, 否则 NAS/外接卷的 detritus 会让 codesign 拒签
echo "[1/6] 拷到本地盘并清扩展属性 ..."
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$SRC" "$STAGE/Sidekey.app"
xattr -cr "$STAGE/Sidekey.app"
APP="$STAGE/Sidekey.app"
DMG="$STAGE/Sidekey.dmg"

echo "[2/6] 给 .app 内所有 Mach-O 二进制签名 (按内容判断, 含无扩展名的 Python.framework 主程序) ..."
find "$APP/Contents" -type f -print0 | while IFS= read -r -d '' f; do
  if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then
    codesign --force --timestamp --options runtime --sign "$DEVID" "$f"
  fi
done

echo "[3/6] 给主程序 + .app 签名 (硬化运行时 + entitlements) ..."
codesign --force --timestamp --options runtime --entitlements "$ENT" --sign "$DEVID" "$APP/Contents/MacOS/Sidekey"
codesign --force --timestamp --options runtime --entitlements "$ENT" --sign "$DEVID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "[4/6] 打成 dmg (含『应用程序』拖拽快捷方式) ..."
rm -f "$DMG"
# set -e 守卫: 卸掉任何同名残留卷(含带空格的 'Sidekey 1'), -force 应对设备忙, || true 防中断
for v in "/Volumes/Sidekey" "/Volumes/Sidekey "*; do
  [ -d "$v" ] && hdiutil detach "$v" -force >/dev/null 2>&1 || true
done

# 本地盘(APFS 启动盘 $STAGE)新建干净 staging: app + 指向 /Applications 的绝对软链
DMGROOT="$STAGE/dmgroot"
rm -rf "$DMGROOT"; mkdir -p "$DMGROOT"
# cp -R(非 mv): 保留 $APP 原件, 只在本地盘内拷贝不引入 NAS detritus。
# 已签名 app 经 cp -R 后签名仍有效: cp -R 不解引用 bundle 内版本化软链(framework/Versions/Current),
# 仅带一个被 codesign 忽略的 com.apple.provenance xattr。严禁改用 cp -RL/会 deref 软链的拷贝方式, 否则破签名。
# 也绝不对 dmgroot 内的 app 跑 xattr -cr(provenance 是内核保护属性, 清不掉且本就不影响签名/公证, 写 app 反破坏被签封存资源)。
cp -R "$APP" "$DMGROOT/Sidekey.app"
# dmgroot 是本步新建空目录, 不会有同名 Applications; rm -f 仅作 set -e 下防御(ln 撞已存在目标会非零退出炸脚本)
rm -f "$DMGROOT/Applications"
ln -s /Applications "$DMGROOT/Applications"

# 一步式 UDZO 打包(无 UDRW->convert, 不丢签名): -fs HFS+ 固定文件系统避免 macOS 默认差异影响软链/根布局
hdiutil create -volname "Sidekey" -srcfolder "$DMGROOT" -fs HFS+ -ov -format UDZO "$DMG" >/dev/null

# 硬校验门: 确认 /Applications 软链确实入镜, 用 attach 回显的真实挂载点(勿硬编码 /Volumes/Sidekey, 同名卷会变 'Sidekey 1')。
# 用 sed 取整段 /Volumes 路径, 避免 awk '{print $NF}' 在带空格卷名上把 ' 1' 截断。
MP=$(hdiutil attach "$DMG" -nobrowse -noverify -noautoopen 2>/dev/null | grep -m1 /Volumes | sed -E 's#.*(/Volumes/.*)$#\1#')
if [ "$(readlink "$MP/Applications" 2>/dev/null)" = "/Applications" ]; then
  hdiutil detach "$MP" -force >/dev/null 2>&1 || true
else
  hdiutil detach "$MP" -force >/dev/null 2>&1 || true
  echo "[错误] dmg 内 Applications 软链缺失, 中止发版。"; exit 1
fi

# 签名作用于最终未被挂载占用的 dmg(已 detach), 顺序: codesign -> notarytool -> staple 全链路不变
codesign --force --timestamp --sign "$DEVID" "$DMG"
codesign --verify --verbose=2 "$DMG"

echo "[5/6] 上传公证 (Apple 审核, 约 1-5 分钟, 需联网) ..."
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "[6/6] 钉票据 + 复制成品回项目 dist ..."
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
# 发版前最后一道闸: 模拟下载者首次双击 dmg 时的 Gatekeeper 评估, 必须 accepted 才放行
if spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | grep -q "accepted"; then
  echo "      Gatekeeper: accepted ✔ (下载者双击不会被拦)"
else
  echo "[错误] Gatekeeper 校验未通过 —— 该 dmg 下载者可能被拦截, 已中止。"; exit 1
fi
mkdir -p dist; cp "$DMG" dist/Sidekey.dmg

echo "============================================"
echo " [完成] ./dist/Sidekey.dmg —— 已签名+公证, 可上传 GitHub Releases / 下载页。"
echo " 别人下载后双击 dmg → 把 Sidekey 拖进『应用程序』即用, 不会被拦。"
echo "============================================"
read -r -p 按回车关闭 _ </dev/tty 2>/dev/null||true
