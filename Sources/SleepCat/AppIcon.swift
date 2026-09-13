// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 应用图标：深夜紫色天空里，一只睁着发光眼睛熬夜的白猫——"喵住不睡"。
/// 按 macOS 图标网格在 1024 画布上绘制，构建时导出成 .iconset 再转 .icns。
enum AppIcon {
    /// 在 1024×1024 坐标系里绘制（原点左下），调用方负责缩放
    static func draw() {
        // macOS 图标主体：824 的圆角方块，四周留 100 给投影
        let body = NSRect(x: 100, y: 100, width: 824, height: 824)
        let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.shadowBlurRadius = 28
        shadow.set()
        NSColor(red: 0.16, green: 0.17, blue: 0.43, alpha: 1).setFill()
        squircle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()

        // 夜空渐变：顶部深靛蓝 → 底部紫罗兰
        NSGradient(starting: NSColor(red: 0.13, green: 0.15, blue: 0.40, alpha: 1),
                   ending: NSColor(red: 0.47, green: 0.28, blue: 0.68, alpha: 1))?
            .draw(in: body, angle: -90)

        drawStars()
        drawMoon()
        drawCat()

        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawStars() {
        let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (190, 845, 7, 0.95), (325, 885, 4.5, 0.7), (405, 770, 3.5, 0.55),
            (585, 860, 5.5, 0.85), (880, 560, 4.5, 0.6), (165, 625, 3.5, 0.5),
            (500, 905, 3, 0.45),
        ]
        for (x, y, r, a) in stars {
            NSColor.white.withAlphaComponent(a).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
        }
    }

    private static func drawMoon() {
        NSGraphicsContext.saveGraphicsState()
        // 用"整张画布挖掉一个偏移圆"做裁剪，填出月牙
        let cut = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        cut.appendOval(in: NSRect(x: 774, y: 808, width: 104, height: 104))
        cut.windingRule = .evenOdd
        cut.addClip()
        NSColor(red: 1.0, green: 0.95, blue: 0.76, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 744, y: 784, width: 112, height: 112)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawCat() {
        // 整只猫下移，下巴被圆角轻轻裁掉，像从底边探出头；耳尖也让开月亮
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let shift = NSAffineTransform()
        shift.translateX(by: 0, yBy: -48)
        shift.concat()

        let fur = NSColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1)
        let pink = NSColor(red: 0.98, green: 0.62, blue: 0.70, alpha: 1)
        let ink = NSColor(red: 0.12, green: 0.10, blue: 0.24, alpha: 1)

        // 头 + 耳朵：猫从图标底边探出来
        fur.setFill()
        NSBezierPath(ovalIn: NSRect(x: 242, y: 130, width: 540, height: 490)).fill()
        for mirror in [false, true] {
            let ear = NSBezierPath()
            ear.move(to: pt(292, 470, mirror))
            ear.line(to: pt(268, 800, mirror))
            ear.line(to: pt(478, 628, mirror))
            ear.close()
            ear.fill()
        }

        // 耳朵内侧
        pink.withAlphaComponent(0.85).setFill()
        for mirror in [false, true] {
            let inner = NSBezierPath()
            inner.move(to: pt(318, 560, mirror))
            inner.line(to: pt(302, 735, mirror))
            inner.line(to: pt(430, 632, mirror))
            inner.close()
            inner.fill()
        }

        // 发光的眼睛：黄绿渐变 + 竖瞳 + 高光
        for cx: CGFloat in [392, 632] {
            let eye = NSBezierPath(ovalIn: NSRect(x: cx - 58, y: 335, width: 116, height: 130))
            NSGradient(starting: NSColor(red: 0.95, green: 0.93, blue: 0.45, alpha: 1),
                       ending: NSColor(red: 0.60, green: 0.84, blue: 0.30, alpha: 1))?
                .draw(in: eye, angle: -90)
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - 15, y: 348, width: 30, height: 104)).fill()
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: cx + 12, y: 418, width: 20, height: 20)).fill()
        }

        // 鼻子
        pink.setFill()
        let nose = NSBezierPath()
        nose.move(to: NSPoint(x: 486, y: 300))
        nose.line(to: NSPoint(x: 538, y: 300))
        nose.line(to: NSPoint(x: 512, y: 272))
        nose.close()
        nose.fill()

        // 嘴：小小的 ω
        ink.withAlphaComponent(0.75).setStroke()
        let mouth = NSBezierPath()
        mouth.lineWidth = 7
        mouth.lineCapStyle = .round
        mouth.move(to: NSPoint(x: 512, y: 272))
        mouth.curve(to: NSPoint(x: 468, y: 250), controlPoint1: NSPoint(x: 508, y: 240),
                    controlPoint2: NSPoint(x: 482, y: 236))
        mouth.move(to: NSPoint(x: 512, y: 272))
        mouth.curve(to: NSPoint(x: 556, y: 250), controlPoint1: NSPoint(x: 516, y: 240),
                    controlPoint2: NSPoint(x: 542, y: 236))
        mouth.stroke()

        // 胡须
        NSColor(red: 0.78, green: 0.76, blue: 0.84, alpha: 1).setStroke()
        for (dy, tilt) in [(CGFloat(0), CGFloat(18)), (-26, 0), (-52, -18)] {
            for mirror in [false, true] {
                let w = NSBezierPath()
                w.lineWidth = 5
                w.lineCapStyle = .round
                w.move(to: pt(420, 292 + dy, mirror))
                w.line(to: pt(262, 292 + dy + tilt, mirror))
                w.stroke()
            }
        }
    }

    /// 左右对称的点：mirror 时绕中线 x=512 翻转
    private static func pt(_ x: CGFloat, _ y: CGFloat, _ mirror: Bool) -> NSPoint {
        NSPoint(x: mirror ? 1024 - x : x, y: y)
    }

    // MARK: - 导出

    static func png(size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let scale = CGFloat(size) / 1024
        let t = NSAffineTransform()
        t.scale(by: scale)
        t.concat()
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// 生成 iconutil 需要的 .iconset 目录
    static func writeIconset(to dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try png(size: base * scale)?.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
            }
        }
    }
}
