import AVFoundation

/// 代码合成的"喵"——系统音效没有猫叫，自己造一个：
/// 基频先扬后抑（咪→呜），谐波权重随时间从高次转向基频（模拟 ee→ow 口型），加轻微颤音。
enum MeowSound {
    private static let sampleRate = 44100.0
    private static let duration = 0.55

    // 播放器要持有住，否则函数返回就被释放、声音掐断
    private static var player: AVAudioPlayer?

    static func play() {
        if player == nil {
            player = try? AVAudioPlayer(data: wavData())
            player?.prepareToPlay()
        }
        player?.currentTime = 0
        player?.play()
    }

    /// 生成 16-bit 单声道 WAV
    static func wavData() -> Data {
        let n = Int(sampleRate * duration)
        var phase = 0.0
        var samples = [Int16](repeating: 0, count: n)

        for i in 0..<n {
            let t = Double(i) / sampleRate          // 秒
            let p = t / duration                    // 进度 0…1

            // 基频轮廓：380Hz 扬到 620Hz（前 35%），再落回 260Hz
            let f0: Double
            if p < 0.35 {
                f0 = 380 + (620 - 380) * smooth(p / 0.35)
            } else {
                f0 = 620 - (620 - 260) * smooth((p - 0.35) / 0.65)
            }
            // 轻微颤音
            let vibrato = 1.0 + 0.012 * sin(2 * .pi * 6.5 * t)
            phase += 2 * .pi * f0 * vibrato / sampleRate

            // 谐波合成：前段偏高次谐波（"咪"），后段偏基频（"呜"）
            let ow = smooth(p)                      // 0=ee 1=ow
            let weights = [
                1.0 * (0.5 + 0.5 * ow),             // 基频
                0.55 * (1.0 - 0.3 * ow),
                0.42 * (1.0 - 0.55 * ow),
                0.30 * (1.0 - 0.75 * ow),
                0.16 * (1.0 - 0.85 * ow),
            ]
            var s = 0.0
            for (k, w) in weights.enumerated() {
                s += w * sin(phase * Double(k + 1))
            }

            // 包络：30ms 起音，尾部 40% 渐弱
            let attack = min(1.0, t / 0.03)
            let release = p > 0.6 ? smooth((1.0 - p) / 0.4) : 1.0
            s *= 0.28 * attack * release

            samples[i] = Int16(max(-1, min(1, s)) * 32767)
        }
        return wrapWAV(samples)
    }

    /// smoothstep 缓动
    private static func smooth(_ x: Double) -> Double {
        let c = max(0, min(1, x))
        return c * c * (3 - 2 * c)
    }

    private static func wrapWAV(_ samples: [Int16]) -> Data {
        var data = Data()
        let byteCount = samples.count * 2
        func append(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(16)
        append16(1); append16(1)                       // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append16(2); append16(16)                      // block align, bits
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
