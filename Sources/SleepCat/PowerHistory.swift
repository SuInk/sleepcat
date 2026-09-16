// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 最近 24 小时的功耗采样，菜单和曲线窗口用。
/// 每分钟往磁盘写一条，重启、更新之后曲线还在（见 PowerLog.appendSample）
struct PowerHistory {
    /// 留多久的数据
    static let window: TimeInterval = 24 * 3600

    fileprivate(set) var samples: [(time: Date, watts: Double)] = []

    mutating func add(watts: Double, at now: Date = Date()) {
        samples.append((now, watts))
        let cutoff = now.addingTimeInterval(-Self.window)
        // 采样是按时间顺序进来的，从头丢到第一个还在窗口内的为止
        if let keep = samples.firstIndex(where: { $0.time >= cutoff }), keep > 0 {
            samples.removeFirst(keep)
        }
    }

    /// 只要最近这一段（曲线跨度切换用）。纯函数，便于测试
    func limited(to seconds: TimeInterval, now: Date = Date()) -> PowerHistory {
        guard seconds < Self.window else { return self }
        let cutoff = now.addingTimeInterval(-seconds)
        var trimmed = PowerHistory()
        trimmed.samples = samples.filter { $0.time >= cutoff }
        return trimmed
    }

    var isEmpty: Bool { samples.isEmpty }
    var latest: Double? { samples.last?.watts }
    var span: TimeInterval { (samples.last?.time.timeIntervalSince(samples.first?.time ?? Date())) ?? 0 }

    var lowest: Double? { samples.map(\.watts).min() }
    var highest: Double? { samples.map(\.watts).max() }

    /// 按时间加权的平均，比把采样值直接平均更准（采样间隔可能不均匀）
    var average: Double? {
        guard let first = samples.first else { return nil }
        guard samples.count > 1 else { return first.watts }
        var energy = 0.0, seconds = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.time.timeIntervalSince(a.time)
            guard dt > 0, dt <= 120 else { continue }   // 跳过休眠造成的大空档
            energy += (a.watts + b.watts) / 2 * dt
            seconds += dt
        }
        return seconds > 0 ? energy / seconds : first.watts
    }

    /// 采样之间隔多久算「断了」。内存里 10 秒一个点、磁盘上 1 分钟一个点，
    /// 5 分钟足够区分「正常采样」和「应用没开 / Mac 睡着」
    static let maxGap: TimeInterval = 300

    /// 把采样重采成 count 个点用来画线：格子落在两个采样之间就线性插值。
    /// 真正断开的地方（超过 maxGap 没有数据）返回 nil，画的时候留白——
    /// 拿前一个值补成直线会让人以为那会儿一直在耗这么多电。纯函数，便于测试
    func curve(points count: Int, now: Date = Date()) -> [Double?] {
        guard count > 0, let first = samples.first else { return [] }
        // 起点是第一个采样，不是「24 小时前」：只采了十分钟就不该在左边画出一大片假曲线
        let start = max(first.time, now.addingTimeInterval(-Self.window))
        let duration = max(1, now.timeIntervalSince(start))
        var result = [Double?](repeating: nil, count: count)
        // 格子里有采样就取最大值：功耗的尖峰往往只有几秒，取平均或插值会被抹平，
        // 结果统计里写着峰值 42 W，曲线上却只看到 15 W
        var peaks = [Double?](repeating: nil, count: count)
        for sample in samples where sample.time >= start {
            let slot = min(count - 1, max(0, Int(sample.time.timeIntervalSince(start) / duration * Double(count))))
            peaks[slot] = max(peaks[slot] ?? sample.watts, sample.watts)
        }
        var index = 0
        for i in 0..<count {
            if let peak = peaks[i] { result[i] = peak; continue }
            let time = start.addingTimeInterval(duration * (Double(i) + 0.5) / Double(count))
            while index + 1 < samples.count, samples[index + 1].time <= time { index += 1 }
            let previous = samples[index]
            let next = index + 1 < samples.count ? samples[index + 1] : nil
            if let next, time >= previous.time {
                let gap = next.time.timeIntervalSince(previous.time)
                if gap <= Self.maxGap {
                    let ratio = gap > 0 ? time.timeIntervalSince(previous.time) / gap : 0
                    result[i] = previous.watts + (next.watts - previous.watts) * ratio
                }
            } else if abs(time.timeIntervalSince(previous.time)) <= Self.maxGap {
                result[i] = previous.watts   // 曲线两头：贴着最近的那个采样
            }
        }
        return result
    }

    /// 跨度的说法：不到一小时说分钟，超过就说小时。菜单和窗口共用
    static func spanText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) 分钟" }
        let hours = Double(minutes) / 60
        return hours < 10 ? String(format: "%.1f 小时", hours) : "\(Int(hours.rounded())) 小时"
    }
}

