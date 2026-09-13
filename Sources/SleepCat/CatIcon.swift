import AppKit

/// 程序化绘制的猫猫图标（模板图，自动适配深浅色菜单栏）
enum CatIcon {
    static let awake = make(awake: true)
    static let asleep = make(awake: false)

    private static func make(awake: Bool) -> NSImage {
        // 右上角要放 Zz 或 ！！，两种状态画布同宽，切换时图标不会左右跳
        let size = NSSize(width: 22, height: 18)
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

            // ── 右上角：睡着飘 Zz，喵住冒 ！！ ──
            ctx.compositingOperation = .sourceOver
            if awake {
                // 两个就好：三个在 18pt 高的菜单栏里挤成一团，最右边的还会出画布。
                // 右边那个更高，和 Zz 一样往右上方"冒"
                drawBang(x: 16.9, y: 7.4, height: 8.2)
                drawBang(x: 20.0, y: 8.9, height: 8.0)
            } else {
                drawZ("Z", at: NSPoint(x: 15.6, y: 9.0), fontSize: 7)
                drawZ("z", at: NSPoint(x: 19.0, y: 13.6), fontSize: 5)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 一个「！」：上粗下细的竖条 + 圆点，略微右倾
    private static func drawBang(x: CGFloat, y: CGFloat, height: CGFloat) {
        let w: CGFloat = 1.8
        let dot: CGFloat = 1.6
        let gap: CGFloat = 0.9
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: x, yBy: y)
        t.rotate(byDegrees: -8)
        t.concat()

        NSBezierPath(ovalIn: NSRect(x: -dot / 2, y: 0, width: dot, height: dot)).fill()

        let base = dot + gap
        let top = height - w / 2
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: w / 2, y: top))
        bar.appendArc(withCenter: NSPoint(x: 0, y: top), radius: w / 2, startAngle: 0, endAngle: 180)
        bar.line(to: NSPoint(x: -w * 0.26, y: base))
        bar.line(to: NSPoint(x: w * 0.26, y: base))
        bar.close()
        bar.fill()
        NSGraphicsContext.restoreGraphicsState()
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
