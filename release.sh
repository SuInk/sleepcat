#!/bin/bash
# 一键发版：./release.sh 1.1.0
# 测试 → 构建 → 打包 → GitHub Release → 更新 homebrew-tap 的 Cask 并推送
#
# 可选环境变量：
#   TAP_DIR         homebrew-tap 仓库位置（默认 ~/project/homebrew-tap）
#   NOTES           更新说明文件；不给就让 GitHub 自动生成（没有 PR 时只有一个对比链接）
#   COMMIT_TRAILER  追加到发版提交信息末尾，比如 Co-Authored-By / Signed-off-by
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?用法: ./release.sh <版本号，如 1.1.0>}
TAP_DIR=${TAP_DIR:-$HOME/project/homebrew-tap}
CASK="$TAP_DIR/Casks/sleepcat.rb"
ZIP="SleepCat-$VERSION.zip"

[[ -f "$CASK" ]] || { echo "❌ 找不到 Cask：$CASK（可用 TAP_DIR=... 指定）"; exit 1; }
if [[ -n "$(git status --porcelain)" ]]; then
    echo "❌ 工作区有未提交的改动，先提交再发版"; exit 1
fi
if [[ -n "${NOTES:-}" && ! -f "$NOTES" ]]; then
    echo "❌ 找不到更新说明文件：$NOTES"; exit 1
fi

commit_message() {
    printf '%s' "$1"
    [[ -n "${COMMIT_TRAILER:-}" ]] && printf '\n\n%s' "$COMMIT_TRAILER"
    return 0
}

# 0. 测试不过不发
./test.sh

# 1. 更新版本号并构建
sed -E -i '' "s|(<key>CFBundleShortVersionString</key> +<string>)[^<]*|\1$VERSION|" build.sh
./build.sh

# 2. 打包 + 校验和
ditto -c -k --keepParent SleepCat.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "sha256: $SHA"

# 3. 提交版本号、创建 GitHub Release
git commit -qam "$(commit_message "Release $VERSION")"
git push -q
if [[ -n "${NOTES:-}" ]]; then
    gh release create "v$VERSION" "$ZIP" --title "SleepCat $VERSION" --notes-file "$NOTES"
else
    gh release create "v$VERSION" "$ZIP" --title "SleepCat $VERSION" --generate-notes
fi

# 4. 更新 Cask 并推送 tap
sed -E -i '' "s|^(  version \").*(\")$|\1$VERSION\2|; s|^(  sha256 \").*(\")$|\1$SHA\2|" "$CASK"
git -C "$TAP_DIR" pull -q --rebase
git -C "$TAP_DIR" commit -qam "$(commit_message "sleepcat $VERSION")"
git -C "$TAP_DIR" push -q

echo "✅ SleepCat $VERSION 发布完成"
echo "   https://github.com/SuInk/sleepcat/releases/tag/v$VERSION"
