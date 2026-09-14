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
        #expect(CatIcon.awake.size == NSSize(width: 24, height: 18))
        #expect(CatIcon.asleep.size == CatIcon.awake.size)
    }

    @Test func headIsVerticallyCenteredAndFullSized() {
        let canvas: CGFloat = 18
        let offset = CatIcon.headOffset(canvasHeight: canvas)
        let bottom = offset.y + CatIcon.designHeadBottom * CatIcon.headScale
        let top = offset.y + CatIcon.designHeadTop * CatIcon.headScale
        // 贴着底边画的话会比旁边的图标沉下去一截
        #expect(abs((bottom + top) / 2 - canvas / 2) < 0.01, "猫头的中心要对准画布中心")
        #expect((15...16.5).contains(top - bottom), "头高应和系统图标的 16pt 左右相当：\(top - bottom)")
        #expect(bottom >= 0 && top <= canvas, "不能超出画布被裁掉")
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
    func battery(_ p: Int) -> PowerStatus { PowerStatus(onBattery: true, percent: p) }
    func plugged(_ p: Int) -> PowerStatus { PowerStatus(onBattery: false, percent: p) }

    @Test func stopsOnceWhenDrainingPastTheThreshold() {
        var g = LowBatteryGuard()
        let r1 = g.shouldStop(battery(40), threshold: 20, sessionActive: true)
        #expect(!r1)
        let r2 = g.shouldStop(battery(21), threshold: 20, sessionActive: true)
        #expect(!r2)
        let r3 = g.shouldStop(battery(20), threshold: 20, sessionActive: true)
        #expect(r3, "到阈值就停")
        let r4 = g.shouldStop(battery(19), threshold: 20, sessionActive: true)
        #expect(!r4, "已经停过，不会反复触发")
    }

    @Test func neverStopsWhilePluggedIn() {
        var g = LowBatteryGuard()
        let r5 = g.shouldStop(plugged(5), threshold: 20, sessionActive: true)
        #expect(!r5, "插着电源就是在充电")
    }

    @Test func offMeansOff() {
        var g = LowBatteryGuard()
        let r6 = g.shouldStop(battery(3), threshold: nil, sessionActive: true)
        #expect(!r6)
    }

    @Test func manualStartBelowThresholdIsRespected() {
        // 电量 15% 时用户手动开喵住：是有意的，不能一开就被停掉
        var g = LowBatteryGuard()
        let r7 = g.noteManualStart(battery(15), threshold: 20)
        #expect(r7, "应该提示用户这次不会自动停")
        let r8 = g.shouldStop(battery(15), threshold: 20, sessionActive: true)
        #expect(!r8)
        let r9 = g.shouldStop(battery(8), threshold: 20, sessionActive: true)
        #expect(!r9)
    }

    @Test func manualStartAboveThresholdNeedsNoNotice() {
        var g = LowBatteryGuard()
        let r10 = g.noteManualStart(battery(60), threshold: 20)
        #expect(!r10)
        let r11 = g.noteManualStart(plugged(10), threshold: 20)
        #expect(!r11)
    }

    @Test func pluggingInReArmsIt() {
        var g = LowBatteryGuard()
        _ = g.noteManualStart(battery(15), threshold: 20)
        let pluggedIn = g.shouldStop(plugged(15), threshold: 20, sessionActive: true)   // 插上电源
        #expect(!pluggedIn)
        let r12 = g.shouldStop(battery(15), threshold: 20, sessionActive: true)
        #expect(r12, "拔掉后重新生效")
    }

    @Test func doesNothingWhenNotKeepingAwake() {
        var g = LowBatteryGuard()
        let r13 = g.shouldStop(battery(10), threshold: 20, sessionActive: false)
        #expect(!r13)
    }

    @Test func readsThisMacsBatterySanely() {
        // 台式机没有电池会返回 nil，那也是对的
        if let s = BatteryMonitor.read() {
            #expect((0...100).contains(s.percent))
        }
    }
}

@Suite struct RecommendTests {
    @Test func copiedTextCarriesTheLink() {
        #expect(SleepCatApp.recommendationText.contains(SleepCatApp.homepage.absoluteString))
    }

    @Test func installCommandIsOneShortLine() {
        // 用户嫌命令长：写全名一行装好，tap / trust / 去隔离标记都不用再手敲
        let cmd = SleepCatApp.installCommand
        #expect(cmd == "brew install suink/tap/sleepcat")
        #expect(!cmd.contains("&&"), "不该再拼接多条命令")
    }

    @Test func installCommandMatchesTheReadme() throws {
        // 推荐出去的命令要和 README 写的一模一样，改一边忘了另一边就会装不上
        let readme = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/SleepCatTests/SleepCatTests.swift", with: "README.md"), encoding: .utf8)
        #expect(readme.contains(SleepCatApp.installCommand))
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
