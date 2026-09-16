// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 可以连着点的菜单行。
///
/// 标准的 NSMenuItem 点一下菜单就关了，想连开三个设置得开三次菜单。
/// 自绘的视图能吃掉这次点击，菜单留在原地，勾当场更新。
/// 只用在开关和单选行上：带子菜单的行还是用标准菜单项，不然子菜单展不开。
final class MenuRow: NSView {
    /// 和标准菜单行对齐用的几个位置（点）
    private enum Metrics {
        static let height: CGFloat = 22
        static let check: CGFloat = 12      // 勾的左边缘
        static let icon: CGFloat = 30       // 图标的左边缘
        static let title: CGFloat = 54      // 文字的左边缘
        static let trailing: CGFloat = 20
    }

    private let symbol: NSImage?
    private let titleProvider: () -> String
    private let isOnProvider: () -> Bool
    private let action: () -> Void
    private var hovering = false

    init(symbol: NSImage?,
         title: @escaping @autoclosure () -> String,
         isOn: @escaping () -> Bool,
         action: @escaping () -> Void) {
        self.symbol = symbol
        self.titleProvider = title
        self.isOnProvider = isOn
        self.action = action
        // 宽度按文字算，菜单自己会取最宽的一行，不会因为这几行变形
        let text = NSAttributedString(string: title(), attributes: [.font: NSFont.menuFont(ofSize: 0)])
        let width = Metrics.title + ceil(text.size().width) + Metrics.trailing
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.height))
        // 宽度只是「至少这么宽」；菜单会把带弹性宽度的视图拉到整行，
        // 不然悬停高亮只盖到文字末尾，和系统那几行对不齐
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { nil }

    /// 同一个菜单里的其他行也跟着刷新（单选组切换时，别的行要取消勾选）
    static func refreshSiblings(of menu: NSMenu?) {
        menu?.items.compactMap { $0.view as? MenuRow }.forEach { $0.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let title = titleProvider()
        let highlighted = hovering && isEnabledInMenu

        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        let ink = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor

        if isOnProvider() {
            NSAttributedString(string: "✓", attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: ink,
            ]).draw(at: NSPoint(x: Metrics.check, y: 3))
        }
        if let symbol {
            let box = NSRect(x: Metrics.icon, y: (bounds.height - symbol.size.height) / 2,
                             width: symbol.size.width, height: symbol.size.height)
            // 模板图要在透明底上染色，直接在这里 sourceAtop 会把整块涂掉
            NSImage(size: box.size, flipped: false) { rect in
                symbol.draw(in: rect)
                ink.set()
                rect.fill(using: .sourceAtop)
                return true
            }.draw(in: box)
        }
        NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: ink,
        ]).draw(at: NSPoint(x: Metrics.title, y: 3))
    }

    private var isEnabledInMenu: Bool { enclosingMenuItem?.isEnabled ?? true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    /// 关键的一行：处理完不调用 cancelTracking，菜单就留在原地
    override func mouseUp(with event: NSEvent) {
        guard isEnabledInMenu else { return }
        action()
        needsDisplay = true
        Self.refreshSiblings(of: enclosingMenuItem?.menu)
    }

}

/// 预览用：给概览块垫一层菜单底色
private final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

/// 功耗子菜单的概览块：当前读数、跨度切换、统计、曲线、时间刻度合成一块自绘。
/// 数据每次绘制时现取，所以在菜单里切换跨度，曲线当场重画，不用关掉菜单再开
final class PowerSummaryView: NSView {
    private let historyProvider: () -> PowerHistory
    private let wattsProvider: () -> Double?

    /// 和 MenuRow 的图标列对齐
    private static let leading: CGFloat = 30
    private static let trailing: CGFloat = 20
    private static let headerHeight: CGFloat = 26
    private static let statsHeight: CGFloat = 16
    private static let ticksHeight: CGFloat = 13

