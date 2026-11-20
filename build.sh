#!/bin/bash
# 本地出包：xcodebuild 编出 arm64 未签名 .app，打成可自签/巨魔的 .ipa
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-Release}"
DERIVED="build"
APP="$DERIVED/Build/Products/$CONFIG-iphoneos/WBHub.app"

echo "==> 清理"
rm -rf "$DERIVED" Payload WBHub.ipa

echo "==> 编译（arm64，不签名）"
xcodebuild \
  -project WBHub.xcodeproj \
  -scheme WBHub \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  build

test -d "$APP" || { echo "构建产物缺失: $APP"; exit 1; }

echo "==> 打包 Payload"
mkdir -p Payload
cp -R "$APP" Payload/
# 巨魔/自签都不需要 _CodeSignature，有反而添乱
rm -rf Payload/WBHub.app/_CodeSignature
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName WB Hub" Payload/WBHub.app/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :MinimumOSVersion 15.0" Payload/WBHub.app/Info.plist 2>/dev/null || true

zip -qry WBHub.ipa Payload
rm -rf Payload

echo "==> 完成: $(pwd)/WBHub.ipa"
ls -lh WBHub.ipa

cat <<'TIP'

安装方式：
  巨魔 TrollStore  直接导入 WBHub.ipa（无需签名，权限最全）
  自签 Sideloadly / AltStore / Esign  用你的 Apple ID 签 WBHub.ipa
  企业签 / 个人证书  codesign -f -s "证书名" --entitlements WBHub/WBHub.entitlements Payload/WBHub.app

注意：Bundle ID 为 com.xiaoshuai.wbhub，与任何官方 App 不冲突。
TIP
