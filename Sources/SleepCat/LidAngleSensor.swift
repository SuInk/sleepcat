// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import Foundation
import IOKit.hid

/// MacBook 盖子铰链角度传感器（Apple Silicon 机型内置）。
/// HID Sensor 页（0x20）里的 Hinge Angle（0x8A），读 Feature Report 拿角度。
final class LidAngleSensor {
    private let device: IOHIDDevice
    private let manager: IOHIDManager  // 保活：释放 manager 会连带关闭它名下打开的设备

    init?() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let match: [String: Any] = [
            kIOHIDPrimaryUsagePageKey as String: 0x0020,  // Sensor
            kIOHIDPrimaryUsageKey as String: 0x008A,      // Orientation: Hinge Angle
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }

        // 匹配到的设备可能不止一个（有的受保护读不了），逐个试读挑出能用的
        for dev in devices {
            guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            var buf = [UInt8](repeating: 0, count: 8)
            var len: CFIndex = buf.count
            if IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, &buf, &len) == kIOReturnSuccess, len >= 3 {
                device = dev
                return
            }
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        return nil
    }

    /// 当前铰链角度（度，0=合死，~130=完全打开）；读取失败返回 nil
    func angle() -> Double? {
        var buf = [UInt8](repeating: 0, count: 8)
        var len: CFIndex = buf.count
        let r = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buf, &len)
        guard r == kIOReturnSuccess, len >= 3 else { return nil }
        let raw = UInt16(buf[1]) | (UInt16(buf[2]) << 8)
        return Double(raw)
    }

    /// 调试：打印原始报文，确认字节布局和单位
    func debugDump() {
        var buf = [UInt8](repeating: 0, count: 8)
        var len: CFIndex = buf.count
        let r = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buf, &len)
        let hex = buf.prefix(max(len, 0)).map { String(format: "%02x", $0) }.joined(separator: " ")
        let raw = UInt16(buf[1]) | (UInt16(buf[2]) << 8)
        print("result=\(String(format: "0x%x", r)) len=\(len) bytes=[\(hex)] u16@1=\(raw) /100=\(Double(raw) / 100)")
    }
}
