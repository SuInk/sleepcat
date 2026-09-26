// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 第一次打开时打个招呼：菜单栏只是多了只猫，新手很容易以为「装了没反应」。
///
/// 带刘海的 MacBook 上菜单栏一挤，新图标会被刘海挡住，用户根本找不到猫；
/// 这时候提示改在屏幕上方弹，告诉他怎么腾位置
enum Welcome {
    private static let shownKey = "welcomeShown"

    /// 老用户升级上来没有 welcomeShown，靠这些用过的痕迹认出来，别对他们也打招呼
    static let usedBeforeKeys = [
        "lastUpdateCheck", "notifiedUpdateVersion", "launchAtLoginDefaulted",
        "lowBatteryThreshold", "soundEnabled", "lidBlockEnabled", "duoEnabled",
        "NSStatusItem Preferred Position SleepCat",
    ]

    /// 这次是不是第一次打开。只会回答一次 true，调用即记下
    static func takeFirstLaunch(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: shownKey) else { return false }
        defaults.set(true, forKey: shownKey)
        return !usedBeforeKeys.contains { defaults.object(forKey: $0) != nil }
    }

    /// 猫猫在菜单栏上是不是看不见：跑到屏幕外，或者落在刘海那一段
    static func isCovered(item: NSRect, screen: NSRect,
                          notchLeftWidth: CGFloat?, notchRightWidth: CGFloat?) -> Bool {
        if item.maxX <= screen.minX || item.minX >= screen.maxX { return true }
        guard let l = notchLeftWidth, let r = notchRightWidth else { return false }
        let notchMinX = screen.minX + l
        let notchMaxX = screen.maxX - r
        return item.maxX > notchMinX && item.minX < notchMaxX
    }

    static func isCovered(_ button: NSStatusBarButton?) -> Bool {
        guard let window = button?.window else { return true }
        // 菜单栏自动隐藏、全屏应用时本来就看不见，那不算被挡
        if NSMenu.menuBarVisible(), !window.occlusionState.contains(.visible) { return true }
        guard let screen = window.screen ?? NSScreen.main else { return false }
        let hasNotch = screen.safeAreaInsets.top > 0
        return isCovered(item: window.frame, screen: screen.frame,
                         notchLeftWidth: hasNotch ? screen.auxiliaryTopLeftArea?.width : nil,
                         notchRightWidth: hasNotch ? screen.auxiliaryTopRightArea?.width : nil)
    }

    static func greet(_ button: NSStatusBarButton?) {
        if isCovered(button) {
            LidBlocker.log("第一次打开：菜单栏放不下，猫猫被挡住了")
            Toast.show("菜单栏太挤，猫猫没地方待了 🐱 按住 ⌘ 把不常用的图标拖出去，给它腾个位置",
                       below: nil, duration: 10)
        } else {
            Toast.show("我在这儿 🐱 左键喵住，右键看设置", below: button, duration: 6)
        }
    }
}
