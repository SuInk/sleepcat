// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

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

/// 低电量自动停止的判定。
///
/// - 只在用电池时生效；插着电源就是在充电，电量再低也不停
/// - 电量已经低于阈值时用户**手动**开启喵住，说明是有意的，这一轮不再把它停掉；
///   等插上电源或电量回升到阈值以上，才重新生效
/// - 启动时自动恢复的会话不算手动，照常判定
struct LowBatteryGuard {
    private(set) var armed = true

    /// 用户手动开启喵住时调用。返回 true 表示这次覆盖了自动停止，界面上应该说明一下
    mutating func noteManualStart(_ status: PowerStatus, threshold: Int?) -> Bool {
        guard let threshold, status.onBattery, status.percent <= threshold else { return false }
        armed = false
        return true
    }

    /// 返回 true 表示现在应该自动停止喵住
    mutating func shouldStop(_ status: PowerStatus, threshold: Int?, sessionActive: Bool) -> Bool {
        guard let threshold else { return false }
        if !status.onBattery || status.percent > threshold {
            armed = true
            return false
        }
        guard armed, sessionActive else { return false }
        armed = false
        return true
    }
}
