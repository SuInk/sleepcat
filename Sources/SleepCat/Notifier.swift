// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import Foundation
import UserNotifications

/// 系统通知。低电量暂停 / 恢复这种事多半发生在人不在电脑前的时候，
/// 菜单栏下的小提示一闪就没了，进通知中心回来还能看到。拿不到权限就退回小提示。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// 只在应用里用：测试进程没有应用包，一碰 UNUserNotificationCenter 就会崩
    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self
    }

    /// 在用户正在操作的时机请求（比如手动开启喵住），别等真出事时才弹——那时多半没人看见
    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self.center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                LidBlocker.log("通知授权：\(granted ? "已允许" : "未允许")\(error.map { "，\($0.localizedDescription)" } ?? "")")
            }
        }
    }

    /// 发一条通知；没有权限或发送失败时在主线程调用 fallback
    /// - Parameter id: 同一个 id 会替换上一条，暂停后又恢复时通知中心里只留最新状态
    func post(id: String, title: String, body: String, sound: Bool, fallback: @escaping () -> Void) {
        center.getNotificationSettings { settings in
            guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
                DispatchQueue.main.async(execute: fallback)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound ? .default : nil
            self.center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                guard let error else { return }
                LidBlocker.log("通知发送失败：\(error.localizedDescription)")
                DispatchQueue.main.async(execute: fallback)
            }
        }
    }

    /// 应用算在前台时系统默认不弹横幅，这里要求照常弹
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
