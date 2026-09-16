// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit
import IOKit

/// 整机功耗读数。
/// 首选 SMC 的 PSTR（system total power，插电和用电池都准）；
/// 读不到就退回电池的电压 × 电流，那个只在用电池时有意义。
enum PowerMeter {
    /// 当前功耗（瓦）。读不到返回 nil
    static func read() -> Double? {
        if let watts = SMC.shared.readFloat("PSTR"), watts > 0, watts < 500 { return watts }
        guard let status = BatteryMonitor.read(), status.onBattery,
              let watts = BatteryMonitor.dischargeWatts(), watts > 0 else { return nil }
        return watts
    }

    /// 读此刻的能量流。插电时适配器输入读 SMC 的 PDTR，读不到就用「整机 + 充电」推算
    static func readFlow() -> PowerFlow? {
        guard let system = read() else { return nil }
        let battery = BatteryMonitor.batteryWatts()
        let pluggedIn = BatteryMonitor.read().map { !$0.onBattery } ?? true   // 台式机没电池，当作插着电
        guard pluggedIn else { return PowerFlow(system: system, adapter: nil, battery: battery) }
        let measured = SMC.shared.readFloat("PDTR").flatMap { $0 > 0.5 && $0 < 500 ? $0 : nil }
        let adapter = measured ?? system + max(0, battery ?? 0)
        return PowerFlow(system: system, adapter: adapter, battery: battery)
    }

    /// 始终带一位小数：整机功耗就在十几二十几瓦这个量级，取整看不出变化
    static func wattsText(_ watts: Double) -> String {
        String(format: "%.1f W", watts)
    }

    /// 「平均 · 峰值 · 最低」，菜单和曲线窗口共用同一套文案和顺序
    static func statsText(_ history: PowerHistory) -> String? {
        guard let average = history.average, let high = history.highest, let low = history.lowest else { return nil }
        return "平均 \(wattsText(average)) · 峰值 \(wattsText(high)) · 最低 \(wattsText(low))"
    }

    /// 电量同样带一位小数，跟功耗的写法保持一致
    static func energyText(_ wattHours: Double) -> String {
        String(format: "%.1f Wh", wattHours)
    }
}

/// 此刻电从哪来、到哪去：适配器输入 = 整机功耗 + 充进电池的功率；用电池时电池放电供整机。
/// 三个数互相能对账，所以顺带当自检用
struct PowerFlow: Equatable {
    /// 整机功耗
    let system: Double
    /// 适配器输入；没插电时为 nil
    let adapter: Double?
    /// 电池功率：充电为正，放电为负；没有电池时为 nil
    let battery: Double?

    /// 低于这个值当作电池不充不放（电流读数有零点几瓦的抖动）
    static let idleThreshold: Double = 0.5

    enum State: Equatable { case charging, pluggedIn, onBattery }

    var state: State {
        guard adapter != nil else { return .onBattery }
        if let battery, battery > Self.idleThreshold { return .charging }
        return .pluggedIn
    }

    /// 汇总的一行，比如「适配器 49.1 W → 整机 11.6 W + 充电 37.5 W」
    var summary: String {
        let w = PowerMeter.wattsText
        switch state {
        case .charging:
            return "适配器 \(w(adapter ?? system)) → 整机 \(w(system)) + 充电 \(w(battery ?? 0))"
        case .pluggedIn:
            return "适配器 \(w(adapter ?? system)) → 整机 \(w(system))"
        case .onBattery:
            let discharge = max(0, -(battery ?? -system))
            return "电池放电 \(w(discharge)) → 整机 \(w(system))"
        }
    }

    /// 灵动岛那种地方放得下的短说法
    var shortState: String {
        switch state {
        case .charging: return "充电 \(PowerMeter.wattsText(battery ?? 0))"
        case .pluggedIn: return "电源供电"
        case .onBattery: return "用电池"
        }
    }

