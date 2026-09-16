// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import Testing
import Foundation
import AppKit
@testable import SleepCat

@Suite struct MeowSoundTests {
    @Test func wavHeaderIsValid() {
        let d = MeowSound.wavData()
        #expect(d.count > 44, "至少要有 WAV 头 + 数据")
        #expect(String(data: d.subdata(in: 0..<4), encoding: .ascii) == "RIFF")
        #expect(String(data: d.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        #expect(String(data: d.subdata(in: 36..<40), encoding: .ascii) == "data")
        // 16-bit 单声道：数据段必须是偶数字节
        #expect((d.count - 44) % 2 == 0)
    }

    @Test func meowIsNotSilent() {
        let d = MeowSound.wavData()
        let samples: [Int16] = d.subdata(in: 44..<d.count).withUnsafeBytes {
            Array($0.bindMemory(to: Int16.self))
        }
        #expect(samples.contains { abs(Int($0)) > 3000 }, "喵声不能是静音")
        // 包络收尾：最后 100 个采样应接近安静（无爆音）
        #expect(samples.suffix(100).allSatisfy { abs(Int($0)) < 2000 }, "结尾应渐弱")
    }
}

@Suite struct AppIconTests {
    @Test func exportsEveryIconsetSizeAtTheRightResolution() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleepcat-test-\(UUID().uuidString).iconset").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try AppIcon.writeIconset(to: dir)

        // iconutil 要求的 10 个文件，名字和像素尺寸都必须严格对应
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                let rep = NSImageRep(contentsOfFile: "\(dir)/\(name)")
                #expect(rep?.pixelsWide == base * scale, "\(name) 尺寸不对")
            }
        }
    }
}

@Suite struct CatIconTests {
    @Test func iconsAreTemplates() {
        #expect(CatIcon.awake.isTemplate, "模板图才能适配深浅色菜单栏")
        #expect(CatIcon.asleep.isTemplate)
    }

    @Test func iconSizes() {
        // 右上角分别要放 ！！ 和 Zz；两种状态同宽，切换时菜单栏里的图标不会左右跳
        #expect(CatIcon.awake.size == CatIcon.canvasSize)
        #expect(CatIcon.awake.size.width == CatIcon.awake.size.width.rounded() &&
                CatIcon.awake.size.height == CatIcon.awake.size.height.rounded(),
                "尺寸必须是整 pt，否则 Retina 上会发虚")
        #expect(CatIcon.awake.size.height <= NSStatusBar.system.thickness, "不能比状态栏还高")
        #expect(CatIcon.asleep.size == CatIcon.awake.size)
    }

    @Test func awakeAndAsleepLookDifferent() {
        #expect(CatIcon.awake.tiffRepresentation != CatIcon.asleep.tiffRepresentation)
    }
}

@Suite struct LidBlockerParseTests {
    @Test func parsesDisabledOn() {
        #expect(LidBlocker.parseSleepDisabled(" SleepDisabled\t\t1\n Sleep On Power Button 1"))
    }

    @Test func parsesDisabledOff() {
        #expect(!LidBlocker.parseSleepDisabled(" SleepDisabled\t\t0\n"))
    }

    @Test func missingKeyMeansOff() {
        #expect(!LidBlocker.parseSleepDisabled("standby 1\nhibernatemode 3\n"))
        #expect(!LidBlocker.parseSleepDisabled(""))
    }

    @Test func pmsetPathExists() {
        #expect(FileManager.default.isExecutableFile(atPath: LidBlocker.pmsetPath),
                "探测到的 pmset 路径必须真实存在")
    }
}

@Suite struct DuoBlurMappingTests {
    @Test func fullyOpenIsClear() {
        #expect(DuoBlur.progress(forAngle: 130) == 0)
        #expect(DuoBlur.progress(forAngle: 100) == 0)
    }

    @Test func closingRampsUp() {
        #expect(DuoBlur.progress(forAngle: 70) == 0.5)
        #expect(abs(DuoBlur.progress(forAngle: 85) - 0.25) < 0.0001)
    }

    @Test func nearClosedIsFullyBlurred() {
        #expect(DuoBlur.progress(forAngle: 40) == 1)
        #expect(DuoBlur.progress(forAngle: 5) == 1)
        #expect(DuoBlur.progress(forAngle: 0) == 1)
    }

