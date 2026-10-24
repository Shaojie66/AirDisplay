import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let virtualDisplay = VirtualDisplay()
    private var statusItem: NSStatusItem!
    private lazy var controlPanel = ControlPanel(virtualDisplay: virtualDisplay)

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "AirDisplay")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        virtualDisplay.onTerminated = { [weak self] in self?.logDisplays() }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.logDisplays()
            self?.controlPanel.refresh()
        }

        controlPanel.onToggle = { [weak self] in
            guard let self else { return }
            self.virtualDisplay.isRunning ? self.stopDisplay() : self.startDisplay()
        }

        // 测试用：带 --start 启动时直接开虚拟屏
        if CommandLine.arguments.contains("--start") { startDisplay() }
        logDisplays()
        if CommandLine.arguments.contains("--test-windows") {
            // 等新屏幕登记进 NSScreen 再放窗口
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.showTestWindows() }
        }
        controlPanel.show()
    }

    /// 再次打开 App（双击、Spotlight）时把控制面板叫出来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controlPanel.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        virtualDisplay.stop()
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if virtualDisplay.isRunning, let c = virtualDisplay.config {
            menu.addItem(disabled: "虚拟屏运行中：\(c.pointWidth)×\(c.pointHeight) @2x，\(Int(c.refreshRate))Hz")
            menu.addItem(withTitle: "关闭虚拟屏", action: #selector(stopDisplay), keyEquivalent: "")
        } else {
            menu.addItem(disabled: "虚拟屏未开启")
            menu.addItem(withTitle: "开启虚拟屏", action: #selector(startDisplay), keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(disabled: "在线显示器：")
        for d in DisplayInfo.online() {
            menu.addItem(disabled: "  " + d.summary)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "每块屏放一个测试窗口", action: #selector(showTestWindows), keyEquivalent: "")
        menu.addItem(withTitle: "关闭测试窗口", action: #selector(closeTestWindows), keyEquivalent: "")
        menu.addItem(withTitle: "显示控制面板", action: #selector(showPanel), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { if $0.action != nil { $0.target = self } }
    }

    @objc private func startDisplay() {
        do {
            try virtualDisplay.start(.air15)
        } catch {
            Log.info("开启失败：\(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "虚拟屏开启失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func stopDisplay() { virtualDisplay.stop() }

    @objc private func showTestWindows() { TestPattern.show(on: NSScreen.screens) }

    @objc private func closeTestWindows() { TestPattern.close() }

    @objc private func showPanel() { controlPanel.show() }

    @objc private func quit() { NSApp.terminate(nil) }

    private func logDisplays() {
        let list = DisplayInfo.online()
        Log.info("在线显示器 \(list.count) 块：\n" + list.map { "  - " + $0.summary }.joined(separator: "\n"))
    }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
