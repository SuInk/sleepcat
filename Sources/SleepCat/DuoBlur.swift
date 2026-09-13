import AppKit

/// 决定这一刻该不该出模糊：**只在盖子正在动的时候出现，停下就消失**。
///
/// 模糊是给"本地的人亲眼看着自己合盖"的过程效果。盖子一旦停住，冻住的毛玻璃对谁都
/// 没用，还会挡住远程控制或外接键鼠的人——而这些场景里盖子恰恰是不动的。
/// 所以用"盖子在不在动"来判断，比猜"是不是有人在远程"可靠得多。
///
/// 同类实现（macTilt、MacBookDuo、MacBookUno）都只看角度、停在半路会一直糊着；
/// 这里刻意不同。
struct BlurGate {
    static let closedAngle = 8.0            // 合死：本地什么都看不见，覆盖层只剩副作用
    static let motionEpsilon = 1.5          // 传感器精度是整度，抖一度不算在动
    static let settleDelay: TimeInterval = 1.0   // 合盖时手顿一下很正常，别一顿就闪没

    private var anchorAngle: Double?
    private var lastMotion = Date.distantPast

    mutating func update(angle: Double, now: Date) {
        guard let anchor = anchorAngle else {
            anchorAngle = angle   // 第一次读数只当基准：启动时盖子本来就停着
            return
        }
        if abs(angle - anchor) >= Self.motionEpsilon {
            anchorAngle = angle
            lastMotion = now
        }
    }

    func shouldShow(angle: Double, now: Date) -> Bool {
        angle > Self.closedAngle && now.timeIntervalSince(lastMotion) < Self.settleDelay
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
        let now = Date()
        gate.update(angle: angle, now: now)

        // 合死了：立刻撤掉，本地已经看不见，留着只会挡住远程画面
        guard angle > BlurGate.closedAngle else {
            hideNow()
            return
        }

        // 停下了就目标归零，下面的平滑跟随会让它柔和地淡出
        let target = gate.shouldShow(angle: angle, now: now) ? CGFloat(Self.progress(forAngle: angle)) : 0
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
