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
        #expect(naked.allSatisfy { ["喵住设置", "效果与提示"].contains($0) }, "缺图标的行：\(naked)")
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
