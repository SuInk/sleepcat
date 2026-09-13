import AppKit

/// 菜单栏猫猫下方弹一下的小提示，1.6 秒后淡出。
/// 点完菜单项菜单就收起了，复制成没成功用户看不到；用系统通知又要申请权限，太重。
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String, below button: NSStatusBarButton?) {
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        let textSize = label.intrinsicContentSize
        let size = NSSize(width: textSize.width + 36, height: 34)

        var origin = NSPoint.zero
        if let button, let window = button.window {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
            if let visible = window.screen?.visibleFrame {   // 猫猫靠右时别让提示出屏幕
                origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            }
        }

        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = size.height / 2
        glass.layer?.masksToBounds = true
        label.frame = NSRect(x: 18, y: (size.height - textSize.height) / 2,
                             width: size.width - 36, height: textSize.height)
        glass.addSubview(label)
        p.contentView = glass

        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard panel === p else { return }   // 期间又弹了新的，旧的已经被换掉
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                p.animator().alphaValue = 0
            }, completionHandler: {
                p.orderOut(nil)
                if panel === p { panel = nil }
            })
        }
    }
}
