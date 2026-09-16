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

    @Test func cursorOnlyHidesOnceWellIntoTheFold() {
        #expect(!DuoBlur.shouldHideCursor(progress: 0))
        #expect(!DuoBlur.shouldHideCursor(progress: 0.4), "刚起雾时用户可能还在操作")
        #expect(DuoBlur.shouldHideCursor(progress: 0.8))
        #expect(DuoBlur.shouldHideCursor(progress: 1))
    }

    @Test func blurAndDimFollowTheAngle() {
        // 全开时什么都不叠，合到底时糊透、压暗到位；中间单调变浓
        #expect(DuoBlur.blurOpacity(progress: 0) == 0)
        #expect(DuoBlur.dimOpacity(progress: 0) == 0)
        #expect(DuoBlur.blurOpacity(progress: 1) == 1)
        #expect(abs(DuoBlur.dimOpacity(progress: 1) - FoldGeometry.maxDim) < 0.001)
        let blur = stride(from: 0.0, through: 1.0, by: 0.05).map { DuoBlur.blurOpacity(progress: $0) }
        let dim = stride(from: 0.0, through: 1.0, by: 0.05).map { DuoBlur.dimOpacity(progress: $0) }
        for (a, b) in zip(blur, blur.dropFirst()) { #expect(b >= a) }
        for (a, b) in zip(dim, dim.dropFirst()) { #expect(b >= a) }
        // 压暗比模糊来得早：半路时画面已经暗下去，但还没糊透
        #expect(DuoBlur.dimOpacity(progress: 0.5) > DuoBlur.blurOpacity(progress: 0.5))
    }

    @Test func pollFollowsTheLid() {
        // 盖子摊开不动时慢慢看着，一开始合就切到 60 帧
        #expect(DuoBlur.pollInterval(progress: 0, angle: 130) == 0.1)
        #expect(DuoBlur.pollInterval(progress: 0, angle: 95) < 0.02)
        #expect(DuoBlur.pollInterval(progress: 0.3, angle: 130) < 0.02)
        // 半开着停稳了就降频，别按 60 帧空转一下午
        #expect(DuoBlur.pollInterval(progress: 0, angle: 95, stillFor: 60) == 0.1)
        #expect(DuoBlur.pollInterval(progress: 0.5, angle: 60, stillFor: 60) < 0.02, "折到一半停住仍要跟手")
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

@Suite struct PowerHistoryTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func filled(_ values: [Double], every seconds: TimeInterval = 10) -> PowerHistory {
        var history = PowerHistory()
        for (i, watts) in values.enumerated() {
            history.add(watts: watts, at: start.addingTimeInterval(Double(i) * seconds))
        }
        return history
    }

    @Test func keepsOnlyTheLastDay() {
        var history = PowerHistory()
        history.add(watts: 5, at: start)
        history.add(watts: 6, at: start.addingTimeInterval(12 * 3600))
        history.add(watts: 7, at: start.addingTimeInterval(24 * 3600 + 60))   // 第一个点已经超过 24 小时
        #expect(history.samples.count == 2)
        #expect(history.samples.first?.watts == 6)
        #expect(history.latest == 7)
    }

    @Test func gapsStayEmptyInsteadOfDrawingAStraightLine() {
        // 应用没开 / Mac 睡着的那几个小时是断的，补成直线会让人以为一直在耗电
        var history = PowerHistory()
        for i in 0..<10 { history.add(watts: 10, at: start.addingTimeInterval(Double(i) * 60)) }
        for i in 0..<10 { history.add(watts: 20, at: start.addingTimeInterval(7200 + Double(i) * 60)) }
        let curve = history.curve(points: 60, now: start.addingTimeInterval(7800))
        #expect(curve.contains { $0 == nil }, "中间那段必须是空的")
        let segments = PowerChart.segments(curve)
        #expect(segments.count == 2, "应该画成两段，实际 \(segments.count) 段")
    }

    @Test func limitedKeepsOnlyTheChosenSpan() {
        var history = PowerHistory()
        let now = start.addingTimeInterval(12 * 3600)
        history.add(watts: 5, at: now.addingTimeInterval(-10 * 3600))
        history.add(watts: 8, at: now.addingTimeInterval(-90 * 60))
        history.add(watts: 12, at: now.addingTimeInterval(-30 * 60))
        #expect(history.limited(to: 3600, now: now).samples.count == 1)
        #expect(history.limited(to: 6 * 3600, now: now).samples.count == 2)
        #expect(history.limited(to: 24 * 3600, now: now).samples.count == 3)
        #expect(history.limited(to: 3600, now: now).latest == 12)
    }

    @Test func spanOptionsAreSaneAndLabelled() {
        #expect(PowerSpan.options.map(\.seconds) == [3600, 21600, 86400])
        #expect(PowerSpan.options.allSatisfy { $0.seconds <= PowerHistory.window }, "跨度不能超过留存的窗口")
        #expect(PowerSpan.label(for: 6 * 3600) == "6 小时")
        #expect(PowerSpan.label(for: 999) == "1 小时", "存了个没见过的值就退回默认")
    }

    @Test func spanTextSwitchesToHours() {
        #expect(PowerHistory.spanText(90) == "2 分钟")
        #expect(PowerHistory.spanText(1800) == "30 分钟")
        #expect(PowerHistory.spanText(3 * 3600 + 1800) == "3.5 小时")
        #expect(PowerHistory.spanText(24 * 3600) == "24 小时")
    }

    @Test func samplesSurviveARestart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleepcat-samples-\(UUID().uuidString)/功耗采样.csv")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date()
        PowerLog.appendSample(watts: 11.5, at: now.addingTimeInterval(-600), to: url)
        PowerLog.appendSample(watts: 9.25, at: now.addingTimeInterval(-300), to: url)
        PowerLog.appendSample(watts: 8, at: now.addingTimeInterval(-40 * 3600), to: url)   // 超过 24 小时

        let history = PowerLog.loadHistory(now: now, from: url)
        #expect(history.samples.count == 2, "太老的采样不该读回来")
        #expect(history.latest == 9.25)
        #expect(history.lowest == 9.25 && history.highest == 11.5)
    }

    @Test func averageIsTimeWeighted() {
        // 10 W 持续 100 秒，接着 20 W 只持续 10 秒：平均该贴近 10，不是简单的 15
        var history = PowerHistory()
        history.add(watts: 10, at: start)
        history.add(watts: 10, at: start.addingTimeInterval(100))
        history.add(watts: 20, at: start.addingTimeInterval(110))
        let average = try! #require(history.average)
        #expect(average > 10 && average < 12)
    }

    @Test func curveStartsAtTheFirstSample() {
        // 只采了十分钟，左边就不该补出五十分钟的假平线
        let history = filled(Array(repeating: 8, count: 60) + Array(repeating: 20, count: 60))
        let now = start.addingTimeInterval(1190)
        let curve = history.curve(points: 100, now: now)
        #expect(curve.count == 100)
        #expect(abs(curve.first!! - 8) < 0.001, "开头就是第一个采样值")
        #expect(abs(curve.last!! - 20) < 0.001, "结尾是最新的采样值")
        // 跳变应该落在中间附近，而不是被挤到右边
        let jump = curve.firstIndex { ($0 ?? 0) > 14 } ?? 0
        #expect(jump > 40 && jump < 60, "跳变位置 \(jump)")
    }

    @Test func emptyHistoryDrawsNothing() {
        let history = PowerHistory()
        #expect(history.isEmpty)
        #expect(history.curve(points: 10).isEmpty)
        #expect(history.average == nil)
        #expect(PowerChart.image(for: history) == nil, "没数据时不该画出空图")
    }

    @Test func axisTicksAreQuartersOrFives() {
        func isMultiple(_ value: Double, of unit: Double) -> Bool {
            abs((value / unit).rounded() - value / unit) < 1e-9
        }
        for (low, high) in [(8.4, 19.7), (0.6, 42.1), (9.9, 10.1), (3.2, 5.7), (12, 88), (0.6, 1.4), (0.2, 0.9)] {
            let (bottom, top, step) = PowerChartView.axis(low: low, high: high)
            #expect(bottom <= low && top >= high, "要把 \(low)…\(high) 装进去")
            #expect(bottom >= 0, "功耗不会是负的，纵轴不该探到 0 以下")
            // 小刻度是 0.25 的倍数，大刻度是 5 的倍数
            #expect(step < 5 ? isMultiple(step, of: 0.25) : isMultiple(step, of: 5), "刻度 \(step) 不合规")
            #expect(isMultiple(bottom, of: step) && isMultiple(top, of: step))
            #expect((top - bottom) / step <= 6, "格子太多挤成一团")
        }
        // 空闲时 1 W 上下的起伏要看得出来：不能被塞进 0～5 W 的轴里
        let idle = PowerChartView.axis(low: 0.6, high: 1.4)
        #expect(idle.step <= 0.5 && idle.top <= 2)
        // 高负载时仍是 5 的倍数
        #expect(PowerChart.axisBounds(low: 0.7, high: 15.3) == (0, 20))
        #expect(PowerAxis.label(0.25) == "0.25 W")
        #expect(PowerAxis.label(1.5) == "1.5 W")
        #expect(PowerAxis.label(20) == "20 W")
    }

    @Test func timeTicksLandOnRoundClockTimes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let end = cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 20, minute: 37))!
        let cases: [(span: TimeInterval, step: TimeInterval)] = [(3600, 900), (21600, 3600), (86400, 14400)]
        for (span, expectedStep) in cases {
            let start = end.addingTimeInterval(-span)
            let ticks = PowerAxis.timeTicks(from: start, to: end, calendar: cal)
            #expect(!ticks.isEmpty && ticks.count <= 6, "跨度 \(span) 秒给了 \(ticks.count) 个刻度")
            #expect(ticks.allSatisfy { $0 >= start && $0 <= end }, "刻度要落在可见范围里")
            for (a, b) in zip(ticks, ticks.dropFirst()) { #expect(b.timeIntervalSince(a) == expectedStep) }
            // 落在整点上：分钟数是步长的整倍数
            for tick in ticks {
                let seconds: TimeInterval = tick.timeIntervalSince(cal.startOfDay(for: tick))
                let remainder: TimeInterval = seconds.truncatingRemainder(dividingBy: expectedStep)
                #expect(remainder == 0, "刻度没对齐到整点")
            }
        }
        #expect(PowerAxis.timeLabel(end, calendar: cal) == "20:37")
    }

    @Test func curveKeepsShortSpikes() {
        // 几秒的尖峰也得画出来：统计写着峰值多少，曲线上就要看得到
        var history = PowerHistory()
        for i in 0..<360 { history.add(watts: i == 200 ? 42 : 5, at: start.addingTimeInterval(Double(i) * 10)) }
        let curve = history.curve(points: 60, now: start.addingTimeInterval(3600))
        #expect(curve.compactMap { $0 }.max() == 42)
    }
}


