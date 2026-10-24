import AppKit

/// 小控制面板。16" MacBook Pro 的刘海可能挡住菜单栏图标，所以启动时和再次打开 App 时都显示它。
final class ControlPanel: NSObject {
    private let panel: NSPanel
    private let statusLabel = NSTextField(labelWithString: "")
    private let toggleButton = NSButton(title: "", target: nil, action: nil)
    private let virtualDisplay: VirtualDisplay
    var onToggle: (() -> Void)?

    init(virtualDisplay: VirtualDisplay) {
        self.virtualDisplay = virtualDisplay
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false
        )
        super.init()
        panel.title = "AirDisplay"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        toggleButton.target = self
        toggleButton.action = #selector(toggle)
        toggleButton.bezelStyle = .rounded
        toggleButton.keyEquivalent = "\r"

        let testOn = NSButton(title: "每块屏放测试窗口", target: self, action: #selector(testOnTapped))
        let testOff = NSButton(title: "关闭测试窗口", target: self, action: #selector(testOffTapped))
        let quit = NSButton(title: "退出", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        let buttons = NSStackView(views: [toggleButton, testOn, testOff])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [statusLabel, buttons, quit])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        panel.contentView = stack
    }

    func show() {
        refresh()
        // 固定放在主屏（带菜单栏那块）中间偏上
        if let main = NSScreen.screens.first {
            let f = main.visibleFrame, size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY + 120))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func refresh() {
        if virtualDisplay.isRunning, let c = virtualDisplay.config {
            statusLabel.stringValue = "虚拟屏运行中：\(c.pointWidth)×\(c.pointHeight) @2x，\(Int(c.refreshRate))Hz\n在线显示器 \(DisplayInfo.online().count) 块"
            toggleButton.title = "关闭虚拟屏"
        } else {
            statusLabel.stringValue = "虚拟屏未开启\n在线显示器 \(DisplayInfo.online().count) 块"
            toggleButton.title = "开启虚拟屏"
        }
        panel.layoutIfNeeded()
    }

    @objc private func toggle() { onToggle?(); refresh() }
    @objc private func testOnTapped() { TestPattern.show(on: NSScreen.screens) }
    @objc private func testOffTapped() { TestPattern.close() }
}
