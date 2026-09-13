#!/bin/bash
# 构建 SleepCat.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="SleepCat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/SleepCat "$APP/Contents/MacOS/SleepCat"

# 应用图标由代码绘制：先导出 .iconset，再用系统自带的 iconutil 转成 .icns
ICONSET="$(mktemp -d)/AppIcon.iconset"
.build/release/SleepCat --make-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>      <string>SleepCat</string>
    <key>CFBundleIdentifier</key>      <string>com.suink.sleepcat</string>
    <key>CFBundleName</key>            <string>SleepCat</string>
    <key>CFBundleDisplayName</key>     <string>SleepCat</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# 临时签名默认的「指定要求」是二进制哈希，改一次代码就变，辅助功能授权随之失效。
# 显式把指定要求写成只认应用 ID，授权就能跨构建、跨版本保留（和 diana 的做法一致）。
IDENTIFIER="com.suink.sleepcat"
codesign --force --sign - --identifier "$IDENTIFIER" \
    --requirements "=designated => identifier \"$IDENTIFIER\"" "$APP"
codesign --verify --strict "$APP"
echo "✅ 构建完成：$APP（运行：open $APP）"
