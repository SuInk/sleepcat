// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import Foundation

/// 合盖模糊的曲线：起始角度、各高度的模糊和压暗强度。
/// 参数取自 iPhone Duo 折叠转场的观感——铰链边清晰，远边先糊先黑。
/// 全是纯函数，方便单测
enum FoldGeometry {
    /// 开始折叠的角度（度）。比这更开就是完全清晰
    static let startAngle: Double = 100

    // MARK: 强度曲线

    /// 模糊整体强度：起步慢一点，合到后半程才真正糊起来
    static func blurStrength(progress: Double) -> Double { pow(max(0, progress), 1.45) }

    /// 变暗整体强度：比模糊来得早一点
    static func dimStrength(progress: Double) -> Double { pow(max(0, progress), 0.9) }

    /// 画面上某个高度（g：0＝铰链边，1＝远边）该有多糊，0…1
    static let blurFloor: Double = 0.08
    static func blurProfile(atHeight g: Double) -> Double {
        let t = min(1, max(0, g))
        return blurFloor + (1 - blurFloor) * pow(t, 1.35)
    }

    /// 同一高度该有多暗，0…1。铰链附近不压暗，远边最黑
    static let dimStart: Double = 0.18
    static let maxDim: Double = 0.92
    static func dimProfile(atHeight g: Double) -> Double {
        let spread = (min(1, max(0, g)) - dimStart) / (1 - dimStart)
        guard spread > 0 else { return 0 }
        return pow(spread, 1.9) * maxDim
    }
}

/// 临界阻尼弹簧：把 100Hz 上来的整数角度磨成显示器刷新率上的连续值，不抖也不过冲
struct AngleSpring {
    /// 角频率（弧度/秒）。14 对应大约 70 毫秒的跟随延迟
    static let omega: Double = 14

    private(set) var value: Double
    private var velocity: Double = 0

    init(value: Double) { self.value = value }

    mutating func step(target: Double, dt: TimeInterval) {
        let dt = min(max(0, dt), 0.1)   // 掉帧时一次别跳太多
        guard dt > 0 else { return }
        let w = Self.omega
        // 临界阻尼的半隐式积分，步长大时也稳定
        let acceleration = -2 * w * velocity - w * w * (value - target)
        velocity += acceleration * dt
        value += velocity * dt
    }

    /// 直接落到目标值（刚开始折叠时用，免得从上一次的残值慢慢爬过去）
    mutating func reset(to target: Double) {
        value = target
        velocity = 0
    }
}
