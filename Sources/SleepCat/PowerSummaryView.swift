// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 功耗子菜单里的概览面板。排版顺序：主读数 → 适配器 / 整机 / 电池三块 → 整机功耗曲线 → 平均 / 峰值 / 最低。
/// 它嵌在原生菜单里，所以字号、颜色、边框都跟菜单其他行一个规格，左边界对齐菜单的图标列。
/// 数据每次绘制时现取，菜单开着时每秒重画一次
final class PowerSummaryView: NSView {
    private let historyProvider: () -> PowerHistory
    private let flowProvider: () -> PowerFlow?

    private enum Layout {
        /// 左右边距和菜单分隔线两端一样（--snapshot-align 量出来的）
        static let leading: CGFloat = 16
        static let width: CGFloat = 330
        /// 内容区宽度：放得下「整机功耗 · 已记录 …」加跨度切换，适配器卡片的额定功率也不会挤到标题上
        static let content: CGFloat = width - leading * 2
        static let headline: CGFloat = 28
        static let cards: CGFloat = 42
        static let section: CGFloat = 26
        static let ticks: CGFloat = 14
        static let stats: CGFloat = 34
    }

    private lazy var spanControl: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: PowerSpan.options.map(\.label),
                                         trackingMode: .selectOne, target: self, action: #selector(spanChanged))
        control.segmentStyle = .rounded
        control.controlSize = .mini
        control.font = .systemFont(ofSize: 10)
        control.selectedSegment = PowerSpan.options.firstIndex { $0.seconds == PowerSpan.current } ?? 0
        return control
    }()

    init(history: @escaping () -> PowerHistory, flow: @escaping () -> PowerFlow?) {
        historyProvider = history
        flowProvider = flow
        super.init(frame: .zero)
        let height = 4 + Layout.headline + Layout.cards + 10 + Layout.section
            + PowerChart.size.height + Layout.ticks + Layout.stats + 4
        setFrameSize(NSSize(width: Layout.width, height: height))
        autoresizingMask = [.width]
        addSubview(spanControl)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }   // 从上往下排版

    private var contentWidth: CGFloat { Layout.content }
    private var cardsTop: CGFloat { 4 + Layout.headline }
    private var sectionTop: CGFloat { cardsTop + Layout.cards + 10 }
    private var chartTop: CGFloat { sectionTop + Layout.section }
    private var ticksTop: CGFloat { chartTop + PowerChart.size.height + 2 }
    private var statsTop: CGFloat { ticksTop + Layout.ticks }

    override func layout() {
        super.layout()
        // 跨度切换和「整机功耗」同一行，右边缘对齐曲线的右边缘
        let size = spanControl.intrinsicContentSize
        spanControl.frame = NSRect(x: Layout.leading + contentWidth - size.width, y: sectionTop + 2,
                                   width: size.width, height: size.height)
    }

    @objc private func spanChanged() {
        PowerSpan.current = PowerSpan.options[spanControl.selectedSegment].seconds
        needsDisplay = true
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let flow = flowProvider()
        let visible = historyProvider().limited(to: PowerSpan.current)
        drawHeadline(flow)
        drawCards(flow?.cards ?? [])
        drawSection(visible)
        drawChart(visible)
        drawStats(visible)
    }

    /// 主读数：插电看适配器、用电池看放电，后面跟一段灰色的状态说明
    private func drawHeadline(_ flow: PowerFlow?) {
        let x = Layout.leading
        guard let flow else {
            text("读不到功耗", NSPoint(x: x, y: 6), .systemFont(ofSize: 15, weight: .semibold), .secondaryLabelColor)
            return
        }
        let headlineFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
        text(flow.headlineText, NSPoint(x: x, y: 6), headlineFont, .labelColor)
        let width = size(flow.headlineText, headlineFont).width
        text(flow.badge.text, NSPoint(x: x + width + 8, y: 9), .systemFont(ofSize: 11), .secondaryLabelColor)
    }

    private func drawCards(_ cards: [PowerFlow.Card]) {
        guard !cards.isEmpty else { return }
        let gap: CGFloat = 6
        let width = (contentWidth - gap * CGFloat(cards.count - 1)) / CGFloat(cards.count)
        for (index, card) in cards.enumerated() {
            let frame = NSRect(x: Layout.leading + CGFloat(index) * (width + gap), y: cardsTop,
                               width: width, height: Layout.cards - 4)
            let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            NSColor.separatorColor.setStroke()
            outline.lineWidth = 1
            outline.stroke()

            let symbol: String
            switch card.kind {
            case .adapter: symbol = "powerplug"
            case .system: symbol = "laptopcomputer"
            case .battery: symbol = "battery.75percent"
            }
            drawSymbol(symbol, in: NSRect(x: frame.minX + 7, y: frame.minY + 5, width: 14, height: 12),
                       color: .secondaryLabelColor, pointSize: 9.5)
            text(card.title, NSPoint(x: frame.minX + 26, y: frame.minY + 4), .systemFont(ofSize: 9.5), .secondaryLabelColor)
            // 额定功率放右上角：跟在数字后面的话，三位数时会顶到边框
            if let suffix = card.suffix {
                let rated = suffix.replacingOccurrences(of: "/ ", with: "") + " W"
                let ratedFont = NSFont.systemFont(ofSize: 9)
                text(rated, NSPoint(x: frame.maxX - 7 - size(rated, ratedFont).width, y: frame.minY + 5),
                     ratedFont, .tertiaryLabelColor)
            }
            let valueColor = card.tone == .normal ? NSColor.labelColor : Self.color(for: card.tone)
            text(card.value, NSPoint(x: frame.minX + 7, y: frame.minY + 18),
                 .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold), valueColor)
        }
    }

    /// 「整机功耗 · 已记录 58 分钟」：说清楚下面的曲线画的是整机，不是上面那个跟着电源状态变的主读数
    private func drawSection(_ visible: PowerHistory) {
        let recorded = visible.isEmpty ? "还没有记录" : "已记录 \(PowerHistory.spanText(visible.span))"
        text("整机功耗 · \(recorded)", NSPoint(x: Layout.leading, y: sectionTop + 3),
             .systemFont(ofSize: 11), .secondaryLabelColor)
    }

    private func drawChart(_ visible: PowerHistory) {
        let box = NSRect(x: Layout.leading, y: chartTop, width: contentWidth, height: PowerChart.size.height)
        if let chart = PowerChart.image(for: visible, size: box.size) {
            chart.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let frame = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.separatorColor.setStroke()
            frame.stroke()
            text("还在采样，攒够一分钟就有曲线了", NSPoint(x: box.minX + 10, y: box.midY - 7),
                 .systemFont(ofSize: 10), .tertiaryLabelColor)
        }

        // 横轴：整点时间刻度，最右边是「现在」。挨太近的跳过
        let font = NSFont.systemFont(ofSize: 9)
        let nowX = box.maxX - size("现在", font).width
        var lastRight = -CGFloat.infinity
        for tick in PowerAxis.relativeTicks(for: visible, maxTicks: 6) {
            let w = size(tick.label, font).width
            let x = min(max(box.minX + box.width * tick.position - w / 2, box.minX), box.maxX - w)
            guard x > lastRight + 6, x + w < nowX - 6 else { continue }
            text(tick.label, NSPoint(x: x, y: ticksTop), font, .tertiaryLabelColor)
            lastRight = x + w
        }
        text("现在", NSPoint(x: nowX, y: ticksTop), font, .tertiaryLabelColor)
    }

    private func drawStats(_ visible: PowerHistory) {
        let items: [(String, Double?)] = [("平均", visible.average), ("峰值", visible.highest), ("最低", visible.lowest)]
        let column = contentWidth / CGFloat(items.count)
        for (index, item) in items.enumerated() {
            let x = Layout.leading + CGFloat(index) * column
            if index > 0 {
                let separator = NSBezierPath()
                separator.move(to: NSPoint(x: x.rounded() + 0.5, y: statsTop + 6))
                separator.line(to: NSPoint(x: x.rounded() + 0.5, y: statsTop + Layout.stats - 4))
                NSColor.separatorColor.setStroke()
                separator.lineWidth = 1
                separator.stroke()
            }
            let inset: CGFloat = index == 0 ? 0 : 10
            text(item.0, NSPoint(x: x + inset, y: statsTop + 4), .systemFont(ofSize: 10), .secondaryLabelColor)
            text(item.1.map(PowerMeter.wattsText) ?? "—", NSPoint(x: x + inset, y: statsTop + 16),
                 .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold), .labelColor)
        }
    }

    // MARK: 小工具

    static func color(for tone: PowerFlow.Tone) -> NSColor {
        switch tone {
        case .normal: return .labelColor
        case .charge: return .systemGreen
        case .discharge: return .systemOrange
        case .plugged: return .labelColor
        case .muted: return .tertiaryLabelColor
        }
    }

    private func text(_ string: String, _ point: NSPoint, _ font: NSFont, _ color: NSColor) {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
    }

    private func size(_ string: String, _ font: NSFont) -> NSSize {
        NSAttributedString(string: string, attributes: [.font: font]).size()
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor, pointSize: CGFloat) {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)
        guard let symbol = base?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)) else { return }
        let size = symbol.size
        let box = NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: size.width, height: size.height)
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
