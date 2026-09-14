// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 应用图标：和菜单栏同一只「轻巧一点的小黑猫」（设计稿 CONCEPT 03），
/// 奶白底、奶白眼睛、ω 嘴、粉腮红，右上角冒 ！！。菜单栏是单色模板图画不了腮红，这里补上。
/// 按 macOS 图标网格在 1024 画布上绘制，构建时导出成 .iconset 再转 .icns。
enum AppIcon {
    static let ink = NSColor(red: 0.11, green: 0.10, blue: 0.12, alpha: 1)
    static let cream = NSColor(red: 1.00, green: 0.97, blue: 0.90, alpha: 1)
    static let blush = NSColor(red: 0.95, green: 0.62, blue: 0.62, alpha: 1)

    /// 在 1024×1024 坐标系里绘制（原点左下），调用方负责缩放
    static func draw() {
        // macOS 图标主体：824 的圆角方块，四周留 100 给投影
        let body = NSRect(x: 100, y: 100, width: 824, height: 824)
        let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowBlurRadius = 26
        shadow.set()
        cream.setFill()
        squircle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        // 很淡的暖色渐变，比纯色多一点质感，又不抢猫的戏
        NSGradient(starting: NSColor(red: 1.00, green: 0.99, blue: 0.96, alpha: 1),
                   ending: NSColor(red: 0.96, green: 0.93, blue: 0.87, alpha: 1))?
            .draw(in: body, angle: -90)
        drawCat()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawCat() {
        // 猫头用菜单栏图标的设计坐标（110×90）画，放大后居中。
        // 头 + ！！ 整体约占 x 1…106、y 2…87，以它的中心对准图标中心略偏下
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        let scale: CGFloat = 5.6
        t.translateX(by: 512 - 53.5 * scale, yBy: 490 - 44.5 * scale)
        t.scale(by: scale)
        t.concat()

        ink.setFill()
        CatIcon.drawHead()

        // 腮红：眼睛外下方，设计稿里在头宽的 15% / 86% 处
        blush.setFill()
        for cx: CGFloat in [12.8, 67.2] {
            NSBezierPath(ovalIn: NSRect(x: cx - 4.6, y: 16.2, width: 9.2, height: 5.8)).fill()
        }

        cream.setFill()
        CatIcon.awakeEyeRects.forEach { NSBezierPath(ovalIn: $0).fill() }
        cream.setStroke()
        CatIcon.mouthPath().stroke()

        // 右上角的 ！！：和菜单栏图标同一套位置（它们用 22×18 坐标，放大 5 倍对齐设计坐标）
        ink.setFill()
        let bangs = NSAffineTransform()
        bangs.scale(by: 5)
        bangs.concat()
        CatIcon.drawBang(x: 17.6, y: 9.4, height: 6.6)
        CatIcon.drawBang(x: 20.3, y: 10.9, height: 7.0)

        NSGraphicsContext.restoreGraphicsState()
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