    @Test func blurIsProgressiveFromHingeToTop() {
        // 靠铰链的底部最清晰，越往上叠的模糊层越多，且单调递增
        let samples = stride(from: 0.0, through: 1.0, by: 0.1).map { DuoBlur.blurDepth(atHeight: $0) }
        #expect(samples.first! < 0.5, "底部应接近清晰")
        #expect(samples.last! == Double(DuoBlur.blurBands.count), "顶部应叠满所有层")
        for (a, b) in zip(samples, samples.dropFirst()) {
            #expect(b >= a, "模糊强度不能出现回落")
        }
    }

    @Test func cursorOnlyHidesOnceWellIntoTheFold() {
        #expect(!DuoBlur.shouldHideCursor(progress: 0))
        #expect(!DuoBlur.shouldHideCursor(progress: 0.4), "刚起雾时用户可能还在操作")
        #expect(DuoBlur.shouldHideCursor(progress: 0.8))
        #expect(DuoBlur.shouldHideCursor(progress: 1))
    }

    @Test func blurRadiusFollowsTheAngle() {
        // 全开时滤镜要整个关掉，不然静止时也在白烧 GPU
        for band in DuoBlur.blurBands.indices {
            #expect(DuoBlur.blurRadius(progress: 0, band: band) == 0)
        }
        // 同一层：越合越糊，单调不回落
        let ramp = stride(from: 0.0, through: 1.0, by: 0.05).map { DuoBlur.blurRadius(progress: $0, band: 0) }
        for (a, b) in zip(ramp, ramp.dropFirst()) { #expect(b >= a) }
        #expect(ramp.last! == DuoBlur.maxBlurRadius)
        // 同一进度：靠上的层先起雾，糊得更厉害
        let atHalf = DuoBlur.blurBands.indices.map { DuoBlur.blurRadius(progress: 0.5, band: $0) }
        for (a, b) in zip(atHalf, atHalf.dropFirst()) { #expect(b >= a) }
    }

    @Test func frostAndPollFollowProgress() {
        #expect(DuoBlur.frostOpacity(progress: 0) == 0)
        #expect(DuoBlur.frostOpacity(progress: 1) > 0.8)
        #expect(DuoBlur.frostOpacity(progress: 0.5) < DuoBlur.frostOpacity(progress: 0.9))
        // 盖子摊开不动时慢慢看着，一开始合就切到 60 帧
        #expect(DuoBlur.pollInterval(progress: 0, angle: 130) == 0.1)
        #expect(DuoBlur.pollInterval(progress: 0, angle: 95) < 0.02)
        #expect(DuoBlur.pollInterval(progress: 0.3, angle: 130) < 0.02)
    }

    @Test func smoothingIsFrameRateIndependent() {
        // 同样的 0.3 秒，用 60 帧还是 10 帧推进，结果要基本一致
        func run(steps: Int) -> Double {
            var value = 0.0
            for _ in 0..<steps { value = DuoBlur.smoothed(current: value, target: 1, dt: 0.3 / Double(steps)) }
            return value
        }
        #expect(abs(run(steps: 18) - run(steps: 3)) < 0.05)
        #expect(run(steps: 18) > 0.9, "0.3 秒内基本跟上")
        #expect(DuoBlur.smoothed(current: 0.5, target: 0.5, dt: 1) == 0.5)
    }

    @Test func grainPatternIsAvailable() {
        #expect(DuoBlur.grainPattern(tile: 16) != nil, "磨砂颗粒生成失败的话玻璃会显得像塑料")
    }

    @Test func neverOutOfRange() {
        for angle in stride(from: -10.0, through: 360.0, by: 5) {
            let p = DuoBlur.progress(forAngle: angle)
            #expect(p >= 0 && p <= 1)
        }
    }
}

@Suite struct DurationTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    func at(_ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: h, minute: m))!
    }

    @Test func durationText() {
        #expect(DurationPicker.durationText(minutes: 45) == "45 分钟")
        #expect(DurationPicker.durationText(minutes: 60) == "1 小时")
        #expect(DurationPicker.durationText(minutes: 90) == "1 小时 30 分")
        #expect(DurationPicker.durationText(minutes: 480) == "8 小时")
    }

    @Test func endTimeSameDay() {
        #expect(DurationPicker.endTimeText(minutes: 90, from: at(14, 0), calendar: cal) == "今天 15:30")
        #expect(DurationPicker.endTimeText(minutes: 90, from: at(14, 0), calendar: cal, showToday: false) == "15:30")
    }

    @Test func endTimeCrossesMidnight() {
        // 晚上 8 点挂 8 小时 → 明早 4 点，这正是"挂一晚上"的典型场景
        #expect(DurationPicker.endTimeText(minutes: 480, from: at(20, 0), calendar: cal) == "明天 04:00")
        #expect(DurationPicker.endTimeText(minutes: 72 * 60, from: at(10, 0), calendar: cal) == "9月16日 10:00")
    }

    @Test func summarySaysWhenTheCatGoesToSleep() {
        // 时长已经在输入框里了，下面那行只说几点去睡
        #expect(DurationPicker.summaryText(minutes: 90, from: at(14, 0), calendar: cal) == "今天 15:30 放猫猫去睡")
        #expect(DurationPicker.summaryText(minutes: 480, from: at(20, 0), calendar: cal) == "明天 04:00 放猫猫去睡")
        #expect(DurationPicker.summaryText(minutes: 0, from: at(20, 0), calendar: cal) == "时长不能为 0")
    }

    @Test func cjkSpacing() {
        #expect(DurationPicker.prefixed("至", "22:39") == "至 22:39")
        #expect(DurationPicker.prefixed("至", "明天 04:00") == "至明天 04:00")
    }

    @Test func presetsCoverAWorkdayOrANight() {
        let minutes = SleepCatApp.presets.map(\.1)
        #expect(minutes == minutes.sorted(), "档位要从短到长")
        #expect(minutes.max()! >= 480, "至少要能挂一整晚")
    }
}

