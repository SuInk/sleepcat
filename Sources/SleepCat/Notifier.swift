// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit
import UserNotifications

/// 系统通知。低电量暂停 / 恢复这种事多半发生在人不在电脑前的时候，
/// 菜单栏下的小提示一闪就没了，进通知中心回来还能看到。拿不到权限就退回小提示。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// 只在应用里用：测试进程没有应用包，一碰 UNUserNotificationCenter 就会崩
    private var center: UNUserNotificationCenter { .current() }

    /// 最近一次查到的授权状态，给菜单用；nil 表示还没查过（测试里建菜单时就是 nil）
    private(set) var status: UNAuthorizationStatus?

    /// 用户关掉了通知，系统不会再弹授权框，只能去系统设置里打开
    var isDenied: Bool { status == .denied }

    func setUp() {
        center.delegate = self
        refreshStatus()
    }

    /// 同步刷新授权状态，最多等 timeout；打开菜单前调用，让菜单反映系统设置里刚改过的开关
    func refreshStatus(timeout: TimeInterval = 0.3) {
        let done = DispatchSemaphore(value: 0)
        let box = StatusBox()
        center.getNotificationSettings { settings in
            box.value = settings.authorizationStatus
            done.signal()
            DispatchQueue.main.async { self.status = settings.authorizationStatus }
        }
        if done.wait(timeout: .now() + timeout) == .success { status = box.value }
    }

    /// 在用户正在操作的时机请求（启动、手动开启喵住、选阈值），别等真出事时才弹——那时多半没人看见。
    /// 授权框出现后进程不能退出：请求被撤掉时系统会直接记成「拒绝」，之后再也不弹
    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self.center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                LidBlocker.log("通知授权：\(granted ? "已允许" : "未允许")\(error.map { "，\($0.localizedDescription)" } ?? "")")
                self.center.getNotificationSettings { settings in
                    DispatchQueue.main.async { self.status = settings.authorizationStatus }
                }
            }
        }
    }

    /// 打开「系统设置 → 通知 → SleepCat」
    func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? "cn.suink.sleepcat"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
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

    private final class StatusBox: @unchecked Sendable { var value: UNAuthorizationStatus? }

    /// 应用算在前台时系统默认不弹横幅，这里要求照常弹
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
