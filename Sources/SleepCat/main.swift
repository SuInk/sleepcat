// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit
import IOKit.pwr_mgt
import UserNotifications

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
    private let battery = BatteryMonitor()
    private var lowBatteryGuard = LowBatteryGuard()
    private var autoStopNote: String?   // 因为电量低被暂停时，状态头里说明原因
    private var batteryRecheck: Timer?  // 低电量确认期到点后复查（电量不变时系统不会再通知）
    /// 喵住因为电量低被暂停、等电源回来自动恢复。会话存档保留着，退出重开也记得
    private var pausedForLowBattery: Bool {
        get { UserDefaults.standard.bool(forKey: "pausedForLowBattery") }
        set { UserDefaults.standard.set(newValue, forKey: "pausedForLowBattery") }
    }
    private var duoBlur: DuoBlur?
    private var powerBucket: PowerSession?   // 攒够一段就写一行记录，和喵不喵住无关
    private var powerTimer: Timer?
    private var latestWatts: Double?
    private var powerHistory = PowerHistory()   // 近 24 小时的采样，菜单和窗口画曲线
    private var minuteSum = 0.0                 // 每分钟往磁盘写一条，不是每次采样都写
    private var minuteCount = 0
    private var minuteStart = Date()
    private var retentionTimer: Timer?
    /// 菜单开着时每秒读一次，顶部状态行、「功耗」菜单项、概览块都用这同一个读数，数字才对得上
    private var latestFlow: PowerFlow?
    private weak var powerItem: NSMenuItem?
    private weak var powerSummary: PowerSummaryView?
    private var offTimer: Timer?
    private var menuRefreshTimer: Timer?
    private var deadline: Date?
    private var headerItem: NSMenuItem?
    private var lidWatchdog: Timer?
    private var permissionPoll: Timer?
    private var updateTimer: Timer?
    private var availableUpdate: UpdateChecker.Release?   // 后台检查发现的新版本，菜单里显示
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
    /// 用电池时电量低于这个百分比就暂停喵住、插上电源自动恢复；nil = 关闭。默认 20%，
    /// 合盖塞包里喵住着把电耗光是最糟的情况，所以默认开着
    private var lowBatteryThreshold: Int? {
        get {
            let value = UserDefaults.standard.object(forKey: "lowBatteryThreshold") as? Int ?? 20
            return value > 0 ? value : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "lowBatteryThreshold") }
    }
    /// Duo 合盖模糊（铰链传感器联动），默认开启
    private var duoBlurEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "duoBlurEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "duoBlurEnabled") }
    }

    /// 用过的旧应用 ID。偏好设置和辅助功能授权都是按应用 ID 记的，换 ID 时要照顾到
    static let legacyBundleIDs = ["com.earlyso.sleepcat", "com.suink.sleepcat"]

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
        Notifier.shared.setUp()
        trimOldLogs()
        // 一直开着的菜单栏应用不会天天重启，所以除了启动时，每天再清一次
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.trimOldLogs()
        }
        powerHistory = PowerLog.loadHistory()   // 接上重启前的曲线
        startPowerSampling()
        if lowBatteryThreshold != nil, BatteryMonitor.read() != nil {
            Notifier.shared.requestAuthorizationIfNeeded()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "SleepCat"   // 记住用户 ⌘ 拖动后的位置
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        island.statusProvider = { [weak self] in
            guard let self else { return .init(active: false, title: "SleepCat", detail: "") }
            // 展开期间每秒刷新一次，这里现读 SMC（一次不到 1 毫秒），是真正的实时值
            let flow = PowerMeter.readFlow()
            if self.blocker.isActive {
                var detail = self.deadline.map { "还剩 \(Self.format($0.timeIntervalSinceNow))" } ?? "无限期"
                if self.lidBlocker.isActive { detail += " · 含合盖" }
                return .init(active: true, title: "喵住中", detail: detail + " · 点按停止",
                             watts: flow?.headline.watts, powerCaption: flow?.shortState)
            }
            return .init(active: false, title: "打盹中", detail: "Mac 可正常休眠 · 点按喵住",
                         watts: flow?.headline.watts, powerCaption: flow?.shortState)
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

        // 等启动流程走完、菜单栏图标出来了再检查，别在应用还没露面时就弹授权框
        DispatchQueue.main.async { [weak self] in self?.restoreLidRuleIfNeeded() }

        startAutomaticUpdateChecks()

        battery.onChange = { [weak self] status in self?.checkBattery(status) }
        battery.start()
        if let status = BatteryMonitor.read() { checkBattery(status) }   // 恢复的会话也要照常判定

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
        } else if pausedForLowBattery {
            resumeAfterLowBattery(manual: true)
        } else {
            activate(duration: nil)
        }
    }

    // MARK: 会话持久化
    //
    // 喵住是用户的意图，只有用户亲手「放猫猫去睡」或定时到点才算结束。
    // 退出应用、应用更新、崩溃、重启 Mac 都只是暂时中断：应用不在跑的时候放 Mac 正常休眠，
    // 下次打开接着喵。所以退出时不清会话，只在 deactivate 里清。

    private static let sessionActiveKey = "sessionActive"
    private static let sessionDeadlineKey = "sessionDeadline"
    private static let sessionPresetKey = "sessionPreset"

    /// 上次的喵住要不要接着来：开着、而且定时还没到点
    static func shouldResume(active: Bool, deadline: Date?, now: Date = Date()) -> Bool {
        guard active else { return false }
        if let deadline, deadline <= now { return false }
        return true
    }

    private func saveSession() {
        let d = UserDefaults.standard
        d.set(true, forKey: Self.sessionActiveKey)
        d.set(deadline, forKey: Self.sessionDeadlineKey)
        d.set(activePreset, forKey: Self.sessionPresetKey)
    }

    private func clearSession() {
        pausedForLowBattery = false   // 暂停状态是会话的一部分，会话没了它也不能留着
        let d = UserDefaults.standard
        [Self.sessionActiveKey, Self.sessionDeadlineKey, Self.sessionPresetKey,
         "sessionHeartbeat"].forEach { d.removeObject(forKey: $0) }   // 心跳是旧版本留下的，顺手清掉
    }

    @discardableResult
    private func resumeInterruptedSession() -> Bool {
        let d = UserDefaults.standard
        let saved = d.object(forKey: Self.sessionDeadlineKey) as? Date
        guard Self.shouldResume(active: d.bool(forKey: Self.sessionActiveKey), deadline: saved) else {
            clearSession()
            return false
        }
        activePreset = d.object(forKey: Self.sessionPresetKey) as? Int
        if pausedForLowBattery {
            // 退出前是因为电量低暂停的：先别喵，启动后的电量检查会在电源已接回时自动恢复
            deadline = saved
            autoStopNote = "电量低，已暂停喵住 · 插上电源自动恢复"
            return false
        }
        activate(duration: saved?.timeIntervalSinceNow, resumed: true)
        // 可能隔了很久才打开应用，自己喵起来得说一声，不然用户会奇怪 Mac 怎么不睡了
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            Toast.show("已恢复上次的喵住", below: self?.statusItem?.button)
        }
        return true
    }

    /// duration 为 nil 表示无限期（定时预设由 menuActivateTimed 先行设置）
    private func activate(duration: TimeInterval?, resumed: Bool = false) {
        if duration == nil { activePreset = nil }
        autoStopNote = nil
        pausedForLowBattery = false
        batteryRecheck?.invalidate()
        if !resumed, lowBatteryThreshold != nil, BatteryMonitor.read() != nil {
            Notifier.shared.requestAuthorizationIfNeeded()
        }
        if !resumed, let status = BatteryMonitor.read(),
           lowBatteryGuard.noteManualStart(status, threshold: lowBatteryThreshold) {
            Toast.show("电量 \(status.percent)%，这次不会因为电量低暂停", below: statusItem?.button)
        }
        blocker.start(keepDisplayOn: keepDisplayOn)
        startPowerSampling()
        // 规则被外部删掉时补装；恢复会话发生在启动时，不在那一刻弹框打扰
        if lidBlockEnabled, resumed || ensureFreePass() {
            if let err = lidBlocker.set(true, allowPrompt: !resumed) {
                // 恢复会话时失败多半是规则丢了，交给启动后的检查去补写，这里不弹一个没法补救的警告
                if !resumed { showWarning("合盖防休眠没有生效", err) }  // 只挡住了闲置休眠
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

    // MARK: 低电量暂停与自动恢复

    private func checkBattery(_ status: PowerStatus) {
        let threshold = lowBatteryThreshold
        if pausedForLowBattery {
            if LowBatteryGuard.shouldResume(status, threshold: threshold) {
                resumeAfterLowBattery(manual: false, notice: status.onBattery ? "已恢复喵住" : "电源接上了，已恢复喵住")
            }
            return
        }
        let now = Date()
        if lowBatteryGuard.shouldPause(status, threshold: threshold, sessionActive: blocker.isActive, now: now) {
            pauseForLowBattery(status)
        } else if let wait = lowBatteryGuard.secondsUntilDecision(now: now) {
            batteryRecheck?.invalidate()
            batteryRecheck = Timer.scheduledTimer(withTimeInterval: wait + 1, repeats: false) { [weak self] _ in
                if let status = BatteryMonitor.read() { self?.checkBattery(status) }
            }
        } else {
            batteryRecheck?.invalidate()
        }
    }

    /// 电量低：先暂停喵住，但记住它（包括定时剩余时间），电源回来自动接上
    private func pauseForLowBattery(_ status: PowerStatus) {
        blocker.stop()
        flushPowerBucket()
        restoreLidSleepIfNeeded()   // 连同合盖防护一起撤掉：合着盖子的话，Mac 会马上正常休眠
        offTimer?.invalidate()
        offTimer = nil
        lidWatchdog?.invalidate()
        lidWatchdog = nil
        pausedForLowBattery = true   // 会话存档和 deadline 都留着
        autoStopNote = "电量 \(status.percent)%，已暂停喵住 · 插上电源自动恢复"
        playSound(awake: false)
        updateIcon()
        island.peek()
        Notifier.shared.post(
            id: "lowBattery", title: "喵住已暂停",
            body: "电量 \(status.percent)%，Mac 现在可以正常休眠。插上电源会自动恢复喵住。",
            sound: !soundEnabled   // 开着音效时刚才已经呼噜过一声，别再响第二声
        ) { [weak self] in
            Toast.show("电量 \(status.percent)%，先暂停喵住；插上电源会自动恢复", below: self?.statusItem?.button)
        }
        LidBlocker.log("低电量暂停：\(status.percent)%，阈值 \(lowBatteryThreshold ?? 0)%")
    }

    /// - Parameters:
    ///   - manual: 用户自己点的恢复算手动开启——电量还低也不会再被暂停
    ///   - notice: 自动恢复时给用户的提示
    private func resumeAfterLowBattery(manual: Bool, notice: String = "已恢复喵住") {
        pausedForLowBattery = false
        // 判定从头来过：不然刚恢复就拔电源、中间没收到过接电通知的话，就再也不会暂停
        lowBatteryGuard = LowBatteryGuard()
        if let d = deadline, d <= Date() {
            // 暂停期间定时已经到点：该结束就结束，不再喵起来
            deadline = nil
            activePreset = nil
            autoStopNote = nil
            clearSession()
            updateIcon()
            LidBlocker.log("低电量暂停期间定时已到点，不再恢复")
            return
        }
        activate(duration: deadline?.timeIntervalSinceNow, resumed: !manual)
        if !manual {
            Notifier.shared.post(id: "lowBattery", title: "喵住已恢复", body: notice, sound: false) { [weak self] in
                Toast.show(notice, below: self?.statusItem?.button)
            }
            LidBlocker.log("低电量暂停后自动恢复：\(notice)")
        }
    }

    @objc private func resumeFromMenu() { resumeAfterLowBattery(manual: true) }

    @objc private func cancelAutoResume() {
        deadline = nil
        activePreset = nil
        autoStopNote = nil
        clearSession()
        updateIcon()
    }

    @objc private func setLowBatteryThreshold(_ sender: NSMenuItem) {
        applyLowBatteryThreshold(sender.tag > 0 ? sender.tag : nil)
    }

    private func applyLowBatteryThreshold(_ value: Int?) {
        lowBatteryThreshold = value
        // 改完阈值立刻按新值判定：比如电量 25% 时把阈值调到 30%，就该马上停
        lowBatteryGuard = LowBatteryGuard()
        if lowBatteryThreshold != nil { Notifier.shared.requestAuthorizationIfNeeded() }
        if let status = BatteryMonitor.read() { checkBattery(status) }
    }

    @objc private func openNotificationSettings() { Notifier.shared.openSettings() }

    private func deactivate() {
        blocker.stop()
        flushPowerBucket()
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

    // MARK: 功耗

    /// 每 10 秒采一次：SMC 读一次不到 1 毫秒，本身的耗电可以忽略
    static let powerSampleInterval: TimeInterval = 10

    /// 一直采着：菜单里的曲线要有数据，同时按段累计写进记录
    private func startPowerSampling() {
        guard powerTimer == nil else { return }
        samplePower()
        powerTimer = Timer.scheduledTimer(withTimeInterval: Self.powerSampleInterval, repeats: true) { [weak self] _ in
            self?.samplePower()
        }
    }

    @discardableResult
    private func samplePower() -> Double? {
        guard let watts = PowerMeter.read() else { return nil }
        let now = Date()
        latestWatts = watts
        powerHistory.add(watts: watts, at: now)
        // 攒够一分钟写一条：一天 1440 行，文件小、重启后曲线能接上
        minuteSum += watts
        minuteCount += 1
        if now.timeIntervalSince(minuteStart) >= 60, minuteCount > 0 {
            PowerLog.appendSample(watts: minuteSum / Double(minuteCount), at: now)
            minuteSum = 0
            minuteCount = 0
            minuteStart = now
        }
        if powerBucket == nil { powerBucket = PowerSession(watts: watts, at: now) }
        else { powerBucket?.add(watts: watts, at: now) }
        // 攒够一段就落一行：记录是连续的，不挂在喵住上
        if let bucket = powerBucket, bucket.duration >= Self.powerRecordInterval { flushPowerBucket() }
        return watts
    }

    /// 日志和功耗记录只留最近 30 天；放到后台做，文件大时不卡界面
    private func trimOldLogs() {
        DispatchQueue.global(qos: .utility).async {
            LogRetention.apply(appLog: URL(fileURLWithPath: LidBlocker.logPath), powerLog: PowerLog.fileURL)
        }
    }

    /// 每段记录多长。10 分钟一行，一天 144 行，既看得出变化、文件也不大
    static let powerRecordInterval: TimeInterval = 600

    /// 把当前这一段写进记录并重新开一段。太短的不写，免得记录里全是几十秒的碎片
    private func flushPowerBucket() {
        defer { powerBucket = nil }
        guard let bucket = powerBucket, bucket.duration >= 60 else { return }
        PowerLog.append(bucket)
    }


    /// 调试：按真实节奏采样若干秒，走一遍「采样 → 汇总 → 写记录」，然后打印结果
    static func probePower(seconds: TimeInterval, log: Bool) {
        let app = SleepCatApp()
        app.blocker.start(keepDisplayOn: false)     // 只在这个进程里持有，退出即释放
        app.startPowerSampling()
        guard app.powerBucket != nil else { print("读不到功耗"); exit(1) }
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            let session = app.powerBucket
            app.blocker.stop()
            app.flushPowerBucket()
            if let session {
                print("采样 \(session.samples) 次，\(Int(session.duration)) 秒，"
                      + "平均 \(PowerMeter.wattsText(session.averageWatts))，"
                      + "峰值 \(PowerMeter.wattsText(session.peakWatts))，"
                      + "用电 \(PowerMeter.energyText(session.energyWattHours))")
            }
            print("记录文件：\(PowerLog.fileURL.path)")
            exit(0)
        }
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
        Notifier.shared.refreshStatus()
        samplePower()
        latestFlow = PowerMeter.readFlow()
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // 用完摘掉，否则左键也会弹菜单
    }

    /// 自绘的开关行没有 action，菜单的自动启用会把它们当成禁用项，点不动。
    /// 每行的可用状态我们自己设，所以整棵菜单都关掉自动启用
    private static func stopAutoEnabling(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.items.compactMap(\.submenu).forEach(stopAutoEnabling)
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
        } else if pausedForLowBattery {
            menu.addItem(makeItem("立即恢复喵住", #selector(resumeFromMenu), symbol: "cup.and.saucer.fill"))
            menu.addItem(makeItem("取消自动恢复", #selector(cancelAutoResume), symbol: "xmark.circle"))
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
            item.attributedTitle = Self.timedTitle(label, minutes: minutes)
            item.state = (blocker.isActive && activePreset == minutes) ? .on : .off
            timedMenu.addItem(item)
        }
        timedMenu.addItem(.separator())
        let customMinutes = activePreset.flatMap { m in Self.presets.contains { $0.1 == m } ? nil : m }
        let isCustom = blocker.isActive && customMinutes != nil
        let timedValue: String? = !blocker.isActive ? nil
            : deadline == nil ? "无限期"
            : customMinutes.map { DurationPicker.durationText(minutes: $0) }
                ?? Self.presets.first { $0.1 == activePreset }?.0
        timedRoot.attributedTitle = Self.trailingTitle("喵住时长", value: timedValue)
        let custom = makeItem(
            isCustom ? "自定义（\(DurationPicker.durationText(minutes: customMinutes!))）…" : "自定义…",
            #selector(menuActivateCustom))
        custom.state = isCustom ? .on : .off
        timedMenu.addItem(custom)
        menu.addItem(timedRoot)
        menu.setSubmenu(timedMenu, for: timedRoot)

        // ── 喵住设置 ──
        menu.addItem(sectionHeader("喵住设置"))

        let displayItem = makeToggleItem("保持屏幕常亮", symbol: "sun.max",
                                         isOn: { [weak self] in self?.keepDisplayOn ?? false },
                                         action: { [weak self] in self?.toggleDisplaySetting() })
        displayItem.toolTip = "关闭时只阻止系统休眠，屏幕仍可自动关闭"
        menu.addItem(displayItem)

        let lidItem = makeToggleItem("合盖也不休眠", symbol: "laptopcomputer",
                                     isOn: { [weak self] in self?.lidBlockEnabled ?? false },
                                     action: { [weak self] in self?.toggleLidSetting() })
        lidItem.toolTip = "首次开启需一次管理员授权，之后切换全程静默"
        menu.addItem(lidItem)

        let lowItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        lowItem.image = symbol("battery.25")
        if BatteryMonitor.read() != nil {
            lowItem.title = "低电量自动暂停"
            lowItem.attributedTitle = Self.trailingTitle("低电量自动暂停", value: Self.thresholdText(lowBatteryThreshold))
            lowItem.toolTip = "只在用电池时生效；插上电源后会自动恢复喵住"
            let thresholds = NSMenu()
            let presets = [("关闭", 0), ("低于 10%", 10), ("低于 20%", 20), ("低于 30%", 30)]
            // 自定义…：选的值不在档位里时打勾，括号里写出来
            let custom = makeItem("自定义…", #selector(menuCustomLowBattery))
            let syncCustom = { [weak self] in
                let current = self?.lowBatteryThreshold
                let customValue = current.flatMap { v in presets.contains { $0.1 == v } ? nil : v }
                custom.title = customValue.map { "自定义（\($0)%）…" } ?? "自定义…"
                custom.state = customValue != nil ? .on : .off
            }
            syncCustom()
            for (label, value) in presets {
                thresholds.addItem(makeToggleItem(label, symbol: nil,
                                                  isOn: { [weak self] in (self?.lowBatteryThreshold ?? 0) == value },
                                                  action: { [weak self] in
                    self?.applyLowBatteryThreshold(value == 0 ? nil : value)
                    lowItem.attributedTitle = Self.trailingTitle("低电量自动暂停",
                                                                 value: Self.thresholdText(value == 0 ? nil : value))
                    syncCustom()
                }))
            }
            thresholds.addItem(.separator())
            thresholds.addItem(custom)
            if lowBatteryThreshold != nil, Notifier.shared.isDenied {
                thresholds.addItem(.separator())
                let notify = makeItem("打开通知提醒…", #selector(openNotificationSettings))
                notify.toolTip = "SleepCat 的通知被关掉了，暂停和恢复时只会在菜单栏下闪一下。去系统设置里打开"
                thresholds.addItem(notify)
            }
            menu.addItem(lowItem)
            menu.setSubmenu(thresholds, for: lowItem)
        } else {
            lowItem.title = "低电量自动暂停"
            lowItem.attributedTitle = Self.trailingTitle("低电量自动暂停", value: "没有电池")
            lowItem.isEnabled = false
            menu.addItem(lowItem)
        }

        // ── 效果与提示 ──
        menu.addItem(sectionHeader("效果与提示"))

        let duoItem = makeToggleItem("刘海灵动岛", symbol: "capsule",
                                     isOn: { [weak self] in self?.duoEnabled ?? false },
                                     action: { [weak self] in self?.toggleDuoSetting() })
        duoItem.toolTip = "鼠标悬停刘海展开状态胶囊，点按可切换"
        menu.addItem(duoItem)

        let blurItem = makeItem("合盖模糊效果", #selector(toggleDuoBlurSetting), symbol: "camera.filters")
        blurItem.toolTip = "合盖时整屏模糊并暗下去，合得越多越糊，重新打开就消散"
        if duoBlur != nil {
            blurItem.state = duoBlurEnabled ? .on : .off
        } else {
            blurItem.action = nil
            blurItem.isEnabled = false
            blurItem.toolTip = "这台 Mac 没有铰链角度传感器"
        }
        menu.addItem(blurItem)

        let soundItem = makeToggleItem("切换时播放喵声", symbol: "speaker.wave.2",
                                       isOn: { [weak self] in self?.soundEnabled ?? false },
                                       action: { [weak self] in self?.toggleSoundSetting() })
        menu.addItem(soundItem)

        // ── 工具 ──
        menu.addItem(sectionHeader("工具"))
        menu.addItem(powerMenuItem())
        menu.addItem(makeItem("清洁键盘…", #selector(startKeyboardCleaning), symbol: "keyboard"))

        // ── 关于 / 退出 ──
        menu.addItem(.separator())
        let recommend = NSMenuItem(title: "推荐给朋友", action: nil, keyEquivalent: "")
        recommend.image = symbol("heart")
        let recommendMenu = NSMenu()
        recommendMenu.addItem(makeItem("复制推荐语和链接", #selector(copyRecommendation), symbol: "doc.on.doc"))
        recommendMenu.addItem(makeItem("复制一行安装命令", #selector(copyInstallCommand), symbol: "terminal"))
        recommendMenu.addItem(makeItem("复制 Homebrew 安装命令", #selector(copyBrewInstallCommand), symbol: "mug"))
        recommendMenu.addItem(.separator())
        recommendMenu.addItem(makeItem("通过其他方式分享…", #selector(shareRecommendation), symbol: "square.and.arrow.up"))
        menu.addItem(recommend)
        menu.setSubmenu(recommendMenu, for: recommend)

        let updateTitle = availableUpdate.map { "更新到 \($0.version)…" } ?? "检查更新…"
        menu.addItem(makeItem(updateTitle, #selector(checkForUpdates), symbol: "arrow.triangle.2.circlepath"))
        menu.addItem(makeItem("项目主页…", #selector(openHomepage), symbol: "link"))
        menu.addItem(makeItem("退出 SleepCat", #selector(quit), symbol: "power", key: "q"))

        Self.stopAutoEnabling(menu)
        return menu
    }

    /// 调试：把菜单结构打成文本，检查分组、缩进、勾选、启用状态
    static func dumpMenu() {
        let app = SleepCatApp()
        app.duoBlur = DuoBlur(sensor: LidAngleSensor())
        app.latestWatts = PowerMeter.read()
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

    /// 文档用：真的弹出菜单，把菜单窗口自己画成 PNG（画自己的窗口不需要屏幕录制权限）。
    /// 状态伪造成「喵住 2 小时」，只在这个进程里持有电源断言，不写会话，退出即释放
    static func snapshotMenu(toDirectory dir: String, dark: Bool) {
        let app = SleepCatApp()
        app.duoBlur = DuoBlur(sensor: LidAngleSensor())
        app.blocker.start(keepDisplayOn: false)
        app.latestWatts = PowerMeter.read()
        app.powerHistory = .preview()       // 菜单里的曲线要有数据才画得出来
        app.deadline = Date().addingTimeInterval(2 * 3600 - 20)
        app.activePreset = 120
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let menu = app.buildMenu()
        var tries = 0
        let timer = Timer(timeInterval: 0.3, repeats: true) { timer in
            tries += 1
            // 有高亮行就再等等：截出来会像被人点了一样
            if menu.highlightedItem != nil, tries < 30 { return }
            timer.invalidate()
            for window in NSApp.windows where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = "menu-\(dark ? "dark" : "light").png"
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
            }
            if menu.highlightedItem != nil { print("⚠️ \(dark ? "深色" : "浅色")菜单截图带着高亮：\(menu.highlightedItem!.title)") }
            // 自绘行要和整行一样宽，悬停高亮才会铺满
            let rowWidths = Set(menu.items.compactMap { ($0.view as? MenuRow)?.frame.width })
            print("菜单宽 \(Int(menu.size.width))，自绘行宽 \(rowWidths.map { Int($0) }.sorted())")
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        // 弹在鼠标的另一半屏幕，不然鼠标下面那一行会被高亮
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let x = NSEvent.mouseLocation.x > screen.midX ? screen.minX + 40 : screen.maxX - 320
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: screen.maxY - 10), in: nil)
        app.blocker.stop()
    }

    /// 带子菜单的行：左边名字，右边灰色的当前值（喵住时长、低电量阈值、功耗读数），各行的值右边缘对齐。
    /// 系统的菜单项徽标（badge）带胶囊底色，和别的行不搭，所以不用
    static func trailingTitle(_ title: String, value: String?) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        guard let value, !value.isEmpty else { return NSAttributedString(string: title, attributes: [.font: font]) }
        let valueText = NSMutableAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        // 右对齐制表位排出来各行会差一两个像素（系统按字框对齐，「期」「%」「W」右边留白不一样），
        // 所以自己算：值的笔画右边缘要落在 trailingTab + trailingOverhang，反推出起点，用左对齐制表位放过去
        let line = CTLineCreateWithAttributedString(valueText)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: trailingTab + trailingOverhang - ink.maxX)]
        // 最后一个字挂负字距：只缩短排版宽度、不挪字形，菜单按缩短后的宽度算，字就伸进箭头左边那块空白里
        valueText.addAttribute(.kern, value: -trailingOverhang,
                               range: NSRange(location: valueText.length - 1, length: 1))
        let text = NSMutableAttributedString(string: title + "\t", attributes: [.font: font])
        text.append(valueText)
        text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))
        return text
    }

    /// 值的右边缘（从文字起点算）= 制表位 + 伸出量。制表位决定这几行至少多宽，取成和现在菜单一样宽，值才落在最右。
    /// 伸出量实测最多约 12 点，再大菜单会跟着变宽、字的位置不变；用 --snapshot-menu 截图核对
    static let trailingTab: CGFloat = 218
    static let trailingOverhang: CGFloat = 12

    static func thresholdText(_ threshold: Int?) -> String {
        threshold.map { "低于 \($0)%" } ?? "已关闭"
    }

    /// 功耗：行尾显示当前读数，子菜单里是概览面板
    static func setPowerReading(_ item: NSMenuItem, _ reading: String) {
        item.title = "功耗"
        item.attributedTitle = trailingTitle("功耗", value: reading)
    }

    private func powerMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "功耗", action: nil, keyEquivalent: "")
        item.image = symbol("bolt")
        guard let watts = latestWatts else {
            item.title = "功耗（这台 Mac 读不到）"
            item.isEnabled = false
            return item
        }
        Self.setPowerReading(item, latestFlow?.headlineText ?? "整机 \(PowerMeter.wattsText(watts))")
        powerItem = item

        // 概览面板：数据绘制时现取，菜单开着时每秒重画
        let sub = NSMenu()
        let summary = NSMenuItem(title: "功耗", action: nil, keyEquivalent: "")
        let panel = PowerSummaryView(history: { [weak self] in self?.powerHistory ?? PowerHistory() },
                                     flow: { [weak self] in self?.latestFlow })
        summary.view = panel
        sub.addItem(summary)
        powerSummary = panel
        item.submenu = sub
        return item
    }

    /// 开关 / 单选行：自绘视图，点完菜单不关，可以连着点好几个
    private func makeToggleItem(_ title: @escaping @autoclosure () -> String, symbol name: String?,
                                isOn: @escaping () -> Bool, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title(), action: nil, keyEquivalent: "")
        item.image = name.flatMap { symbol($0) }     // 只为菜单结构检查留着，显示走下面的视图
        item.isEnabled = true
        item.state = isOn() ? .on : .off             // 同上：显示由视图负责
        item.view = MenuRow(symbol: item.image, title: title(), isOn: isOn, action: action)
        return item
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
            if let flow = latestFlow { detail += " · \(flow.headlineText)" }
        } else if lidBlocker.isActive {
            title = "打盹中 · 休眠仍被禁用"
            detail = "开关一次「合盖也不休眠」可恢复"
        } else {
            title = "打盹中"
            detail = autoStopNote ?? "Mac 可正常休眠"
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

    // MARK: 推荐给朋友

    /// 下载和安装说明都在这里。以后有了官网专页，改这一个地方就行
    static let homepage = URL(string: "https://github.com/SuInk/sleepcat")!

    static let recommendationBlurb =
        "推荐一个 Mac 小工具 SleepCat 🐱 菜单栏里的小黑猫，点一下就能让 Mac 不休眠，合上盖子也照样跑，还能临时锁住键盘方便清洁。免费开源"

    /// 发微信 / QQ 用：一段话带上链接和安装命令，对方复制到终端就能装
    static var recommendationText: String {
        "\(recommendationBlurb)：\(homepage.absoluteString)\n终端一行安装：\(installCommand)"
    }

    /// 首推的安装方式：不需要先装 Homebrew。脚本同时负责升级
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/SuInk/sleepcat/main/install.sh | bash"

    /// 写全名：Homebrew 会自动 tap，也不再要求先 brew trust；隔离标记由 cask 安装后清掉
    static let brewInstallCommand = "brew install suink/tap/sleepcat"

    @objc private func copyRecommendation() {
        copyToPasteboard(Self.recommendationText)
        Toast.show("已复制，去粘贴给朋友吧", below: statusItem.button)
    }

    @objc private func copyInstallCommand() {
        copyToPasteboard(Self.installCommand)
        Toast.show("已复制安装命令，粘贴到终端就能装", below: statusItem.button)
    }

    @objc private func copyBrewInstallCommand() {
        copyToPasteboard(Self.brewInstallCommand)
        Toast.show("已复制 Homebrew 安装命令", below: statusItem.button)
    }

    @objc private func shareRecommendation() {
        guard let button = statusItem.button else { return }
        // 文字和链接分开给：信息、邮件会把链接渲染成卡片，文字里再带一遍链接就重复了
        let picker = NSSharingServicePicker(items: [Self.recommendationBlurb as NSString, Self.homepage as NSURL])
        picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: 检查更新

    /// 每天自动查一次（要联网访问 GitHub，所以可以在检查更新的弹窗里关掉）
    private var autoUpdateCheck: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdateCheck") }
    }

    private func startAutomaticUpdateChecks() {
        updateTimer?.invalidate()
        guard autoUpdateCheck else { return }
        // 启动先等一会儿再查，别和启动流程抢；之后每小时看一眼是否已满一天
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.backgroundUpdateCheck() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.backgroundUpdateCheck()
        }
    }

    private func backgroundUpdateCheck() {
        let defaults = UserDefaults.standard
        guard autoUpdateCheck else { return }
        if let last = defaults.object(forKey: "lastUpdateCheck") as? Date,
           Date().timeIntervalSince(last) < 86_400 { return }
        UpdateChecker.fetchLatest { [weak self] result in
            guard let self, case .success(let release) = result else { return }   // 后台失败就安静地算了
            defaults.set(Date(), forKey: "lastUpdateCheck")
            guard UpdateChecker.isNewer(release.version, than: UpdateChecker.currentVersion) else { return }
            self.availableUpdate = release
            // 同一个版本只提醒一次，之后靠菜单里的「更新到 x.x.x…」
            guard defaults.string(forKey: "notifiedUpdateVersion") != release.version else { return }
            defaults.set(release.version, forKey: "notifiedUpdateVersion")
            Toast.show("SleepCat \(release.version) 可以更新了，右键菜单里更新", below: self.statusItem?.button)
        }
    }

    @objc private func checkForUpdates() {
        UpdateChecker.fetchLatest { [weak self] result in
            guard let self else { return }
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            let current = UpdateChecker.currentVersion
            var release: UpdateChecker.Release?

            switch result {
            case .failure(let error):
                alert.alertStyle = .warning
                alert.messageText = "检查更新失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
            case .success(let latest) where UpdateChecker.isNewer(latest.version, than: current):
                release = latest
                self.availableUpdate = latest
                alert.messageText = "SleepCat \(latest.version) 可以更新了"
                if UpdateChecker.installedViaHomebrew {
                    alert.informativeText = "当前是 \(current)。你是用 Homebrew 装的，在终端运行：\n\n\(UpdateChecker.upgradeCommand)"
                } else {
                    alert.informativeText = "当前是 \(current)。在终端运行下面这行就能升级，设置和授权都会保留：\n\n\(Self.installCommand)"
                }
                alert.addButton(withTitle: "复制升级命令")
                alert.addButton(withTitle: "查看更新内容")
                alert.addButton(withTitle: "以后再说")
            case .success:
                self.availableUpdate = nil
                alert.messageText = "已经是最新版本"
                alert.informativeText = "当前是 \(current)。"
                alert.addButton(withTitle: "好")
            }

            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "每天自动检查更新"
            alert.suppressionButton?.state = self.autoUpdateCheck ? .on : .off
            let response = alert.runModal()
            self.autoUpdateCheck = alert.suppressionButton?.state == .on
            self.startAutomaticUpdateChecks()

            guard let release else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.copyToPasteboard(UpdateChecker.installedViaHomebrew ? UpdateChecker.upgradeCommand : Self.installCommand)
                Toast.show("已复制，粘贴到终端运行就能升级", below: self.statusItem?.button)
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(release.page)
            default:
                break
            }
        }
    }

    @objc private func openHomepage() {
        NSWorkspace.shared.open(Self.homepage)
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

    static func makeCustomDurationAlert(minutes: Int) -> (NSAlert, DurationPicker) {
        let picker = DurationPicker(minutes: minutes)
        let alert = NSAlert()
        alert.messageText = "自定义喵住时长"
        alert.informativeText = "到点后 Mac 会恢复正常休眠。"
        alert.accessoryView = picker.view
        alert.addButton(withTitle: "开始喵住")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\u{1b}"   // Esc 取消
        picker.onChange = { [weak alert] total in alert?.buttons.first?.isEnabled = total > 0 }
        picker.alignLeadingEdge(to: alert)
        alert.window.initialFirstResponder = picker.hoursField
        return (alert, picker)
    }

    /// 文档 / 调试用：弹出自定义时长对话框，把窗口画成 PNG 后关掉
    static func snapshotCustomDurationAlert(toDirectory dir: String, dark: Bool) {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let (alert, _) = makeCustomDurationAlert(minutes: 90)
        let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
            if let view = alert.window.contentView?.superview,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(dir)/duration-alert-\(dark ? "dark" : "light").png"))
            }
            NSApp.abortModal()
        }
        RunLoop.main.add(timer, forMode: .common)
        _ = alert.runModal()
    }

    static func makeCustomThresholdAlert(percent: Int) -> (NSAlert, ThresholdPicker) {
        let picker = ThresholdPicker(percent: percent)
        let alert = NSAlert()
        alert.messageText = "自定义低电量阈值"
        alert.informativeText = "插上电源后会自动恢复喵住。"
        alert.accessoryView = picker.view
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\u{1b}"   // Esc 取消
        DurationPicker.alignLeadingEdge(of: picker.view, field: picker.field, to: alert)
        alert.window.initialFirstResponder = picker.field
        return (alert, picker)
    }

    /// 调试用：把任意对话框画成 PNG 后关掉
    static func snapshotAlert(_ alert: NSAlert, toDirectory dir: String, name: String) {
        let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
            if let view = alert.window.contentView?.superview,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
            NSApp.abortModal()
        }
        RunLoop.main.add(timer, forMode: .common)
        _ = alert.runModal()
    }

    @objc private func menuCustomLowBattery() {
        NSApp.activate(ignoringOtherApps: true)
        let (alert, picker) = Self.makeCustomThresholdAlert(percent: lowBatteryThreshold ?? 15)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applyLowBatteryThreshold(picker.percent)
    }

    @objc private func menuActivateCustom() {
        NSApp.activate(ignoringOtherApps: true)
        let (alert, picker) = Self.makeCustomDurationAlert(minutes: lastCustomMinutes)
        guard alert.runModal() == .alertFirstButtonReturn, picker.totalMinutes > 0 else { return }
        lastCustomMinutes = picker.totalMinutes
        activePreset = picker.totalMinutes
        activate(duration: TimeInterval(picker.totalMinutes * 60))
    }

    /// 档位名左对齐，结束时刻右对齐成灰色一列，扫一眼就知道到几点
    static func timedTitle(_ label: String, minutes: Int, from now: Date = Date()) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: 170)]
        let font = NSFont.menuFont(ofSize: 0)   // 不显式给字体会退回 Helvetica 12
        // 结束时间用等宽数字：右对齐时各行右边缘齐了，但「1」比「2」窄，左边的「至」会错开几个像素
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        let s = NSMutableAttributedString(string: label + "\t", attributes: [
            .font: font, .paragraphStyle: para,
        ])
        s.append(NSAttributedString(
            string: DurationPicker.prefixed("至", DurationPicker.endTimeText(minutes: minutes, from: now, showToday: false)),
            attributes: [.font: timeFont, .paragraphStyle: para, .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    // MARK: NSMenuDelegate —— 菜单打开期间每秒刷新倒计时

    /// 菜单开着就每秒刷新：倒计时、实时功耗都要跟着变。
    /// 以前只在定时喵住（有倒计时）时才刷，无限期喵住或者打盹时，功耗数字打开菜单后就不动了
    func menuWillOpen(_ menu: NSMenu) {
        menuRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshOpenMenu()
        }
        RunLoop.current.add(timer, forMode: .common)  // 菜单会切到 eventTracking 模式，默认模式下定时器不走
        menuRefreshTimer = timer
    }

    private func refreshOpenMenu() {
        latestFlow = PowerMeter.readFlow()
        headerItem?.attributedTitle = headerTitle()
        if let flow = latestFlow, let powerItem { Self.setPowerReading(powerItem, flow.headlineText) }
        powerSummary?.needsDisplay = true
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
    /// - Parameter restoring: 启动时发现规则丢失、为已开启的合盖模式补写，文案不同于首次开启
    private func ensureFreePass(restoring: Bool = false) -> Bool {
        if lidBlocker.freePassInstalled() { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = restoring
            ? "合盖防护的授权规则不见了，重新写入一次？"
            : "开启「合盖也不休眠」需要一次授权"
        let why = restoring
            ? "你开着「合盖也不休眠」，但放行 pmset 的免密规则已经不可用了——常见原因是卸载时清理过、换了电脑，或者系统更新挪了 pmset 的位置，让规则里的路径失效。不补上的话，合盖还是会休眠。"
            : "合盖休眠是系统强制行为，要用管理员权限执行 pmset disablesleep 才能挡住。"
        alert.informativeText = """
        \(why)

        授权后会写入 /etc/sudoers.d/sleepcat，只放行这一条命令（开 / 关两种写法），不开放其他任何权限。之后开关合盖防护全程静默，不会再要密码。

        ⚠️ 喵住期间合上盖子，Mac 仍在运行、会发热耗电。放进背包前请先点猫猫停止。
        """
        alert.addButton(withTitle: restoring ? "重新写入" : "授权并开启")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if let err = lidBlocker.installFreePass() {
            showWarning("授权没有完成", "\(err)\n\n合盖防护未开启。")
            return false
        }
        return true
    }

    /// 启动时是否该提醒补写免密规则。用户在这个版本里拒绝过就不再每次启动都追问；
    /// 应用更新到新版本后再问一次，因为更新本身可能就是规则失效的原因。
    static func shouldRestoreLidRule(lidEnabled: Bool, ruleUsable: Bool,
                                     declinedVersion: String?, currentVersion: String) -> Bool {
        lidEnabled && !ruleUsable && declinedVersion != currentVersion
    }

    /// 应用重启或更新后，合盖模式开着但免密规则不可用：主动补写，
    /// 而不是等合上盖子、Mac 睡着了才发现没挡住。补写成功且正在喵住，立刻把合盖防护加上。
    private func restoreLidRuleIfNeeded() {
        let defaults = UserDefaults.standard
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        guard Self.shouldRestoreLidRule(lidEnabled: lidBlockEnabled,
                                        ruleUsable: lidBlocker.freePassInstalled(),
                                        declinedVersion: defaults.string(forKey: "lidRuleDeclinedVersion"),
                                        currentVersion: version) else { return }
        LidBlocker.log("启动检查：合盖模式开着但免密规则不可用，请求补写")
        guard ensureFreePass(restoring: true) else {
            defaults.set(version, forKey: "lidRuleDeclinedVersion")
            return
        }
        defaults.removeObject(forKey: "lidRuleDeclinedVersion")
        if blocker.isActive, lidBlocker.set(true) == nil {
            lidSetByUs = true
            startLidWatchdog()
            updateIcon()
        }
    }

    /// 合盖防护看门狗。
    ///
    /// 按理说 disablesleep 设一次就该管到重启，但这台机器上
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
            alert.informativeText = "禁用键盘要拦截系统的按键事件，macOS 规定这需要辅助功能权限。"
            alert.addButton(withTitle: "去授权")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                KeyboardLock.requestPermission(alsoReset: Self.legacyBundleIDs)
                waitForAccessibilityGrant()
            }
            return
        }
        if let err = keyboardLock.lock() {
            showWarning("没能禁用键盘", err)
        }
    }

    /// 用户去系统设置里打开授权后，这边没有任何动静会让人不知道下一步干嘛；
    /// 盯着授权状态，一变成已授权就提示一句。三分钟没等到就不等了
    private func waitForAccessibilityGrant() {
        permissionPoll?.invalidate()
        let started = Date()
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            if KeyboardLock.hasPermission {
                timer.invalidate()
                Toast.show("授权好了，再点一次「清洁键盘」就能用", below: self.statusItem?.button)
            } else if Date().timeIntervalSince(started) > 180 {
                timer.invalidate()
            }
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
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 应用不在跑时没人管合盖和休眠，得把 Mac 交还给系统；但不清会话，下次打开接着喵
        blocker.stop()
        flushPowerBucket()   // 退出前把没写完的那一段记下来
        restoreLidSleepIfNeeded()
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

// 调试：./SleepCat --check-update 真的去 GitHub 查一次最新版本，打印结果后退出
if CommandLine.arguments.contains("--check-update") {
    UpdateChecker.fetchLatest { result in
        switch result {
        case .success(let r):
            print("当前 \(UpdateChecker.currentVersion)，最新 \(r.version)，" +
                  "需要更新：\(UpdateChecker.isNewer(r.version, than: UpdateChecker.currentVersion))，" +
                  "Homebrew 安装：\(UpdateChecker.installedViaHomebrew)，页面 \(r.page)")
            exit(0)
        case .failure(let e):
            print("失败：\(e.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(20))
    print("超时")
    exit(1)
}

// 调试：open -n SleepCat.app --args --test-notification
// 请求通知权限并发一条测试通知，结果写进 SleepCat.log。要从应用包启动，直接跑二进制拿不到通知中心
if CommandLine.arguments.contains("--test-notification") {
    Notifier.shared.setUp()
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        LidBlocker.log("测试通知：当前授权状态 \(settings.authorizationStatus.rawValue)（0 未决定 1 拒绝 2 允许 3 临时）")
    }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
        LidBlocker.log("测试通知：授权\(granted ? "已允许" : "未允许")\(error.map { "，\($0.localizedDescription)" } ?? "")")
        let content = UNMutableNotificationContent()
        content.title = "SleepCat 通知测试"
        content.body = "看到这条，说明低电量暂停和恢复时的通知能正常弹出"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: content, trigger: nil)) { error in
            LidBlocker.log("测试通知：\(error.map { "发送失败，\($0.localizedDescription)" } ?? "已交给通知中心")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        }
    }
    // 不设超时：授权框还没点就退出，系统会把这次请求记成「拒绝」
    RunLoop.main.run()
}

// 文档用：./SleepCat --snapshot-menu <目录> 输出浅色 / 深色菜单截图后退出
if let i = CommandLine.arguments.firstIndex(of: "--snapshot-menu") {
    let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "."
    NSApplication.shared.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        SleepCatApp.snapshotMenu(toDirectory: dir, dark: false)
        SleepCatApp.snapshotMenu(toDirectory: dir, dark: true)
        exit(0)
    }
    NSApplication.shared.run()
}

// 调试：./SleepCat --snapshot-duration <目录> 输出自定义时长对话框的截图后退出
if let i = CommandLine.arguments.firstIndex(of: "--snapshot-duration") {
    let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "."
    NSApplication.shared.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        SleepCatApp.snapshotCustomDurationAlert(toDirectory: dir, dark: false)
        SleepCatApp.snapshotCustomDurationAlert(toDirectory: dir, dark: true)
        SleepCatApp.snapshotAlert(SleepCatApp.makeCustomThresholdAlert(percent: 15).0, toDirectory: dir, name: "threshold-alert-dark")
        exit(0)
    }
    NSApplication.shared.run()
}

// 调试：./SleepCat --power-probe [秒数] 按真实节奏采一段功耗，写进记录文件后退出
if let i = CommandLine.arguments.firstIndex(of: "--power-probe") {
    let seconds = CommandLine.arguments.count > i + 1 ? Double(CommandLine.arguments[i + 1]) ?? 70 : 70
    SleepCatApp.probePower(seconds: seconds, log: true)
    RunLoop.main.run()
}

// 调试：./SleepCat --blur-demo [进度 0-1] [秒] 按固定进度显示毛玻璃；--blur-sweep 模拟合盖来回扫一遍
if let i = CommandLine.arguments.firstIndex(of: "--blur-demo") ?? CommandLine.arguments.firstIndex(of: "--blur-sweep") {
    let sweep = CommandLine.arguments[i] == "--blur-sweep"
    let args = CommandLine.arguments.dropFirst(i + 1).compactMap(Double.init)
    NSApplication.shared.setActivationPolicy(.accessory)
    guard let blur = DuoBlur(sensor: LidAngleSensor()) else {
        print("这台 Mac 没有铰链角度传感器，毛玻璃不可用"); exit(1)
    }
    DispatchQueue.main.async {
        if sweep { blur.showSweep(seconds: args.first ?? 6) }
        else { blur.showDemo(progress: args.first ?? 0.7, seconds: args.count > 1 ? args[1] : 6) }
    }
    NSApplication.shared.run()
}

// 调试：./SleepCat --power-flow 打印此刻的能量流和自检结果
if CommandLine.arguments.contains("--power-flow") {
    if let flow = PowerMeter.readFlow() {
        print("整机 \(PowerMeter.wattsText(flow.system))，适配器 \(flow.adapter.map(PowerMeter.wattsText) ?? "未插电")，"
              + "电池 \(flow.battery.map { String(format: "%+.1f W", $0) } ?? "无")")
        print("主读数：\(flow.headlineText)　细节：\(flow.detail)")
        print("自检：\(flow.isConsistent ? "对得上" : "对不上，某个读数不可信")")
    } else {
        print("读不到功耗")
    }
    exit(0)
}

// 调试：./SleepCat --snapshot-align <目录> 原生行和自绘行放在同一个菜单里截图，检查左边界对不对齐
if let i = CommandLine.arguments.firstIndex(of: "--snapshot-align") {
    let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "."
    NSApplication.shared.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let native = NSMenuItem(title: "原生 低于 20%", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        native.state = .on
        menu.addItem(native)
        menu.addItem(NSMenuItem(title: "原生 关闭", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        row.view = MenuRow(symbol: nil, title: "自绘 低于 20%", isOn: { true }, action: {})
        menu.addItem(row)
        let row2 = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        row2.view = MenuRow(symbol: nil, title: "自绘 关闭", isOn: { false }, action: {})
        menu.addItem(row2)
        // 喵住时长那种右对齐时间列：检查「至」是不是竖直对齐
        menu.addItem(.separator())
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 1, minute: 25))!
        for (label, minutes) in SleepCatApp.presets {
            let item = NSMenuItem(title: label, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            item.attributedTitle = SleepCatApp.timedTitle(label, minutes: minutes, from: base)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // 带图标的两种，检查勾和图标之间的距离
        let icon = NSImage(systemSymbolName: "capsule", accessibilityDescription: nil)
        let nativeIcon = NSMenuItem(title: "原生 刘海灵动岛", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        nativeIcon.image = icon
        nativeIcon.state = .on
        menu.addItem(nativeIcon)
        let rowIcon = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        rowIcon.view = MenuRow(symbol: icon, title: "自绘 刘海灵动岛", isOn: { true }, action: {})
        menu.addItem(rowIcon)
        // 功耗面板：左右边距要和分隔线两端对齐
        menu.addItem(.separator())
        let panel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let history = PowerHistory.preview(hours: 1)
        panel.view = PowerSummaryView(history: { history },
                                      flow: { PowerFlow(system: 6.1, adapter: nil, battery: -7.0) })
        menu.addItem(panel)
        // 真实的功耗子菜单里只有这块面板：单独弹一个一模一样的菜单再看一次
        if CommandLine.arguments.contains("--power-only") {
            menu.removeAllItems()
            menu.addItem(panel)
        }
        let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
            for window in NSApp.windows where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/align.png"))
            }
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let x = NSEvent.mouseLocation.x > screen.midX ? screen.minX + 40 : screen.maxX - 320
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: screen.maxY - 10), in: nil)
        exit(0)
    }
    NSApplication.shared.run()
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
    PowerChart.renderPreview(toDirectory: dir)
    PowerSummaryView.renderPreview(toDirectory: dir)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // 只出现在菜单栏，不占 Dock
let delegate = SleepCatApp()
app.delegate = delegate
app.run()
