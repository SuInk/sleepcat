// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 决定这一刻该不该出模糊：跟着角度走，停在半路保持模糊，合到底也不变回清晰。
///
/// 唯一让开的情况：屏幕正被持续监看（远程控制、屏幕共享、录屏）——
/// 覆盖层会盖住对方看到的画面。合着盖子远程也靠这一条，不需要再按角度判断。
enum BlurGate {
    static func shouldShow(screenWatched: Bool) -> Bool {
        !screenWatched
    }
}

/// Duo 合盖模糊：铰链角度传感器驱动的全屏渐进模糊。
/// 盖子合到 100° 开始起雾，40° 拉满；重新打开反向消散。只出现在内建屏幕上。
///
/// 渲染按 iPhone Duo 折叠的那套来，但不读屏幕内容、不要任何权限：
/// 1. 渐进模糊：铰链边始终清晰，越往远边越糊，半径按 g^1.35 涨（和 Duo 的曲线一致）
/// 2. 渐隐到黑：远边先暗下去，接近合死时整屏没入黑暗
/// 都是背景滤镜，由系统每帧合成，所以底下的画面在动，模糊后面也跟着动
final class DuoBlur {
    private let sensor: LidAngleSensor
    private var window: NSWindow?
    private var timer: Timer?
    private var currentProgress: Double = 0
    private var lastTick = Date()
    private var blurView: NSVisualEffectView?
    private var voidLayer: CALayer?   // 暗场：越接近合死越黑
    private var cursorHidden = false
    private var screenWatched = false
    private var lastWatchCheck = Date.distantPast
    private var lastAngle: Double?
    private var lastMotion = Date.distantPast
    private var spring = AngleSpring(value: 130)

    /// 光标由窗口服务器画在所有窗口之上，覆盖层盖不住它，只能显式隐藏。
    /// 起雾初期还留着（用户可能正在操作），糊到一半以后才收走。
    static func shouldHideCursor(progress: Double) -> Bool { progress > 0.5 }

    /// 整屏模糊的浓度（0…1）：跟着角度走，起步慢、后半程才真糊
    static func blurOpacity(progress: Double) -> Double {
        min(1, FoldGeometry.blurStrength(progress: progress) * 1.1)
    }

    /// 压暗程度（0…1）：比模糊来得早一点，接近合死时整屏沉下去
    static func dimOpacity(progress: Double) -> Double {
        FoldGeometry.dimStrength(progress: progress) * FoldGeometry.maxDim
    }

    /// 盖子多久没动就算停稳了
    static let idleTimeout: TimeInterval = 3

    /// 传感器轮询间隔：盖子没动时慢慢看着，一开始合就切到 60 帧跟手。
    /// 停稳了就降频——不然半开着放一下午，会一直按 60 帧空转
    static func pollInterval(progress: Double, angle: Double, stillFor: TimeInterval = 0) -> TimeInterval {
        if progress > 0 { return 1.0 / 60 }
        if stillFor > idleTimeout { return 0.1 }
        return angle < 110 ? 1.0 / 60 : 0.1
    }

    /// 平滑跟随（按时间算，帧率变了跟随速度不变）。time constant 约 60 毫秒
    static func smoothed(current: Double, target: Double, dt: TimeInterval) -> Double {
        let k = 1 - exp(-max(0, dt) / 0.06)
        return current + (target - current) * k
    }

    init?(sensor: LidAngleSensor?) {
        guard let sensor else { return nil }
        self.sensor = sensor
    }

    /// 角度 → 模糊进度（0 全清晰，1 全模糊）。100° 起雾，40° 拉满。纯函数，便于测试
    static func progress(forAngle angle: Double) -> Double {
        let closed = 40.0
        return min(1, max(0, (FoldGeometry.startAngle - angle) / (FoldGeometry.startAngle - closed)))
    }

    var isRunning: Bool { timer != nil }