@Suite struct MenuLayoutTests {
    @MainActor @Test func everyIconSharesOneColumnWidth() {
        let widths = Set(SleepCatApp().buildMenu().items.compactMap { $0.image?.size.width })
        #expect(widths.count == 1, "图标宽度必须统一，否则每行文字起点会左右浮动：\(widths)")
    }

    @MainActor @Test func noRowIsIndented() {
        // 缩进会把勾、图标、文字整体右移，上一版的「免密切换」就是这么歪的
        let indented = SleepCatApp().buildMenu().items.filter { $0.indentationLevel > 0 }.map(\.title)
        #expect(indented.isEmpty, "缩进的行：\(indented)")
    }

    @MainActor @Test func everyRowHasAnIcon() {
        let rows = SleepCatApp().buildMenu().items.filter {
            !$0.isSeparatorItem && $0.attributedTitle == nil && !$0.title.isEmpty
        }
        let naked = rows.filter { $0.image == nil }.map(\.title)
        // 分组标题本身没有图标，其余每行都该有
        #expect(naked.allSatisfy { ["喵住设置", "效果与提示", "工具"].contains($0) }, "缺图标的行：\(naked)")
    }
}

@Suite struct KeyboardLockTests {
    // 不在测试里真的调用 lock()：跑测试的终端若恰好有辅助功能权限，会把人的键盘锁住
    @Test func blocksKeysModifiersAndFunctionRow() {
        let mask = KeyboardLock.blockedMask
        for type in [CGEventType.keyDown, .keyUp, .flagsChanged] {
            #expect(mask & (1 << type.rawValue) != 0, "\(type.rawValue) 没被拦截")
        }
        #expect(mask & (1 << 14) != 0, "亮度 / 音量 / 媒体键（NX_SYSDEFINED）没被拦截")
    }

    @MainActor @Test func noTextOnThePanelIsSelectable() {
        // 可选中的文本会让鼠标变成输入光标（wrappingLabelWithString 默认就是可选中的）
        func walk(_ v: NSView) -> [NSTextField] {
            (v as? NSTextField).map { [$0] } ?? [] + v.subviews.flatMap(walk)
        }
        let content = KeyboardLock.makeContent(size: KeyboardLock.panelSize, target: nil, action: nil)
        let fields = walk(content)
        #expect(!fields.isEmpty)
        let selectable = fields.filter { $0.isSelectable || $0.isEditable }.map(\.stringValue)
        #expect(selectable.isEmpty, "可选中的文本：\(selectable)")
    }

    @MainActor @Test func unlockButtonWorksWithoutTheWindowBeingActive() {
        let button = PillButton(title: "清洁完成")
        var clicked = false
        button.onClick = { clicked = true }
        #expect(button.acceptsFirstMouse(for: nil), "面板从不是当前窗口，不接受首次点击就得点两下")
        #expect(button.accessibilityPerformPress())
        #expect(clicked)
    }

    @Test func leavesTheMouseAloneSoTheUnlockButtonStaysClickable() {
        let mask = KeyboardLock.blockedMask
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .mouseMoved] {
            #expect(mask & (1 << type.rawValue) == 0)
        }
    }
}

