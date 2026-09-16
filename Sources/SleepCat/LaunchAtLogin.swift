// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit
import ServiceManagement

/// 开机自动启动：用系统的登录项（SMAppService），出现在「系统设置 › 通用 › 登录项」里，用户在那边也能关。
///
/// 装进「应用程序」文件夹后第一次启动时默认打开一次；之后以用户的选择为准，不再自作主张。
/// 从项目目录跑的开发版不自动注册，免得登录项指向一个随时会被删掉的构建产物
enum LaunchAtLogin {
    private static let defaultedKey = "launchAtLoginDefaulted"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 注册了但被用户在系统设置里拦下，要去那边点开
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// 是不是装好的正式版：只认「应用程序」文件夹（含用户自己的 ~/Applications）
    static func isInstalled(bundlePath: String = Bundle.main.bundlePath) -> Bool {
        let home = NSHomeDirectory()
        return bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/Applications/")
    }

    /// 启动时调用：正式版第一次运行，默认打开
    static func applyDefaultIfNeeded(defaults: UserDefaults = .standard) {
        guard isInstalled(), !defaults.bool(forKey: defaultedKey) else { return }
        defaults.set(true, forKey: defaultedKey)
        guard SMAppService.mainApp.status != .enabled else { return }
        set(true)
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            LidBlocker.log(on ? "已打开开机自动启动" : "已关闭开机自动启动")
            return true
        } catch {
            LidBlocker.log("开机自动启动设置失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 打开或关闭；系统要求用户批准时，直接带去登录项设置页
    static func toggle() {
        if isEnabled {
            set(false)
        } else {
            set(true)
            if needsApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }
}
