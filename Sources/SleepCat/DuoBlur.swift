// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// Duo 合盖模糊：铰链角度传感器驱动的全屏渐变模糊（iPhone Duo 折叠时的液态玻璃效果）。
/// 盖子合到 100° 开始起雾，40° 模糊拉满；重新打开则反向消散。
final class DuoBlur {
    private let sensor: LidAngleSensor
    private var window: NSWindow?
    private var timer: Timer?
    private var currentAlpha: CGFloat = 0

    init?(sensor: LidAngleSensor?) {
        guard let sensor else { return nil }
        self.sensor = sensor
    }

    /// 角度 → 模糊进度（0 全清晰，1 全模糊）。纯函数，便于测试。
    static func progress(forAngle angle: Double) -> Double {
        let open = 100.0, closed = 40.0
        return min(1, max(0, (open - angle) / (open - closed)))
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        currentAlpha = 0
        window?.orderOut(nil)
    }

    // MARK: - 驱动

    private func tick() {
        guard let angle = sensor.angle() else { return }
        let target = CGFloat(Self.progress(forAngle: angle))
        currentAlpha += (target - currentAlpha) * 0.45  // 平滑跟随，避免传感器抖动
        if target == 0 && currentAlpha < 0.02 {
            currentAlpha = 0
            window?.orderOut(nil)
            return
        }
        if window == nil { window = makeWindow() }
        if let w = window {
            if !w.isVisible { w.orderFrontRegardless() }
            w.alphaValue = currentAlpha
        }
    }

    // MARK: - 覆盖层

    private func makeWindow() -> NSWindow? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
            return nil
        }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))  // 盖住一切，包括菜单栏
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.alphaValue = 0

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]

        let dim = NSView(frame: blur.bounds)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        dim.autoresizingMask = [.width, .height]
        blur.addSubview(dim)

        let catSize = NSSize(width: 110, height: 90)
        let cat = NSImageView(frame: NSRect(x: blur.bounds.midX - catSize.width / 2,
                                            y: blur.bounds.midY - catSize.height / 2,
                                            width: catSize.width, height: catSize.height))
        cat.image = CatIcon.asleep
        cat.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        cat.imageScaling = .scaleProportionallyUpOrDown
        cat.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        blur.addSubview(cat)

        w.contentView = blur
        return w
    }
}
