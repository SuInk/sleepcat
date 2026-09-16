// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import Foundation

/// 合盖折叠的几何与曲线。
///
/// 做法跟 iPhone Duo 的折叠转场一致：画面**停在原地**，物理屏幕从画面里转过去。
/// 把眼睛放在起始角度时屏幕法线前方，向画面四角连线、与当前屏幕平面求交，
/// 得到画面落在屏幕上的四边形；再用它做一次透视变换，屏幕上看到的就是「画面没动」。
///
/// 全是纯函数，方便单测；实际渲染在 ScreenFold 里。
enum FoldGeometry {
    /// 开始折叠的角度（度）。比这更开就是完全清晰
    static let startAngle: Double = 100

    /// 眼睛离屏幕多远、多高，单位都是「屏幕高度」。2.6 个屏高 ≈ 16 寸上的 56 厘米
    static let eyeDistance: Double = 2.6
    static let eyeHeight: Double = 0.5

    /// 透视强度：按真实几何算太猛，打六折更耐看
    static let projectionStrength: Double = 0.6

    /// 角度 → 进度（0 全清晰，1 完全折叠）
    static func progress(forAngle angle: Double) -> Double {
        min(1, max(0, (startAngle - angle) / startAngle))
    }

    /// 画面上一点（x 从中心算，y 从铰链边算，单位都是点）映射到屏幕平面上的位置。
    /// - Parameters:
    ///   - height: 屏幕高度（点）
    ///   - delta: 已经转过的角度（弧度），0 表示还没开始折
    static func project(x: Double, y: Double, height: Double, delta: Double) -> (x: Double, y: Double) {
        let b = sin(delta)
        let c = -eyeDistance * height
        let k = b * (height / 2 + eyeHeight * height) + c * cos(delta)
        let denominator = k - b * y
        // 画面平面掠过眼睛时分母趋近 0，夹一下免得算出无穷大
        guard abs(denominator) > 1e-6 else { return (x, y) }
        return (k * x / denominator, c * y / denominator)
    }

    /// 画面四角落在屏幕上的位置（屏幕坐标，原点在左下＝铰链侧）。
    /// 顺序：左下、右下、左上、右上
    static func projectedCorners(width: Double, height: Double, angle: Double) -> [(x: Double, y: Double)] {
        let delta = max(0, (startAngle - angle)) * projectionStrength * .pi / 180
        return [(-width / 2, 0.0), (width / 2, 0.0), (-width / 2, height), (width / 2, height)].map {
            let p = project(x: $0.0, y: $0.1, height: height, delta: delta)
            return (p.x + width / 2, p.y)
        }
    }

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