    func start() {
        guard timer == nil else { return }
        schedule(interval: 0.1)
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval / 4
        RunLoop.main.add(t, forMode: .common)   // 菜单打开、拖窗口时也不能停
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        currentProgress = 0
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
        let now0 = Date()
        let dt = now0.timeIntervalSince(lastTick)
        lastTick = now0

        // 半秒查一次就够：远程连上到画面传过去本来就有延迟
        let now = Date()
        if now.timeIntervalSince(lastWatchCheck) >= 0.5 {
            lastWatchCheck = now
            let watched = ScreenWatch.isScreenWatched()
            if watched != screenWatched {
                screenWatched = watched
                LidBlocker.log(watched ? "屏幕开始被持续监看（远程 / 共享 / 录屏），合盖模糊让开"
                                       : "屏幕不再被监看，合盖模糊恢复")
            }
        }

        // 有人在看屏幕：立刻撤掉，不做淡出——淡出过程远程那边是看得见的
        guard BlurGate.shouldShow(screenWatched: screenWatched) else {
            hideNow()
            return
        }

        // 传感器给的是整度，用临界阻尼弹簧磨成连续值；没在折的时候直接跟上，免得下次从残值爬
        let raw = Self.progress(forAngle: angle)
        if raw <= 0, currentProgress <= 0 { spring.reset(to: angle) } else { spring.step(target: angle, dt: dt) }
        currentProgress = Self.progress(forAngle: spring.value)

        // 盖子停稳了就降频，别一直按 60 帧空转
        if let lastAngle, abs(angle - lastAngle) > 0.5 { lastMotion = now }
        if lastAngle == nil { lastMotion = now }
        lastAngle = angle
        let wanted = Self.pollInterval(progress: currentProgress, angle: angle,
                                       stillFor: now.timeIntervalSince(lastMotion))
        if let timer, abs(timer.timeInterval - wanted) > 0.001 { schedule(interval: wanted) }

        if raw == 0 && currentProgress < 0.01 {
            hideNow()
            return
        }
        setCursorHidden(Self.shouldHideCursor(progress: currentProgress))
        if window == nil { window = makeWindow() }
        guard let w = window else { return }
        render(progress: currentProgress)
        if !w.isVisible { w.orderFrontRegardless() }
    }

    /// 把这一刻的进度画出来：整屏一层毛玻璃 + 一层压暗，浓度跟着角度连续变化
    private func render(progress: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // 关掉隐式动画，跟手
        blurView?.alphaValue = Self.blurOpacity(progress: progress)
        voidLayer?.opacity = Float(Self.dimOpacity(progress: progress))
        CATransaction.commit()
    }

    /// 撤掉覆盖层并释放窗口：下次出现时重新绑定当前的内建屏幕（显示器可能插拔过）
    private func hideNow() {
        currentProgress = 0
        setCursorHidden(false)
        window?.orderOut(nil)
        window = nil
        voidLayer = nil
        blurView = nil
    }

    /// 调试：不接传感器，按给定进度显示若干秒（./SleepCat --blur-demo 0.6 8）
    func showDemo(progress: Double, seconds: TimeInterval) {
        let angle = FoldGeometry.startAngle * (1 - min(1, max(0, progress)))
        runDemo(seconds: seconds) { _ in angle }
    }

    /// 调试：模拟合盖，从全开扫到合死再扫回来（./SleepCat --blur-sweep）
    func showSweep(seconds: TimeInterval) {
        runDemo(seconds: seconds) { elapsed in
            let phase = elapsed / seconds * 2                    // 三角波：合上去再打开
            return FoldGeometry.startAngle * (1 - (phase <= 1 ? phase : 2 - phase))
        }
    }

    /// 演示的公共部分：按给定的角度曲线逐帧画
    private func runDemo(seconds: TimeInterval, angle: @escaping (TimeInterval) -> Double) {
        guard let w = window ?? makeWindow() else { exit(1) }
        window = w
        w.orderFrontRegardless()
        let start = Date()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(start)
            guard elapsed < seconds else {
                timer.invalidate(); self.hideNow(); exit(0)
            }
            self.render(progress: Self.progress(forAngle: angle(elapsed)))
        }
        RunLoop.main.add(t, forMode: .common)
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

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]

        // 整屏一层系统毛玻璃：真正把背后画面糊掉的就是它
        let blur = NSVisualEffectView(frame: root.bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.alphaValue = 0
        blur.autoresizingMask = [.width, .height]
        root.addSubview(blur)
        blurView = blur

        // 压暗：整屏一层黑，浓度跟着角度走
        let void = CALayer()
        void.frame = root.bounds
        void.backgroundColor = NSColor.black.cgColor
        void.opacity = 0
        root.layer?.addSublayer(void)
        voidLayer = void

        w.contentView = root
        return w
    }
}
