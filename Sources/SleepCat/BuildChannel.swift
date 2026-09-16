// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import Foundation

/// 这份是开发版还是正式版：build.sh 写进 Info.plist 的 SleepCatChannel。
/// 没有这个键（直接跑 .build 里的二进制、生成 README 配图）按正式版处理
enum BuildChannel {
    static var isDev: Bool { isDev(info: Bundle.main.infoDictionary) }

    static func isDev(info: [String: Any]?) -> Bool {
        info?["SleepCatChannel"] as? String == "dev"
    }
}
