#!/bin/bash
# 重新生成 README 配图：./docs/make-images.sh
# 图标、菜单、灵动岛、清洁键盘面板都由应用自己的绘制代码画出来，再用无界面 Chrome 排版。
# 注意：生成菜单图时屏幕上会闪一下真实菜单，期间别动鼠标（鼠标停在菜单上会截到高亮行）。
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
[[ -x "$CHROME" ]] || { echo "❌ 找不到 Google Chrome（可用 CHROME=... 指定）"; exit 1; }

swift build -c release
BIN=.build/release/SleepCat
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

"$BIN" --dump-icons "$WORK"
"$BIN" --make-iconset "$WORK/icon.iconset"
# 用命令行参数指定菜单里展示的设置，不读也不改本机的偏好设置
"$BIN" --snapshot-menu "$WORK" \
    -lidBlockEnabled YES -keepDisplayOn NO -duoEnabled NO -duoBlurEnabled YES \
    -soundEnabled NO -lowBatteryThreshold 20

mkdir "$WORK/compose"
cp docs/images/src/*.html "$WORK/compose/"

shot() {  # shot <页面> <宽,高> <输出文件名>
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
        --default-background-color=00000000 --allow-file-access-from-files --virtual-time-budget=2000 \
        --window-size="$2" --screenshot="$PWD/docs/images/$3" "file://$WORK/compose/$1" >/dev/null 2>&1
}
shot menubar.html      648,364 menubar.png
shot "menu.html#light" 344,526 menu-light.png
shot "menu.html#dark"  344,526 menu-dark.png
shot features.html     888,262 features.png
cp "$WORK/icon.iconset/icon_512x512.png" docs/images/icon.png

echo "✅ 已更新 docs/images/"
