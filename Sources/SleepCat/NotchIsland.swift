// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// Duo 岛：把 MacBook 刘海当灵动岛用（iPhone Duo 的形态连续感）。
/// 平时完全隐身贴在刘海上；鼠标移过去或喵住状态变化时，
/// 流畅展开成黑色胶囊，显示猫猫状态与剩余时间；点按直接切换喵住。
final class NotchIsland: NSObject {
    struct Status {
        let active: Bool
        let title: String
        let detail: String
        /// 实时整机功耗，读不到就不显示
        var watts: Double? = nil
    }

    var statusProvider: (() -> Status)?
    var onToggle: (() -> Void)?

    private var panel: NSPanel?
    private var islandView: IslandView?
    private var pollTimer: Timer?
    private var expanded = false
    private var keepUntil = Date.distantPast   // 展开状态至少维持到这个时刻
    private var tick = 0

    var isRunning: Bool { panel != nil }

    // MARK: - 几何

    /// 优先挑有刘海的屏幕
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// 收起态：贴住刘海的隐形热区（无刘海的屏幕退化为顶部中央一条）
    private var collapsedFrame: NSRect {
        guard let s = screen else { return .zero }
        let inset = s.safeAreaInsets.top
        var width: CGFloat = 220
        if inset > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            width = s.frame.width - l.width - r.width + 24  // 刘海宽度 + 两侧一点余量
        }
        let height = max(inset, 26)
        return NSRect(x: s.frame.midX - width / 2, y: s.frame.maxY - height,
                      width: width, height: height)
    }

    /// 展开态：刘海下方的胶囊
    private var expandedFrame: NSRect {
        guard let s = screen else { return .zero }
        let size = NSSize(width: 404, height: 84)   // 右边留出功耗读数的位置
        return NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: - 生命周期

    func start() {
        guard panel == nil, screen != nil else { return }
        let p = NSPanel(contentRect: collapsedFrame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true   // 收起时不拦截任何点击
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let v = IslandView(frame: NSRect(origin: .zero, size: collapsedFrame.size))
        v.island = self
        v.alphaValue = 0
        p.contentView = v
        p.orderFrontRegardless()

        panel = p
        islandView = v
        refresh()

        // 轮询鼠标位置驱动展开/收起（全局事件监听在部分系统上不可靠，轮询最稳）
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        panel?.orderOut(nil)
        panel = nil
        islandView = nil
        expanded = false
    }

    /// 状态变化时探出来晃一下（iPhone 灵动岛的活动通知感）
    func peek() {
        guard panel != nil else { return }
        keepUntil = Date().addingTimeInterval(2.2)
        expandIfNeeded()
    }

    func refresh() {
        guard let v = islandView, let status = statusProvider?() else { return }
        v.apply(status)
    }

    fileprivate func handleClick() {
        onToggle?()
        keepUntil = Date().addingTimeInterval(1.6)
        refresh()
    }

    // MARK: - 展开 / 收起

    private func poll() {
        guard panel != nil else { return }
        let mouse = NSEvent.mouseLocation
        let zone = expanded ? expandedFrame.insetBy(dx: -8, dy: -8) : collapsedFrame
        if zone.contains(mouse) {
            keepUntil = max(keepUntil, Date().addingTimeInterval(0.35))
            expandIfNeeded()
        } else if expanded, Date() > keepUntil {
            collapse()
        }
        tick += 1
        if expanded, tick % 10 == 0 { refresh() }  // 展开时每秒刷新倒计时
    }

    private func expandIfNeeded() {
        guard let p = panel, let v = islandView, !expanded else { return }
        expanded = true
        refresh()
        p.ignoresMouseEvents = false
        p.hasShadow = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            p.animator().setFrame(expandedFrame, display: true)
            v.animator().alphaValue = 1
        }
    }

    private func collapse() {
        guard let p = panel, let v = islandView, expanded else { return }
        expanded = false
        p.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(self.collapsedFrame, display: true)
            v.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.expanded else { return }
            self.panel?.hasShadow = false
        })
    }
}

extension NotchIsland {
    /// 调试用：把展开态的岛离屏渲染成 PNG（2x）
    static func renderPreview(toDirectory dir: String) {
        let size = NSSize(width: 404, height: 84)
        let samples: [(String, Status)] = [
            ("island-active", Status(active: true, title: "喵住中", detail: "还剩 1 小时 59 分 · 点按停止", watts: 12.5)),
            ("island-idle", Status(active: false, title: "打盹中", detail: "Mac 可正常休眠 · 点按喵住", watts: 4.3)),
        ]
        for (name, status) in samples {
            let v = IslandView(frame: NSRect(origin: .zero, size: size))
            v.alphaValue = 1
            v.apply(status)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.contentView = v
            v.needsLayout = true
            v.layoutSubtreeIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
    }
}

// MARK: - 岛本体视图

private final class IslandView: NSView {
    weak var island: NotchIsland?

    private let capsule = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let powerIcon = NSImageView()
    private let powerLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = NSColor.black.cgColor
        capsule.layer?.cornerRadius = 20
        capsule.layer?.cornerCurve = .continuous
        // 只圆下面两个角，上沿和刘海无缝相接
        capsule.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(capsule)

        iconView.contentTintColor = .white  // 模板猫图标染白，贴合灵动岛黑底
        iconView.imageScaling = .scaleProportionallyUpOrDown
        capsule.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        capsule.addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        detailLabel.lineBreakMode = .byTruncatingTail
        capsule.addSubview(detailLabel)

        // 右侧的实时功耗：等宽数字，跳动时宽度不变，不会左右抖
        powerIcon.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "功耗")
        powerIcon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        powerIcon.contentTintColor = NSColor.white.withAlphaComponent(0.65)
        capsule.addSubview(powerIcon)

        powerLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        powerLabel.textColor = .white
        powerLabel.alignment = .right
        capsule.addSubview(powerLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ status: NotchIsland.Status) {
        iconView.image = status.active ? CatIcon.awake : CatIcon.asleep
        titleLabel.stringValue = status.title
        detailLabel.stringValue = status.detail
        powerLabel.stringValue = status.watts.map { PowerMeter.wattsText($0) } ?? ""
        powerIcon.isHidden = status.watts == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        capsule.frame = bounds
        let iconSize = NSSize(width: 36, height: 30)
        iconView.frame = NSRect(x: 24, y: bounds.midY - iconSize.height / 2 - 2,
                                width: iconSize.width, height: iconSize.height)
        // 右侧功耗：读数右对齐，闪电贴在读数左边
        let powerWidth: CGFloat = powerLabel.stringValue.isEmpty ? 0 : 76
        powerLabel.frame = NSRect(x: bounds.width - 22 - powerWidth, y: bounds.midY - 13,
                                  width: powerWidth, height: 22)
        let boltSize: CGFloat = 12
        let textWidth = powerLabel.attributedStringValue.size().width
        powerIcon.frame = NSRect(x: powerLabel.frame.maxX - textWidth - boltSize - 4, y: bounds.midY - 8,
                                 width: boltSize, height: boltSize + 2)

        let textX = iconView.frame.maxX + 14
        let textRight = powerWidth > 0 ? powerIcon.frame.minX - 10 : bounds.width - 16
        titleLabel.frame = NSRect(x: textX, y: bounds.midY, width: textRight - textX, height: 18)
        detailLabel.frame = NSRect(x: textX, y: bounds.midY - 17, width: textRight - textX, height: 15)
    }

    override func mouseDown(with event: NSEvent) {
        island?.handleClick()
    }
}
