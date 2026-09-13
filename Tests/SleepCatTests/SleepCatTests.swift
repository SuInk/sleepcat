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
        #expect(CatIcon.awake.size == NSSize(width: 18, height: 18))
        #expect(CatIcon.asleep.size == NSSize(width: 22, height: 18), "睡觉图要给 Zz 留宽度")
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

    @Test func leavesTheMouseAloneSoTheUnlockButtonStaysClickable() {
        let mask = KeyboardLock.blockedMask
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .mouseMoved] {
            #expect(mask & (1 << type.rawValue) == 0)
        }
    }
}

@Suite struct BlurGateTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func t(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func closingMotionShowsBlur() {
        var g = BlurGate()
        for (s, angle) in [(0.0, 120.0), (0.2, 100), (0.4, 80), (0.6, 60)] {
            g.update(angle: angle, now: t(s))
        }
        #expect(g.shouldShow(angle: 60, now: t(0.6)))
    }

    @Test func stoppingMakesItDisappear() {
        var g = BlurGate()
        g.update(angle: 120, now: t(0))
        g.update(angle: 60, now: t(0.5))
        g.update(angle: 60, now: t(1.0))
        #expect(g.shouldShow(angle: 60, now: t(1.0)), "刚停，还在宽限期内")
        g.update(angle: 60, now: t(2.0))
        #expect(!g.shouldShow(angle: 60, now: t(2.0)), "停稳超过 1 秒就该消失")
    }

    @Test func briefPauseMidCloseDoesNotFlicker() {
        // 合盖时手顿一下很正常，不能一顿就闪没
        var g = BlurGate()
        g.update(angle: 110, now: t(0))
        g.update(angle: 70, now: t(0.4))
        g.update(angle: 70, now: t(1.0))   // 顿了 0.6 秒
        #expect(g.shouldShow(angle: 70, now: t(1.0)))
        g.update(angle: 40, now: t(1.3))
        #expect(g.shouldShow(angle: 40, now: t(1.3)))
    }

    @Test func sensorJitterIsNotMotion() {
        // 远程连着、盖子停在半路：传感器在 ±1° 抖，不能因此冒出模糊
        var g = BlurGate()
        for (i, angle) in [45.0, 46, 45, 44, 45, 46, 45].enumerated() {
            g.update(angle: angle, now: t(Double(i)))
        }
        #expect(!g.shouldShow(angle: 45, now: t(6)))
    }

    @Test func lidAlreadyStillAtLaunchShowsNothing() {
        var g = BlurGate()
        g.update(angle: 60, now: t(0))
        #expect(!g.shouldShow(angle: 60, now: t(0)))
    }

    @Test func fullyClosedNeverShowsEvenWhileMoving() {
        var g = BlurGate()
        g.update(angle: 40, now: t(0))
        g.update(angle: 5, now: t(0.3))
        #expect(!g.shouldShow(angle: 5, now: t(0.3)))
    }
}

@Suite struct SessionResumeTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func resumesAfterAFreshKill() {
        #expect(SleepCatApp.shouldResume(active: true, heartbeat: now.addingTimeInterval(-20),
                                         deadline: nil, now: now))
    }

    @Test func ignoresStaleSessionFromAPreviousBoot() {
        // 心跳是几小时前的 → 是上次开机的旧会话，不该自己喵起来
        #expect(!SleepCatApp.shouldResume(active: true, heartbeat: now.addingTimeInterval(-7200),
                                          deadline: nil, now: now))
    }

    @Test func ignoresExpiredTimer() {
        #expect(!SleepCatApp.shouldResume(active: true, heartbeat: now.addingTimeInterval(-10),
                                          deadline: now.addingTimeInterval(-1), now: now))
    }

    @Test func resumesTimerStillRunning() {
        #expect(SleepCatApp.shouldResume(active: true, heartbeat: now.addingTimeInterval(-10),
                                         deadline: now.addingTimeInterval(600), now: now))
    }

    @Test func noSessionNoResume() {
        #expect(!SleepCatApp.shouldResume(active: false, heartbeat: now, deadline: nil, now: now))
        #expect(!SleepCatApp.shouldResume(active: true, heartbeat: nil, deadline: nil, now: now))
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
