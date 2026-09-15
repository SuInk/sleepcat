import Foundation
import IOKit.ps

struct PowerStatus: Equatable {
    let onBattery: Bool
    let percent: Int
}

/// 读内建电池状态，电量或供电方式一变就回调。
/// 用系统的电源通知推送，不轮询：合盖塞包里时 Mac 还醒着，通知照样会来。
final class BatteryMonitor {
    var onChange: ((PowerStatus) -> Void)?
    private var source: CFRunLoopSource?

    /// 没有内建电池（台式机）时返回 nil
    static func read() -> PowerStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let state = d[kIOPSPowerSourceStateKey] as? String
            return PowerStatus(onBattery: state == kIOPSBatteryPowerValue, percent: current * 100 / max)
        }
        return nil
    }

    func start() {
        guard source == nil else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            if let status = BatteryMonitor.read() { monitor.onChange?(status) }
        }, me)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        source = src
    }
}

/// 低电量时暂停喵住、电源回来自动恢复的判定。
///
/// - 只在用电池时生效；插着电源就是在充电，电量再低也不暂停
/// - 要**连续**用电池且电量不高于阈值满 `grace` 秒才暂停：负载高、充电器一时带不动时，
///   系统会短暂报告成「用电池」几秒钟，不能因此就把喵住停掉（合着盖子的话会直接睡过去）
/// - 电量已经低于阈值时用户**手动**开启喵住，说明是有意的，这一轮不再暂停；
///   等插上电源或电量回升到阈值以上，才重新生效
/// - 暂停后满足 `shouldResume` 就自动恢复
struct LowBatteryGuard {
    static let grace: TimeInterval = 60
    /// 在电池上靠电量回升来恢复时要多出的余量，免得电量在阈值上下跳动时反复暂停、恢复
    static let resumeMargin = 2

    private(set) var armed = true
    private var lowSince: Date?

    /// 用户手动开启喵住时调用。返回 true 表示这次覆盖了自动暂停，界面上应该说明一下
    mutating func noteManualStart(_ status: PowerStatus, threshold: Int?) -> Bool {
        guard let threshold, status.onBattery, status.percent <= threshold else { return false }
        armed = false
        lowSince = nil
        return true
    }

    /// 返回 true 表示现在应该暂停喵住
    mutating func shouldPause(_ status: PowerStatus, threshold: Int?, sessionActive: Bool, now: Date) -> Bool {
        guard let threshold else {
            lowSince = nil
            return false
        }
        if !status.onBattery || status.percent > threshold {
            armed = true
            lowSince = nil
            return false
        }
        guard armed, sessionActive else {
            lowSince = nil
            return false
        }
        let since = lowSince ?? now
        lowSince = since
        guard now.timeIntervalSince(since) >= Self.grace else { return false }
        armed = false
        lowSince = nil
        return true
    }

    /// 正在确认期内时，还要等多久才该再判一次（电量没变化系统不会再通知，得自己约时间复查）
    func secondsUntilDecision(now: Date) -> TimeInterval? {
        lowSince.map { max(0, Self.grace - now.timeIntervalSince($0)) }
    }

    /// 因低电量暂停的喵住，现在能不能恢复：插上电源、关掉了这个功能，或电量明显高于阈值
    static func shouldResume(_ status: PowerStatus, threshold: Int?) -> Bool {
        guard let threshold else { return true }
        return !status.onBattery || status.percent >= threshold + resumeMargin
    }
}