/// 把曲线画成菜单里能放的小图
enum PowerChart {
    /// 调试：把菜单里那条迷你曲线单独存成 PNG，检查边框和留白
    static func renderPreview(toDirectory dir: String) {
        for (name, appearance) in [("power-sparkline", NSAppearance(named: .aqua)),
                                   ("power-sparkline-dark", NSAppearance(named: .darkAqua))] {
            NSAppearance.current = appearance
            guard let image = image(for: .preview()),
                  let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }

        static let size = NSSize(width: 236, height: 52)

    /// 画折线 + 填充。菜单条目的图会在展示时才绘制，所以深浅色会自动跟着系统走
    static func image(for history: PowerHistory, size: NSSize = size) -> NSImage? {
        let values = history.curve(points: Int(size.width / 2))
        let known = values.compactMap { $0 }
        guard values.count > 1, known.count > 1 else { return nil }
        // 纵轴上下限取到好读的刻度：0 W / 20 W、0.5 W / 1.5 W 这种
        let (bottom, top) = axisBounds(low: known.min() ?? 0, high: known.max() ?? 1)
        let lowest = bottom, highest = top

        return NSImage(size: size, flipped: false) { full in
            // 和曲线窗口一样的圆角卡片，菜单里也有个边界
            let frame = full.insetBy(dx: 0.5, dy: 0.5)
            let card = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
            NSColor.separatorColor.setStroke()
            card.lineWidth = 1
            card.stroke()
            card.setClip()

            let rect = full.insetBy(dx: 2, dy: 3)
            let step = rect.width / CGFloat(values.count - 1)
            func point(_ i: Int, _ value: Double) -> NSPoint {
                NSPoint(x: rect.minX + CGFloat(i) * step,
                        y: rect.minY + rect.height * CGFloat((value - bottom) / (top - bottom)))
            }
            // 有数据的连续段各画各的，中间断开的地方留白
            for segment in PowerChart.segments(values) {
                let path = NSBezierPath()
                for (n, i) in segment.enumerated() {
                    let p = point(i, values[i]!)
                    if n == 0 { path.move(to: p) } else { path.line(to: p) }
                }
                let fill = path.copy() as! NSBezierPath
                fill.line(to: NSPoint(x: point(segment.last!, values[segment.last!]!).x, y: full.minY))
                fill.line(to: NSPoint(x: point(segment.first!, values[segment.first!]!).x, y: full.minY))
                fill.close()
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                fill.fill()

                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 1.5
                path.lineJoinStyle = .round
                path.stroke()
            }

            // 菜单里放不下刻度线，就把上下限标在左边，至少知道纵轴的量级
            func label(_ watts: Double, at y: CGFloat) {
                NSAttributedString(string: PowerAxis.label(watts), attributes: [
                    .font: NSFont.systemFont(ofSize: 8),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]).draw(at: NSPoint(x: full.minX + 4, y: y))
            }
            label(highest, at: full.maxY - 11)
            label(lowest, at: full.minY + 2)
            return true
        }
    }

    /// 迷你曲线的上下限：和窗口用同一套刻度规则，只是格子少一点
    static func axisBounds(low: Double, high: Double) -> (bottom: Double, top: Double) {
        let axis = PowerAxis.axis(low: low, high: high, maxTicks: 3)
        return (axis.bottom, axis.top)
    }

    /// 把带空洞的曲线切成一段段连续下标。纯函数，便于测试
    static func segments(_ values: [Double?]) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        for (i, value) in values.enumerated() {
            if value != nil { current.append(i) }
            else if current.count > 1 { result.append(current); current = [] }
            else { current = [] }
        }
        if current.count > 1 { result.append(current) }
        return result
    }
}

