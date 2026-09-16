// SleepCat —— 菜单栏里的猫猫防休眠
// Copyright (C) 2026 SuInk
// 自由软件：按 GNU AGPL v3（或更新版本）发布，不附任何担保。详见 LICENSE。

import AppKit

/// 自定义低电量阈值的输入面板（放进 NSAlert 的 accessoryView），样子和自定义喵住时长一致：
/// 输入框 + 步进器 + 「%」，下面一行灰字说清楚什么时候暂停
final class ThresholdPicker: NSObject, NSTextFieldDelegate {
    /// 可选范围。太低来不及反应，太高等于插着电才能喵住
    static let range = 5...90

    let view = NSStackView()
    let field = NSTextField()
    private let stepper = NSStepper()
    private let hintLabel = NSTextField(labelWithString: "")

    var percent: Int { stepper.integerValue }

    init(percent: Int) {
        super.init()
        stepper.minValue = Double(Self.range.lowerBound)
        stepper.maxValue = Double(Self.range.upperBound)
        stepper.increment = 5
        stepper.valueWraps = false
        stepper.integerValue = Self.clamp(percent)
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        stepper.controlSize = .large

        field.integerValue = stepper.integerValue
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let unit = NSTextField(labelWithString: "%")
        unit.font = .systemFont(ofSize: 13)
        let row = NSStackView(views: [field, stepper, unit])
        row.spacing = 4
        row.setCustomSpacing(8, after: stepper)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "battery.25", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        let hintRow = NSStackView(views: [icon, hintLabel])
        hintRow.spacing = 5

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 12
        view.addArrangedSubview(row)
        view.addArrangedSubview(hintRow)
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 68)
        refresh()
    }

    static func clamp(_ value: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// 输入框下面那行
    static func hintText(percent: Int) -> String {
        "用电池时低于 \(percent)% 暂停喵住"
    }

    @objc private func stepperChanged() {
        field.integerValue = stepper.integerValue
        refresh()
    }

    func controlTextDidChange(_ note: Notification) {
        let typed = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? Self.range.lowerBound
        stepper.integerValue = Self.clamp(typed)
        refresh()
    }

    /// 输入超范围（比如填 99）时，离开输入框就把显示改回实际生效的值
    func controlTextDidEndEditing(_ note: Notification) {
        field.integerValue = stepper.integerValue
    }

    private func refresh() {
        hintLabel.stringValue = Self.hintText(percent: percent)
    }
}
