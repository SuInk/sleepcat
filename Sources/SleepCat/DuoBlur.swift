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

/// Duo 合盖模糊：铰链角度传感器驱动的全屏渐进毛玻璃（iPhone Duo 折叠时的液态玻璃效果）。
/// 盖子合到 100° 开始起雾，40° 模糊拉满；重新打开则反向消散。只出现在内建屏幕上。
///
/// 毛玻璃分三层叠出来，都是实时合成的，底下的画面在动，玻璃后面也跟着动：
/// 1. 模糊：每层一个高斯模糊的背景滤镜，半径跟着角度连续变化（不是靠整体透明度淡入淡出）
/// 2. 白釉 + 高光：磨砂玻璃的乳白感和斜向反光
/// 3. 细颗粒：磨砂面的微观纹理，纯色大面积才不会显得像塑料
final class DuoBlur {
    private let sensor: LidAngleSensor
    private var window: NSWindow?
    private var timer: Timer?
    private var currentProgress: Double = 0
    private var lastTick = Date()
    private var bands: [(layer: CALayer, fallback: NSVisualEffectView)] = []
    private var frostLayer: CALayer?         // 白釉 + 高光
    private var voidLayer: CALayer?   // 暗场：越接近合死越黑
    private var cursorHidden = false
    private var screenWatched = false
    private var lastWatchCheck = Date.distantPast
    private let fold = ScreenFold()          // 首选：实时截屏 + 透视重投影
    private var foldPermission = false       // 没有屏幕录制权限就退回下面的毛玻璃
    private var spring = AngleSpring(value: 130)

    /// 光标由窗口服务器画在所有窗口之上，覆盖层盖不住它，只能显式隐藏。
    /// 起雾初期还留着（用户可能正在操作），糊到一半以后才收走。
    static func shouldHideCursor(progress: Double) -> Bool { progress > 0.5 }

    /// 分层模糊的遮罩区间（单位坐标，0=屏幕底部即铰链侧，1=顶部）。
    /// 层层叠加，越靠顶部经过的模糊层越多 → 渐进模糊，而不是一片均匀糊。
    static let blurBands: [(start: Double, end: Double)] = [
        (0.00, 0.35), (0.30, 0.60), (0.55, 0.80), (0.75, 1.00),
    ]

    /// 单层最大模糊半径（点）。四层叠起来顶部约 60，接近系统「毛玻璃」材质的观感
    static let maxBlurRadius: Double = 16

    /// 这一刻某一层该用多大的模糊半径：越接近合死越糊，全开时为 0（滤镜整个关掉）
    static func blurRadius(progress: Double, band: Int) -> Double {
        guard progress > 0 else { return 0 }
        // 靠上的层（band 序号大，遮罩更靠屏幕顶部）先起雾，配合遮罩做出「从上往下结霜」
        let head = Double(blurBands.count - 1 - band) * 0.12
        let t = min(1, max(0, (progress - head) / (1 - head)))
        return t * maxBlurRadius
    }

    /// 白釉浓度：磨砂玻璃的乳白感，比模糊来得稍晚
    static func frostOpacity(progress: Double) -> Double { min(1, max(0, progress * progress * 0.85)) }

    /// 传感器轮询间隔：盖子没动时慢慢看着，一开始合就切到 60 帧跟手
    static func pollInterval(progress: Double, angle: Double) -> TimeInterval {
        progress > 0 || angle < 110 ? 1.0 / 60 : 0.1
    }

    /// 平滑跟随（按时间算，帧率变了跟随速度不变）。time constant 约 60 毫秒
    static func smoothed(current: Double, target: Double, dt: TimeInterval) -> Double {
        let k = 1 - exp(-max(0, dt) / 0.06)
        return current + (target - current) * k
    }

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

    /// 有没有拿到屏幕录制权限。没有就只能用毛玻璃，菜单里给个去授权的入口
    var needsScreenRecording: Bool { !foldPermission }

    /// 打开「系统设置 → 隐私与安全性 → 屏幕录制」
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 让系统弹一次授权请求（用户点菜单里的「开启…」时用）
    func requestScreenRecording() {
        ScreenFold.checkPermission { [weak self] granted in
            self?.foldPermission = granted
            if !granted { Self.openScreenRecordingSettings() }
        }
    }

