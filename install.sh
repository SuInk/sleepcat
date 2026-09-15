#!/bin/bash
# SleepCat 一键安装（不需要 Homebrew）：
#   curl -fsSL https://raw.githubusercontent.com/SuInk/sleepcat/main/install.sh | bash
#
# 可选环境变量（写在 bash 前面，比如 ... | SLEEPCAT_VERSION=1.1.0 bash）：
#   SLEEPCAT_VERSION   装指定版本，默认最新
#   SLEEPCAT_APP_DIR   安装目录，默认 /Applications
#   SLEEPCAT_NO_OPEN   设了就装完不自动打开
#
# 只用 macOS 自带的工具（curl、shasum、ditto），兼容系统自带的 bash 3.2。
set -euo pipefail

REPO="SuInk/sleepcat"
APP_NAME="SleepCat.app"
APP_DIR="${SLEEPCAT_APP_DIR:-/Applications}"
DEST="$APP_DIR/$APP_NAME"

say() { printf '🐱 %s\n' "$*"; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "SleepCat 只支持 macOS"
macos=$(sw_vers -productVersion)
(( ${macos%%.*} >= 13 )) || die "需要 macOS 13 Ventura 及以上，当前是 $macos"

# Homebrew 装过的就该用 Homebrew 升级：直接覆盖会让 brew 记录的版本和实际装的对不上
if [[ "$DEST" == "/Applications/$APP_NAME" ]]; then
    for caskroom in /opt/homebrew/Caskroom/sleepcat /usr/local/Caskroom/sleepcat; do
        [[ -d "$caskroom" ]] && die "SleepCat 是用 Homebrew 装的，请改用：brew upgrade suink/tap/sleepcat"
    done
fi

if [[ -n "${SLEEPCAT_VERSION:-}" ]]; then
    api="https://api.github.com/repos/$REPO/releases/tags/v${SLEEPCAT_VERSION#v}"
else
    api="https://api.github.com/repos/$REPO/releases/latest"
fi

say "正在查询版本…"
json=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api") \
    || die "查不到版本信息：检查网络，或者确认版本号 ${SLEEPCAT_VERSION:-} 存在"

# 不依赖 jq：把 JSON 按逗号拆成行再挑字段。每个版本只发布一个 zip，所以取第一个就是它。
# 用 awk 而不是 head 取第一行：head 提前退出会让上游收到 SIGPIPE，配合 pipefail 会误判失败
tag=$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | awk 'NR == 1')
url=$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"browser_download_url": *"\([^"]*SleepCat-[^"]*\.zip\)".*/\1/p' | awk 'NR == 1')
digest=$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"digest": *"sha256:\([0-9a-f]*\)".*/\1/p' | awk 'NR == 1')
[[ -n "$tag" && -n "$url" ]] || die "这个版本里没有可下载的安装包"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "下载 SleepCat ${tag#v}…"
curl -fL --progress-bar -o "$tmp/SleepCat.zip" "$url" || die "下载失败，检查一下网络"

if [[ -n "$digest" ]]; then
    actual=$(shasum -a 256 "$tmp/SleepCat.zip" | awk '{print $1}')
    [[ "$actual" == "$digest" ]] || die "校验失败：下载到的文件和发布的不一致，已停止安装"
    say "校验通过"
else
    say "这个版本没有提供校验值，跳过校验"
fi

ditto -x -k "$tmp/SleepCat.zip" "$tmp/unpacked" || die "解压失败"
[[ -d "$tmp/unpacked/$APP_NAME" ]] || die "安装包里没有 $APP_NAME"

# 要打开新版，就先正常退出旧的：喵住状态会保留，也免得菜单栏出现两只猫
if [[ -z "${SLEEPCAT_NO_OPEN:-}" ]] && pgrep -x SleepCat >/dev/null; then
    say "先退出正在运行的 SleepCat…"
    osascript -e 'quit app "SleepCat"' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -x SleepCat >/dev/null || break
        sleep 0.25
    done
fi

mkdir -p "$APP_DIR" 2>/dev/null || true
[[ -w "$APP_DIR" ]] || die "没有权限写入 $APP_DIR，可以装到自己的目录：SLEEPCAT_APP_DIR=~/Applications"
rm -rf "$DEST"
ditto "$tmp/unpacked/$APP_NAME" "$DEST"
# curl 下载的文件本来就不带隔离标记，这里只是保险：确保第一次打开不会被系统拦下
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
say "已安装到 $DEST"

if [[ -z "${SLEEPCAT_NO_OPEN:-}" ]]; then
    open "$DEST"
    say "完成！菜单栏里的小黑猫就是它：左键开关喵住，右键打开菜单"
else
    say "完成！"
fi
