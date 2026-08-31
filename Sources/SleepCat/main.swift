import AppKit
import IOKit.pwr_mgt

// MARK: - 电源断言管理（真正"喵住"Mac 的部分）

final class SleepBlocker {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    /// keepDisplayOn: true = 屏幕也常亮；false = 只阻止系统休眠（屏幕可以关）
    func start(keepDisplayOn: Bool) {
        stop()
        let type = keepDisplayOn
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "SleepCat is keeping your Mac awake" as CFString,
            &assertionID
        )
        isActive = (result == kIOReturnSuccess)
    }

    func stop() {
        if isActive {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isActive = false
        }
    }
}

// MARK: - 应用主体

final class SleepCatApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let blocker = SleepBlocker()
    private let lidBlocker = LidBlocker()
    private var offTimer: Timer?
    private var menuRefreshTimer: Timer?
    private var deadline: Date?

    // 偏好
    private var keepDisplayOn: Bool {
        get { UserDefaults.standard.bool(forKey: "keepDisplayOn") }
        set { UserDefaults.standard.set(newValue, forKey: "keepDisplayOn") }
    }
    private var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }
    private var lidBlockEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "lidBlockEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "lidBlockEnabled") }
    }
    private var lidWarningShown: Bool {
        get { UserDefaults.standard.bool(forKey: "lidWarningShown") }
        set { UserDefaults.standard.set(newValue, forKey: "lidWarningShown") }
    }
    /// 归属标记：disablesleep=1 是不是我们设置的（区分用户/其他工具自己开的）
    private var lidSetByUs: Bool {
        get { UserDefaults.standard.bool(forKey: "lidSetByUs") }
        set { UserDefaults.standard.set(newValue, forKey: "lidSetByUs") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // 崩溃自愈：上次是我们禁用了休眠但没恢复（崩溃/强退），免密可用时静默恢复
        if lidBlocker.isActive && lidSetByUs {
            lidBlocker.trySilentRestore()
            if !lidBlocker.isActive { lidSetByUs = false }
        }
        updateIcon()
    }

    // 左键：直接切换开关；右键：弹菜单
    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            toggle()
        }
    }

    private func toggle() {
        if blocker.isActive {
            deactivate()
        } else {
            activate(duration: nil)
        }
    }

    /// duration 为 nil 表示无限期
    private func activate(duration: TimeInterval?) {
        blocker.start(keepDisplayOn: keepDisplayOn)
        if lidBlockEnabled {
            if let err = lidBlocker.set(true) {
                showLidError("合盖防休眠没有生效", err)  // 只挡住了闲置休眠
            } else {
                lidSetByUs = true
            }
        }
        offTimer?.invalidate()
        if let duration {
            deadline = Date().addingTimeInterval(duration)
            offTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.deactivate()
            }
        } else {
            deadline = nil
        }
        playSound(awake: true)
        updateIcon()
    }

    private func deactivate() {
        blocker.stop()
        restoreLidSleepIfNeeded()
        offTimer?.invalidate()
        offTimer = nil
        deadline = nil
        playSound(awake: false)
        updateIcon()
    }

    private func playSound(awake: Bool) {
        guard soundEnabled else { return }
        if awake {
            MeowSound.play()                 // 醒来喵一声！
        } else {
            NSSound(named: "Purr")?.play()   // 去睡时呼噜~
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = blocker.isActive ? CatIcon.awake : CatIcon.asleep
        button.toolTip = blocker.isActive
            ? "SleepCat：正在喵住你的 Mac（点击放它去睡）"
            : "SleepCat：猫猫在打盹，Mac 可以正常休眠（点击叫醒）"
    }

    // MARK: 菜单

    private func showMenu() {
        let menu = NSMenu()

        var statusTitle: String
        if blocker.isActive {
            if let deadline {
                statusTitle = "😼 喵住中 · 还剩 \(Self.format(deadline.timeIntervalSinceNow))"
            } else {
                statusTitle = "😼 喵住中 · 无限期"
            }
            if lidBlocker.isActive { statusTitle += " · 含合盖" }
        } else {
            statusTitle = "🐱 打盹中 · 允许 Mac 休眠"
            if lidBlocker.isActive { statusTitle = "⚠️ 系统休眠仍被禁用（pmset disablesleep）" }
        }
        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        if blocker.isActive {
            menu.addItem(makeItem("💤 放猫猫去睡（停止）", #selector(menuDeactivate)))
        } else {
            menu.addItem(makeItem("☕️ 无限期喵住", #selector(menuActivateForever)))
        }

        let timedMenu = NSMenu()
        for (label, minutes) in [("15 分钟", 15), ("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("4 小时", 240)] {
            let item = makeItem(label, #selector(menuActivateTimed(_:)))
            item.tag = minutes
            timedMenu.addItem(item)
        }
        let timedRoot = NSMenuItem(title: "⏰ 定时喵住", action: nil, keyEquivalent: "")
        menu.addItem(timedRoot)
        menu.setSubmenu(timedMenu, for: timedRoot)

        menu.addItem(.separator())

        let displayItem = makeItem("同时保持屏幕常亮", #selector(toggleDisplaySetting))
        displayItem.state = keepDisplayOn ? .on : .off
        menu.addItem(displayItem)

        let lidItem = makeItem("🔒 合盖也不休眠", #selector(toggleLidSetting))
        lidItem.state = lidBlockEnabled ? .on : .off
        menu.addItem(lidItem)

        let hasFreePass = lidBlocker.freePassInstalled()
        let fpItem = makeItem(
            hasFreePass ? "卸载合盖免密规则" : "安装合盖免密规则（一次授权）",
            #selector(toggleFreePass)
        )
        fpItem.indentationLevel = 1
        menu.addItem(fpItem)

        let soundItem = makeItem("音效：喵 / 呼噜 🔉", #selector(toggleSoundSetting))
        soundItem.state = soundEnabled ? .on : .off
        menu.addItem(soundItem)

        menu.addItem(.separator())
        menu.addItem(makeItem("退出 SleepCat", #selector(quit), key: "q"))

        // 弹出菜单期间每秒刷新剩余时间
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // 用完摘掉，否则左键也会弹菜单
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        if m > 0 { return "\(m) 分钟" }
        return "\(s) 秒"
    }

    @objc private func menuActivateForever() { activate(duration: nil) }
    @objc private func menuDeactivate() { deactivate() }

    @objc private func menuActivateTimed(_ sender: NSMenuItem) {
        activate(duration: TimeInterval(sender.tag * 60))
    }

    @objc private func toggleDisplaySetting() {
        keepDisplayOn.toggle()
        if blocker.isActive {
            blocker.start(keepDisplayOn: keepDisplayOn)  // 立即按新设置重挂断言
        }
    }

    @objc private func toggleSoundSetting() { soundEnabled.toggle() }

    @objc private func toggleLidSetting() {
        if !lidBlockEnabled {
            // 只要免密规则还没装，开启时就给安装机会（不再只弹一次）
            if !lidBlocker.freePassInstalled() {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "开启「合盖也不休眠」？"
                alert.informativeText = """
                合盖休眠是系统强制行为，需要管理员权限执行 pmset disablesleep 才能关掉。

                推荐安装"免密规则"：往 /etc/sudoers.d/sleepcat 写一条只放行这条 pmset 命令的规则，授权一次，之后开关合盖防护完全静默。不装的话每次开关都要输一次密码。

                ⚠️ 注意：喵住期间合上盖子，Mac 仍在运行、会发热耗电。放进背包前请先点猫猫停止。停止喵住 / 退出时会自动恢复正常休眠。
                """
                alert.addButton(withTitle: "安装免密规则并开启")
                alert.addButton(withTitle: "开启（每次输密码）")
                alert.addButton(withTitle: "取消")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    if let err = lidBlocker.installFreePass() {
                        showLidError("免密规则安装失败", "\(err)\n\n仍可以用每次输密码的方式。")
                    } else {
                        syncLidStateAfterFreePass()
                    }
                case .alertSecondButtonReturn:
                    break
                default:
                    return
                }
                lidWarningShown = true
            }
            lidBlockEnabled = true
            if blocker.isActive {
                if let err = lidBlocker.set(true) {
                    showLidError("合盖防休眠没有生效", err)
                } else {
                    lidSetByUs = true
                }
            }
        } else {
            lidBlockEnabled = false
            restoreLidSleepIfNeeded()
        }
    }

    @objc private func toggleFreePass() {
        if lidBlocker.freePassInstalled() {
            if let err = lidBlocker.removeFreePass() {
                showLidError("免密规则卸载失败", err)
            }
        } else {
            if let err = lidBlocker.installFreePass() {
                showLidError("免密规则安装失败", err)
            } else {
                syncLidStateAfterFreePass()
            }
        }
    }

    /// 免密规则装好后，把系统 disablesleep 对齐到当前应有的状态（全程静默）
    private func syncLidStateAfterFreePass() {
        if blocker.isActive && lidBlockEnabled {
            if lidBlocker.set(true) == nil { lidSetByUs = true }
        } else if lidBlocker.isActive && lidSetByUs {
            lidBlocker.trySilentRestore()
            if !lidBlocker.isActive { lidSetByUs = false }
        }
    }

    /// 恢复正常合盖休眠；失败时弹警告避免不知情
    private func restoreLidSleepIfNeeded() {
        guard lidBlocker.isActive else { return }
        if let err = lidBlocker.set(false) {
            showLidError("系统休眠仍处于禁用状态",
                         "\(err)\n\n合盖暂时不会休眠。可以稍后在菜单里重试，或在终端执行：sudo pmset -a disablesleep 0")
        } else {
            lidSetByUs = false
        }
    }

    private func showLidError(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    @objc private func quit() {
        blocker.stop()
        restoreLidSleepIfNeeded()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        blocker.stop()
        restoreLidSleepIfNeeded()
    }
}

// MARK: - 启动

// 调试：./SleepCat --dump-icons <目录> 把图标渲染成 PNG 后退出
if let flagIndex = CommandLine.arguments.firstIndex(of: "--dump-icons") {
    let dir = CommandLine.arguments.count > flagIndex + 1
        ? CommandLine.arguments[flagIndex + 1] : "."
    CatIcon.dump(toDirectory: dir)
    try? MeowSound.wavData().write(to: URL(fileURLWithPath: "\(dir)/meow.wav"))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // 只出现在菜单栏，不占 Dock
let delegate = SleepCatApp()
app.delegate = delegate
app.run()