@Suite struct BlurGateTests {
    @Test func staysBlurredWhetherRestingOrFullyClosed() {
        // 停在半路、合到底都保持模糊，不会在最后一下变回清晰
        #expect(BlurGate.shouldShow(screenWatched: false))
        #expect(DuoBlur.progress(forAngle: 0) == 1, "合到底时模糊应该是满的")
    }

    @Test func getsOutOfTheWayWhileTheScreenIsWatched() {
        // 远程控制 / 屏幕共享 / 录屏时覆盖层会盖住对方看到的画面
        #expect(!BlurGate.shouldShow(screenWatched: true))
    }
}

@Suite struct ScreenWatchTests {
    @Test func probeResolvesOnThisSystem() {
        // 私有接口，系统升级可能改名；那时检测会静默失效，这条测试负责报警
        #expect(ScreenWatch.isAvailable, "SkyLight 里找不到 SLSIsScreenWatcherPresent")
    }
}

@Suite struct LowBatteryGuardTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func t(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func battery(_ p: Int) -> PowerStatus { PowerStatus(onBattery: true, percent: p) }
    func plugged(_ p: Int) -> PowerStatus { PowerStatus(onBattery: false, percent: p) }

    @Test func pausesOnlyAfterStayingLowOnBatteryForTheGracePeriod() {
        var g = LowBatteryGuard()
        let early = g.shouldPause(battery(20), threshold: 20, sessionActive: true, now: t(0))
        #expect(!early, "刚到阈值不立刻停，要先确认")
        #expect(g.secondsUntilDecision(now: t(10)) == LowBatteryGuard.grace - 10, "要约好复查时间")
        let late = g.shouldPause(battery(19), threshold: 20, sessionActive: true, now: t(LowBatteryGuard.grace))
        #expect(late, "持续低电量满确认期就暂停")
        let again = g.shouldPause(battery(18), threshold: 20, sessionActive: true, now: t(200))
        #expect(!again, "已经暂停过，不会反复触发")
    }

    @Test func briefSwitchToBatteryWhilePluggedInIsIgnored() {
        // 2026-09-16 00:07:34 真实发生过：电源插着，负载高时系统报告「用电池」4 秒又切回电源
        var g = LowBatteryGuard()
        let a = g.shouldPause(plugged(20), threshold: 20, sessionActive: true, now: t(0))
        let b = g.shouldPause(battery(20), threshold: 20, sessionActive: true, now: t(1))
        let c = g.shouldPause(plugged(20), threshold: 20, sessionActive: true, now: t(5))
        let d = g.shouldPause(plugged(20), threshold: 20, sessionActive: true, now: t(120))
        #expect(!a && !b && !c && !d)
        #expect(g.secondsUntilDecision(now: t(5)) == nil, "切回电源后确认期作废")
    }

    @Test func neverPausesWhilePluggedIn() {
        var g = LowBatteryGuard()
        let r = g.shouldPause(plugged(5), threshold: 20, sessionActive: true, now: t(999))
        #expect(!r, "插着电源就是在充电")
    }

    @Test func offMeansOff() {
        var g = LowBatteryGuard()
        let a = g.shouldPause(battery(3), threshold: nil, sessionActive: true, now: t(0))
        let b = g.shouldPause(battery(3), threshold: nil, sessionActive: true, now: t(999))
        #expect(!a && !b)
    }

    @Test func manualStartBelowThresholdIsRespected() {
        // 电量 15% 时用户手动开喵住：是有意的，不能过一分钟就被暂停
        var g = LowBatteryGuard()
        let overridden = g.noteManualStart(battery(15), threshold: 20)
        #expect(overridden, "应该提示用户这次不会暂停")
        let a = g.shouldPause(battery(15), threshold: 20, sessionActive: true, now: t(0))
        let b = g.shouldPause(battery(8), threshold: 20, sessionActive: true, now: t(600))
        #expect(!a && !b)
    }

    @Test func pluggingInReArmsIt() {
        var g = LowBatteryGuard()
        _ = g.noteManualStart(battery(15), threshold: 20)
        _ = g.shouldPause(plugged(15), threshold: 20, sessionActive: true, now: t(0))
        _ = g.shouldPause(battery(15), threshold: 20, sessionActive: true, now: t(10))
        let r = g.shouldPause(battery(15), threshold: 20, sessionActive: true, now: t(10 + LowBatteryGuard.grace))
        #expect(r, "拔掉电源、持续低电量后重新生效")
    }

    @Test func doesNothingWhenNotKeepingAwake() {
        var g = LowBatteryGuard()
        _ = g.shouldPause(battery(10), threshold: 20, sessionActive: false, now: t(0))
        let r = g.shouldPause(battery(10), threshold: 20, sessionActive: false, now: t(999))
        #expect(!r)
    }

    @Test func resumesWhenPowerComesBackOrTheFeatureIsOff() {
        #expect(LowBatteryGuard.shouldResume(plugged(18), threshold: 20), "插上电源就恢复")
        #expect(LowBatteryGuard.shouldResume(battery(18), threshold: nil), "关掉了低电量暂停就恢复")
    }

    @Test func doesNotFlapAroundTheThresholdOnBattery() {
        // 用电池时电量在 20、21 之间跳，不能跟着反复恢复、暂停；要高出余量才算回来了
        #expect(!LowBatteryGuard.shouldResume(battery(21), threshold: 20))
        #expect(LowBatteryGuard.shouldResume(battery(20 + LowBatteryGuard.resumeMargin), threshold: 20),
                "比如把阈值调低到当前电量以下，就该恢复")
    }

    @Test func readsThisMacsBatterySanely() {
        // 台式机没有电池会返回 nil，那也是对的
        if let s = BatteryMonitor.read() {
            #expect((0...100).contains(s.percent))
        }
    }
}

