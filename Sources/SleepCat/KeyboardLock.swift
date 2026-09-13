// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit
import ApplicationServices

/// 清洁键盘：拦截所有键盘事件，屏幕中央浮一个面板，点按钮恢复。
///
/// 做法和同类项目（macos-keyboardblocker、ShinyMac）一样：会话级最前面插一个事件拦截，
/// 把按键、修饰键和 NX_SYSDEFINED（亮度 / 音量 / 媒体键）吞掉。需要辅助功能权限。
/// 另外补上它们漏掉的两点：系统停用拦截时立刻补回；确认拦截真的生效了才提示已锁定。
final class KeyboardLock: NSObject {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var panel: NSPanel?
    private(set) var isLocked = false

    /// 第 14 类是 NX_SYSDEFINED，功能键行的亮度、音量、播放控制都走它
    static let blockedMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) |
        (1 << CGEventType.keyUp.rawValue) |
        (1 << CGEventType.flagsChanged.rawValue) |
        (1 << 14)

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// 把应用登记进「辅助功能」列表并打开设置页
    static func requestPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 锁上键盘。成功返回 nil，失败返回原因——失败时绝不显示"已锁定"，
    /// 否则用户以为锁好了去擦键盘，会乱打一堆字。
    func lock() -> String? {
        guard !isLocked else { return nil }
        guard Self.hasPermission else { return "还没有辅助功能权限" }

        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.blockedMask,
            callback: { _, type, event, refcon in
                // 回调超时或特定输入会让系统停用拦截；不补回的话键盘会在清洁中途悄悄恢复
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon {
                        Unmanaged<KeyboardLock>.fromOpaque(refcon).takeUnretainedValue().reenable()
                    }
                    return Unmanaged.passUnretained(event)
                }
                return nil   // 吞掉
            },
            userInfo: me
        ) else {
            return "无法创建键盘拦截。如果刚更新过应用，请在「辅助功能」里把 SleepCat 关掉再重新打开"
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source

        guard CGEvent.tapIsEnabled(tap: tap) else {
            teardown()
            return "键盘拦截没能启用"
        }
        isLocked = true
        showPanel()
        return nil
    }

    func unlock() {
        guard isLocked else { return }
        teardown()
        panel?.orderOut(nil)
        panel = nil
        isLocked = false
    }

    fileprivate func reenable() {
        guard isLocked, let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func teardown() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    // MARK: - 面板

    private func showPanel() {
        let size = NSSize(width: 380, height: 268)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let origin = screen.map {
            NSPoint(x: $0.frame.midX - size.width / 2, y: $0.frame.midY - size.height / 2)
        } ?? .zero

        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .screenSaver   // 压在所有窗口之上，清洁时不会被别的窗口挡住
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = Self.makeContent(size: size, target: self, action: #selector(doneTapped))
        p.orderFrontRegardless()
        panel = p
    }

    @objc private func doneTapped() { unlock() }

    static func makeContent(size: NSSize, target: AnyObject?, action: Selector?) -> NSView {
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 22
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 44, weight: .regular))
        icon.contentTintColor = .labelColor

        let title = NSTextField(labelWithString: "键盘已禁用")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: "放心擦吧，所有按键都不会生效。\n清洁完点下面的按钮恢复。")
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.alignment = .center

        let note = NSTextField(labelWithString: "电源键和 Touch ID 是硬件级的，无法屏蔽，别按到")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        // 只有按钮能解锁：擦触控板时会产生点击，点面板任意处就解锁会误触
        let done = NSButton(title: "清洁完成，恢复键盘", target: target, action: action)
        done.bezelStyle = .push
        done.controlSize = .large
        done.bezelColor = .controlAccentColor   // 回车用不了，只能靠颜色把它标成主操作
        done.keyEquivalent = ""   // 键盘此时是禁用的，回车触发不了，也不该触发

        let stack = NSStackView(views: [icon, title, body, note, done])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(18, after: note)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: glass.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: size.width - 48),
        ])
        return glass
    }

    /// 调试用：离屏渲染面板检查排版
    static func renderPreview(toDirectory dir: String) {
        let size = NSSize(width: 380, height: 268)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        let content = makeContent(size: size, target: nil, action: nil)
        // 离屏时毛玻璃采不到背后的内容，垫一层底色好看清排版
        content.layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        w.contentView = content
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "\(dir)/keyboard-lock.png"))
        }
    }
}
