// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 最近一小时的功耗采样，菜单里画成折线图用。
/// 只放在内存里：关掉应用就没了，长期数据看 CSV 记录
struct PowerHistory {
    /// 留多久的数据
    static let window: TimeInterval = 3600

    private(set) var samples: [(time: Date, watts: Double)] = []

    mutating func add(watts: Double, at now: Date = Date()) {
        samples.append((now, watts))
        let cutoff = now.addingTimeInterval(-Self.window)
        // 采样是按时间顺序进来的，从头丢到第一个还在窗口内的为止
        if let keep = samples.firstIndex(where: { $0.time >= cutoff }), keep > 0 {
            samples.removeFirst(keep)
        }
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

    /// 把采样压成 count 个点用来画线：每格取平均，空格子用前后值补上。
    /// 纯函数，便于测试
    func curve(points count: Int, now: Date = Date()) -> [Double] {
        guard count > 0, let first = samples.first else { return [] }
        // 起点是第一个采样，不是「一小时前」：只采了十分钟就不该在左边画出五十分钟的假平线
        let start = max(first.time, now.addingTimeInterval(-Self.window))
        let duration = max(1, now.timeIntervalSince(start))
        var sums = [Double](repeating: 0, count: count)
        var hits = [Int](repeating: 0, count: count)
        for sample in samples {
            let ratio = sample.time.timeIntervalSince(start) / duration
            let slot = min(count - 1, max(0, Int(ratio * Double(count))))
            sums[slot] += sample.watts
            hits[slot] += 1
        }
        var curve = [Double]()
        var carry = samples.first?.watts ?? 0
        for i in 0..<count {
            if hits[i] > 0 { carry = sums[i] / Double(hits[i]) }
            curve.append(carry)
        }
        return curve
    }
}

/// 把曲线画成菜单里能放的小图
enum PowerChart {
    static let size = NSSize(width: 236, height: 52)

    /// 画折线 + 填充。菜单条目的图会在展示时才绘制，所以深浅色会自动跟着系统走
    static func image(for history: PowerHistory, size: NSSize = size) -> NSImage? {
        let values = history.curve(points: Int(size.width / 2))
        guard values.count > 1 else { return nil }
        let lowest = values.min() ?? 0
        let highest = values.max() ?? 1
        // 上下各留一点余量，曲线不会贴边；全程恒定时画在中间
        let span = max(1.0, highest - lowest)
        let bottom = lowest - span * 0.25, top = highest + span * 0.25

        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            let step = rect.width / CGFloat(values.count - 1)
            for (i, value) in values.enumerated() {
                let ratio = (value - bottom) / (top - bottom)
                let point = NSPoint(x: rect.minX + CGFloat(i) * step,
                                    y: rect.minY + rect.height * CGFloat(ratio))
                if i == 0 { path.move(to: point) } else { path.line(to: point) }
            }

            // 线下方填一层淡色，读数走势一眼能看出来
            let fill = path.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            fill.line(to: NSPoint(x: rect.minX, y: rect.minY))
            fill.close()
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            fill.fill()

            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            path.stroke()
            return true
        }
    }
}
