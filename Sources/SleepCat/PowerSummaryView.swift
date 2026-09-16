// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 功耗子菜单里的整块面板：标题、大数字和状态、三块卡片、整机功耗曲线、统计、查看大图的入口。
/// 全部自绘；数据每次绘制时现取，菜单开着时每秒重画一次
final class PowerSummaryView: NSView {
    private let historyProvider: () -> PowerHistory
    private let flowProvider: () -> PowerFlow?
    /// 点底部「查看功耗曲线」时调用
    var onOpenChart: (() -> Void)?

    private enum Layout {
        static let width: CGFloat = 372
        static let padding: CGFloat = 18
        static let header: CGFloat = 34
        static let hero: CGFloat = 62
        static let cards: CGFloat = 58
        static let sectionHeader: CGFloat = 44
        static let chart: CGFloat = 118
        static let stats: CGFloat = 50
        static let footer: CGFloat = 38
        static let gap: CGFloat = 12
    }

    private var footerRect = NSRect.zero
    private var footerHovered = false

    private lazy var spanControl: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: PowerSpan.options.map(\.label),
                                         trackingMode: .selectOne, target: self, action: #selector(spanChanged))
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.font = .systemFont(ofSize: 11)
        control.selectedSegment = PowerSpan.options.firstIndex { $0.seconds == PowerSpan.current } ?? 0
        return control
    }()

    init(history: @escaping () -> PowerHistory, flow: @escaping () -> PowerFlow?) {
        historyProvider = history
        flowProvider = flow
        super.init(frame: .zero)
        let height = Layout.header + Layout.hero + Layout.cards + Layout.gap * 2 + 1
            + Layout.sectionHeader + Layout.chart + Layout.gap + 1 + Layout.stats + 1 + Layout.footer + 6
        setFrameSize(NSSize(width: Layout.width, height: height))
        autoresizingMask = [.width]
        addSubview(spanControl)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }   // 从上往下排版

    private var contentWidth: CGFloat { bounds.width - Layout.padding * 2 }

    // 各块的纵向起点（翻转坐标，y 往下）
    private var heroTop: CGFloat { Layout.header }
    private var cardsTop: CGFloat { heroTop + Layout.hero }
    private var firstDivider: CGFloat { cardsTop + Layout.cards + Layout.gap }
    private var sectionTop: CGFloat { firstDivider + 1 + Layout.gap }
    private var chartTop: CGFloat { sectionTop + Layout.sectionHeader }
    private var secondDivider: CGFloat { chartTop + Layout.chart + Layout.gap }
    private var statsTop: CGFloat { secondDivider + 1 }
    private var thirdDivider: CGFloat { statsTop + Layout.stats }
    private var footerTop: CGFloat { thirdDivider + 1 }

    override func layout() {
        super.layout()
        let size = spanControl.intrinsicContentSize
        spanControl.frame = NSRect(x: bounds.width - Layout.padding - size.width, y: sectionTop + 4,
                                   width: size.width, height: size.height)
        footerRect = NSRect(x: 6, y: footerTop, width: bounds.width - 12, height: Layout.footer)
    }

    @objc private func spanChanged() {
        PowerSpan.current = PowerSpan.options[spanControl.selectedSegment].seconds
        needsDisplay = true
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let flow = flowProvider()
        let visible = historyProvider().limited(to: PowerSpan.current)
        drawHeader()
        drawHero(flow)
        drawCards(flow?.cards ?? [])
        drawDivider(at: firstDivider)
        drawSectionHeader(visible)
        drawChart(visible)
        drawDivider(at: secondDivider)
        drawStats(visible)
        drawDivider(at: thirdDivider)
        drawFooter()
    }

    private func drawHeader() {
        let x = Layout.padding
        drawSymbol("bolt.fill", in: NSRect(x: x, y: 9, width: 14, height: 18), color: .systemBlue, pointSize: 15)
        text("功耗", NSPoint(x: x + 22, y: 9), .systemFont(ofSize: 14, weight: .semibold), .labelColor)

        let live = "实时"
        let font = NSFont.systemFont(ofSize: 12)
        let width = size(live, font).width
        let right = bounds.width - Layout.padding
        text(live, NSPoint(x: right - width, y: 10), font, .secondaryLabelColor)
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: NSRect(x: right - width - 13, y: 14.5, width: 8, height: 8)).fill()
    }

    private func drawHero(_ flow: PowerFlow?) {
        let x = Layout.padding
        guard let flow else {
            text("读不到功耗", NSPoint(x: x, y: heroTop + 16), .systemFont(ofSize: 20, weight: .semibold), .secondaryLabelColor)
            return
        }
        let number = String(format: "%.1f", flow.headline.watts)
        let numberFont = NSFont.systemFont(ofSize: 46, weight: .bold)
        text(number, NSPoint(x: x - 2, y: heroTop - 2), numberFont, .labelColor)
        let numberWidth = size(number, numberFont).width
        let unitFont = NSFont.systemFont(ofSize: 22, weight: .medium)
        text("W", NSPoint(x: x + numberWidth + 4, y: heroTop + 23), unitFont, .secondaryLabelColor)

        // 状态胶囊
        let badge = flow.badge
        let badgeFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let badgeSize = size(badge.text, badgeFont)
        let pill = NSRect(x: x + numberWidth + 4 + size("W", unitFont).width + 16, y: heroTop + 16,
                          width: badgeSize.width + 24, height: 28)
        let color = Self.color(for: badge.tone)
        let path = NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10)
        color.withAlphaComponent(0.14).setFill()
        path.fill()
        color.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
        text(badge.text, NSPoint(x: pill.minX + 12, y: pill.midY - badgeSize.height / 2), badgeFont, color)
    }

    private func drawCards(_ cards: [PowerFlow.Card]) {
        guard !cards.isEmpty else { return }
        let gap: CGFloat = 8
        let width = (contentWidth - gap * CGFloat(cards.count - 1)) / CGFloat(cards.count)
        for (index, card) in cards.enumerated() {
            let frame = NSRect(x: Layout.padding + CGFloat(index) * (width + gap), y: cardsTop,
                               width: width, height: Layout.cards)
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()

            let symbol: String
            switch card.kind {
            case .adapter: symbol = "powerplug"
            case .system: symbol = "laptopcomputer"
            case .battery: symbol = "battery.75percent"
            }
            let iconColor: NSColor = card.kind == .battery && card.tone != .muted
                ? Self.color(for: card.tone) : .secondaryLabelColor
            drawSymbol(symbol, in: NSRect(x: frame.minX + 10, y: frame.minY + 9, width: 18, height: 14),
                       color: iconColor, pointSize: 12)
            text(card.title, NSPoint(x: frame.minX + 32, y: frame.minY + 8), .systemFont(ofSize: 11), .secondaryLabelColor)

            let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
            let valueColor = card.tone == .normal ? NSColor.labelColor : Self.color(for: card.tone)
            text(card.value, NSPoint(x: frame.minX + 32, y: frame.minY + 27), valueFont, valueColor)
            // 额定功率放在右上角的小字里：跟在数字后面的话，三位数时会顶到卡片边上
            if let suffix = card.suffix {
                let rated = suffix.replacingOccurrences(of: "/ ", with: "") + " W"
                let ratedFont = NSFont.systemFont(ofSize: 10)
                let width = size(rated, ratedFont).width
                text(rated, NSPoint(x: frame.maxX - 9 - width, y: frame.minY + 9), ratedFont, .tertiaryLabelColor)
            }
        }
    }

    private func drawSectionHeader(_ visible: PowerHistory) {
        text("整机功耗", NSPoint(x: Layout.padding, y: sectionTop), .systemFont(ofSize: 14, weight: .semibold), .labelColor)
        let recorded = visible.isEmpty ? "还没有记录" : "已记录 \(PowerHistory.spanText(visible.span))"
        text(recorded, NSPoint(x: Layout.padding, y: sectionTop + 20), .systemFont(ofSize: 11), .secondaryLabelColor)
    }

    private func drawChart(_ visible: PowerHistory) {
        let labelWidth: CGFloat = 36
        let plot = NSRect(x: Layout.padding + labelWidth, y: chartTop + 6,
                          width: contentWidth - labelWidth, height: Layout.chart - 30)
        let now = Date()
        let values = visible.curve(points: max(2, Int(plot.width / 2)), now: now)
        let known = values.compactMap { $0 }
        let axis = PowerAxis.axis(low: known.min() ?? 0, high: known.max() ?? 5, maxTicks: 3)

        func y(_ watts: Double) -> CGFloat {
            plot.maxY - plot.height * CGFloat((watts - axis.bottom) / max(0.001, axis.top - axis.bottom))
        }

        // 横向点状网格 + 纵轴刻度
        let labelFont = NSFont.systemFont(ofSize: 10)
        var tick = axis.bottom
        while tick <= axis.top + 0.001 {
            dotted(from: NSPoint(x: plot.minX, y: y(tick).rounded() + 0.5), to: NSPoint(x: plot.maxX, y: y(tick).rounded() + 0.5))
            let label = PowerAxis.label(tick)
            let labelSize = size(label, labelFont)
            text(label, NSPoint(x: plot.minX - 8 - labelSize.width, y: y(tick) - labelSize.height / 2),
                 labelFont, .secondaryLabelColor)
            tick += axis.step
        }

        // 横轴：整点时间刻度 + 竖向点状线
        if let start = visible.samples.first?.time, now.timeIntervalSince(start) > 0 {
            let duration = now.timeIntervalSince(start)
            var lastRight = -CGFloat.infinity
            let nowWidth = size("现在", labelFont).width
            for time in PowerAxis.timeTicks(from: start, to: now, maxTicks: 5) {
                let x = plot.minX + plot.width * CGFloat(time.timeIntervalSince(start) / duration)
                dotted(from: NSPoint(x: x.rounded() + 0.5, y: plot.minY), to: NSPoint(x: x.rounded() + 0.5, y: plot.maxY))
                let label = PowerAxis.timeLabel(time)
                let width = size(label, labelFont).width
                let labelX = min(max(x - width / 2, plot.minX), plot.maxX - width)
                guard labelX > lastRight + 8, labelX + width < plot.maxX - nowWidth - 8 else { continue }
                text(label, NSPoint(x: labelX, y: plot.maxY + 8), labelFont, .secondaryLabelColor)
                lastRight = labelX + width
            }
            text("现在", NSPoint(x: plot.maxX - nowWidth, y: plot.maxY + 8), labelFont, .secondaryLabelColor)
        }

        // 底边实线
        let base = NSBezierPath()
        base.move(to: NSPoint(x: plot.minX, y: plot.maxY - 0.5))
        base.line(to: NSPoint(x: plot.maxX, y: plot.maxY - 0.5))
        NSColor.separatorColor.setStroke()
        base.lineWidth = 1
        base.stroke()

        guard known.count > 1 else {
            text("还在采样，攒够一分钟就有曲线了", NSPoint(x: plot.minX + 12, y: plot.midY - 7),
                 .systemFont(ofSize: 11), .tertiaryLabelColor)
            return
        }
        let step = plot.width / CGFloat(values.count - 1)
        for segment in PowerChart.segments(values) {
            let line = NSBezierPath()
            for (n, i) in segment.enumerated() {
                let point = NSPoint(x: plot.minX + CGFloat(i) * step, y: y(values[i]!))
                if n == 0 { line.move(to: point) } else { line.line(to: point) }
            }
            // 线下面是由浓到淡的渐变填充
            let fill = line.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: plot.minX + CGFloat(segment.last!) * step, y: plot.maxY))
            fill.line(to: NSPoint(x: plot.minX + CGFloat(segment.first!) * step, y: plot.maxY))
            fill.close()
            NSGradient(starting: NSColor.systemBlue.withAlphaComponent(0.45),
                       ending: NSColor.systemBlue.withAlphaComponent(0.02))?.draw(in: fill, angle: 90)

            NSColor.systemBlue.setStroke()
            line.lineWidth = 2
            line.lineJoinStyle = .round
            line.stroke()
        }
    }

    private func drawStats(_ visible: PowerHistory) {
        let items: [(String, Double?)] = [("平均", visible.average), ("峰值", visible.highest), ("最低", visible.lowest)]
        let column = contentWidth / CGFloat(items.count)
        for (index, item) in items.enumerated() {
            let x = Layout.padding + CGFloat(index) * column
            if index > 0 {
                let separator = NSBezierPath()
                separator.move(to: NSPoint(x: x.rounded() + 0.5, y: statsTop + 12))
                separator.line(to: NSPoint(x: x.rounded() + 0.5, y: statsTop + Layout.stats - 10))
                NSColor.separatorColor.setStroke()
                separator.lineWidth = 1
                separator.stroke()
            }
            let inset: CGFloat = index == 0 ? 2 : 16
            text(item.0, NSPoint(x: x + inset, y: statsTop + 8), .systemFont(ofSize: 11), .secondaryLabelColor)
            text(item.1.map(PowerMeter.wattsText) ?? "—", NSPoint(x: x + inset, y: statsTop + 23),
                 .monospacedDigitSystemFont(ofSize: 17, weight: .semibold), .labelColor)
        }
    }

    private func drawFooter() {
        if footerHovered {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: footerRect.insetBy(dx: 0, dy: 3), xRadius: 6, yRadius: 6).fill()
        }
        let ink: NSColor = footerHovered ? .selectedMenuItemTextColor : .labelColor
        let x = Layout.padding
        drawSymbol("chart.xyaxis.line", in: NSRect(x: x, y: footerTop + 11, width: 18, height: 16), color: ink, pointSize: 13)
        text("查看功耗曲线", NSPoint(x: x + 28, y: footerTop + 10), .systemFont(ofSize: 13), ink)
        drawSymbol("chevron.right", in: NSRect(x: bounds.width - Layout.padding - 8, y: footerTop + 12, width: 8, height: 14),
                   color: footerHovered ? ink : .secondaryLabelColor, pointSize: 11)
    }

    // MARK: 交互：底部那一行可以点

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }

    override func mouseExited(with event: NSEvent) {
        guard footerHovered else { return }
        footerHovered = false
        needsDisplay = true
    }

    private func updateHover(_ event: NSEvent) {
        let hovered = footerRect.contains(convert(event.locationInWindow, from: nil))
        guard hovered != footerHovered else { return }
        footerHovered = hovered
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard footerRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        // 打开窗口要先把菜单收起来，不然窗口会被菜单挡在后面
        enclosingMenuItem?.menu?.cancelTracking()
        enclosingMenuItem?.menu?.supermenu?.cancelTracking()
        onOpenChart?()
    }

    // MARK: 小工具

    static func color(for tone: PowerFlow.Tone) -> NSColor {
        switch tone {
        case .normal: return .labelColor
        case .charge: return .systemGreen
        case .discharge: return .systemOrange
        case .plugged: return .systemBlue
        case .muted: return .tertiaryLabelColor
        }
    }

    private func text(_ string: String, _ point: NSPoint, _ font: NSFont, _ color: NSColor) {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
    }

    private func size(_ string: String, _ font: NSFont) -> NSSize {
        NSAttributedString(string: string, attributes: [.font: font]).size()
    }

    private func drawDivider(at y: CGFloat) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: Layout.padding, y: y.rounded() + 0.5))
        line.line(to: NSPoint(x: bounds.width - Layout.padding, y: y.rounded() + 0.5))
        NSColor.separatorColor.setStroke()
        line.lineWidth = 1
        line.stroke()
    }

    private func dotted(from start: NSPoint, to end: NSPoint) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = 1
        path.setLineDash([2, 3], count: 2, phase: 0)
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        path.stroke()
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor, pointSize: CGFloat) {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)
        guard let symbol = base?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium)) else { return }
        let size = symbol.size
        let box = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        // 模板图要在透明底上染色
        let tinted = NSImage(size: size, flipped: false) { r in
            symbol.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: 调试预览

    /// 把面板画成 PNG。-previewHours 调数据跨度，-previewBattery YES 看用电池的样子
    static func renderPreview(toDirectory dir: String) {
        let hours = UserDefaults.standard.double(forKey: "previewHours")
        let history = PowerHistory.preview(hours: hours > 0 ? hours : 1.2)
        let onBattery = UserDefaults.standard.bool(forKey: "previewBattery")
        let flow = onBattery
            ? PowerFlow(system: 4.2, adapter: nil, battery: -5.6)
            : PowerFlow(system: 11.6, adapter: 49.1, battery: 37.5, adapterRated: 70)
        for (name, appearance) in [("power-summary", NSAppearance(named: .aqua)),
                                   ("power-summary-dark", NSAppearance(named: .darkAqua))] {
            NSAppearance.current = appearance
            let view = PowerSummaryView(history: { history }, flow: { flow })
            view.appearance = appearance
            let canvas = PreviewBackdrop(frame: view.bounds)
            canvas.appearance = appearance
            canvas.addSubview(view)
            canvas.layoutSubtreeIfNeeded()
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { continue }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}

/// 预览用：垫一层菜单底色，不然浅色文字在透明底上看不见
private final class PreviewBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}