@Suite struct RecommendTests {
    @Test func copiedTextCarriesTheLinkAndTheInstallCommand() {
        #expect(SleepCatApp.recommendationText.contains(SleepCatApp.homepage.absoluteString))
        #expect(SleepCatApp.recommendationText.contains(SleepCatApp.installCommand))
    }

    @Test func installCommandsAreOneLine() {
        // 一行命令是首推：不需要先装 Homebrew；两条都不能拼接多条命令
        #expect(SleepCatApp.installCommand.hasPrefix("curl -fsSL "))
        #expect(SleepCatApp.installCommand.hasSuffix("/install.sh | bash"))
        #expect(SleepCatApp.brewInstallCommand == "brew install suink/tap/sleepcat")
        for cmd in [SleepCatApp.installCommand, SleepCatApp.brewInstallCommand] {
            #expect(!cmd.contains("&&"), "不该再拼接多条命令")
        }
    }

    @Test func installCommandsMatchTheReadme() throws {
        // 推荐出去的命令要和 README 写的一模一样，改一边忘了另一边就会装不上
        let readme = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/SleepCatTests/SleepCatTests.swift", with: "README.md"), encoding: .utf8)
        #expect(readme.contains(SleepCatApp.installCommand))
        #expect(readme.contains(SleepCatApp.brewInstallCommand))
        // README 里一行命令要排在 Homebrew 前面
        let script = try #require(readme.range(of: SleepCatApp.installCommand))
        let brew = try #require(readme.range(of: SleepCatApp.brewInstallCommand))
        #expect(script.lowerBound < brew.lowerBound)
    }
}

@Suite struct UpdateCheckerTests {
    @Test func comparesVersionsNumerically() {
        #expect(UpdateChecker.isNewer("1.2.0", than: "1.1.0"))
        #expect(UpdateChecker.isNewer("1.10.0", than: "1.9.0"), "按数字比，不能按字符串比")
        #expect(UpdateChecker.isNewer("2.0", than: "1.99.99"))
        #expect(!UpdateChecker.isNewer("1.1.0", than: "1.1.0"))
        #expect(!UpdateChecker.isNewer("1.0.9", than: "1.1.0"), "旧版本不能提示更新")
    }

    @Test func toleratesTagPrefixAndShortVersions() {
        #expect(!UpdateChecker.isNewer("v1.2", than: "1.2.0"), "v 前缀和补零不影响比较")
        #expect(UpdateChecker.isNewer("v1.2.1", than: "1.2"))
    }

    @Test func parsesGitHubLatestRelease() throws {
        let json = #"{"tag_name":"v1.2.0","html_url":"https://github.com/SuInk/sleepcat/releases/tag/v1.2.0","name":"SleepCat 1.2.0"}"#
        let release = try #require(UpdateChecker.parse(Data(json.utf8)))
        #expect(release.version == "1.2.0")
        #expect(release.page.absoluteString.hasSuffix("/v1.2.0"))
    }

    @Test func rejectsUnexpectedPayloads() {
        #expect(UpdateChecker.parse(Data(#"{"message":"Not Found"}"#.utf8)) == nil)
        #expect(UpdateChecker.parse(Data("not json".utf8)) == nil)
    }
}

