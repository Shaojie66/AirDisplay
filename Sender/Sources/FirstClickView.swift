import AppKit

/// 面板在后台时，第一次点击也直接触发按钮（不只是激活窗口）
final class FirstClickStackView: NSStackView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
