// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 决定这一轮合盖该不该出模糊。
///
/// 模糊只是给"本地的人亲眼看着自己合盖"准备的。一旦有人在用这台 Mac——远程连进来、
/// 或者外接键鼠——覆盖层就只会挡住他的屏幕（远程那边会看到一块黑屏）。
/// 进程名单靠不住（远程软件平时就常驻后台），所以看行为：
/// **合盖动作开始之后还有键鼠输入**，就不是本地在合盖。
struct BlurGate {
    static let openAngle = 100.0     // 高于此视为开着，新一轮重新判定
    static let closedAngle = 8.0     // 低于此视为合死：本地什么都看不见，覆盖层只剩副作用
    static let regainDrop = 15.0     // 被压制后盖子又明显往下合，说明确实是本地在合

    private(set) var suppressed = false
    private var closingSince: Date?
    private var suppressedAt: Double?

    /// - Parameters:
    ///   - lastInput: 最近一次键鼠输入的时刻（远程注入的事件同样算）
    mutating func update(angle: Double, lastInput: Date, now: Date) {
        if angle >= Self.openAngle {
            self = BlurGate()
            return
        }
        if closingSince == nil { closingSince = now }

        if suppressed, let at = suppressedAt, angle < at - Self.regainDrop {
            suppressed = false
            suppressedAt = nil
            closingSince = now   // 之前的输入不再算数
        }
        // 留 0.5 秒余量：合盖前最后一下触控板不该算
        if !suppressed, let since = closingSince, lastInput > since.addingTimeInterval(0.5) {
            suppressed = true
            suppressedAt = angle
        }
    }

    func shouldShow(angle: Double) -> Bool {
        !suppressed && angle > Self.closedAngle
    }
}

/// Duo 合盖模糊：铰链角度传感器驱动的全屏渐变模糊（iPhone Duo 折叠时的液态玻璃效果）。
/// 盖子合到 100° 开始起雾，40° 模糊拉满；重新打开则反向消散。只出现在内建屏幕上。
final class DuoBlur {
    private let sensor: LidAngleSensor
    private var window: NSWindow?
    private var timer: Timer?
    private var currentAlpha: CGFloat = 0
    private var voidLayer: CALayer?   // 暗场：越接近合死越黑
    private var cursorHidden = false
    private var gate = BlurGate()

    /// 最近一次任意键鼠输入的时刻（kCGAnyInputEventType = ~0）
    private static func lastInputDate() -> Date {
        let anyInput = CGEventType(rawValue: ~0)!
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return Date().addingTimeInterval(-seconds)
    }

    /// 光标由窗口服务器画在所有窗口之上，覆盖层盖不住它，只能显式隐藏。
    /// 起雾初期还留着（用户可能正在操作），糊到一半以后才收走。
    static func shouldHideCursor(progress: Double) -> Bool { progress > 0.5 }

    /// 分层模糊的遮罩区间（单位坐标，0=屏幕底部即铰链侧，1=顶部）。
    /// 层层叠加，越靠顶部经过的模糊层越多 → 渐进模糊，而不是一片均匀糊。
    static let blurBands: [(start: Double, end: Double)] = [
        (0.00, 0.35), (0.30, 0.60), (0.55, 0.80), (0.75, 1.00),
    ]

    /// 某个高度上叠加了几层模糊（0…层数），用于验证渐进曲线
    static func blurDepth(atHeight y: Double) -> Double {
        blurBands.reduce(0) { depth, band in
            let t = (y - band.start) / (band.end - band.start)
            return depth + min(1, max(0, t))
        }
    }

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
        setCursorHidden(false)
        window?.orderOut(nil)
    }

    deinit { setCursorHidden(false) }   // 绝不能把用户的光标弄丢

    /// 隐藏是计数式的，必须严格成对，否则光标再也回不来
    private func setCursorHidden(_ hide: Bool) {
        guard hide != cursorHidden else { return }
        if hide {
            CGDisplayHideCursor(CGMainDisplayID())
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
        }
        cursorHidden = hide
    }

    // MARK: - 驱动

    private func tick() {
        guard let angle = sensor.angle() else { return }
        gate.update(angle: angle, lastInput: Self.lastInputDate(), now: Date())

        // 合死了或者有人在用：立刻撤掉，不做淡出——淡出过程远程那边是看得见的
        guard gate.shouldShow(angle: angle) else {
            hideNow()
            return
        }

        let target = CGFloat(Self.progress(forAngle: angle))
        currentAlpha += (target - currentAlpha) * 0.45  // 平滑跟随，避免传感器抖动
        if target == 0 && currentAlpha < 0.02 {
            hideNow()
            return
        }
        setCursorHidden(Self.shouldHideCursor(progress: Double(currentAlpha)))
        if window == nil { window = makeWindow() }
        if let w = window {
            if !w.isVisible { w.orderFrontRegardless() }
            w.alphaValue = currentAlpha
            // 暗场比模糊来得晚、收得急：接近合死时才真正滑入黑暗
            CATransaction.begin()
            CATransaction.setDisableActions(true)   // 关掉隐式动画，跟手
            voidLayer?.opacity = Float(currentAlpha * currentAlpha)
            CATransaction.commit()
        }
    }

    /// 撤掉覆盖层并释放窗口：下次出现时重新绑定当前的内建屏幕（显示器可能插拔过）
    private func hideNow() {
        currentAlpha = 0
        setCursorHidden(false)
        window?.orderOut(nil)
        window = nil
        voidLayer = nil
    }

    // MARK: - 覆盖层

    /// 只认内建屏幕。外接显示器合盖模式下内建屏不在列表里，这时就不该出任何覆盖层
    private static var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let id = screen.deviceDescription[key] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    private func makeWindow() -> NSWindow? {
        guard let screen = Self.builtInScreen else { return nil }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))  // 盖住一切，包括菜单栏
        // 尽量不进屏幕共享 / 录屏。新系统上 ScreenCaptureKit 未必遵守，所以只作兜底
        w.sharingType = .none
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.alphaValue = 0

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]

        // 渐进模糊：多层毛玻璃，各自用渐变遮罩，越靠屏幕上方（离铰链越远）叠得越厚。
        // 合盖时视觉上是从上往下扫过来结霜，而不是整屏一起糊。
        for band in Self.blurBands {
            let blur = NSVisualEffectView(frame: root.bounds)
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]

            let mask = CAGradientLayer()
            mask.frame = root.bounds
            mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
            mask.locations = [NSNumber(value: band.start), NSNumber(value: band.end)]
            mask.startPoint = CGPoint(x: 0.5, y: 0)   // 底部＝铰链侧
            mask.endPoint = CGPoint(x: 0.5, y: 1)     // 顶部
            blur.layer?.mask = mask
            root.addSubview(blur)
        }

        // 暗场：顶部先暗下去，随合盖加深，最后整屏滑入黑暗
        let void = CAGradientLayer()
        void.frame = root.bounds
        void.colors = [
            NSColor.black.withAlphaComponent(0.10).cgColor,
            NSColor.black.withAlphaComponent(0.95).cgColor,
        ]
        void.locations = [0.15, 1.0]
        void.startPoint = CGPoint(x: 0.5, y: 0)
        void.endPoint = CGPoint(x: 0.5, y: 1)
        void.opacity = 0
        root.layer?.addSublayer(void)
        voidLayer = void

        w.contentView = root
        return w
    }
}