@Suite struct PowerFlowTests {
    @Test func chargingShowsWhereTheAdapterPowerGoes() {
        // 实测过的一组：适配器 49.1 W，整机 11.6 W，充进电池 37.5 W
        let flow = PowerFlow(system: 11.6, adapter: 49.1, battery: 37.5)
        #expect(flow.state == .charging)
        #expect(flow.summary == "适配器 49.1 W → 整机 11.6 W + 充电 37.5 W")
        #expect(flow.shortState == "充电 37.5 W")
        #expect(flow.isConsistent)
    }

    @Test func pluggedInAndFullDoesNotClaimCharging() {
        // 充满后电流在零点几安上下抖，不能说成在充电
        let flow = PowerFlow(system: 11.6, adapter: 11.9, battery: 0.2)
        #expect(flow.state == .pluggedIn)
        #expect(flow.summary == "适配器 11.9 W → 整机 11.6 W")
        #expect(flow.shortState == "电源供电")
    }

    @Test func onBatteryShowsTheDischarge() {
        let flow = PowerFlow(system: 9.7, adapter: nil, battery: -10.2)
        #expect(flow.state == .onBattery)
        #expect(flow.summary == "电池放电 10.2 W → 整机 9.7 W")
        #expect(flow.shortState == "用电池")
        #expect(flow.isConsistent, "没插电时没有适配器可对账")
    }