    func start() {
        guard timer == nil else { return }
        ScreenFold.checkPermission { [weak self] granted in
            self?.foldPermission = granted
            LidBlocker.log(granted ? "合盖折叠：有屏幕录制权限，用实时重投影"
                                   : "合盖折叠：没有屏幕录制权限，退回毛玻璃")
        }
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
        fold.stop()
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

        // 半秒查一次就够：远程连上到画面传过去本来就有延迟。
        // 自己在抓屏时不查：我们自己就会被算成「有人在看屏幕」，查了会把自己关掉
        let now = Date()
        if !fold.isRunning, now.timeIntervalSince(lastWatchCheck) >= 0.5 {
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
        let raw = FoldGeometry.progress(forAngle: angle)
        if raw <= 0, currentProgress <= 0 { spring.reset(to: angle) } else { spring.step(target: angle, dt: dt) }
        currentProgress = FoldGeometry.progress(forAngle: spring.value)

        // 盖子不动时不用一直 60 帧跑着
        let wanted = Self.pollInterval(progress: currentProgress, angle: angle)
        if let timer, abs(timer.timeInterval - wanted) > 0.001 { schedule(interval: wanted) }

        // 预热：快到起始角度就开始抓屏，真折下去第一帧就有画面，不会闪一下黑
        if foldPermission, !fold.isRunning, angle <= FoldGeometry.startAngle + 12 { startFold() }

        if raw == 0 && currentProgress < 0.01 {
            hideNow()
            return
        }
        setCursorHidden(Self.shouldHideCursor(progress: currentProgress))
        if window == nil { window = makeWindow() }
        guard let w = window else { return }
        let drawn = renderFrame(angle: spring.value)
        // 第一帧还没到之前别把窗口放出来，否则是一块黑屏
        if drawn, !w.isVisible { w.orderFrontRegardless() }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// 开始抓屏。必须先有覆盖窗口，才能把它从捕获里排除掉（否则自己拍自己，套娃）
    private func startFold() {
        guard let screen = Self.builtInScreen, let display = Self.displayID(of: screen) else { return }
        if window == nil { window = makeWindow() }
        fold.start(display: display, excluding: window) { [weak self] ok in
            guard let self else { return }
            if !ok {
                self.foldPermission = false   // 权限没了或者被拒，这一轮就用毛玻璃
                self.rebuildWindowForFallback()
            }
        }
    }

    /// 权限掉了：把 Metal 那块窗口换成毛玻璃那套
    private func rebuildWindowForFallback() {
        let wasVisible = window?.isVisible ?? false
        window?.orderOut(nil)
        window = nil
        bands = []
        frostLayer = nil
        voidLayer = nil
        guard wasVisible, let w = makeWindow() else { return }
        window = w
        w.orderFrontRegardless()
    }

    /// 画一帧：优先走实时重投影，没有画面时退回毛玻璃。返回这一帧有没有真的画上去
    @discardableResult
    private func renderFrame(angle: Double) -> Bool {
        if fold.isRunning, let screen = Self.builtInScreen {
            let scale = screen.backingScaleFactor
            let size = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
            if fold.render(angle: angle, pixelSize: size, scale: scale) { return true }
            return false   // 流刚起来还没出帧
        }
        render(progress: FoldGeometry.progress(forAngle: angle))
        return true
    }

    /// 把这一刻的进度画出来。模糊半径每帧现算，底下画面在动时玻璃后面跟着动
    private func render(progress: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // 关掉隐式动画，跟手
        for (i, band) in bands.enumerated() {
            let radius = Self.blurRadius(progress: progress, band: i)
            if radius <= 0.01 {
                band.layer.backgroundFilters = []
            } else if let blur = CIFilter(name: "CIGaussianBlur",
                                          parameters: [kCIInputRadiusKey: radius]) {
                band.layer.backgroundFilters = [blur]
            }
            // 兜底层跟着一起淡入，否则刚一合盖就突然糊上一层
            band.fallback.alphaValue = radius / Self.maxBlurRadius * 0.5 / Double(Self.blurBands.count)
        }
        frostLayer?.opacity = Float(Self.frostOpacity(progress: progress))
        // 暗场比模糊来得晚、收得急：接近合死时才真正滑入黑暗
        voidLayer?.opacity = Float(progress * progress)
        CATransaction.commit()
    }

    /// 撤掉覆盖层并释放窗口：下次出现时重新绑定当前的内建屏幕（显示器可能插拔过）
    private func hideNow() {
        fold.stop()
        currentProgress = 0
        setCursorHidden(false)
        window?.orderOut(nil)
        window = nil
        voidLayer = nil
        frostLayer = nil
        bands = []
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

    /// 演示的公共部分：有权限就先把抓屏开起来，再按给定的角度曲线逐帧画
    private func runDemo(seconds: TimeInterval, angle: @escaping (TimeInterval) -> Double) {
        ScreenFold.checkPermission { [weak self] granted in
            guard let self else { return }
            self.foldPermission = granted
            print(granted ? "有屏幕录制权限：实时重投影" : "没有屏幕录制权限：退回毛玻璃（在系统设置里授权后效果更好）")
            guard let w = self.window ?? self.makeWindow() else { exit(1) }
            self.window = w
            if granted { self.startFold() }
            let start = Date()
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(start)
                guard elapsed < seconds else {
                    timer.invalidate(); self.hideNow(); exit(0)
                }
                if self.renderFrame(angle: angle(elapsed)), !w.isVisible { w.orderFrontRegardless() }
            }
            RunLoop.main.add(t, forMode: .common)
        }
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

    /// 磨砂颗粒：生成一小块噪点，用图案色平铺，避免整屏噪点图占内存
    static func grainPattern(tile: Int = 128) -> CGColor? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: tile, pixelsHigh: tile,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let pixels = rep.bitmapData else { return nil }
        var generator = SystemRandomNumberGenerator()
        for i in stride(from: 0, to: tile * tile * 4, by: 4) {
            let v = UInt8.random(in: 140...255, using: &generator)
            pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
            pixels[i + 3] = UInt8.random(in: 0...90, using: &generator)
        }
        let image = NSImage(size: NSSize(width: tile, height: tile))
        image.addRepresentation(rep)
        return NSColor(patternImage: image).cgColor
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

        // 有屏幕录制权限：整块交给实时重投影的 Metal 层，下面那套毛玻璃就不建了
        if foldPermission, fold.isAvailable {
            fold.layer.frame = root.bounds
            fold.layer.contentsScale = screen.backingScaleFactor
            root.layer?.addSublayer(fold.layer)
            w.contentView = root
            return w
        }

        // 渐进毛玻璃：每层一个高斯背景滤镜 + 渐变遮罩，越靠屏幕上方（离铰链越远）叠得越厚。
        // 背景滤镜作用在窗口后面的画面上，由系统每帧合成，所以底下的画面在动，玻璃后面也在动。
        // 每层里再垫一个系统的毛玻璃视图：背景滤镜万一在某些机器上不生效，至少还有它撑住。
        bands = []
        for band in Self.blurBands {
            let layerView = NSView(frame: root.bounds)
            layerView.wantsLayer = true
            layerView.autoresizingMask = [.width, .height]
            guard let layer = layerView.layer else { continue }

            let mask = CAGradientLayer()
            mask.frame = root.bounds
            mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
            mask.locations = [NSNumber(value: band.start), NSNumber(value: band.end)]
            mask.startPoint = CGPoint(x: 0.5, y: 0)   // 底部＝铰链侧
            mask.endPoint = CGPoint(x: 0.5, y: 1)     // 顶部
            layer.mask = mask

            let fallback = NSVisualEffectView(frame: root.bounds)
            fallback.material = .hudWindow
            fallback.blendingMode = .behindWindow
            fallback.state = .active
            fallback.alphaValue = 0
            fallback.autoresizingMask = [.width, .height]
            layerView.addSubview(fallback)

            root.addSubview(layerView)
            bands.append((layer, fallback))
        }

        // 白釉 + 斜向高光 + 磨砂颗粒：这三样合起来才像玻璃，不然只是一片糊
        let frost = CALayer()
        frost.frame = root.bounds
        frost.opacity = 0

        let milk = CAGradientLayer()
        milk.frame = root.bounds
        milk.colors = [
            NSColor.white.withAlphaComponent(0.34).cgColor,
            NSColor.white.withAlphaComponent(0.16).cgColor,
        ]
        milk.startPoint = CGPoint(x: 0.5, y: 1)
        milk.endPoint = CGPoint(x: 0.5, y: 0)
        frost.addSublayer(milk)

        let sheen = CAGradientLayer()
        sheen.frame = root.bounds
        sheen.colors = [
            NSColor.white.withAlphaComponent(0.22).cgColor,
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.10).cgColor,
        ]
        sheen.locations = [0, 0.45, 1]
        sheen.startPoint = CGPoint(x: 0, y: 1)    // 左上打光
        sheen.endPoint = CGPoint(x: 1, y: 0)
        frost.addSublayer(sheen)

        if let grain = Self.grainPattern() {
            let noise = CALayer()
            noise.frame = root.bounds
            noise.backgroundColor = grain
            noise.opacity = 0.05
            frost.addSublayer(noise)
        }
        root.layer?.addSublayer(frost)
        frostLayer = frost

        w.contentView = root
        return w
    }
}
