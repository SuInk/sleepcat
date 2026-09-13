import AppKit

/// 菜单栏猫猫图标：「软乎乎的小黑猫」（设计稿 CONCEPT 02）。
/// 模板图——五官是挖空的透明洞，透出菜单栏底色：浅色模式是黑猫白五官，
/// 深色模式系统自动反成白猫深五官，和设计稿「缩小也可爱」那栏一致。
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
            drawBody()
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
                drawZ(x: 17.0, y: 8.4, width: 3.0, height: 3.0, stroke: 1.35)
                drawZ(x: 19.6, y: 13.3, width: 1.8, height: 2.0, stroke: 1.05)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 趴着的年糕身子 + 圆头耳朵 + 底下探出来的两只小爪子（设计坐标 110×90，y 向上）
    private static func drawBody() {
        // 宽扁的年糕：椭圆撑出鼓鼓的两颊，宽圆角矩形把头顶压得又宽又平
        NSBezierPath(ovalIn: NSRect(x: 2, y: 3, width: 80, height: 44)).fill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 14, width: 68, height: 36), xRadius: 20, yRadius: 20).fill()

        // 耳朵长在头顶两角，短而圆；两耳之间留出宽宽的头顶。
        // 三角形再用粗圆角描一圈，耳尖就是圆的；左耳更圆、右耳稍尖稍高，和设计稿一样
        let ears: [(pts: [NSPoint], round: CGFloat)] = [
            ([NSPoint(x: 7, y: 36), NSPoint(x: 9, y: 61), NSPoint(x: 31, y: 50)], 9),
            ([NSPoint(x: 76, y: 36), NSPoint(x: 75, y: 63), NSPoint(x: 53, y: 50)], 6),
        ]
        for ear in ears {
            let p = NSBezierPath()
            p.move(to: ear.pts[0])
            p.line(to: ear.pts[1])
            p.line(to: ear.pts[2])
            p.close()
            p.lineJoinStyle = .round
            p.lineWidth = ear.round
            p.fill()
            p.stroke()
        }

        // 小爪子
        NSBezierPath(ovalIn: NSRect(x: 15, y: 0.5, width: 20, height: 11)).fill()
        NSBezierPath(ovalIn: NSRect(x: 49, y: 0.5, width: 20, height: 11)).fill()
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
        let eyes: [CGFloat] = [27, 57]

        if awake {
            // 大圆眼睛
            for cx in eyes {
                NSBezierPath(ovalIn: NSRect(x: cx - 6.2, y: 25, width: 12.4, height: 12.4)).fill()
            }
            // ω 嘴：两个连着的小 U
            stroked(3.2) { m in
                m.move(to: NSPoint(x: 35.5, y: 26.5))
                m.curve(to: NSPoint(x: 42, y: 25), controlPoint1: NSPoint(x: 35.5, y: 20.5),
                        controlPoint2: NSPoint(x: 42, y: 20.5))
                m.curve(to: NSPoint(x: 48.5, y: 26.5), controlPoint1: NSPoint(x: 42, y: 20.5),
                        controlPoint2: NSPoint(x: 48.5, y: 20.5))
            }
        } else {
            // 闭着的 U 形眼睛
            for cx in eyes {
                stroked(3.4) { e in
                    e.move(to: NSPoint(x: cx - 6.5, y: 32))
                    e.curve(to: NSPoint(x: cx + 6.5, y: 32), controlPoint1: NSPoint(x: cx - 5, y: 25),
                            controlPoint2: NSPoint(x: cx + 5, y: 25))
                }
            }
            // 打呼的小圆圈嘴
            stroked(2.4) { o in
                o.appendOval(in: NSRect(x: 38.8, y: 19.8, width: 6.4, height: 6.4))
            }
        }

        // 爪子上沿的 ⌒ 分界线
        for cx: CGFloat in [25, 59] {
            stroked(2.6) { l in
                l.move(to: NSPoint(x: cx - 6, y: 7))
                l.curve(to: NSPoint(x: cx + 6, y: 7), controlPoint1: NSPoint(x: cx - 4, y: 12.5),
                        controlPoint2: NSPoint(x: cx + 4, y: 12.5))
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
