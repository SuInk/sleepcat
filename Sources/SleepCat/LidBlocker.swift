import AppKit

/// 合盖防休眠：电源断言挡不住合盖的强制休眠，只能用 `pmset disablesleep`（需要 root）。
///
/// 拿权限分两档：
/// 1. 免密规则（推荐）：往 /etc/sudoers.d/sleepcat 装一条只放行
///    `pmset -a disablesleep 1/0` 的 NOPASSWD 规则，装时授权一次，之后 `sudo -n` 静默切换。
/// 2. 没装规则：每次切换用 osascript 弹系统管理员密码框。
final class LidBlocker {
    private(set) var isActive = false

    private static let logPath = ("~/Library/Logs/SleepCat.log" as NSString).expandingTildeInPath
    private static let sudoersPath = "/etc/sudoers.d/sleepcat"

    /// macOS 27 起 pmset 在 /usr/bin，老系统在 /usr/sbin
    static let pmsetPath: String = ["/usr/bin/pmset", "/usr/sbin/pmset"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/pmset"

    init() {
        // 启动时读系统当前状态（比如上次异常退出留下的 disablesleep=1）
        isActive = Self.readSleepDisabled()
    }

    /// 从 `pmset -g` 读 SleepDisabled 当前值
    static func readSleepDisabled() -> Bool {
        let out = run(pmsetPath, ["-g"]).stdout
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.contains("1")
        }
        return false
    }

    // MARK: - 免密规则

    /// 免密规则是否可用（sudo -n -l 试探，无副作用、不弹框）
    func freePassInstalled() -> Bool {
        Self.run("/usr/bin/sudo", ["-n", "-l", Self.pmsetPath, "-a", "disablesleep", "1"]).exitCode == 0
    }

    /// 安装 sudoers 免密规则（弹一次管理员密码框）。
    /// 规则先用 visudo -c 校验语法再落盘，避免写坏 sudo。成功返回 nil。
    func installFreePass() -> String? {
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: \(Self.pmsetPath) -a disablesleep 1, \(Self.pmsetPath) -a disablesleep 0"
        let script = """
        set -e
        tmp=$(mktemp)
        printf '%s\\n' '\(rule)' > "$tmp"
        visudo -c -q -f "$tmp"
        install -m 0440 -o root -g wheel "$tmp" \(Self.sudoersPath)
        rm -f "$tmp"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleepcat-grant-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return "无法写入临时脚本：\(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let osa = "do shell script \"/bin/sh \(scriptURL.path)\" with administrator privileges"
        let r = Self.run("/usr/bin/osascript", ["-e", osa])
        Self.log("installFreePass exit=\(r.exitCode) stderr=\(r.stderr.trimmed)")

        if freePassInstalled() { return nil }
        if r.stderr.contains("-128") { return "已取消密码验证" }
        return r.stderr.trimmed.isEmpty ? "规则安装后校验未通过" : r.stderr.trimmed
    }

    /// 卸载免密规则（弹管理员密码框）。成功返回 nil。
    func removeFreePass() -> String? {
        let osa = "do shell script \"rm -f \(Self.sudoersPath)\" with administrator privileges"
        let r = Self.run("/usr/bin/osascript", ["-e", osa])
        Self.log("removeFreePass exit=\(r.exitCode) stderr=\(r.stderr.trimmed)")
        if !freePassInstalled() { return nil }
        if r.stderr.contains("-128") { return "已取消密码验证" }
        return r.stderr.trimmed
    }

    // MARK: - 切换

    /// 切换 disablesleep：先试免密（sudo -n），不行再弹密码框。
    /// 成功返回 nil，失败返回可读的错误描述（用户取消也算失败）。
    func set(_ on: Bool) -> String? {
        guard isActive != on else { return nil }
        let value = on ? "1" : "0"

        // 免密通道：装了规则就完全静默
        let quiet = Self.run("/usr/bin/sudo", ["-n", Self.pmsetPath, "-a", "disablesleep", value])
        if Self.readSleepDisabled() == on {
            isActive = on
            Self.log("set(\(on)) via sudo -n ok")
            return nil
        }

        // 回退：系统管理员密码框
        let osa = "do shell script \"\(Self.pmsetPath) -a disablesleep \(value)\" with administrator privileges"
        let r = Self.run("/usr/bin/osascript", ["-e", osa])
        let actual = Self.readSleepDisabled()
        isActive = actual
        Self.log("set(\(on)) sudo-n=\(quiet.exitCode) osa=\(r.exitCode) actual=\(actual) stderr=\(r.stderr.trimmed)")

        if actual == on { return nil }
        if r.stderr.contains("-128") { return "已取消密码验证" }
        return r.stderr.trimmed.isEmpty
            ? "pmset 执行后状态未改变（详见 ~/Library/Logs/SleepCat.log）"
            : r.stderr.trimmed
    }

    /// 静默恢复（只走免密通道，绝不弹框）——用于启动时清理上次崩溃的残留
    func trySilentRestore() {
        guard isActive else { return }
        _ = Self.run("/usr/bin/sudo", ["-n", Self.pmsetPath, "-a", "disablesleep", "0"])
        isActive = Self.readSleepDisabled()
        Self.log("trySilentRestore -> stillDisabled=\(isActive)")
    }

    // MARK: - 工具

    private static func run(_ path: String, _ args: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            return (-1, "", "无法启动 \(path)：\(error.localizedDescription)")
        }
        // 先读再 wait，避免管道写满死锁
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (
            p.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private static func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
        NSLog("SleepCat: %@", message)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