@Suite struct LidRuleRestoreTests {
    @Test func promptsWhenLidModeIsOnButTheRuleIsGone() {
        #expect(SleepCatApp.shouldRestoreLidRule(lidEnabled: true, ruleUsable: false,
                                                 declinedVersion: nil, currentVersion: "1.1.0"))
    }

    @Test func staysQuietWhenNothingIsMissing() {
        #expect(!SleepCatApp.shouldRestoreLidRule(lidEnabled: true, ruleUsable: true,
                                                  declinedVersion: nil, currentVersion: "1.1.0"))
        #expect(!SleepCatApp.shouldRestoreLidRule(lidEnabled: false, ruleUsable: false,
                                                  declinedVersion: nil, currentVersion: "1.1.0"),
                "没开合盖模式就用不到这条规则")
    }

    @Test func doesNotNagEveryLaunchAfterADecline() {
        #expect(!SleepCatApp.shouldRestoreLidRule(lidEnabled: true, ruleUsable: false,
                                                  declinedVersion: "1.1.0", currentVersion: "1.1.0"))
    }

    @Test func asksAgainAfterAnUpdate() {
        // 更新本身可能就是规则失效的原因
        #expect(SleepCatApp.shouldRestoreLidRule(lidEnabled: true, ruleUsable: false,
                                                 declinedVersion: "1.0.0", currentVersion: "1.1.0"))
    }
}

@Suite struct InstallScriptTests {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func scriptParsesUnderSystemBash() throws {
        // 用户是 curl | bash，macOS 自带的是 bash 3.2，语法错一个字符就整个装不上
        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = ["-n", root.appendingPathComponent("install.sh").path]
        try bash.run()
        bash.waitUntilExit()
        #expect(bash.terminationStatus == 0)
    }

    @Test func readmeCommandPointsAtTheScriptInThisRepo() throws {
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme.contains("curl -fsSL https://raw.githubusercontent.com/SuInk/sleepcat/main/install.sh | bash"))
        #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("install.sh").path))
    }
}

@Suite struct LegacyDefaultsMigrationTests {
    @Test func carriesSettingsOverWithoutClobberingOrRepeating() throws {
        let legacy = "test.sleepcat.legacy.\(UUID().uuidString)"
        let destName = "test.sleepcat.dest.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: legacy)
            UserDefaults.standard.removePersistentDomain(forName: destName)
        }
        UserDefaults.standard.setPersistentDomain(
            ["lidBlockEnabled": true, "soundEnabled": true, "sessionActive": true], forName: legacy)
        let dest = try #require(UserDefaults(suiteName: destName))
        dest.set(false, forKey: "soundEnabled")   // 新 ID 下已经改过的设置

        SleepCatApp.migrateLegacyDefaults(from: [legacy], into: dest)
        #expect(dest.bool(forKey: "lidBlockEnabled"), "旧设置要搬过来")
        #expect(dest.bool(forKey: "sessionActive"), "进行中的会话也要搬，才能无缝接上")
        #expect(!dest.bool(forKey: "soundEnabled"), "不能覆盖新 ID 下已有的值")

        // 只搬一次：之后旧域里再有变化也不再同步
        UserDefaults.standard.setPersistentDomain(["keepDisplayOn": true], forName: legacy)
        SleepCatApp.migrateLegacyDefaults(from: [legacy], into: dest)
        #expect(!dest.bool(forKey: "keepDisplayOn"))
    }
}

@Suite struct SessionResumeTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func unlimitedSessionSurvivesAnyGap() {
        // 退出、更新、重启 Mac 之后隔多久打开都接着喵，只有用户亲手停才算结束
        #expect(SleepCatApp.shouldResume(active: true, deadline: nil, now: now))
    }

    @Test func runningTimerResumesWithTheRemainingTime() {
        #expect(SleepCatApp.shouldResume(active: true, deadline: now.addingTimeInterval(600), now: now))
    }

    @Test func expiredTimerDoesNotResume() {
        // 应用关着的时候定时已经到点：该停就停，不能打开应用又喵起来
        #expect(!SleepCatApp.shouldResume(active: true, deadline: now.addingTimeInterval(-1), now: now))
    }

    @Test func stoppedSessionDoesNotResume() {
        #expect(!SleepCatApp.shouldResume(active: false, deadline: nil, now: now))
    }
}

