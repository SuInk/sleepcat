// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import Foundation

/// 检查更新：读 GitHub 上最新发布的版本（release.sh 就是发到那里），和当前版本比。
enum UpdateChecker {
    struct Release: Equatable {
        let version: String
        let page: URL
    }

    enum CheckError: LocalizedError {
        case badResponse(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "GitHub 返回了 \(code)"
            case .unreadable: return "没看懂 GitHub 返回的内容"
            }
        }
    }

    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/SuInk/sleepcat/releases/latest")!
    static let upgradeCommand = "brew upgrade suink/tap/sleepcat"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 用 Homebrew 装的就该用 Homebrew 升级，自己去换文件会让 brew 记录的版本对不上。
    /// 光有 Caskroom 记录不够——同一台机器上也可能在跑别处的一份（比如源码构建的），
    /// 所以还要求正在运行的就是 brew 装进 /Applications 的那份
    static var installedViaHomebrew: Bool {
        Bundle.main.bundlePath == "/Applications/SleepCat.app" &&
            ["/opt/homebrew/Caskroom/sleepcat", "/usr/local/Caskroom/sleepcat"]
                .contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// 解析 GitHub releases/latest 的返回（纯函数，便于测试）
    static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return Release(version: normalized(tag), page: page)
    }

    /// 按数字逐段比较："1.10.0" 比 "1.9.0" 新，"v1.2" 和 "1.2.0" 一样
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = components(remote), l = components(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    private static func components(_ version: String) -> [Int] {
        normalized(version).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func fetchLatest(completion: @escaping (Result<Release, Error>) -> Void) {
        var request = URLRequest(url: latestReleaseAPI, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SleepCat/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Release, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(CheckError.badResponse(http.statusCode))
            } else if let data, let release = parse(data) {
                result = .success(release)
            } else {
                result = .failure(CheckError.unreadable)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
