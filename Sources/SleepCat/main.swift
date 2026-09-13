// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

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

final class SleepCatApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let blocker = SleepBlocker()
    private let lidBlocker = LidBlocker()
    private let island = NotchIsland()
    private let lidSensor = LidAngleSensor()   // 同一个 HID 设备只开一次，模糊和看门狗共用
    private let keyboardLock = KeyboardLock()
    private var duoBlur: DuoBlur?
    private var offTimer: Timer?
    private var menuRefreshTimer: Timer?
    private var deadline: Date?
    private var headerItem: NSMenuItem?
    private var heartbeatTimer: Timer?
    private var lidWatchdog: Timer?
    private var activePreset: Int?   // 当前生效的定时预设（分钟）

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
    /// 归属标记：disablesleep=1 是不是我们设置的（区分用户/其他工具自己开的）
    private var lidSetByUs: Bool {
        get { UserDefaults.standard.bool(forKey: "lidSetByUs") }
        set { UserDefaults.standard.set(newValue, forKey: "lidSetByUs") }
    }
    /// Duo 岛（刘海灵动岛）。悬停就展开面板比较打扰，默认关闭、按需开启
    private var duoEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "duoEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "duoEnabled") }
    }
    /// Duo 合盖模糊（铰链传感器联动），默认开启
    private var duoBlurEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "duoBlurEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "duoBlurEnabled") }
    }

    /// 用过的旧应用 ID。偏好设置和辅助功能授权都是按应用 ID 记的，换 ID 时要照顾到
    static let legacyBundleIDs = ["com.suink.sleepcat"]

    /// 把旧应用 ID 下的偏好搬到当前 ID，包括进行中的喵住会话，这样换 ID 后
    /// 合盖模式、音效等设置不丢，正在喵住的也能无缝接上。只搬一次，不覆盖已有的值。
    static func migrateLegacyDefaults(from legacyIDs: [String] = legacyBundleIDs,
                                      into defaults: UserDefaults = .standard) {
        let flag = "migratedLegacyDefaults"
        guard !defaults.bool(forKey: flag) else { return }
        for id in legacyIDs {
            guard let old = UserDefaults.standard.persistentDomain(forName: id) else { continue }
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: flag)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.migrateLegacyDefaults()   // 必须在读任何设置之前
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "SleepCat"   // 记住用户 ⌘ 拖动后的位置
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        island.statusProvider = { [weak self] in
            guard let self else { return .init(active: false, title: "SleepCat", detail: "") }
            if self.blocker.isActive {
                var detail = self.deadline.map { "还剩 \(Self.format($0.timeIntervalSinceNow))" } ?? "无限期"
                if self.lidBlocker.isActive { detail += " · 含合盖" }
                return .init(active: true, title: "喵住中", detail: detail + " · 点按停止")
            }
            return .init(active: false, title: "打盹中", detail: "Mac 可正常休眠 · 点按喵住")
        }
        island.onToggle = { [weak self] in self?.toggle() }
        if duoEnabled {
            island.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.island.peek()  // 启动时探出来打个招呼
            }
        }

        duoBlur = DuoBlur(sensor: lidSensor)
        if duoBlurEnabled { duoBlur?.start() }

        // 上次的喵住被强杀/崩溃打断 → 接着喵，而不是静默放 Mac 去睡。
        // 只有在没有会话可恢复时，才清掉上次残留的"禁止休眠"。
        if !resumeInterruptedSession(), lidBlocker.isActive, lidSetByUs {
            lidBlocker.trySilentRestore()
            if !lidBlocker.isActive { lidSetByUs = false }
        }

        updateIcon()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.logStatusItemPosition()
        }
    }

    /// 把状态项落位写进 ~/Library/Logs/SleepCat.log，用于验证位置设置是否生效
    private func logStatusItemPosition() {
        guard let f = statusItem.button?.window?.frame,
              let screen = NSScreen.main else { return }
        let line = "[\(Date())] status item x=\(Int(f.minX)) 距右边缘=\(Int(screen.frame.maxX - f.maxX)) 宽=\(Int(f.width))\n"
        let path = ("~/Library/Logs/SleepCat.log" as NSString).expandingTildeInPath
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
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

    // MARK: 会话持久化
    //
    // 应用被强杀或崩溃时，喵住会话不能就这么没了：那会让 disablesleep 被下次启动
    // 的自愈逻辑清掉，用户合着盖子的 Mac 就直接睡了。这里把会话存下来，
    // 靠心跳区分"刚刚被打断"和"上次开机时的旧会话"。

    private static let sessionActiveKey = "sessionActive"
    private static let sessionDeadlineKey = "sessionDeadline"
    private static let sessionPresetKey = "sessionPreset"
    private static let sessionBeatKey = "sessionHeartbeat"

    /// 会话是否值得恢复：必须有新鲜心跳（默认 5 分钟内），且定时还没到点
    static func shouldResume(active: Bool, heartbeat: Date?, deadline: Date?,
                             now: Date = Date(), maxGap: TimeInterval = 300) -> Bool {
        guard active, let heartbeat, now.timeIntervalSince(heartbeat) < maxGap else { return false }
        if let deadline, deadline <= now { return false }
        return true
    }

    private func saveSession() {
        let d = UserDefaults.standard
        d.set(true, forKey: Self.sessionActiveKey)
        d.set(deadline, forKey: Self.sessionDeadlineKey)
        d.set(activePreset, forKey: Self.sessionPresetKey)
        d.set(Date(), forKey: Self.sessionBeatKey)
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            UserDefaults.standard.set(Date(), forKey: Self.sessionBeatKey)
        }
    }

    private func clearSession() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        let d = UserDefaults.standard
        [Self.sessionActiveKey, Self.sessionDeadlineKey,
         Self.sessionPresetKey, Self.sessionBeatKey].forEach { d.removeObject(forKey: $0) }
    }

    @discardableResult
    private func resumeInterruptedSession() -> Bool {
        let d = UserDefaults.standard
        let saved = d.object(forKey: Self.sessionDeadlineKey) as? Date
        guard Self.shouldResume(active: d.bool(forKey: Self.sessionActiveKey),
                                heartbeat: d.object(forKey: Self.sessionBeatKey) as? Date,
                                deadline: saved) else {
            clearSession()
            return false
        }
        activePreset = d.object(forKey: Self.sessionPresetKey) as? Int
        activate(duration: saved?.timeIntervalSinceNow, resumed: true)
        return true
    }

    /// duration 为 nil 表示无限期（定时预设由 menuActivateTimed 先行设置）
    private func activate(duration: TimeInterval?, resumed: Bool = false) {
        if duration == nil { activePreset = nil }
        blocker.start(keepDisplayOn: keepDisplayOn)
        // 规则被外部删掉时补装；恢复会话发生在启动时，不在那一刻弹框打扰
        if lidBlockEnabled, resumed || ensureFreePass() {
            if let err = lidBlocker.set(true, allowPrompt: !resumed) {
                showWarning("合盖防休眠没有生效", err)  // 只挡住了闲置休眠
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
        saveSession()
        startLidWatchdog()
        if !resumed { playSound(awake: true) }   // 恢复会话时不喵，免得启动就叫
        updateIcon()
        island.peek()
    }

    private func deactivate() {
        blocker.stop()
        restoreLidSleepIfNeeded()
        offTimer?.invalidate()
        offTimer = nil
        deadline = nil
        activePreset = nil
        clearSession()
        lidWatchdog?.invalidate()
        lidWatchdog = nil
        playSound(awake: false)
        updateIcon()
        island.peek()
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
        island.refresh()
        button.toolTip = blocker.isActive
            ? "SleepCat：正在喵住你的 Mac（点击放它去睡）"
            : "SleepCat：猫猫在打盹，Mac 可以正常休眠（点击叫醒）"
    }

    // MARK: 菜单

    /// 从短暂离开到挂一整晚：30 分钟起步，8 小时覆盖下载 / 编译 / 通宵跑任务
    static let presets: [(String, Int)] = [
        ("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("4 小时", 240), ("8 小时", 480),
    ]

    private var lastCustomMinutes: Int {
        get { UserDefaults.standard.object(forKey: "lastCustomMinutes") as? Int ?? 90 }
        set { UserDefaults.standard.set(newValue, forKey: "lastCustomMinutes") }
    }

    private func showMenu() {
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // 用完摘掉，否则左键也会弹菜单
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        headerItem = makeHeaderItem()
        menu.addItem(headerItem!)
        menu.addItem(.separator())

        // ── 主操作 ──
        if blocker.isActive {
            menu.addItem(makeItem("放猫猫去睡", #selector(menuDeactivate), symbol: "moon.zzz.fill"))
        } else {
            menu.addItem(makeItem("立即喵住", #selector(menuActivateForever), symbol: "cup.and.saucer.fill"))
        }

        let timedRoot = NSMenuItem(title: "喵住时长", action: nil, keyEquivalent: "")
        timedRoot.image = symbol("timer")
        let timedMenu = NSMenu()
        let forever = makeItem("无限期", #selector(menuActivateForever))
        forever.state = (blocker.isActive && deadline == nil) ? .on : .off
        timedMenu.addItem(forever)
        timedMenu.addItem(.separator())
        for (label, minutes) in Self.presets {
            let item = makeItem(label, #selector(menuActivateTimed(_:)))
            item.tag = minutes
            item.attributedTitle = timedTitle(label, minutes: minutes)
            item.state = (blocker.isActive && activePreset == minutes) ? .on : .off
            timedMenu.addItem(item)
        }
        timedMenu.addItem(.separator())
        let customMinutes = activePreset.flatMap { m in Self.presets.contains { $0.1 == m } ? nil : m }
        let isCustom = blocker.isActive && customMinutes != nil
        let custom = makeItem(
            isCustom ? "自定义（\(DurationPicker.durationText(minutes: customMinutes!))）…" : "自定义…",
            #selector(menuActivateCustom))
        custom.state = isCustom ? .on : .off
        timedMenu.addItem(custom)
        menu.addItem(timedRoot)
        menu.setSubmenu(timedMenu, for: timedRoot)

        // ── 喵住设置 ──
        menu.addItem(sectionHeader("喵住设置"))

        let displayItem = makeItem("保持屏幕常亮", #selector(toggleDisplaySetting), symbol: "sun.max")
        displayItem.state = keepDisplayOn ? .on : .off
        displayItem.toolTip = "关闭时只阻止系统休眠，屏幕仍可自动关闭"
        menu.addItem(displayItem)

        let lidItem = makeItem("合盖也不休眠", #selector(toggleLidSetting), symbol: "laptopcomputer")
        lidItem.state = lidBlockEnabled ? .on : .off
        lidItem.toolTip = "首次开启需一次管理员授权，之后切换全程静默"
        menu.addItem(lidItem)

        // ── 效果与提示 ──
        menu.addItem(sectionHeader("效果与提示"))

        let duoItem = makeItem("刘海灵动岛", #selector(toggleDuoSetting), symbol: "capsule")
        duoItem.state = duoEnabled ? .on : .off
        duoItem.toolTip = "鼠标悬停刘海展开状态胶囊，点按可切换"
        menu.addItem(duoItem)

        let blurItem = makeItem("合盖渐变模糊", #selector(toggleDuoBlurSetting), symbol: "camera.filters")
        if duoBlur != nil {
            blurItem.state = duoBlurEnabled ? .on : .off
            blurItem.toolTip = "跟随铰链角度实时模糊屏幕"
        } else {
            blurItem.action = nil
            blurItem.isEnabled = false
            blurItem.toolTip = "这台 Mac 没有铰链角度传感器"
        }
        menu.addItem(blurItem)

        let soundItem = makeItem("切换时播放喵声", #selector(toggleSoundSetting), symbol: "speaker.wave.2")
        soundItem.state = soundEnabled ? .on : .off
        menu.addItem(soundItem)

        // ── 工具 ──
        menu.addItem(sectionHeader("工具"))
        menu.addItem(makeItem("清洁键盘…", #selector(startKeyboardCleaning), symbol: "keyboard"))

        // ── 关于 / 退出 ──
        menu.addItem(.separator())
        menu.addItem(makeItem("项目主页…", #selector(openHomepage), symbol: "link"))
        menu.addItem(makeItem("退出 SleepCat", #selector(quit), symbol: "power", key: "q"))

        return menu
    }

    /// 调试：把菜单结构打成文本，检查分组、缩进、勾选、启用状态
    static func dumpMenu() {
        let app = SleepCatApp()
        app.duoBlur = DuoBlur(sensor: LidAngleSensor())
        func walk(_ menu: NSMenu, depth: Int) {
            for item in menu.items {
                if item.isSeparatorItem {
                    print(String(repeating: "  ", count: depth) + "───────")
                    continue
                }
                let title = item.attributedTitle?.string ?? item.title
                var marks: [String] = []
                if item.state == .on { marks.append("✓") }
                if !item.isEnabled { marks.append("灰") }
                if item.image != nil { marks.append("图") }
                if item.hasSubmenu { marks.append("▸") }
                let pad = String(repeating: "  ", count: depth + item.indentationLevel)
                let suffix = marks.isEmpty ? "" : "  [\(marks.joined(separator: " "))]"
                print(pad + title.replacingOccurrences(of: "\n", with: " / ") + suffix)
                if let sub = item.submenu { walk(sub, depth: depth + 1) }
            }
        }
        let menu = app.buildMenu()
        walk(menu, depth: 0)
        let widest = menu.items.compactMap { $0.image?.size.width }.max() ?? 0
        print("菜单尺寸 \(Int(menu.size.width))×\(Int(menu.size.height))，最宽图标 \(Int(widest))pt")
    }

    /// 每个可点条目都配一个符号图标，菜单左缘才是一条直线（缺图标的行文字会往左串）
    private func makeItem(_ title: String, _ action: Selector,
                          symbol name: String? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let name { item.image = symbol(name) }
        return item
    }

    /// 菜单图标统一画布。符号本身宽窄不一（laptopcomputer 比 key 宽一倍），
    /// 直接用原图会让每行文字的起点左右浮动，菜单左缘就成锯齿了。
    private static let iconCanvas = NSSize(width: 18, height: 16)

    private static func fitIcon(_ src: NSImage) -> NSImage {
        let out = NSImage(size: iconCanvas, flipped: false) { rect in
            let s = src.size
            guard s.width > 0, s.height > 0 else { return true }
            let scale = min(rect.width / s.width, rect.height / s.height)
            let w = s.width * scale, h = s.height * scale
            src.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            return true
        }
        out.isTemplate = true
        return out
    }

    private func symbol(_ name: String) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return nil }
        return Self.fitIcon(img)
    }

    /// 分组标题（macOS 14+ 用原生 section header，老系统退化为灰色小标题）
    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    /// 两行状态头：猫图标 + 主状态 + 次要说明（禁用态也保持彩色，靠 attributedTitle）
    private func makeHeaderItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.image = headerIcon()
        item.toolTip = "左键点菜单栏的猫猫可直接切换"
        item.attributedTitle = headerTitle()
        return item
    }

    /// 状态头的猫比普通条目图标大一圈，压得住两行文字
    private func headerIcon() -> NSImage {
        Self.fitIcon(blocker.isActive ? CatIcon.awake : CatIcon.asleep)
    }

    private func headerTitle() -> NSAttributedString {
        let title: String
        var detail: String
        if blocker.isActive {
            title = "喵住中"
            detail = deadline.map { "还剩 \(Self.format($0.timeIntervalSinceNow))" } ?? "无限期"
            if lidBlocker.isActive { detail += " · 含合盖防护" }
        } else if lidBlocker.isActive {
            title = "打盹中 · 休眠仍被禁用"
            detail = "开关一次「合盖也不休眠」可恢复"
        } else {
            title = "打盹中"
            detail = "Mac 可正常休眠"
        }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2   // 两行贴太紧会糊成一团
        let s = NSMutableAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ])
        s.append(NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]))
        return s
    }

    @objc private func openHomepage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/SuInk/sleepcat")!)
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
        activePreset = sender.tag
        activate(duration: TimeInterval(sender.tag * 60))
    }

    @objc private func menuActivateCustom() {
        NSApp.activate(ignoringOtherApps: true)
        let picker = DurationPicker(minutes: lastCustomMinutes)
        let alert = NSAlert()
        alert.messageText = "自定义喵住时长"
        alert.informativeText = "到点后自动放猫猫去睡。"
        alert.accessoryView = picker.view
        alert.addButton(withTitle: "开始喵住")
        alert.addButton(withTitle: "取消")
        picker.onChange = { [weak alert] total in alert?.buttons.first?.isEnabled = total > 0 }
        alert.window.initialFirstResponder = picker.hoursField
        guard alert.runModal() == .alertFirstButtonReturn, picker.totalMinutes > 0 else { return }
        lastCustomMinutes = picker.totalMinutes
        activePreset = picker.totalMinutes
        activate(duration: TimeInterval(picker.totalMinutes * 60))
    }

    /// 档位名左对齐，结束时刻右对齐成灰色一列，扫一眼就知道到几点
    private func timedTitle(_ label: String, minutes: Int) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: 170)]
        let font = NSFont.menuFont(ofSize: 0)   // 不显式给字体会退回 Helvetica 12
        let s = NSMutableAttributedString(string: label + "\t", attributes: [
            .font: font, .paragraphStyle: para,
        ])
        s.append(NSAttributedString(
            string: DurationPicker.prefixed("至", DurationPicker.endTimeText(minutes: minutes, showToday: false)),
            attributes: [.font: font, .paragraphStyle: para, .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    // MARK: NSMenuDelegate —— 菜单打开期间每秒刷新倒计时

    func menuWillOpen(_ menu: NSMenu) {
        menuRefreshTimer?.invalidate()
        guard blocker.isActive, deadline != nil else { return }
        menuRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.headerItem?.attributedTitle = self.headerTitle()
        }
        RunLoop.current.add(menuRefreshTimer!, forMode: .common)  // 菜单会切到 eventTracking 模式
    }

    func menuDidClose(_ menu: NSMenu) {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
        headerItem = nil
    }

    @objc private func toggleDisplaySetting() {
        keepDisplayOn.toggle()
        if blocker.isActive {
            blocker.start(keepDisplayOn: keepDisplayOn)  // 立即按新设置重挂断言
        }
    }

    @objc private func toggleSoundSetting() { soundEnabled.toggle() }

    @objc private func toggleDuoBlurSetting() {
        duoBlurEnabled.toggle()
        if duoBlurEnabled {
            duoBlur?.start()
        } else {
            duoBlur?.stop()
        }
    }

    @objc private func toggleDuoSetting() {
        duoEnabled.toggle()
        if duoEnabled {
            island.start()
            island.peek()
        } else {
            island.stop()
        }
    }

    @objc private func toggleLidSetting() {
        if lidBlockEnabled {
            lidBlockEnabled = false
            restoreLidSleepIfNeeded()
            return
        }
        // 免密规则是合盖模式的一部分，不是可选项：装不上就不开
        guard ensureFreePass() else { return }
        lidBlockEnabled = true
        if blocker.isActive {
            if let err = lidBlocker.set(true) {
                showWarning("合盖防休眠没有生效", err)
            } else {
                lidSetByUs = true
            }
        }
    }

    /// 确保免密规则在位；缺失时解释一次并请求授权。返回是否可用。
    @discardableResult
    private func ensureFreePass() -> Bool {
        if lidBlocker.freePassInstalled() { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "开启「合盖也不休眠」需要一次授权"
        alert.informativeText = """
        合盖休眠是系统强制行为，要用管理员权限执行 pmset disablesleep 才能挡住。

        授权后会写入 /etc/sudoers.d/sleepcat，只放行这一条命令（开 / 关两种写法），不开放其他任何权限。之后开关合盖防护全程静默，不会再要密码。

        ⚠️ 喵住期间合上盖子，Mac 仍在运行、会发热耗电。放进背包前请先点猫猫停止。
        """
        alert.addButton(withTitle: "授权并开启")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if let err = lidBlocker.installFreePass() {
            showWarning("授权没有完成", "\(err)\n\n合盖防护未开启。")
            return false
        }
        return true
    }

    /// 合盖防护看门狗。
    ///
    /// 按理说 disablesleep 设一次就该管到重启（其他项目都这么假设），但这台机器上
    /// 实测被外部清掉过：23:31 设成 1 并验证通过，期间我们没动过、也没重启，
    /// 到 00:49 读回来已经是 0，中间两次合盖就这么睡了。
    ///
    /// 所以与其盲目定时轮询，不如盯住真正要紧的那一刻：**盖子开始合上的瞬间**。
    /// 铰链角度我们本来就在读，顺带用它当触发器；再配一个慢速兜底和唤醒补偿。
    private func startLidWatchdog() {
        lidWatchdog?.invalidate()
        guard lidBlockEnabled else { return }
        var lastAngle = lidSensor?.angle() ?? 180
        var lastSweep = Date.distantPast

        lidWatchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.blocker.isActive, self.lidBlockEnabled else { return }
            let angle = self.lidSensor?.angle()

            // 触发点一：盖子正在往下合（跨过 100°）——此刻必须确保防护在位
            let closing = (angle.map { $0 < 100 && lastAngle >= 100 }) ?? false
            if let angle { lastAngle = angle }

            // 触发点二：每 30 秒兜底核对一次，覆盖传感器读不到的机型
            let sweepDue = Date().timeIntervalSince(lastSweep) > 30
            guard closing || sweepDue else { return }
            lastSweep = Date()
            if self.lidBlocker.reassertIfCleared() { self.lidSetByUs = true }
        }

        // 触发点三：唤醒瞬间
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func systemDidWake() {
        guard blocker.isActive, lidBlockEnabled else { return }
        if lidBlocker.reassertIfCleared() { lidSetByUs = true }
    }

    /// 恢复正常合盖休眠；失败时弹警告避免不知情
    private func restoreLidSleepIfNeeded() {
        guard lidBlocker.isActive else { return }
        if let err = lidBlocker.set(false) {
            showWarning("系统休眠仍处于禁用状态",
                         "\(err)\n\n合盖暂时不会休眠。可以稍后在菜单里重试，或在终端执行：sudo pmset -a disablesleep 0")
        } else {
            lidSetByUs = false
        }
    }

    @objc private func startKeyboardCleaning() {
        guard KeyboardLock.hasPermission else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "清洁键盘需要「辅助功能」权限"
            alert.informativeText = """
            禁用键盘要拦截系统的按键事件，macOS 规定这需要辅助功能权限。

            如果设置里 SleepCat 看起来已经是打开的：那是早期版本留下的授权记录，已经失效，关掉再打开也没用。点「重新授权」会先清掉它。授权一次后，以后更新应用都不用再授权。

            之后在列表里打开 SleepCat，再回来点一次「清洁键盘…」。
            """
            alert.addButton(withTitle: "重新授权")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                KeyboardLock.requestPermission(alsoReset: Self.legacyBundleIDs)
            }
            return
        }
        if let err = keyboardLock.lock() {
            showWarning("没能禁用键盘", err)
        }
    }

    private func showWarning(_ title: String, _ detail: String) {
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
        clearSession()   // 主动退出＝有意结束，下次启动不该自己又喵起来
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        blocker.stop()
        restoreLidSleepIfNeeded()
        clearSession()
        duoBlur?.stop()   // 确保光标一定还给用户
        keyboardLock.unlock()
    }
}

// MARK: - 启动

// 构建用：./SleepCat --make-iconset <目录> 导出应用图标的 .iconset 后退出
if let i = CommandLine.arguments.firstIndex(of: "--make-iconset"), CommandLine.arguments.count > i + 1 {
    do {
        try AppIcon.writeIconset(to: CommandLine.arguments[i + 1])
        exit(0)
    } catch {
        FileHandle.standardError.write("iconset 生成失败：\(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// 调试：./SleepCat --dump-menu 打印菜单结构后退出
if CommandLine.arguments.contains("--dump-menu") {
    SleepCatApp.dumpMenu()
    exit(0)
}

// 调试：./SleepCat --lid-angle 连续打印铰链角度传感器读数后退出
if CommandLine.arguments.contains("--lid-angle") {
    guard let sensor = LidAngleSensor() else {
        print("没有找到铰链角度传感器")
        exit(1)
    }
    for _ in 0..<8 {
        sensor.debugDump()
        Thread.sleep(forTimeInterval: 0.4)
    }
    exit(0)
}

// 调试：./SleepCat --dump-icons <目录> 把图标渲染成 PNG 后退出
if let flagIndex = CommandLine.arguments.firstIndex(of: "--dump-icons") {
    let dir = CommandLine.arguments.count > flagIndex + 1
        ? CommandLine.arguments[flagIndex + 1] : "."
    CatIcon.dump(toDirectory: dir)
    try? MeowSound.wavData().write(to: URL(fileURLWithPath: "\(dir)/meow.wav"))
    NotchIsland.renderPreview(toDirectory: dir)
    DurationPicker.renderPreview(toDirectory: dir)
    KeyboardLock.renderPreview(toDirectory: dir)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // 只出现在菜单栏，不占 Dock
let delegate = SleepCatApp()
app.delegate = delegate
app.run()
