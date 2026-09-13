// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import Foundation

/// 屏幕是否正被别的程序持续监看：远程控制（UU 远程、ToDesk、向日葵……）、屏幕共享、录屏。
///
/// 没有公开 API。SkyLight 私有的 `SLSIsScreenWatcherPresent` 能回答这个问题；
/// 系统里找不到这个符号（比如以后改名了）就当作没人在看，不影响其他功能。
/// 单张截图不会让它变成 true，所以截个图不会误伤合盖模糊。
enum ScreenWatch {
    private static let probe: (@convention(c) () -> Bool)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "SLSIsScreenWatcherPresent") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Bool).self)
    }()

    static var isAvailable: Bool { probe != nil }

    static func isScreenWatched() -> Bool { probe?() ?? false }
}
