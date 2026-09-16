// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import Foundation

/// 日志和功耗记录只留最近 30 天，不然一直开着的菜单栏应用会让文件无限变长。
/// 启动时清一次，之后每天清一次。曲线用的采样文件另有 24 小时的清理，不归这里管
enum LogRetention {
    static let days = 30

    /// 应用日志：每行开头是 `[2026-09-16 17:00:55 +0000]`
    static func trimAppLog(_ text: String, now: Date = Date()) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return trim(lines: text, cutoff: cutoff(from: now), header: false) { line in
            guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { return nil }
            return parser.date(from: String(line[line.index(after: line.startIndex)..<end]))
        }
    }

    /// 功耗记录：第一行是表头，之后每行开头是本地时间 `2026-09-16 17:29`
    static func trimPowerLog(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
        parser.dateFormat = "yyyy-MM-dd HH:mm"
        return trim(lines: text, cutoff: cutoff(from: now), header: true) { line in
            line.split(separator: ",", maxSplits: 1).first.flatMap { parser.date(from: String($0)) }
        }
    }

    /// 按行过滤。读不出时间的行（比如多行报错的后半截）跟着上一行走，不单独删
    private static func trim(lines text: String, cutoff: Date, header: Bool,
                             date: (Substring) -> Date?) -> String {
        var kept: [Substring] = []
        var keepCurrent = true
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if header, index == 0 { kept.append(line); continue }
            if let stamp = date(line) { keepCurrent = stamp >= cutoff }
            if keepCurrent { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    private static func cutoff(from now: Date) -> Date {
        now.addingTimeInterval(-Double(days) * 24 * 3600)
    }

    /// 实际清理两个文件。只在真有东西要删时才重写，免得每天白写一次盘
    static func apply(appLog: URL, powerLog: URL, now: Date = Date()) {
        rewrite(appLog) { trimAppLog($0, now: now) }
        rewrite(powerLog) { trimPowerLog($0, now: now) }
    }

    private static let bom = Data([0xEF, 0xBB, 0xBF])

    private static func rewrite(_ url: URL, _ transform: (String) -> String) {
        guard let data = try? Data(contentsOf: url) else { return }
        // 功耗记录开头有 BOM（Excel 靠它认中文）。按文本读会被吃掉，所以按字节剥下来，写回时再补上
        let hasBOM = data.starts(with: bom)
        guard let text = String(data: hasBOM ? data.dropFirst(bom.count) : data, encoding: .utf8) else { return }
        let trimmed = transform(text)
        guard trimmed != text else { return }
        try? ((hasBOM ? bom : Data()) + Data(trimmed.utf8)).write(to: url, options: .atomic)
    }
}
