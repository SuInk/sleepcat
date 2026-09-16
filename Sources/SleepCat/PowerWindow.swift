// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 功耗曲线窗口：比菜单里那条小曲线看得清楚，能看出一小时里的起伏。
/// 菜单栏应用平时没有窗口，所以打开时要主动把自己带到前台
final class PowerWindowController: NSObject, NSWindowDelegate {
    static let shared = PowerWindowController()

    private var window: NSWindow?
    private var chart: PowerChartView?
    private var timer: Timer?
    private var source: (() -> (history: PowerHistory, footnote: String?))?

    /// - Parameters:
    ///   - history: 每次刷新时现取，窗口不自己存数据
    ///   - footnote: 底部那行（今天用电），文案和菜单里保持一致
    func show(history: @escaping () -> (history: PowerHistory, footnote: String?)) {
        source = history
        if let window {
            refresh()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = PowerChartView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        let w = NSWindow(contentRect: view.frame,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "功耗曲线"
        w.contentView = view
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.center()
        w.minSize = NSSize(width: 380, height: 220)
        window = w
        chart = view
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        guard let source else { return }
        let snapshot = source()
        chart?.history = snapshot.history
        chart?.footnote = snapshot.footnote
        chart?.needsDisplay = true
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

/// 曲线本体：标题行 + 折线 + 横向网格。自己画，不引第三方图表库
final class PowerChartView: NSView {
    var history = PowerHistory() {
        didSet { needsDisplay = true }
    }
    var footnote: String?
    /// 切换跨度后回调，让菜单那边也跟着变
    var onSpanChange: (() -> Void)?

    private lazy var spanControl: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: PowerSpan.options.map(\.label),
                                         trackingMode: .selectOne, target: self, action: #selector(spanChanged))
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.font = .systemFont(ofSize: 11)
        control.selectedSegment = PowerSpan.options.firstIndex { $0.seconds == PowerSpan.current } ?? 0
        return control
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(spanControl)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let size = spanControl.intrinsicContentSize
        spanControl.frame = NSRect(x: bounds.maxX - size.width - 20, y: bounds.maxY - size.height - 22,
                                   width: size.width, height: size.height)
    }

    @objc private func spanChanged() {
        PowerSpan.current = PowerSpan.options[spanControl.selectedSegment].seconds
        needsDisplay = true
        onSpanChange?()
    }

    /// 当前选中的那一段
    private var visible: PowerHistory { history.limited(to: PowerSpan.current) }

    private let inset = NSEdgeInsets(top: 78, left: 56, bottom: 54, right: 20)

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let plot = NSRect(x: bounds.minX + inset.left,
                          y: bounds.minY + inset.bottom,
                          width: bounds.width - inset.left - inset.right,
                          height: bounds.height - inset.top - inset.bottom)
        // 圆角卡片：和清洁键盘面板、灵动岛一个路子
        let frame = plot.insetBy(dx: -10, dy: -10).insetBy(dx: 0.5, dy: 0.5)   // 半像素对齐，边框才是实的一条
        let card = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        NSColor.textBackgroundColor.withAlphaComponent(0.6).setFill()
        card.fill()
        NSColor.separatorColor.setStroke()
        card.lineWidth = 1
        card.stroke()
        drawHeader()
        guard plot.width > 20, plot.height > 20 else { return }

        let now = Date()
        let values = visible.curve(points: max(2, Int(plot.width / 2)), now: now)
        let known = values.compactMap { $0 }
        guard values.count > 1, known.count > 1, let low = known.min(), let high = known.max() else {
            drawPlaceholder(in: plot)
            return
        }

        // 纵轴取整到好看的刻度，曲线不贴边
        let (bottom, top, step) = Self.axis(low: low, high: high)
        drawGrid(in: plot, bottom: bottom, top: top, step: step)
        drawCurve(values, in: plot, bottom: bottom, top: top)
        drawTimeAxis(in: plot, now: now)
    }

    private func drawHeader() {
        let textX = inset.left
        let current = visible.latest.map { PowerMeter.wattsText($0) } ?? "读不到"
        // 字号和面板、灵动岛一致：标题 semibold，副文案 11pt 次要色
        draw(current, at: NSPoint(x: textX, y: bounds.maxY - 42),
             font: .systemFont(ofSize: 24, weight: .semibold), color: .labelColor)
        draw(PowerMeter.statsText(visible) ?? "", at: NSPoint(x: textX, y: bounds.maxY - 61),
             font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    }

    private func drawPlaceholder(in plot: NSRect) {
        draw("还在采样，攒够一分钟就有曲线了",
             at: NSPoint(x: plot.midX - 96, y: plot.midY), font: .systemFont(ofSize: 12), color: .tertiaryLabelColor)
    }

    private func drawGrid(in plot: NSRect, bottom: Double, top: Double, step: Double) {
        // 纵轴：贴着卡片左内缘的一条实线，刻度就挂在它左边
        let axis = NSBezierPath()
        axis.move(to: NSPoint(x: plot.minX.rounded() + 0.5, y: plot.minY))
        axis.line(to: NSPoint(x: plot.minX.rounded() + 0.5, y: plot.maxY))
        NSColor.separatorColor.setStroke()
        axis.lineWidth = 1
        axis.stroke()

        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        var value = bottom
        while value <= top + 0.001 {
            let y = plot.minY + plot.height * CGFloat((value - bottom) / (top - bottom))
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y.rounded() + 0.5))
            line.line(to: NSPoint(x: plot.maxX, y: y.rounded() + 0.5))
            line.lineWidth = 1
            line.stroke()
            draw(PowerAxis.label(value), at: NSPoint(x: plot.minX - 50, y: y - 6),
                 font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
            value += step
        }
    }

    /// 有数据的连续段各画各的：应用没开、Mac 睡着的那几段留白，不画成直线
    private func drawCurve(_ values: [Double?], in plot: NSRect, bottom: Double, top: Double) {
        let step = plot.width / CGFloat(values.count - 1)
        func point(_ i: Int, _ value: Double) -> NSPoint {
            NSPoint(x: plot.minX + CGFloat(i) * step,
                    y: plot.minY + plot.height * CGFloat((value - bottom) / (top - bottom)))
        }
        for segment in PowerChart.segments(values) {
            let path = NSBezierPath()
            for (n, i) in segment.enumerated() {
                let p = point(i, values[i]!)
                if n == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            let fill = path.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: point(segment.last!, values[segment.last!]!).x, y: plot.minY))
            fill.line(to: NSPoint(x: point(segment.first!, values[segment.first!]!).x, y: plot.minY))
            fill.close()
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            fill.fill()

            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    /// 横轴：整点时间刻度 + 淡淡的竖向网格线。起点和曲线一致（第一个采样），终点是现在
    private func drawTimeAxis(in plot: NSRect, now: Date) {
        guard let first = visible.samples.first?.time else { return }
        let start = max(first, now.addingTimeInterval(-PowerHistory.window))
        let duration = now.timeIntervalSince(start)
        guard duration > 0 else { return }
        let font = NSFont.systemFont(ofSize: 10)
        for tick in PowerAxis.timeTicks(from: start, to: now) {
            let x = plot.minX + plot.width * CGFloat(tick.timeIntervalSince(start) / duration)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x.rounded() + 0.5, y: plot.minY))
            line.line(to: NSPoint(x: x.rounded() + 0.5, y: plot.maxY))
            NSColor.separatorColor.withAlphaComponent(0.18).setStroke()
            line.lineWidth = 1
            line.stroke()

            let text = PowerAxis.timeLabel(tick)
            let width = NSAttributedString(string: text, attributes: [.font: font]).size().width
            // 标签居中在刻度下面，但别探出绘图区左右两边
            let labelX = min(max(x - width / 2, plot.minX), plot.maxX - width)
            draw(text, at: NSPoint(x: labelX, y: plot.minY - 28), font: font, color: .tertiaryLabelColor)
        }
        if let footnote {
            draw(footnote, at: NSPoint(x: inset.left, y: 8),
                 font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        }
    }

    private func draw(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            .draw(at: point)
    }

    /// 纵轴范围：规则见 PowerAxis。
    /// 纯函数，便于测试
    static func axis(low: Double, high: Double) -> (bottom: Double, top: Double, step: Double) {
        PowerAxis.axis(low: low, high: high)
    }

    /// 调试：拿一段合成数据把窗口画成 PNG，方便看排版
    static func renderPreview(toDirectory dir: String) {
        let history = PowerHistory.preview(hours: 24, gap: 0.12...0.37)
        for (name, appearance) in [("power-window", NSAppearance(named: .aqua)),
                                   ("power-window-dark", NSAppearance(named: .darkAqua))] {
            let view = PowerChartView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
            view.appearance = appearance
            view.history = history
            view.footnote = "今天用电 12.4 Wh"
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
