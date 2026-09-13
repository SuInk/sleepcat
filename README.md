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
- 🏝️ **Duo 岛**：把 MacBook 刘海当灵动岛用（iPhone Duo 风格）——平时隐身，鼠标悬停到刘海或喵住状态变化时流畅展开成黑色胶囊，显示猫猫状态和剩余时间，点按直接切换；菜单可关
- 🌫️ **Duo 合盖模糊**：读取 MacBook 内置的铰链角度传感器（HID Sensor 0x20/0x8A），合盖过程中屏幕随角度实时渐变模糊 + 暗化（100° 起雾、40° 拉满），复刻 iPhone Duo 折叠时的液态玻璃效果；重新打开反向消散。只在盖子正在动的时候出现，停下 1 秒就淡出、合死立即撤掉，所以远程控制或外接键鼠时（盖子不动）完全不会挡住画面。只画在内建屏幕上。调试：`SleepCat --lid-angle` 打印实时角度
- 模板图标，自动适配深浅色菜单栏；按住 ⌘ 拖动可调整猫猫在菜单栏里的位置（位置会记住）
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

合盖休眠是系统强制行为，电源断言挡不住（Apple 在 `IOPMLib.h` 里写明了断言不管合盖），只能用 `pmset disablesleep`（需要 root）。

第一次开启「合盖也不休眠」时会请求一次管理员授权，往 `/etc/sudoers.d/sleepcat` 写入一条 **只放行两条精确命令** 的规则：

```
<你的用户名> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

写入前用 `visudo -c` 校验语法。之后开关合盖防护全程静默。移除规则：`sudo rm /etc/sudoers.d/sleepcat`，或 `brew uninstall --zap --cask sleepcat`。

⚠️ 喵住 + 合盖期间 Mac 仍在运行、会发热耗电，**放进背包前先停止喵住**。停止/退出时自动恢复正常休眠。

> 小知识：合盖后屏幕会关、再打开是锁屏界面——看起来像睡了，其实后台任务一直在跑。验证方法：合盖时放首歌，声音不停就是没睡。

## 系统要求

macOS 13+，Apple Silicon / Intel。

## License

MIT
