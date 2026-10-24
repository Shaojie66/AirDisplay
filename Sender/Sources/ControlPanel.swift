import AppKit

/// 小控制面板。16" MacBook Pro 的刘海可能挡住菜单栏图标，所以启动时和再次打开 App 时都显示它。
final class ControlPanel: NSObject {
    struct Actions {
        var toggleDisplay: () -> Void
        var toggleLoopback: () -> Void
    }

    private let panel: NSPanel
    private let statusLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let displayButton = FirstClickButton(title: "", target: nil, action: nil)
    private let loopbackButton = FirstClickButton(title: "", target: nil, action: nil)
    var actions: Actions?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false
        )
        super.init()
        panel.title = "AirDisplay"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        for l in [statusLabel, statsLabel] {
            l.maximumNumberOfLines = 0
            l.lineBreakMode = .byWordWrapping
            l.preferredMaxLayoutWidth = 420
        }
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = .secondaryLabelColor

        displayButton.target = self
        displayButton.action = #selector(displayTapped)
        loopbackButton.target = self
        loopbackButton.action = #selector(loopbackTapped)

        let testOn = FirstClickButton(title: "放测试窗口", target: self, action: #selector(testOnTapped))
        let testOff = FirstClickButton(title: "关测试窗口", target: self, action: #selector(testOffTapped))
        let quit = FirstClickButton(title: "退出", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        let row1 = NSStackView(views: [displayButton, loopbackButton])
        let row2 = NSStackView(views: [testOn, testOff, quit])
        let stack = FirstClickStackView(views: [statusLabel, row1, row2, statsLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        panel.contentView = stack
    }

    func show() {
        if let main = NSScreen.screens.first {
            let f = main.visibleFrame, size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 40))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func update(display: String, displayRunning: Bool, loopbackRunning: Bool, stats: String?) {
        statusLabel.stringValue = display
        displayButton.title = displayRunning ? "关闭虚拟屏" : "开启虚拟屏"
        loopbackButton.title = loopbackRunning ? "停止本机回环" : "开始本机回环（M2）"
        statsLabel.stringValue = stats ?? ""
        statsLabel.isHidden = stats == nil
    }

    @objc private func displayTapped() { Log.info("面板：虚拟屏开关"); actions?.toggleDisplay() }
    @objc private func loopbackTapped() { Log.info("面板：回环开关"); actions?.toggleLoopback() }
    @objc private func testOnTapped() { Log.info("面板：放测试窗口"); TestPattern.show(on: NSScreen.screens) }
    @objc private func testOffTapped() { Log.info("面板：关测试窗口"); TestPattern.close() }
}
