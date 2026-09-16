#!/bin/bash
# 一键发版：./release.sh 1.1.0
# 测试 → 构建 → 打包 → GitHub Release → 更新 homebrew-tap 的 Cask 并推送
#
# 可选环境变量：
#   TAP_DIR         homebrew-tap 仓库位置（默认 ~/project/homebrew-tap，不存在就临时克隆）
#   NOTES           更新说明文件，只写这一版的改动；开头会自动加上统一的「安装 / 升级」段落
#                   不给就让 GitHub 自动生成改动部分（没有 PR 时只有一个对比链接）
#   COMMIT_TRAILER  追加到发版提交信息末尾，比如 Co-Authored-By / Signed-off-by
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?用法: ./release.sh <版本号，如 1.1.0>}
TAP_DIR=${TAP_DIR:-$HOME/project/homebrew-tap}
if [[ ! -d "$TAP_DIR/.git" ]]; then
    # 本地没有 tap 仓库就临时克隆一份，发完删掉：不用为了发版在别处常驻一个副本
    TAP_DIR="$(mktemp -d)/homebrew-tap"
    trap 'rm -rf "$(dirname "$TAP_DIR")"' EXIT
    echo "本地没有 homebrew-tap，临时克隆到 $TAP_DIR"
    gh repo clone SuInk/homebrew-tap "$TAP_DIR" -- -q
fi
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
CHANNEL=release ./build.sh

# 2. 打包 + 校验和
ditto -c -k --keepParent SleepCat.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "sha256: $SHA"

# 3. 提交版本号、创建 GitHub Release（一行命令安装排第一：不需要先装 Homebrew）
git commit -qam "$(commit_message "Release $VERSION")"
git push -q
BODY=$(mktemp)
cat > "$BODY" <<'MD'
## 安装 / 升级

打开「终端」粘贴运行，安装和升级都是这一行（不需要 Homebrew）：

```sh
curl -fsSL https://raw.githubusercontent.com/SuInk/sleepcat/main/install.sh | bash
```

用 Homebrew 的话：`brew install suink/tap/sleepcat`，升级 `brew upgrade suink/tap/sleepcat`。完整安装、更新、卸载说明见 [README](https://github.com/SuInk/sleepcat#安装)。

MD
if [[ -n "${NOTES:-}" ]]; then
    cat "$NOTES" >> "$BODY"
    gh release create "v$VERSION" "$ZIP" --title "SleepCat $VERSION" --notes-file "$BODY"
else
    gh release create "v$VERSION" "$ZIP" --title "SleepCat $VERSION" --notes-file "$BODY" --generate-notes
fi
rm -f "$BODY"

# 4. 更新 Cask 并推送 tap（先拉再改：改完再拉会因为有未提交改动被 git 拒绝）
git -C "$TAP_DIR" pull -q --rebase
sed -E -i '' "s|^(  version \").*(\")$|\1$VERSION\2|; s|^(  sha256 \").*(\")$|\1$SHA\2|" "$CASK"
git -C "$TAP_DIR" -c core.hooksPath="$PWD/.githooks" commit -qam "$(commit_message "sleepcat $VERSION")"
git -C "$TAP_DIR" push -q

echo "✅ SleepCat $VERSION 发布完成"
echo "   https://github.com/SuInk/sleepcat/releases/tag/v$VERSION"
