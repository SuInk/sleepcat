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

/// 功耗子菜单顶部的概览块：当前读数、统计、曲线、今天用电合在一行里自绘，
/// 左边界和下面那些带图标的操作行对齐，不再是三段各自为政的文字
final class PowerSummaryView: NSView {
    private let current: String
    private let stats: String?
    private let chart: NSImage?
    private let footnote: String?

    /// 和 MenuRow 的图标列对齐
    private static let leading: CGFloat = 30
    private static let trailing: CGFloat = 20

    init(current: String, stats: String?, chart: NSImage?, footnote: String?) {
        self.current = current
        self.stats = stats
        self.chart = chart
        self.footnote = footnote
        super.init(frame: .zero)
        let chartHeight = chart?.size.height ?? 0
        // 宽度按最宽的那行算，不然统计那行会被截掉
        func textWidth(_ text: String?, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
            guard let text else { return 0 }
            return ceil(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
            ]).size().width)
        }
        let widest = max(textWidth(current, size: 15, weight: .semibold),
                         textWidth(stats, size: 11),
                         textWidth(footnote, size: 11),
                         chart?.size.width ?? 0)
        let width = max(widest + Self.leading + Self.trailing, 260)
        var height: CGFloat = 26                                  // 当前读数
        if stats != nil { height += 16 }
        if chart != nil { height += chartHeight + 8 }
        if footnote != nil { height += 16 }
        setFrameSize(NSSize(width: width, height: height + 8))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        var y = bounds.maxY - 22
        draw(current, at: NSPoint(x: Self.leading, y: y),
             font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor)
        if let stats {
            y -= 16
            draw(stats, at: NSPoint(x: Self.leading, y: y), font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        }
        if let chart {
            y -= chart.size.height + 6
            chart.draw(in: NSRect(x: Self.leading, y: y, width: chart.size.width, height: chart.size.height))
        }
        if let footnote {
            y -= 16
            draw(footnote, at: NSPoint(x: Self.leading, y: y), font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        }
    }

    private func draw(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
    }

    /// 调试：把概览块画成 PNG，检查对齐和字号
    static func renderPreview(toDirectory dir: String) {
        let history = PowerHistory.preview(hours: 6)
        for (name, appearance) in [("power-summary", NSAppearance(named: .aqua)),
                                   ("power-summary-dark", NSAppearance(named: .darkAqua))] {
            NSAppearance.current = appearance
            let view = PowerSummaryView(
                current: "当前 12.5 W",
                stats: PowerMeter.statsText(history).map { "近 \(PowerHistory.spanText(history.span))　\($0)" },
                chart: PowerChart.image(for: history),
                footnote: "本次喵住 1.6 Wh · 今天记录 12.4 Wh")
            view.appearance = appearance
            // 菜单里是半透明底，这里垫一层菜单底色，不然浅色文字在透明底上看不见
            let canvas = BackdropView(frame: view.bounds)
            canvas.appearance = appearance
            canvas.addSubview(view)
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { continue }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