extension PowerHistory {
    /// 文档 / 调试用：造一段有起伏、中间带休眠空档的采样
    static func preview(hours: Double = 1, gap: ClosedRange<Double>? = nil) -> PowerHistory {
        var history = PowerHistory()
        let minutes = Int(hours * 60)
        let start = Date().addingTimeInterval(-hours * 3600)
        for minute in 0..<minutes {
            let t = Double(minute) / Double(minutes)
            if let gap, gap.contains(t) { continue }
            let watts = 9 + 5 * sin(t * 18) + (t > 0.72 && t < 0.78 ? 13 : 0) + Double.random(in: -0.8...0.8)
            history.add(watts: watts, at: start.addingTimeInterval(Double(minute) * 60))
        }
        return history
    }
}

/// 曲线看多长一段。菜单和窗口共用这一个设置
enum PowerSpan {
    static let options: [(label: String, seconds: TimeInterval)] = [
        ("1 小时", 3600), ("6 小时", 6 * 3600), ("24 小时", 24 * 3600),
    ]

    static var current: TimeInterval {
        get {
            let saved = UserDefaults.standard.double(forKey: "powerChartSpan")
            return options.contains { $0.seconds == saved } ? saved : 3600
        }
        set { UserDefaults.standard.set(newValue, forKey: "powerChartSpan") }
    }

    static func label(for seconds: TimeInterval) -> String {
        options.first { $0.seconds == seconds }?.label ?? options[0].label
    }
}

/// 功耗纵轴的刻度规则，菜单曲线和窗口共用。
/// 刻度小于 5 时取 0.25 的倍数（0.25、0.5、1、2.5），5 以上取 5 的倍数（5、10、20、25、50、100）：
/// 空闲时 1 W 上下的起伏也看得出来，高负载时数字又不会零碎
enum PowerAxis {
    static let steps: [Double] = [0.25, 0.5, 1, 2.5, 5, 10, 20, 25, 50, 100]

    /// 纯函数，便于测试
    static func axis(low: Double, high: Double, maxTicks: Int = 5) -> (bottom: Double, top: Double, step: Double) {
        // 至少跨 1 瓦：读数平稳时别把零点零几瓦的噪声放大成大起大落
        let span = max(1, high - low)
        let step = steps.first { span / $0 <= Double(maxTicks) } ?? steps.last!
        let bottom = max(0, (low / step).rounded(.down) * step)
        var top = (high / step).rounded(.up) * step
        while top - bottom < step * 2 { top += step }   // 至少两格
        return (bottom, top, step)
    }

    /// 横轴刻度：落在整点上的时间（14:00、14:15…），间隔从下面几档里挑，保证不超过 maxTicks 个。
    /// 纯函数，便于测试
    static let timeSteps: [TimeInterval] = [5, 15, 30, 60, 120, 180, 240, 360].map { $0 * 60 }

    static func timeTicks(from start: Date, to end: Date, maxTicks: Int = 6,
                          calendar: Calendar = .current) -> [Date] {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return [] }
        // 留一点余量：正好一小时的跨度会因为多出几毫秒被挤到下一档
        let step = timeSteps.first { duration / $0 <= Double(maxTicks) + 0.05 } ?? timeSteps.last!
        // 按当地时间对齐到整点：从当天零点起算，往后找第一个整倍数
        let midnight = calendar.startOfDay(for: start)
        let offset = start.timeIntervalSince(midnight)
        var tick = midnight.addingTimeInterval((offset / step).rounded(.up) * step)
        var ticks: [Date] = []
        while tick <= end {
            ticks.append(tick)
            tick = tick.addingTimeInterval(step)
        }
        return ticks
    }

    /// 给曲线用的刻度：换算成占宽度的比例。起点和曲线一致（第一个采样），终点是现在
    static func relativeTicks(for history: PowerHistory, now: Date = Date(), maxTicks: Int,
                              calendar: Calendar = .current) -> [(position: CGFloat, label: String)] {
        guard let start = history.samples.first?.time else { return [] }
        let duration = now.timeIntervalSince(start)
        guard duration > 0 else { return [] }
        return timeTicks(from: start, to: now, maxTicks: maxTicks, calendar: calendar).map {
            (CGFloat($0.timeIntervalSince(start) / duration), timeLabel($0, calendar: calendar))
        }
    }

    static func timeLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// 刻度标签：整数不带小数点，0.25 这种保留到需要的位数
    static func label(_ watts: Double) -> String {
        if watts == watts.rounded() { return String(format: "%.0f W", watts) }
        if (watts * 2) == (watts * 2).rounded() { return String(format: "%.1f W", watts) }
        return String(format: "%.2f W", watts)
    }
}