    /// 自检：插电时适配器输入应该约等于整机 + 充电。差得太多说明某个读数不可信
    var isConsistent: Bool {
        guard let adapter else { return true }
        let expected = system + max(0, battery ?? 0)
        return abs(adapter - expected) <= max(3, expected * 0.15)
    }
}

/// 一段时间内的功耗统计（记录文件里的一行）。按梯形法把功率积成电量
struct PowerSession {
    private(set) var startedAt: Date
    private(set) var lastAt: Date
    private(set) var lastWatts: Double
    private(set) var energyWattHours: Double = 0
    private(set) var peakWatts: Double
    private(set) var samples = 1

    /// 采样间隔之外的空档（合盖、睡眠、进程卡住）不算进电量里，免得一睡一夜积出个天文数字
    static let maxGap: TimeInterval = 120

    init(watts: Double, at now: Date = Date()) {
        startedAt = now
        lastAt = now
        lastWatts = watts
        peakWatts = watts
    }

    mutating func add(watts: Double, at now: Date) {
        let gap = now.timeIntervalSince(lastAt)
        if gap > 0, gap <= Self.maxGap {
            energyWattHours += (lastWatts + watts) / 2 * gap / 3600
        }
        lastAt = now
        lastWatts = watts
        peakWatts = max(peakWatts, watts)
        samples += 1
    }

    /// 平均功耗：用累计电量除以实际计入的时间，比把采样值平均更准
    var averageWatts: Double {
        let hours = duration / 3600
        return hours > 0 ? energyWattHours / hours : lastWatts
    }

    var duration: TimeInterval { lastAt.timeIntervalSince(startedAt) }

    /// 写进记录文件的一行（CSV）
    func csvLine(formatter: DateFormatter) -> String {
        [
            formatter.string(from: startedAt),
            formatter.string(from: lastAt),
            String(Int((duration / 60).rounded())),
            String(format: "%.2f", safeEnergyWattHours),
            String(format: "%.1f", averageWatts),
            String(format: "%.1f", peakWatts),
            String(samples),
        ].joined(separator: ",")
    }

    private var safeEnergyWattHours: Double { energyWattHours.isFinite ? energyWattHours : 0 }
}

/// 功耗记录文件（CSV，用表格软件能直接打开）。一直记，和喵不喵住无关
enum PowerLog {
    static let header = "开始时间,结束时间,时长分钟,用电Wh,平均W,峰值W,采样数"

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SleepCat", isDirectory: true)
        return dir.appendingPathComponent("功耗记录.csv")
    }

    /// 在访达里选中记录文件；还没有记录时打开所在的文件夹
    static func revealInFinder() {
        let url = fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    static func append(_ session: PowerSession, to url: URL = fileURL) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        write(line: session.csvLine(formatter: f), to: url)
    }

    static func write(line: String, to url: URL, header: String = header) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                // ﻿：Excel 认这个开头才不会把中文表头显示成乱码
                try "\u{feff}\(header)\n".write(to: url, atomically: true, encoding: .utf8)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            LidBlocker.log("功耗记录写入失败：\(error.localizedDescription)")
        }
    }

    // MARK: 采样文件（给 24 小时曲线用）

    /// 每分钟一条，重启后曲线还能接上。和给人看的「功耗记录.csv」分开放：
    /// 这个是程序自己读的，时间用 Unix 时间戳，省得来回解析本地时间
    static var samplesURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("功耗采样.csv") }
    static let samplesHeader = "时间戳,功耗W"

    static func appendSample(watts: Double, at time: Date = Date(), to url: URL = samplesURL) {
        write(line: String(format: "%.0f,%.2f", time.timeIntervalSince1970, watts), to: url, header: samplesHeader)
    }

    /// 读回最近 24 小时的采样；顺带把过期的行清掉，文件不会无限长
    static func loadHistory(now: Date = Date(), from url: URL = samplesURL) -> PowerHistory {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return PowerHistory() }
        let kept = parseSamples(text, now: now)
        var history = PowerHistory()
        for sample in kept { history.add(watts: sample.watts, at: sample.time) }
        // 行数明显多于窗口内的量就重写一遍（一天 1440 行，超过两天份就整理）
        if text.split(separator: "\n").count > kept.count + 1440 {
            let body = kept.map { String(format: "%.0f,%.2f", $0.time.timeIntervalSince1970, $0.watts) }
            try? ("\u{feff}\(samplesHeader)\n" + body.joined(separator: "\n") + "\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }
        return history
    }

    /// 纯函数，便于测试
    static func parseSamples(_ text: String, now: Date,
                             window: TimeInterval = PowerHistory.window) -> [(time: Date, watts: Double)] {
        let cutoff = now.addingTimeInterval(-window)
        return text.split(separator: "\n").compactMap { line in
            let cells = line.split(separator: ",")
            guard cells.count >= 2, let epoch = Double(cells[0]), let watts = Double(cells[1]) else { return nil }
            let time = Date(timeIntervalSince1970: epoch)
            guard time >= cutoff, time <= now.addingTimeInterval(60) else { return nil }
            return (time, watts)
        }
    }
}

