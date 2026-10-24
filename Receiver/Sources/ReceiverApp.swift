import AppKit
import IOKit.pwr_mgt

/// Air 上的接收 App：全屏黑底显示 Pro 推过来的画面。
/// 按 S 开关统计浮层，按 Esc 或 ⌘Q 退出。
@main
final class ReceiverAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let videoView = VideoView(frame: .zero)
    private let overlay = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    private let client = StreamClient()
    private var sleepAssertion: IOPMAssertionID = 0
    private var statsTimer: Timer?
    private var showStats = false
    private var lastStats = ""

    static func main() {
        let app = NSApplication.shared
        let delegate = ReceiverAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        preventSleep()

        client.onPixelBuffer = { [weak self] pb in self?.videoView.display(pb) }
        client.onState = { [weak self] s in self?.render(state: s) }
        client.start()
        render(state: client.state)

        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let s = self.client.takeStats()
            self.lastStats = s.summary
            self.overlay.stringValue = s.summary
            if s.fps > 0, Int(Date().timeIntervalSince1970) % 5 == 0 { Log.info("统计：\(s.summary)") }
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            switch e.keyCode {
            case 53: NSApp.terminate(nil); return nil            // Esc
            case 1: self.toggleStats(); return nil                // S
            default: return e
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
        CGDisplayShowCursor(CGMainDisplayID())
    }

    // MARK: - 窗口

    private func buildWindow() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        // 调试：-windowed YES 用普通窗口（同一台机器上自测，不占满屏幕）
        let windowed = UserDefaults.standard.bool(forKey: "windowed")
        Log.info("Air 屏幕：\(Int(screen.frame.width))×\(Int(screen.frame.height)) 点 @\(Int(screen.backingScaleFactor))x")
        let frame = windowed ? NSRect(x: 80, y: 80, width: 720, height: 466) : screen.frame
        window = KeyableWindow(contentRect: frame, styleMask: windowed ? [.titled, .closable, .resizable] : [.borderless],
                               backing: .buffered, defer: false)
        window.title = "AirDisplay Receiver（调试窗口）"
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]

        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        videoView.frame = root.bounds
        videoView.autoresizingMask = [.width, .height]
        root.addSubview(videoView)

        message.font = .systemFont(ofSize: 22, weight: .medium)
        message.textColor = .white
        message.alignment = .center
        message.maximumNumberOfLines = 0
        message.frame = NSRect(x: 40, y: root.bounds.midY - 80, width: root.bounds.width - 80, height: 160)
        message.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        root.addSubview(message)

        overlay.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        overlay.textColor = .white
        overlay.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        overlay.drawsBackground = true
        overlay.frame = NSRect(x: 12, y: root.bounds.height - 34, width: root.bounds.width - 24, height: 22)
        overlay.autoresizingMask = [.width, .minYMargin]
        overlay.isHidden = true
        root.addSubview(overlay)

        window.contentView = root
        window.setFrame(frame, display: true)
        if !windowed { NSApp.presentationOptions = [.hideDock, .hideMenuBar] }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func render(state: StreamClient.State) {
        switch state {
        case .searching(let hint):
            message.stringValue = "AirDisplay 接收端\n\(hint)\n\n按 Esc 退出"
            message.isHidden = false
            CGDisplayShowCursor(CGMainDisplayID())
        case .connecting(let iface):
            message.stringValue = "正在通过 \(iface) 连接…"
            message.isHidden = false
        case .connected:
            message.isHidden = true
            // 光标已经画在画面里，隐藏 Air 自己的
            if !UserDefaults.standard.bool(forKey: "windowed") { CGDisplayHideCursor(CGMainDisplayID()) }
        }
    }

    private func toggleStats() {
        showStats.toggle()
        overlay.isHidden = !showStats
    }

    private func preventSleep() {
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "AirDisplay 正在显示画面" as CFString, &sleepAssertion)
        Log.info("防休眠：\(r == kIOReturnSuccess ? "已开启" : "失败")")
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 AirDisplay Receiver", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}

/// 无边框窗口默认不能成为 key window，收不到键盘
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