@Suite struct SleepBlockerTests {
    @Test func assertionLifecycle() {
        let b = SleepBlocker()
        b.start(keepDisplayOn: false)
        #expect(b.isActive, "IOPM 断言创建应成功")
        b.stop()
        #expect(!b.isActive)
    }

    @Test func restartReplacesAssertion() {
        let b = SleepBlocker()
        b.start(keepDisplayOn: false)
        b.start(keepDisplayOn: true)  // 重挂不同类型的断言
        #expect(b.isActive)
        b.stop()
        #expect(!b.isActive)
    }
}

@Suite struct PowerTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func integratesWattsIntoWattHours() {
        // 恒定 10 W 跑一小时就是 10 Wh
        var session = PowerSession(watts: 10, at: start)
        for minute in 1...60 {
            session.add(watts: 10, at: start.addingTimeInterval(TimeInterval(minute * 60)))
        }
        #expect(abs(session.energyWattHours - 10) < 0.01)
        #expect(abs(session.averageWatts - 10) < 0.01)
        #expect(session.peakWatts == 10)
    }

    @Test func averagesAcrossChangingLoad() {
        // 半小时 20 W + 半小时 4 W = 12 Wh，平均 12 W（按真实的采样节奏，一分钟一个点）
        var session = PowerSession(watts: 20, at: start)
        for minute in 1...60 {
            session.add(watts: minute <= 30 ? 20 : 4, at: start.addingTimeInterval(TimeInterval(minute * 60)))
        }
        // 功率骤降的那一分钟按梯形算，会比理论值多一点点（12.13 Wh）
        #expect(abs(session.energyWattHours - 12) < 0.2)
        #expect(abs(session.averageWatts - 12) < 0.2)
        #expect(session.peakWatts == 20)
    }

    @Test func skipsLongGaps() {
        // 合盖睡过去几小时后才有下一个采样：这段空档不能按最后的功率算进去
        var session = PowerSession(watts: 10, at: start)
        session.add(watts: 10, at: start.addingTimeInterval(4 * 3600))
        #expect(session.energyWattHours == 0)
    }

    @Test func csvLineMatchesTheHeader() {
        var session = PowerSession(watts: 10, at: start)
        for minute in 1...60 {
            session.add(watts: 10, at: start.addingTimeInterval(TimeInterval(minute * 60)))
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let cells = session.csvLine(formatter: f).split(separator: ",", omittingEmptySubsequences: false)
        #expect(cells.count == PowerLog.header.split(separator: ",").count)
        #expect(cells[2] == "60")            // 时长分钟
        #expect(cells[3] == "10.00")         // 用电 Wh
    }

    @Test func sumsTodayFromTheLog() {
        let csv = """
        \(PowerLog.header)
        2026-09-16 01:00,2026-09-16 02:00,60,10.00,10.0,22.0,360
        2026-09-16 09:00,2026-09-16 09:30,30,4.50,9.0,15.0,180
        2026-09-15 23:00,2026-09-15 23:30,30,3.00,6.0,11.0,180
        """
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 12))!
        let total = PowerLog.sumWattHours(inCSV: csv, on: day, calendar: cal)
        #expect(total.map { abs($0 - 14.5) < 0.001 } == true)
        #expect(PowerLog.sumWattHours(inCSV: PowerLog.header, on: day, calendar: cal) == nil)
    }

    @Test func appendsToTheLogFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleepcat-power-\(UUID().uuidString)/功耗记录.csv")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var session = PowerSession(watts: 10, at: start)
        for minute in 1...60 { session.add(watts: 10, at: start.addingTimeInterval(TimeInterval(minute * 60))) }
        PowerLog.append(session, to: url)
        PowerLog.append(session, to: url)

        let data = try Data(contentsOf: url)
        let text = try #require(String(data: data, encoding: .utf8))
        let lines = text.split(separator: "\n")
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF], "带 BOM，Excel 打开中文表头才不乱码")
        #expect(lines.count == 3, "表头只写一次，两次记录各占一行")
        #expect(lines[0].hasSuffix(PowerLog.header))
        #expect(lines[1] == lines[2])
    }

    @Test func formatsWattsAndEnergy() {
        // 一律带一位小数：取整的话十几瓦的变化在菜单上看不出来
        #expect(PowerMeter.wattsText(9.74) == "9.7 W")
        #expect(PowerMeter.wattsText(23.4) == "23.4 W")
        #expect(PowerMeter.wattsText(100) == "100.0 W")
        #expect(PowerMeter.energyText(4.26) == "4.3 Wh")
        #expect(PowerMeter.energyText(34.6) == "34.6 Wh")
    }
}