/// SMC（系统管理控制器）只读客户端。
/// SMCParamStruct 是 80 字节的 C 结构，Swift 会重排结构体字段，所以按固定偏移拼字节
final class SMC {
    static let shared = SMC()

    private static let structSize = 80
    private static let offsetKey = 0, offsetDataSize = 28, offsetDataType = 32
    private static let offsetResult = 40, offsetSelector = 42, offsetBytes = 48
    private static let selectorKeyInfo: UInt8 = 9, selectorReadBytes: UInt8 = 5

    private var connection: io_connect_t = 0
    private let lock = NSLock()

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != kIOReturnSuccess { connection = 0 }
    }

    /// 读一个 `flt ` 类型的键（比如 PSTR：整机功耗）
    func readFloat(_ key: String) -> Double? {
        guard let (type, bytes) = read(key), type == "flt ", bytes.count == 4 else { return nil }
        let raw = UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
        let value = Double(Float(bitPattern: raw))
        return value.isFinite ? value : nil
    }

    private func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard connection != 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }

        var request = [UInt8](repeating: 0, count: Self.structSize)
        Self.put32(&request, Self.offsetKey, Self.fourCC(key))
        guard let info = call(request, selector: Self.selectorKeyInfo) else { return nil }
        let dataSize = Self.get32(info, Self.offsetDataSize), dataType = Self.get32(info, Self.offsetDataType)
        guard dataSize > 0, dataSize <= 32 else { return nil }

        Self.put32(&request, Self.offsetDataSize, dataSize)
        Self.put32(&request, Self.offsetDataType, dataType)
        guard let out = call(request, selector: Self.selectorReadBytes) else { return nil }
        let type = withUnsafeBytes(of: dataType.bigEndian) { String(bytes: $0, encoding: .ascii) ?? "" }
        return (type, Array(out[Self.offsetBytes ..< Self.offsetBytes + Int(dataSize)]))
    }

    private func call(_ input: [UInt8], selector: UInt8) -> [UInt8]? {
        var request = input
        request[Self.offsetSelector] = selector
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let rc = request.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(connection, 2, inPtr.baseAddress!, Self.structSize,
                                          outPtr.baseAddress!, &outputSize)
            }
        }
        guard rc == kIOReturnSuccess, output[Self.offsetResult] == 0 else { return nil }
        return output
    }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) } }

    private static func put32(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { for (n, byte) in $0.enumerated() { buffer[offset + n] = byte } }
    }

    private static func get32(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buffer[offset]) | UInt32(buffer[offset + 1]) << 8
            | UInt32(buffer[offset + 2]) << 16 | UInt32(buffer[offset + 3]) << 24
    }
}
