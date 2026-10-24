import AppKit
import IOKit.pwr_mgt

/// Air 上的接收 App：全屏显示 Pro 推过来的画面，并把本机键鼠转发给 Pro（M5）。
/// ⌃⌥⌘S 开关统计浮层，⌃⌥⌘Q 退出。
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
    /// 断线后延迟退出全屏（短暂断线不闪）
    private var pendingHide: DispatchWorkItem?
    private var hasConnectedOnce = false
    private var isFullscreenShown = false

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

        // 快捷键：⌃⌥⌘Q 退出，⌃⌥⌘S 统计浮层（其他按键全屏时都转发给 Pro）
        let hotkeyMods: NSEvent.ModifierFlags = [.control, .option, .command]
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == hotkeyMods {
                switch e.keyCode {
                case 12: NSApp.terminate(nil); return nil       // Q
                case 1: self.toggleStats(); return nil          // S
                default: break
                }
            }
            return self.forward(e) ? nil : e
        }
        NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .keyUp, .flagsChanged,
        ]) { [weak self] e in
            guard let self else { return e }
            return self.forward(e) ? nil : e
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
        CGDisplayShowCursor(CGMainDisplayID())
    }

    // MARK: - 窗口
    //
    // 没连上时只是一个普通的小状态窗口（系统的权限弹窗不会被挡住）；
    // 连上后切成无边框全屏；断开 3 秒后退回小窗口。

    private let statusSize = NSSize(width: 620, height: 300)
    private var isDebugWindowed: Bool { UserDefaults.standard.bool(forKey: "windowed") }

    private func buildWindow() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        Log.info("Air 屏幕：\(Int(screen.frame.width))×\(Int(screen.frame.height)) 点 @\(Int(screen.backingScaleFactor))x")
        window = KeyableWindow(contentRect: NSRect(origin: .zero, size: statusSize),
                               styleMask: [.titled, .closable, .miniaturizable],
                               backing: .buffered, defer: false)
        window.title = "AirDisplay Receiver"
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true

        let root = NSView(frame: NSRect(origin: .zero, size: statusSize))
        videoView.frame = root.bounds
        videoView.autoresizingMask = [.width, .height]
        root.addSubview(videoView)

        message.font = .systemFont(ofSize: 15, weight: .medium)
        message.textColor = .white
        message.alignment = .center
        message.maximumNumberOfLines = 0
        message.frame = root.bounds.insetBy(dx: 24, dy: 24)
        message.autoresizingMask = [.width, .height]
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
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isFullscreenShown = false
    }

    private func render(state: StreamClient.State) {
        switch state {
        case .searching(let hint):
            message.stringValue = "AirDisplay 接收端\n\n\(hint)\n\n连上后会自动全屏。全屏时 ⌃⌥⌘Q 退出，⌃⌥⌘S 看统计。"
            message.isHidden = false
            CGDisplayShowCursor(CGMainDisplayID())
            if isFullscreenShown { scheduleExitFullscreen() }
        case .connecting(let iface):
            message.stringValue = "正在通过 \(iface) 连接…\n\n如果系统询问「查找本地网络上的设备」，请点「允许」。"
            message.isHidden = false
        case .connected:
            hasConnectedOnce = true
            pendingHide?.cancel()
            pendingHide = nil
            message.isHidden = true
            enterFullscreen()
        }
    }

    /// 断开 3 秒还没连回来就退回小窗口，Air 恢复正常桌面
    private func scheduleExitFullscreen() {
        guard pendingHide == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingHide = nil
            if case .connected = self.client.state { return }
            Log.info("断开超过 3 秒，退出全屏，等待重新连接")
            self.exitFullscreen()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func showFullscreenFromDock() {
        isFullscreenShown = false
        enterFullscreen()
    }

    private func enterFullscreen() {
        guard !isFullscreenShown else { return }
        Log.info("已连接，进入全屏")
        if !isDebugWindowed, let screen = window.screen ?? NSScreen.main {
            window.styleMask = [.borderless]
            window.setFrame(screen.frame, display: true)
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            // 光标已经画在画面里，隐藏 Air 自己的
            CGDisplayHideCursor(CGMainDisplayID())
        } else {
            window.setContentSize(NSSize(width: 720, height: 466))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isFullscreenShown = true
    }

    private func exitFullscreen() {
        NSApp.presentationOptions = []
        CGDisplayShowCursor(CGMainDisplayID())
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "AirDisplay Receiver"
        window.setContentSize(statusSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        isFullscreenShown = false
    }

    // MARK: - M5 键鼠转发

    private var forwardInput: Bool {
        get { UserDefaults.standard.object(forKey: "forwardInput") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "forwardInput") }
    }

    /// 全屏且已连接时，把事件发给 Pro；返回 true 表示本地吞掉
    private func forward(_ e: NSEvent) -> Bool {
        guard forwardInput, isFullscreenShown, case .connected = client.state, e.window === window || e.window == nil else {
            return false
        }
        var ev: InputEvent
        let flags = UInt32(truncatingIfNeeded: e.cgEvent?.flags.rawValue ?? 0)
        switch e.type {
        case .mouseMoved: ev = InputEvent(kind: .mouseMove)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: ev = InputEvent(kind: .mouseDown)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: ev = InputEvent(kind: .mouseUp)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: ev = InputEvent(kind: .mouseDrag)
        case .scrollWheel:
            ev = InputEvent(kind: e.hasPreciseScrollingDeltas ? .scrollPixel : .scrollLine)
            ev.dx = Float(e.scrollingDeltaX)
            ev.dy = Float(e.scrollingDeltaY)
            ev.flags = flags
            client.sendInput(ev)
            return true
        case .keyDown: ev = InputEvent(kind: .keyDown)
        case .keyUp: ev = InputEvent(kind: .keyUp)
        case .flagsChanged: ev = InputEvent(kind: .flagsChanged)
        default: return false
        }
        ev.flags = flags
        switch e.type {
        case .keyDown, .keyUp, .flagsChanged:
            ev.keyCode = e.keyCode
        default:
            // 鼠标：换算成视频画面里的相对位置（左上角为原点）
            let rect = videoRect()
            let p = e.locationInWindow
            ev.x = Float((p.x - rect.minX) / rect.width)
            ev.y = Float(1 - (p.y - rect.minY) / rect.height)
            ev.button = UInt8(clamping: e.buttonNumber)
            ev.clickCount = UInt8(clamping: max(e.clickCount, 1))
        }
        client.sendInput(ev)
        return true
    }

    /// 视频在窗口里实际显示的区域（按比例缩放、居中）
    private func videoRect() -> CGRect {
        let bounds = window.contentView?.bounds ?? .zero
        let aspect = client.videoAspect ?? (bounds.width / max(bounds.height, 1))
        var w = bounds.width, h = w / aspect
        if h > bounds.height { h = bounds.height; w = h * aspect }
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    @objc func toggleForwardInput(_ sender: NSMenuItem) {
        forwardInput.toggle()
        sender.state = forwardInput ? .on : .off
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
        let login = NSMenuItem(title: "登录时自动打开", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        appMenu.addItem(login)
        let fwd = NSMenuItem(title: "用本机键盘和触控板操作 Pro", action: #selector(toggleForwardInput(_:)), keyEquivalent: "")
        fwd.target = self
        fwd.state = forwardInput ? .on : .off
        appMenu.addItem(fwd)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 AirDisplay Receiver", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}

extension ReceiverAppDelegate {
    @objc func toggleLoginItem(_ sender: NSMenuItem) {
        sender.state = LoginItem.set(sender.state != .on) ? .on : .off
    }

    /// 点 Dock 图标时，如果已连接就回到全屏
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if case .connected = client.state { showFullscreenFromDock() }
        return true
    }
}

/// 无边框窗口默认不能成为 key window，收不到键盘
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
