// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 自定义喵住时长的输入面板（放进 NSAlert 的 accessoryView）。
/// 小时、分钟各一组输入框 + 步进器，下方实时显示"到几点"。
final class DurationPicker: NSObject, NSTextFieldDelegate {
    let view = NSStackView()
    let hoursField = NSTextField()
    private let minutesField = NSTextField()
    private let hoursStepper = NSStepper()
    private let minutesStepper = NSStepper()
    private let endLabel = NSTextField(labelWithString: "")

    /// 数值变化时回调总分钟数（用来启用/禁用确认按钮）
    var onChange: ((Int) -> Void)? {
        didSet { onChange?(totalMinutes) }
    }

    var totalMinutes: Int { hoursStepper.integerValue * 60 + minutesStepper.integerValue }

    init(minutes: Int) {
        super.init()
        configure(hoursField, hoursStepper, max: 72, increment: 1, value: minutes / 60)
        configure(minutesField, minutesStepper, max: 59, increment: 5, value: minutes % 60)

        let hoursUnit = NSTextField(labelWithString: "小时")
        let row = NSStackView(views: [
            hoursField, hoursStepper, hoursUnit,
            minutesField, minutesStepper, NSTextField(labelWithString: "分钟"),
        ])
        row.spacing = 6
        row.setCustomSpacing(18, after: hoursUnit)

        endLabel.font = .systemFont(ofSize: 12)
        endLabel.textColor = .secondaryLabelColor

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 10
        view.addArrangedSubview(row)
        view.addArrangedSubview(endLabel)
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 58)
        refresh()
    }

    private func configure(_ field: NSTextField, _ stepper: NSStepper,
                           max: Double, increment: Double, value: Int) {
        stepper.minValue = 0
        stepper.maxValue = max
        stepper.increment = increment
        stepper.valueWraps = false
        stepper.integerValue = Swift.min(Int(max), Swift.max(0, value))
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))

        field.integerValue = stepper.integerValue
        field.alignment = .right
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 46).isActive = true
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        (sender === hoursStepper ? hoursField : minutesField).integerValue = sender.integerValue
        refresh()
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        let stepper = field === hoursField ? hoursStepper : minutesStepper
        let typed = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        stepper.integerValue = Swift.min(Int(stepper.maxValue), Swift.max(0, typed))
        refresh()
    }

    /// 输入超范围（比如分钟填 75）时，离开输入框就把显示改回实际生效的值
    func controlTextDidEndEditing(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        field.integerValue = (field === hoursField ? hoursStepper : minutesStepper).integerValue
    }

    private func refresh() {
        let total = totalMinutes
        endLabel.stringValue = total > 0
            ? "喵住 \(Self.durationText(minutes: total))，" + Self.prefixed("到", Self.endTimeText(minutes: total))
            : "时长不能为 0"
        onChange?(total)
    }

    // MARK: - 文案（纯函数，便于测试）

    /// 汉字接数字时留空格（"至 22:39"），汉字接汉字不留（"至明天 04:00"）
    static func prefixed(_ word: String, _ text: String) -> String {
        text.first?.isNumber == true ? "\(word) \(text)" : word + text
    }

    static func durationText(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) 分钟"
        case (_, 0): return "\(h) 小时"
        default:     return "\(h) 小时 \(m) 分"
        }
    }

    /// 结束时刻：今天 / 明天 / 后天 / 具体日期。菜单里空间紧，同一天时可省掉"今天"
    static func endTimeText(minutes: Int, from now: Date = Date(),
                            calendar: Calendar = .current, showToday: Bool = true) -> String {
        let end = now.addingTimeInterval(TimeInterval(minutes * 60))
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: end)).day ?? 0
        switch days {
        case 0:  return showToday ? "今天 \(f.string(from: end))" : f.string(from: end)
        case 1:  return "明天 \(f.string(from: end))"
        case 2:  return "后天 \(f.string(from: end))"
        default:
            f.dateFormat = "M月d日 HH:mm"
            return f.string(from: end)
        }
    }

    /// 调试用：把面板离屏渲染成 PNG，检查排版
    static func renderPreview(toDirectory dir: String) {
        let picker = DurationPicker(minutes: 90)
        let w = NSWindow(contentRect: picker.view.frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = picker.view
        picker.view.layoutSubtreeIfNeeded()
        guard let rep = picker.view.bitmapImageRepForCachingDisplay(in: picker.view.bounds) else { return }
        picker.view.cacheDisplay(in: picker.view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "\(dir)/duration-picker.png"))
        }
    }
}
