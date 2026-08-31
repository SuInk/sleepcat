#!/bin/bash
# 构建 SleepCat.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="SleepCat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/SleepCat "$APP/Contents/MacOS/SleepCat"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>      <string>SleepCat</string>
    <key>CFBundleIdentifier</key>      <string>local.diana.sleepcat</string>
    <key>CFBundleName</key>            <string>SleepCat</string>
    <key>CFBundleDisplayName</key>     <string>SleepCat</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "✅ 构建完成：$APP（运行：open $APP）"