    private lazy var spanControl: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: PowerSpan.options.map(\.label),
                                         trackingMode: .selectOne, target: self, action: #selector(spanChanged))
        control.segmentStyle = .rounded
        control.controlSize = .mini
        control.font = .systemFont(ofSize: 10)
        control.selectedSegment = PowerSpan.options.firstIndex { $0.seconds == PowerSpan.current } ?? 0
        return control
    }()

    init(history: @escaping () -> PowerHistory, watts: @escaping () -> Double?) {
        historyProvider = history
        wattsProvider = watts
        super.init(frame: .zero)
        // 宽度按最长的统计行估：峰值三位数时也放得下
        let sample = "近 24 小时　平均 188.8 W · 峰值 188.8 W · 最低 188.8 W"
        let statsWidth = ceil(NSAttributedString(string: sample, attributes: [.font: NSFont.systemFont(ofSize: 11)])
            .size().width)
        let width = max(statsWidth, PowerChart.size.width) + Self.leading + Self.trailing
        let height = Self.headerHeight + Self.statsHeight + PowerChart.size.height + 8 + Self.ticksHeight + 8
        setFrameSize(NSSize(width: width, height: height))
        autoresizingMask = [.width]
        addSubview(spanControl)
    }

    required init?(coder: NSCoder) { nil }

    private var contentWidth: CGFloat { bounds.width - Self.leading - Self.trailing }

    override func layout() {
        super.layout()
        // 跨度切换和「当前」读数同一行，右边缘对齐曲线的右边缘
        let size = spanControl.intrinsicContentSize
        spanControl.frame = NSRect(x: Self.leading + PowerChart.size.width - size.width,
                                   y: bounds.maxY - 21, width: size.width, height: size.height)
    }

    @objc private func spanChanged() {
        PowerSpan.current = PowerSpan.options[spanControl.selectedSegment].seconds
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let visible = historyProvider().limited(to: PowerSpan.current)
        var y = bounds.maxY - 22
        let current = wattsProvider().map { "当前 \(PowerMeter.wattsText($0))" } ?? "当前读不到"
        draw(current, at: NSPoint(x: Self.leading, y: y), font: .systemFont(ofSize: 15, weight: .semibold),
             color: .labelColor)

        y -= Self.statsHeight
        let stats = PowerMeter.statsText(visible).map { "近 \(PowerHistory.spanText(visible.span))　\($0)" }
            ?? "还在采样，攒够一分钟就有曲线了"
        draw(stats, at: NSPoint(x: Self.leading, y: y), font: .systemFont(ofSize: 11), color: .secondaryLabelColor)

        y -= PowerChart.size.height + 6
        let box = NSRect(x: Self.leading, y: y, width: PowerChart.size.width, height: PowerChart.size.height)
        if let chart = PowerChart.image(for: visible) {
            chart.draw(in: box)
        } else {
            let frame = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.separatorColor.setStroke()
            frame.stroke()
        }

        // 横轴：整点时间刻度，最右边是「现在」。标签居中对准刻度，挨太近的跳过
        y -= Self.ticksHeight
        let font = NSFont.systemFont(ofSize: 9)
        func width(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        let nowX = box.maxX - width("现在")
        var lastRight = -CGFloat.infinity
        for tick in PowerAxis.relativeTicks(for: visible, maxTicks: 6) {
            let w = width(tick.label)
            let x = min(max(box.minX + box.width * tick.position - w / 2, box.minX), box.maxX - w)
            guard x > lastRight + 6, x + w < nowX - 6 else { continue }
            draw(tick.label, at: NSPoint(x: x, y: y), font: font, color: .tertiaryLabelColor)
            lastRight = x + w
        }
        draw("现在", at: NSPoint(x: nowX, y: y), font: font, color: .tertiaryLabelColor)
    }

    private func draw(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
    }

    /// 调试：把概览块画成 PNG，检查对齐和字号。-previewHours 1 / 6 / 24 调跨度
    static func renderPreview(toDirectory dir: String) {
        let hours = UserDefaults.standard.double(forKey: "previewHours")
        let history = PowerHistory.preview(hours: hours > 0 ? hours : 6)
        for (name, appearance) in [("power-summary", NSAppearance(named: .aqua)),
                                   ("power-summary-dark", NSAppearance(named: .darkAqua))] {
            NSAppearance.current = appearance
            let view = PowerSummaryView(history: { history }, watts: { 12.5 })
            view.appearance = appearance
            // 菜单里是半透明底，这里垫一层菜单底色，不然浅色文字在透明底上看不见
            let canvas = BackdropView(frame: view.bounds)
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
