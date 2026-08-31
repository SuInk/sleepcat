import AppKit

/// 程序化绘制的猫猫图标（模板图，自动适配深浅色菜单栏）
enum CatIcon {
    static let awake = make(awake: true)
    static let asleep = make(awake: false)

    private static func make(awake: Bool) -> NSImage {
        // 睡觉时右侧要飘 Zz，画布宽一点
        let size = NSSize(width: awake ? 18 : 22, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return true }
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // ── 剪影：头 + 两只耳朵（分开填充，避免绕向抵消出缺口）──
            NSBezierPath(ovalIn: NSRect(x: 3, y: 0.5, width: 12, height: 12)).fill()
            let leftEar = NSBezierPath()
            leftEar.move(to: NSPoint(x: 4.0, y: 9.8))
            leftEar.line(to: NSPoint(x: 3.4, y: 16.5))
            leftEar.line(to: NSPoint(x: 8.2, y: 12.2))
            leftEar.close()
            leftEar.fill()
            let rightEar = NSBezierPath()
            rightEar.move(to: NSPoint(x: 14.0, y: 9.8))
            rightEar.line(to: NSPoint(x: 14.6, y: 16.5))
            rightEar.line(to: NSPoint(x: 9.8, y: 12.2))
            rightEar.close()
            rightEar.fill()

            // ── 在剪影上"抠"出五官（destinationOut = 挖透明洞）──
            ctx.compositingOperation = .destinationOut

            if awake {
                // 睁开的圆眼睛
                NSBezierPath(ovalIn: NSRect(x: 5.0, y: 5.7, width: 2.5, height: 2.5)).fill()
                NSBezierPath(ovalIn: NSRect(x: 10.5, y: 5.7, width: 2.5, height: 2.5)).fill()
            } else {
                // 闭眼：两道下弯的弧线
                for xOffset: CGFloat in [0, 5.5] {
                    let eye = NSBezierPath()
                    eye.move(to: NSPoint(x: 5.0 + xOffset, y: 7.5))
                    eye.curve(to: NSPoint(x: 7.5 + xOffset, y: 7.5),
                              controlPoint1: NSPoint(x: 5.7 + xOffset, y: 6.0),
                              controlPoint2: NSPoint(x: 6.8 + xOffset, y: 6.0))
                    eye.lineWidth = 1.1
                    eye.lineCapStyle = .round
                    eye.stroke()
                }
            }

            // 小三角鼻子
            let nose = NSBezierPath()
            nose.move(to: NSPoint(x: 8.1, y: 4.4))
            nose.line(to: NSPoint(x: 9.9, y: 4.4))
            nose.line(to: NSPoint(x: 9.0, y: 3.2))
            nose.close()
            nose.fill()

            // ── 睡觉时头顶飘 Zz ──
            ctx.compositingOperation = .sourceOver
            if !awake {
                drawZ("Z", at: NSPoint(x: 15.6, y: 9.0), fontSize: 7)
                drawZ("z", at: NSPoint(x: 19.0, y: 13.6), fontSize: 5)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawZ(_ char: String, at point: NSPoint, fontSize: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: NSColor.black,
        ]
        (char as NSString).draw(at: point, withAttributes: attrs)
    }

    /// 调试用：把两个图标放大渲染成 PNG（白底黑图）
    static func dump(toDirectory dir: String) {
        for (name, image) in [("awake", awake), ("asleep", asleep)] {
            let scale: CGFloat = 8
            let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: w, height: h).fill()
            image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
    }
}
