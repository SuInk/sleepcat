// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 菜单栏猫猫图标：「轻巧一点的小黑猫」（设计稿 CONCEPT 03）——只有一颗头，没有身子和爪子。
/// 模板图——五官是挖空的透明洞，透出菜单栏底色：浅色模式是黑猫白五官，
/// 深色模式系统自动反成白猫深五官。
/// 腮红是彩色的，单色模板图画不出来，设计稿的小尺寸版本也没有。
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

            // 猫身在 110×90 的设计坐标里画（比 22×18 好调比例），缩小 5 倍
            NSGraphicsContext.saveGraphicsState()
            let scale = NSAffineTransform()
            scale.scale(by: 0.2)
            scale.concat()
            drawHead()
            ctx.compositingOperation = .destinationOut   // 下面画的都是挖空
            drawFace(awake: awake)
            NSGraphicsContext.restoreGraphicsState()

            // ── 右上角：精神喵冒 ！！，困困喵飘 Zz ──
            ctx.compositingOperation = .sourceOver
            if awake {
                // 两个就好：三个在 18pt 高的菜单栏里挤成一团。右边那个更高，往右上方"冒"
                drawBang(x: 17.6, y: 9.4, height: 6.6)
                drawBang(x: 20.3, y: 10.9, height: 7.0)
            } else {
                // 大 Z 在左下、小 z 在右上；和右耳之间留出空隙，不然会粘成一团
                drawZ(x: 17.3, y: 9.0, width: 3.0, height: 3.0, stroke: 1.35)
                drawZ(x: 19.8, y: 13.6, width: 1.7, height: 1.9, stroke: 1.05)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 一颗圆包子头 + 两只尖耳朵（设计坐标 110×90，y 向上）。
    /// 比例量自设计稿大图：头宽 : 头高 ≈ 1.27，最宽处在下半部分，底部圆润
    private static func drawHead() {
        // 最宽处压在下三分之一，从那里就开始往上收，才是圆包子而不是圆角方块
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 40, y: 2))
        head.curve(to: NSPoint(x: 79, y: 22), controlPoint1: NSPoint(x: 66, y: 2),
                   controlPoint2: NSPoint(x: 79, y: 9))                    // 右下鼓出来
        head.curve(to: NSPoint(x: 64, y: 54), controlPoint1: NSPoint(x: 79, y: 34),
                   controlPoint2: NSPoint(x: 71, y: 50))                   // 右侧往上收窄
        head.curve(to: NSPoint(x: 16, y: 54), controlPoint1: NSPoint(x: 54, y: 59),
                   controlPoint2: NSPoint(x: 26, y: 59))                   // 头顶微微隆起
        head.curve(to: NSPoint(x: 1, y: 22), controlPoint1: NSPoint(x: 9, y: 50),
                   controlPoint2: NSPoint(x: 1, y: 34))                    // 左侧
        head.curve(to: NSPoint(x: 40, y: 2), controlPoint1: NSPoint(x: 1, y: 9),
                   controlPoint2: NSPoint(x: 14, y: 2))                    // 左下鼓出来
        head.close()
        head.fill()

        // 耳朵：外沿顺着收窄的脸颊往上，内沿斜着落到头顶；三角形描粗圆角让耳尖变圆
        for pts in [[NSPoint(x: 7, y: 40), NSPoint(x: 11, y: 71), NSPoint(x: 30, y: 56)],
                    [NSPoint(x: 73, y: 40), NSPoint(x: 69, y: 71), NSPoint(x: 50, y: 56)]] {
            let ear = NSBezierPath()
            ear.move(to: pts[0])
            ear.line(to: pts[1])
            ear.line(to: pts[2])
            ear.close()
            ear.lineJoinStyle = .round
            ear.lineWidth = 7
            ear.fill()
            ear.stroke()
        }
    }

    /// 挖空的五官（调用前已切到 destinationOut）
    private static func drawFace(awake: Bool) {
        func stroked(_ width: CGFloat, _ build: (NSBezierPath) -> Void) {
            let p = NSBezierPath()
            p.lineWidth = width
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            build(p)
            p.stroke()
        }
        let eyes: [CGFloat] = [22, 58]   // 设计稿里眼睛在头宽的 26% / 76% 处

        if awake {
            // 大圆眼睛，略微竖长
            for cx in eyes {
                NSBezierPath(ovalIn: NSRect(x: cx - 6.2, y: 23, width: 12.4, height: 13.6)).fill()
            }
            // ω 嘴：两个连着的小 U，比上一版小一号
            stroked(3.0) { m in
                m.move(to: NSPoint(x: 34.5, y: 24.5))
                m.curve(to: NSPoint(x: 40, y: 23), controlPoint1: NSPoint(x: 34.5, y: 19),
                        controlPoint2: NSPoint(x: 40, y: 19))
                m.curve(to: NSPoint(x: 45.5, y: 24.5), controlPoint1: NSPoint(x: 40, y: 19),
                        controlPoint2: NSPoint(x: 45.5, y: 19))
            }
        } else {
            // 闭着的 U 形眼睛
            for cx in eyes {
                stroked(3.3) { e in
                    e.move(to: NSPoint(x: cx - 6.3, y: 31))
                    e.curve(to: NSPoint(x: cx + 6.3, y: 31), controlPoint1: NSPoint(x: cx - 4.8, y: 24.5),
                            controlPoint2: NSPoint(x: cx + 4.8, y: 24.5))
                }
            }
            // 打呼的小圆圈嘴
            stroked(2.4) { o in
                o.appendOval(in: NSRect(x: 36.8, y: 18, width: 6.4, height: 6.4))
            }
        }
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

    /// 一个 Z：圆头粗笔画一笔画成（字体打出来的 Z 太硬，也不好控制边界，小的会被裁掉）
    private static func drawZ(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, stroke: CGFloat) {
        let z = NSBezierPath()
        z.move(to: NSPoint(x: x, y: y + height))
        z.line(to: NSPoint(x: x + width, y: y + height))
        z.line(to: NSPoint(x: x, y: y))
        z.line(to: NSPoint(x: x + width, y: y))
        z.lineWidth = stroke
        z.lineCapStyle = .round
        z.lineJoinStyle = .round
        z.stroke()
    }

    /// 调试用：按真实尺寸（Retina 2x）把模板图标画在浅色 / 深色菜单栏上，
    /// 对照设计稿「缩小也可爱」那一栏，检查小尺寸下五官还分不分得清
    static func dumpMenuBarPreview(toDirectory dir: String) {
        let px: CGFloat = 2, zoom: CGFloat = 4
        let bars: [(String, NSColor, NSColor)] = [
            ("menubar-light", NSColor(white: 0.91, alpha: 1), .black),
            ("menubar-dark", NSColor(white: 0.22, alpha: 1), .white),
        ]
        for (name, bg, ink) in bars {
            let w = Int(64 * px), h = Int(22 * px)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            bg.setFill()
            NSRect(x: 0, y: 0, width: w, height: h).fill()
            for (i, icon) in [awake, asleep].enumerated() {
                // 模板图的用法：只取 alpha，染成菜单栏的前景色
                let tinted = NSImage(size: icon.size, flipped: false) { rect in
                    icon.draw(in: rect)
                    ink.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: (6 + CGFloat(i) * 30) * px, y: 2 * px,
                                       width: icon.size.width * px, height: icon.size.height * px))
            }
            NSGraphicsContext.restoreGraphicsState()
            // 按像素放大 4 倍输出，保留实际分辨率下的锯齿，方便肉眼判断
            let big = NSImage(size: NSSize(width: CGFloat(w) * zoom, height: CGFloat(h) * zoom))
            big.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .none
            rep.draw(in: NSRect(origin: .zero, size: big.size))
            big.unlockFocus()
            if let tiff = big.tiffRepresentation, let out = NSBitmapImageRep(data: tiff),
               let data = out.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
    }

    /// 调试用：把两个图标放大渲染成 PNG（白底黑图）
    static func dump(toDirectory dir: String) {
        dumpMenuBarPreview(toDirectory: dir)
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
