// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import QuartzCore
import ScreenCaptureKit

/// 折叠渲染：把内建屏幕实时截下来，按 FoldGeometry 的透视重新投影，
/// 再叠渐进模糊和压暗，画进覆盖窗口的 Metal 层。
///
/// 画面看起来停在原地，物理屏幕从画面里转过去——这是和「就地糊一层」最大的区别。
/// 需要屏幕录制权限；没有权限时由 DuoBlur 退回原来的毛玻璃。
final class ScreenFold: NSObject, SCStreamOutput {
    /// 远边最大模糊半径（点）
    static let maxBlurRadius: Double = 120

    let layer = CAMetalLayer()

    private let device = MTLCreateSystemDefaultDevice()
    private var commandQueue: MTLCommandQueue?
    private var context: CIContext?
    private var stream: SCStream?
    private let frameQueue = DispatchQueue(label: "cn.suink.sleepcat.fold")
    private var latestFrame: CIImage?
    private let frameLock = NSLock()

    override init() {
        super.init()
        guard let device else { return }
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        commandQueue = device.makeCommandQueue()
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false,
                                                          .workingColorSpace: NSNull()])
    }

    var isAvailable: Bool { device != nil }
    var isRunning: Bool { stream != nil }

    // MARK: 截屏

    /// 有没有屏幕录制权限。没授权时系统会在这里弹一次授权请求
    static func checkPermission(_ done: @escaping (Bool) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            DispatchQueue.main.async { done(content != nil) }
        }
    }

    /// 开始捕获内建屏幕。`excluding` 是我们自己的覆盖窗口，必须排除掉，否则会自己拍自己
    func start(display: CGDirectDisplayID, excluding overlay: NSWindow?, done: @escaping (Bool) -> Void) {
        guard stream == nil, isAvailable else { done(stream != nil); return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            guard let content, let scDisplay = content.displays.first(where: { $0.displayID == display }) else {
                LidBlocker.log("折叠：拿不到屏幕内容（\(error?.localizedDescription ?? "没有屏幕录制权限")）")
                DispatchQueue.main.async { done(false) }
                return
            }
            let mine = content.windows.filter { window in
                window.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                    || (overlay.map { Int($0.windowNumber) == Int(window.windowID) } ?? false)
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: mine)
            let config = SCStreamConfiguration()
            config.width = scDisplay.width * 2      // Retina：按物理像素抓，缩放后才不糊
            config.height = scDisplay.height * 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 3
            config.showsCursor = false               // 光标我们自己会藏，抓进来会跟着一起变形
            config.pixelFormat = kCVPixelFormatType_32BGRA
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.frameQueue)
                stream.startCapture { error in
                    if let error {
                        LidBlocker.log("折叠：开始捕获失败 \(error.localizedDescription)")
                        DispatchQueue.main.async { done(false) }
                    } else {
                        LidBlocker.log("合盖折叠：开始抓屏（录屏指示灯会亮，折完就撤）")
                        DispatchQueue.main.async { self.stream = stream; done(true) }
                    }
                }
            } catch {
                LidBlocker.log("折叠：装不上输出 \(error.localizedDescription)")
                DispatchQueue.main.async { done(false) }
            }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        frameLock.lock()
        latestFrame = nil
        frameLock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvImageBuffer: buffer)
        frameLock.lock()
        latestFrame = image
        frameLock.unlock()
    }

    // MARK: 渲染

    /// 画一帧。`angle` 是平滑后的铰链角度，`size` 是屏幕的像素尺寸
    @discardableResult
    func render(angle: Double, pixelSize: CGSize, scale: CGFloat) -> Bool {
        frameLock.lock()
        let frame = latestFrame
        frameLock.unlock()
        guard let frame, let context, let queue = commandQueue else { return false }

        let image = Self.compose(picture: frame, angle: angle, pixelSize: pixelSize, scale: scale)
        layer.drawableSize = pixelSize
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return false }
        context.render(image,
                       to: drawable.texture,
                       commandBuffer: buffer,
                       bounds: CGRect(origin: .zero, size: pixelSize),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        buffer.present(drawable)
        buffer.commit()
        return true
    }

    /// 调试：不截屏，用合成图跑 N 帧，量一帧要多久。返回每帧毫秒数
    static func benchmark(frames: Int, pixelSize: CGSize, scale: CGFloat) -> Double? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false,
                                                             .workingColorSpace: NSNull()])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(pixelSize.width), height: Int(pixelSize.height), mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        // 拿一张有细节的图当桌面：纯色图会被优化掉，量不准
        let checker = CIFilter.checkerboardGenerator()
        checker.width = 64
        checker.color0 = CIColor(red: 0.16, green: 0.2, blue: 0.3)
        checker.color1 = CIColor(red: 0.9, green: 0.85, blue: 0.7)
        let picture = (checker.outputImage ?? CIImage(color: .gray))
            .cropped(to: CGRect(origin: .zero, size: pixelSize))

        let start = Date()
        for i in 0..<frames {
            let angle = FoldGeometry.startAngle * (1 - Double(i) / Double(max(1, frames - 1)))
            let image = compose(picture: picture, angle: angle, pixelSize: pixelSize, scale: scale)
            guard let buffer = queue.makeCommandBuffer() else { return nil }
            context.render(image, to: texture, commandBuffer: buffer,
                           bounds: CGRect(origin: .zero, size: pixelSize),
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        return Date().timeIntervalSince(start) / Double(frames) * 1000
    }

    /// 一帧的完整效果：重投影 → 渐进模糊 → 压暗 → 垫黑底。
    /// 拆成静态函数，跑基准测试时不用真的去截屏
    static func compose(picture: CIImage, angle: Double, pixelSize: CGSize, scale: CGFloat) -> CIImage {
        let bounds = CGRect(origin: .zero, size: pixelSize)
        let progress = FoldGeometry.progress(forAngle: angle)
        let source = picture.transformed(by: fitTransform(from: picture.extent, to: bounds))

        let blurred = progressiveBlur(source, progress: progress, bounds: bounds, scale: scale)
        let dimmed = dim(blurred, progress: progress, bounds: bounds)
        let projected = reproject(dimmed, angle: angle, bounds: bounds)
        let black = CIImage(color: .black).cropped(to: bounds)
        return projected.composited(over: black).cropped(to: bounds)
    }

    /// 抓下来的画面和屏幕像素尺寸未必一致（缩放分辨率、多显示器），拉到刚好铺满
    private static func fitTransform(from extent: CGRect, to bounds: CGRect) -> CGAffineTransform {
        guard extent.width > 0, extent.height > 0 else { return .identity }
        return CGAffineTransform(scaleX: bounds.width / extent.width, y: bounds.height / extent.height)
            .concatenating(CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    /// 渐进模糊：铰链边保持清晰，越往远边越糊。
    /// 用「清晰 / 半糊 / 全糊」三级按遮罩混合来近似连续半径，比逐像素变半径便宜得多
    private static func progressiveBlur(_ image: CIImage, progress: Double,
                                        bounds: CGRect, scale: CGFloat) -> CIImage {
        let strength = FoldGeometry.blurStrength(progress: progress)
        guard strength > 0.001 else { return image }
        let radius = Self.maxBlurRadius * strength * Double(scale)
        guard radius > 0.5 else { return image }

        let mid = blur(image, radius: radius * 0.35, bounds: bounds)
        // 全糊那层在半糊的基础上再糊：高斯叠高斯等于更大的高斯，比从原图重算便宜
        let far = blur(mid, radius: sqrt(max(0, radius * radius - pow(radius * 0.35, 2))), bounds: bounds)
        // 下半程先混到半糊，上半程再混到全糊，衔接处正好接上
        let lower = gradientMask(bounds: bounds, gamma: 1.35, from: 0.0, to: 0.55, strength: 1)
        let upper = gradientMask(bounds: bounds, gamma: 1.35, from: 0.45, to: 1.0, strength: 1)
        let step1 = blend(foreground: mid, background: image, mask: lower)
        return blend(foreground: far, background: step1, mask: upper)
    }

    /// 大半径高斯很贵：先缩小再糊，出来的结果反正也是糊的，肉眼看不出差别
    private static func blur(_ image: CIImage, radius: Double, bounds: CGRect) -> CIImage {
        let factor = max(1.0, radius / 8)
        let small = image
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / factor, y: 1 / factor))
        let blurred = small.applyingGaussianBlur(sigma: radius / factor / 2)
        return blurred
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            .cropped(to: bounds)
    }

    private static func blend(foreground: CIImage, background: CIImage, mask: CIImage) -> CIImage {
        let f = CIFilter.blendWithMask()
        f.inputImage = foreground
        f.backgroundImage = background
        f.maskImage = mask
        return f.outputImage ?? background
    }

    /// 遮罩和渐变每帧都一样，按尺寸缓存；不缓存的话光生成就吃掉好几毫秒
    private static var cache: [String: CIImage] = [:]
    private static let cacheLock = NSLock()

    private static func cached(_ key: String, _ make: () -> CIImage) -> CIImage {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cache[key] { return hit }
        let image = make()
        if cache.count > 8 { cache.removeAll() }   // 换了分辨率就重来
        cache[key] = image
        return image
    }

    /// 从铰链边到远边的灰度渐变，再用 gamma 掰成 g^1.35 那条曲线
    private static func gradientMask(bounds: CGRect, gamma: Double,
                                     from: Double, to: Double, strength: Double) -> CIImage {
        cached("mask-\(bounds.size)-\(gamma)-\(from)-\(to)-\(strength)") {
            makeGradientMask(bounds: bounds, gamma: gamma, from: from, to: to, strength: strength)
        }
    }

    private static func makeGradientMask(bounds: CGRect, gamma: Double,
                                         from: Double, to: Double, strength: Double) -> CIImage {
        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = CGPoint(x: 0, y: bounds.height * from)
        gradient.point1 = CGPoint(x: 0, y: bounds.height * to)
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let base = (gradient.outputImage ?? CIImage(color: .white)).cropped(to: bounds)
        let shaped = CIFilter.gammaAdjust()
        shaped.inputImage = base
        shaped.power = Float(gamma)
        let output = shaped.outputImage ?? base
        guard strength < 0.999 else { return output }
        let scaled = CIFilter.colorMatrix()
        scaled.inputImage = output
        scaled.rVector = CIVector(x: CGFloat(strength), y: 0, z: 0, w: 0)
        scaled.gVector = CIVector(x: 0, y: CGFloat(strength), z: 0, w: 0)
        scaled.bVector = CIVector(x: 0, y: 0, z: CGFloat(strength), w: 0)
        return scaled.outputImage ?? output
    }

    /// 压暗：远边先黑下去，铰链附近几乎不动
    private static func dim(_ image: CIImage, progress: Double, bounds: CGRect) -> CIImage {
        let strength = FoldGeometry.dimStrength(progress: progress)
        guard strength > 0.001 else { return image }
        let shade = cached("dim-\(bounds.size)") {
            let gradient = CIFilter.smoothLinearGradient()
            gradient.point0 = CGPoint(x: 0, y: bounds.height * FoldGeometry.dimStart)
            gradient.point1 = CGPoint(x: 0, y: bounds.height)
            gradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(FoldGeometry.maxDim))
            return (gradient.outputImage ?? CIImage.empty()).cropped(to: bounds)
        }
        let faded = CIFilter.colorMatrix()
        faded.inputImage = shade
        faded.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(strength))
        return (faded.outputImage ?? shade).composited(over: image)
    }

    /// 透视重投影：把画面四角挪到 FoldGeometry 算出来的位置
    private static func reproject(_ image: CIImage, angle: Double, bounds: CGRect) -> CIImage {
        let corners = FoldGeometry.projectedCorners(width: Double(bounds.width),
                                                    height: Double(bounds.height),
                                                    angle: angle)
        let f = CIFilter.perspectiveTransform()
        f.inputImage = image
        f.bottomLeft = CGPoint(x: corners[0].x, y: corners[0].y)
        f.bottomRight = CGPoint(x: corners[1].x, y: corners[1].y)
        f.topLeft = CGPoint(x: corners[2].x, y: corners[2].y)
        f.topRight = CGPoint(x: corners[3].x, y: corners[3].y)
        return f.outputImage ?? image
    }
}
