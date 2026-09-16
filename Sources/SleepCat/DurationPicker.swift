// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 自定义喵住时长的输入面板（放进 NSAlert 的 accessoryView）。
/// 小时、分钟各一组输入框 + 步进器，下方实时显示"到几点放猫猫去睡"。
final class DurationPicker: NSObject, NSTextFieldDelegate {
    let view = NSStackView()
    let hoursField = NSTextField()
    private let minutesField = NSTextField()
    private let hoursStepper = NSStepper()
    private let minutesStepper = NSStepper()
    private let endLabel = NSTextField(labelWithString: "")
    private let endIcon = NSImageView()

    /// 数值变化时回调总分钟数（用来启用/禁用确认按钮）
    var onChange: ((Int) -> Void)? {
        didSet { onChange?(totalMinutes) }
    }

    var totalMinutes: Int { hoursStepper.integerValue * 60 + minutesStepper.integerValue }

    init(minutes: Int) {
        super.init()
        configure(hoursField, hoursStepper, max: 72, increment: 1, value: minutes / 60)
        configure(minutesField, minutesStepper, max: 59, increment: 5, value: minutes % 60)

        let hoursUnit = unitLabel("小时")
        let row = NSStackView(views: [
            hoursField, hoursStepper, hoursUnit,
            minutesField, minutesStepper, unitLabel("分钟"),
        ])
        row.spacing = 4
        row.setCustomSpacing(8, after: hoursStepper)
        row.setCustomSpacing(22, after: hoursUnit)
        row.setCustomSpacing(8, after: minutesStepper)

        endIcon.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil)
        endIcon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        endIcon.contentTintColor = .secondaryLabelColor
        endLabel.font = .systemFont(ofSize: 12)
        endLabel.textColor = .secondaryLabelColor
        let endRow = NSStackView(views: [endIcon, endLabel])
        endRow.spacing = 5

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 12
        view.addArrangedSubview(row)
        view.addArrangedSubview(endRow)
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 68)
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
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true
        stepper.controlSize = .large
    }

    private func unitLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        return label
    }

    /// NSAlert 把附加视图摆得比标题文字靠左几个点，输入框看着和标题没对齐；按标题的实际位置补齐
    func alignLeadingEdge(to alert: NSAlert) {
        Self.alignLeadingEdge(of: view, field: hoursField, to: alert)
    }

    /// 同上，给别的对话框（比如自定义电量阈值）共用
    static func alignLeadingEdge(of view: NSStackView, field: NSView, to alert: NSAlert) {
        alert.layout()
        guard let content = alert.window.contentView,
              let title = label(withText: alert.messageText, in: content) else { return }
        let titleX = title.convert(title.bounds, to: nil).minX
        let fieldX = field.convert(field.bounds, to: nil).minX
        let delta = (titleX - fieldX).rounded()
        guard delta > 0 else { return }
        // 只加内边距、不加宽：视图一变宽 NSAlert 会把它往左挪，抵掉一半
        view.edgeInsets.left += delta
        alert.layout()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    private static func label(withText text: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == text { return field }
        for sub in view.subviews { if let hit = label(withText: text, in: sub) { return hit } }
        return nil
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
        endLabel.stringValue = Self.summaryText(minutes: total)
        endIcon.isHidden = total == 0
        onChange?(total)
    }

    // MARK: - 文案（纯函数，便于测试）

    /// 输入框下面那行：几点放猫猫去睡（时长就在上面的输入框里，不再重复）
    static func summaryText(minutes: Int, from now: Date = Date(), calendar: Calendar = .current) -> String {
        guard minutes > 0 else { return "时长不能为 0" }
        return "\(endTimeText(minutes: minutes, from: now, calendar: calendar)) 放猫猫去睡"
    }

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