@Suite struct FoldGeometryTests {
    let w = 1710.0, h = 1112.0

    @Test func fullyOpenIsIdentity() {
        // 还没开始折的时候，画面必须原封不动地贴在屏幕上
        let corners = FoldGeometry.projectedCorners(width: w, height: h, angle: FoldGeometry.startAngle)
        #expect(abs(corners[0].x - 0) < 0.001 && abs(corners[0].y - 0) < 0.001)
        #expect(abs(corners[3].x - w) < 0.001 && abs(corners[3].y - h) < 0.001)
        #expect(FoldGeometry.progress(forAngle: FoldGeometry.startAngle) == 0)
        #expect(FoldGeometry.progress(forAngle: 130) == 0)
    }

    @Test func pictureStaysPutAsTheLidCloses() {
        // 屏幕转过去以后，画面在屏幕坐标里必须「长高」：这正是画面没跟着动的表现
        var lastTop = h
        for angle in stride(from: FoldGeometry.startAngle, through: 10, by: -10) {
            let corners = FoldGeometry.projectedCorners(width: w, height: h, angle: angle)
            #expect(corners[2].y >= lastTop - 0.001, "顶边应该越来越高，角度 \(angle)")
            lastTop = corners[2].y
            // 铰链边永远钉在原处
            #expect(abs(corners[0].y) < 0.001 && abs(corners[1].y) < 0.001)
            // 左右对称
            #expect(abs((corners[2].x - w / 2) + (corners[3].x - w / 2)) < 0.001)
        }
        #expect(lastTop > h, "合到底时画面顶边应该已经超出屏幕")
    }

    @Test func profilesStaySharpAtTheHinge() {
        #expect(FoldGeometry.blurProfile(atHeight: 0) == FoldGeometry.blurFloor)
        #expect(FoldGeometry.blurProfile(atHeight: 1) == 1)
        #expect(FoldGeometry.dimProfile(atHeight: 0) == 0)
        #expect(FoldGeometry.dimProfile(atHeight: FoldGeometry.dimStart) == 0, "铰链附近不压暗")
        #expect(abs(FoldGeometry.dimProfile(atHeight: 1) - FoldGeometry.maxDim) < 0.001)
        let ramp = stride(from: 0.0, through: 1.0, by: 0.05).map { FoldGeometry.dimProfile(atHeight: $0) }
        for (a, b) in zip(ramp, ramp.dropFirst()) { #expect(b >= a) }
    }

    @Test func strengthCurvesStartSlow() {
        #expect(FoldGeometry.blurStrength(progress: 0) == 0)
        #expect(FoldGeometry.blurStrength(progress: 1) == 1)
        // 模糊比变暗起得晚：前半程画面先暗下去，还没糊
        #expect(FoldGeometry.blurStrength(progress: 0.5) < FoldGeometry.dimStrength(progress: 0.5))
    }
}

@Suite struct AngleSpringTests {
    @Test func settlesWithoutOvershoot() {
        var spring = AngleSpring(value: 100)
        var maxValue = 100.0
        for _ in 0..<120 { spring.step(target: 60, dt: 1.0 / 60); maxValue = min(maxValue, spring.value) }
        #expect(abs(spring.value - 60) < 0.5, "两秒内要稳定到目标值")
        #expect(maxValue >= 60 - 0.01, "临界阻尼不能过冲")
    }

    @Test func lagsAboutSeventyMilliseconds() {
        // 传感器每 10 毫秒来一个整数角度，弹簧输出要跟得上又不抖
        var spring = AngleSpring(value: 100)
        for _ in 0..<6 { spring.step(target: 90, dt: 0.01) }
        #expect(spring.value < 100 && spring.value > 90, "60 毫秒内走完大半，但没到头")
    }

    @Test func isFrameRateIndependent() {
        func run(steps: Int) -> Double {
            var spring = AngleSpring(value: 100)
            for _ in 0..<steps { spring.step(target: 40, dt: 0.5 / Double(steps)) }
            return spring.value
        }
        #expect(abs(run(steps: 60) - run(steps: 30)) < 2, "30 帧和 60 帧下跟随速度要一致")
    }

    @Test func resetJumpsStraightThere() {
        var spring = AngleSpring(value: 100)
        spring.step(target: 40, dt: 0.1)
        spring.reset(to: 128)
        #expect(spring.value == 128)
        spring.step(target: 128, dt: 0.1)
        #expect(spring.value == 128, "落定后不该再漂")
    }
}