    @Test func selfCheckCatchesReadingsThatDoNotAddUp() {
        // 适配器说 60 W，整机 + 充电只有 20 W：某个读数错了
        #expect(!PowerFlow(system: 10, adapter: 60, battery: 10).isConsistent)
        // 转换损耗带来的小误差不算错
        #expect(PowerFlow(system: 27.0, adapter: 63.0, battery: 36.5).isConsistent)
    }

    @Test func amperageIsReadAsSigned() {
        // 注册表里的放电电流是 64 位补码：18446744073709550845 就是 -771 mA
        #expect(BatteryMonitor.signedMilliamps(NSNumber(value: UInt64(18446744073709550845))) == -771)
        #expect(BatteryMonitor.signedMilliamps(NSNumber(value: 2973)) == 2973)
    }
}

@Suite struct LogRetentionTests {
    let now = Date(timeIntervalSince1970: 1_789_560_000)   // 2026-09-16 左右

    func stamp(daysAgo: Double, format: String, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f.string(from: now.addingTimeInterval(-daysAgo * 86400))
    }

    @Test func appLogKeepsThirtyDays() {
        let utc = TimeZone(identifier: "UTC")!
        let old = "[\(stamp(daysAgo: 45, format: "yyyy-MM-dd HH:mm:ss Z", timeZone: utc))] 很久以前"
        let continuation = "  报错的第二行"
        let recent = "[\(stamp(daysAgo: 3, format: "yyyy-MM-dd HH:mm:ss Z", timeZone: utc))] 三天前"
        let text = [old, continuation, recent, ""].joined(separator: "\n")
        let trimmed = LogRetention.trimAppLog(text, now: now)
        #expect(!trimmed.contains("很久以前"))
        #expect(!trimmed.contains("报错的第二行"), "没有时间戳的续行跟着上一行一起删")
        #expect(trimmed.contains("三天前"))
    }

