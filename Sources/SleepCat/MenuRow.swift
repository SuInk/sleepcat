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
