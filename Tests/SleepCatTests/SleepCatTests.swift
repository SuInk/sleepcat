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