    @Test func powerLogKeepsHeaderAndThirtyDays() {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let old = stamp(daysAgo: 31, format: "yyyy-MM-dd HH:mm", timeZone: tz)
        let edge = stamp(daysAgo: 29.9, format: "yyyy-MM-dd HH:mm", timeZone: tz)
        let text = [PowerLog.header, "\(old),\(old),10,1.00,6.0,9.0,60", "\(edge),\(edge),10,2.00,12.0,20.0,60", ""]
            .joined(separator: "\n")
        let trimmed = LogRetention.trimPowerLog(text, now: now, timeZone: tz)
        #expect(trimmed.hasPrefix(PowerLog.header), "表头不能被删")
        #expect(!trimmed.contains(",1.00,"))
        #expect(trimmed.contains(",2.00,"), "29.9 天前的还在期限内")
    }

    @Test func rewritingKeepsTheBOMAndSkipsUntouchedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sleepcat-retention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let power = dir.appendingPathComponent("功耗记录.csv")
        let app = dir.appendingPathComponent("SleepCat.log")

        let tz = TimeZone.current
        let old = stamp(daysAgo: 40, format: "yyyy-MM-dd HH:mm", timeZone: tz)
        let fresh = stamp(daysAgo: 1, format: "yyyy-MM-dd HH:mm", timeZone: tz)
        let body = "\(PowerLog.header)\n\(old),\(old),10,1.00,6.0,9.0,60\n\(fresh),\(fresh),10,2.00,12.0,20.0,60\n"
        try (Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)).write(to: power)
        let recentLog = "[\(stamp(daysAgo: 1, format: "yyyy-MM-dd HH:mm:ss Z", timeZone: tz))] 昨天\n"
        try recentLog.write(to: app, atomically: true, encoding: .utf8)
        let before = try FileManager.default.attributesOfItem(atPath: app.path)[.modificationDate] as? Date

        LogRetention.apply(appLog: app, powerLog: power, now: now)

        let data = try Data(contentsOf: power)
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF], "BOM 丢了 Excel 打开中文会乱码")
        let text = try #require(String(data: data.dropFirst(3), encoding: .utf8))
        #expect(!text.contains(",1.00,") && text.contains(",2.00,"))
        let after = try FileManager.default.attributesOfItem(atPath: app.path)[.modificationDate] as? Date
        #expect(before == after, "没有要删的就不该重写文件")
    }
}
