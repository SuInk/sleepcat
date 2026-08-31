# SleepCat 🐱

A cat in your menu bar that keeps your Mac awake — including with the lid closed.

菜单栏里的一只猫猫，喵住你的 Mac 不让它休眠，连合盖都能挡住。

| 状态 | 图标 | 含义 |
|---|---|---|
| 喵住中 | 😼 睁眼猫 | Mac 不休眠 |
| 打盹中 | 🐱💤 闭眼猫 + Zz | 允许正常休眠 |

## 功能

- **左键点猫猫**：一键开关防休眠（IOKit 电源断言，和 `caffeinate` 同机制）
- **右键菜单**：
  - ⏰ 定时喵住（15 分钟 ~ 4 小时 / 无限期），显示剩余时间
  - 🔒 **合盖也不休眠**：用 `pmset disablesleep` 挡住合盖强制休眠
  - 同时保持屏幕常亮（可选，默认只防系统休眠）
  - 音效：喵（代码合成）/ 呼噜（默认关闭）
- 模板图标，自动适配深浅色菜单栏
- 崩溃自愈：异常退出残留的"禁止休眠"状态会在下次启动时自动恢复

## 安装

```sh
brew tap suink/tap
brew trust suink/tap        # Homebrew 6 起第三方 tap 需要显式信任
brew install --cask sleepcat
xattr -dr com.apple.quarantine /Applications/SleepCat.app
```

（最后一步是因为应用只做了 ad-hoc 签名、未公证，不去掉 quarantine 标记会被 Gatekeeper 拦。）

或者从源码构建（需要 Xcode Command Line Tools）：

```sh
git clone https://github.com/SuInk/sleepcat.git
cd sleepcat && ./build.sh && open SleepCat.app
```

## 合盖模式的权限说明

合盖休眠是系统强制行为，电源断言挡不住，只能用 `pmset disablesleep`（需要 root）。SleepCat 提供两种方式：

1. **免密规则（推荐）**：授权一次，往 `/etc/sudoers.d/sleepcat` 写入一条 **只放行两条精确命令** 的规则：

   ```
   <你的用户名> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
   ```

   写入前用 `visudo -c` 校验语法。之后开关合盖防护完全静默。菜单里随时可卸载。

2. **每次输密码**：不装规则，每次切换弹系统管理员密码框。

⚠️ 喵住 + 合盖期间 Mac 仍在运行、会发热耗电，**放进背包前先停止喵住**。停止/退出时自动恢复正常休眠。

> 小知识：合盖后屏幕会关、再打开是锁屏界面——看起来像睡了，其实后台任务一直在跑。验证方法：合盖时放首歌，声音不停就是没睡。

## 系统要求

macOS 13+，Apple Silicon / Intel。

## License

MIT
