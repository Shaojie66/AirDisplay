import AppKit
import ApplicationServices

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let virtualDisplay = VirtualDisplay()
    private let loopback = Loopback()
    private let server = StreamServer()
    private let injector = InputInjector()
    private let controlPanel = ControlPanel()
    private var statusItem: NSStatusItem!
    private var lastStats: String?
    /// Air 断开后延迟移除虚拟屏（短暂断线不折腾窗口）
    private var pendingRemoval: DispatchWorkItem?
    private let removalDelay: TimeInterval = 3
    /// Air 连上才建虚拟屏、断开就移除。默认开。
    private var autoManageDisplay: Bool {
        get { UserDefaults.standard.object(forKey: "autoManageDisplay") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoManageDisplay") }
    }
    private var statsTimer: Timer?

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

        virtualDisplay.onTerminated = { [weak self] in
            self?.loopback.stop()
            self?.logDisplays()
            self?.refreshPanel()
        }
        loopback.onStopped = { [weak self] in
            self?.lastStats = nil
            self?.refreshPanel()
        }
        controlPanel.toggles = [
            .init(title: "Air 断开时移除虚拟屏（窗口回到主屏）",
                  get: { [weak self] in self?.autoManageDisplay ?? true },
                  set: { [weak self] v in self?.autoManageDisplay = v }),
            .init(title: "4:4:4 色度：彩色小字更清晰（延迟约 +8 ms，码率约 3 倍）",
                  get: { UserDefaults.standard.bool(forKey: "chroma444") },
                  set: { [weak self] v in
                      UserDefaults.standard.set(v, forKey: "chroma444")
                      self?.server.restartStreamingIfActive()
                  }),
            .init(title: "允许用 Air 的键盘和触控板操作（需要「辅助功能」权限）",
                  get: { UserDefaults.standard.object(forKey: "allowAirInput") as? Bool ?? true },
                  set: { v in
                      UserDefaults.standard.set(v, forKey: "allowAirInput")
                      if v && !InputInjector.isTrusted {
                          let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                          _ = AXIsProcessTrustedWithOptions(opts)
                      }
                  }),
            .init(title: "登录时自动打开 AirDisplay Sender",
                  get: { LoginItem.isEnabled },
                  set: { v in LoginItem.set(v) }),
        ]
        controlPanel.actions = .init(
            toggleDisplay: { [weak self] in
                guard let self else { return }
                self.virtualDisplay.isRunning ? self.stopDisplay() : self.startDisplay()
            },
            toggleLoopback: { [weak self] in
                guard let self else { return }
                self.loopback.isRunning ? self.loopback.stop() : self.startLoopback()
            }
        )

        server.displayProvider = { [weak self] in
            guard let self else { return nil }
            if !self.virtualDisplay.isRunning { self.startDisplay() }
            guard let id = self.virtualDisplay.displayID, let c = self.virtualDisplay.config else { return nil }
            return (id, c)
        }
        server.prefer444 = { UserDefaults.standard.bool(forKey: "chroma444") }
        // M5：Air 的键鼠 → 注入到虚拟屏
        injector.isEnabled = { UserDefaults.standard.object(forKey: "allowAirInput") as? Bool ?? true }
        injector.displayBounds = { [weak self] in
            guard let id = self?.virtualDisplay.displayID else { return nil }
            return CGDisplayBounds(id)
        }
        let injector = self.injector
        server.onInput = { ev in injector.handle(ev) }
        server.onInputPeerGone = { injector.releaseAll() }
        server.onStateChange = { [weak self] state in
            self?.handleServerState(state)
            self?.refreshPanel()
        }
        server.start()
        VirtualDisplay.watchReconfiguration()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.logDisplays()
            self?.refreshPanel()
        }

        // 测试用启动参数
        let args = CommandLine.arguments
        if args.contains("--start") || args.contains("--loopback") { startDisplay() }
        logDisplays()
        if args.contains("--test-windows") || args.contains("--loopback") {
            // 等新屏幕登记进 NSScreen 再放窗口
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.showTestWindows() }
        }
        if args.contains("--loopback") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { self.startLoopback() }
        }
        // 测试用：-snapshot <tag> 在回环开始 6 秒后保存一组对比截图
        if let tag = UserDefaults.standard.string(forKey: "snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { self.loopback.snapshot.request(tag: tag) }
        }

        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickStats() }
        refreshPanel()
        controlPanel.show()
    }

    /// 再次打开 App（双击、Spotlight）时把控制面板叫出来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controlPanel.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
        loopback.stop()
        virtualDisplay.stop()
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled: displayStatus())
        menu.addItem(withTitle: virtualDisplay.isRunning ? "关闭虚拟屏" : "开启虚拟屏",
                     action: virtualDisplay.isRunning ? #selector(stopDisplay) : #selector(startDisplay),
                     keyEquivalent: "")
        menu.addItem(withTitle: loopback.isRunning ? "停止本机回环" : "开始本机回环（M2）",
                     action: #selector(toggleLoopbackFromMenu), keyEquivalent: "")
        if let s = lastStats {
            for line in s.split(separator: "\n") { menu.addItem(disabled: String(line)) }
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

    // MARK: - 动作

    @objc private func startDisplay() {
        do {
            try virtualDisplay.start(.air15)
        } catch {
            Log.info("开启失败：\(error.localizedDescription)")
        }
        refreshPanel()
    }

    @objc private func stopDisplay() {
        loopback.stop()
        virtualDisplay.stop()
        refreshPanel()
    }

    @objc private func toggleLoopbackFromMenu() {
        loopback.isRunning ? loopback.stop() : startLoopback()
    }

    private func startLoopback() {
        // 屏幕录制权限：没有就让系统弹授权框
        guard CGPreflightScreenCaptureAccess() else {
            Log.info("没有屏幕录制权限，请求授权")
            CGRequestScreenCaptureAccess()
            // 不用模态弹窗（会卡住整个 App 的按钮），提示写在面板上
            lastStats = "⚠️ 需要「屏幕录制」权限：系统设置 → 隐私与安全性 → 屏幕与系统音频录制 → 打开 AirDisplaySender，然后重新打开本 App。"
            refreshPanel()
            return
        }
        if !virtualDisplay.isRunning { startDisplay() }
        guard let id = virtualDisplay.displayID, let config = virtualDisplay.config else { return }
        Task { @MainActor in
            do {
                try await loopback.start(displayID: id, config: config)
            } catch {
                Log.info("本机回环启动失败：\(error.localizedDescription)")
                loopback.stop()
            }
            refreshPanel()
        }
    }

    @objc private func showTestWindows() { Log.info("菜单：放测试窗口"); TestPattern.show(on: NSScreen.screens) }
    @objc private func closeTestWindows() { Log.info("菜单：关测试窗口"); TestPattern.close() }
    @objc private func showPanel() { controlPanel.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - 自动管理虚拟屏

    private func handleServerState(_ state: StreamServer.State) {
        switch state {
        case .streaming:
            pendingRemoval?.cancel()
            pendingRemoval = nil
        case .listening, .stopped:
            guard autoManageDisplay, virtualDisplay.isRunning, !loopback.isRunning else { return }
            pendingRemoval?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if case .streaming = self.server.state { return }
                guard !self.loopback.isRunning else { return }
                Log.info("Air 已断开 \(Int(self.removalDelay)) 秒，等显示器配置稳定后移除虚拟屏")
                self.virtualDisplay.stopWhenDisplaysSettle(shouldProceed: { [weak self] in
                    guard let self else { return false }
                    if case .streaming = self.server.state { return false }
                    return self.autoManageDisplay && !self.loopback.isRunning
                }, done: { [weak self] in
                    self?.refreshPanel()
                })
            }
            pendingRemoval = work
            DispatchQueue.main.asyncAfter(deadline: .now() + removalDelay, execute: work)
        }
    }

    // MARK: - 状态

    private func serverStatus() -> String {
        switch server.state {
        case .stopped: return "网络：未启动"
        case .listening: return "网络：等待 Air 连接（雷雳网桥）"
        case .streaming(_, let iface): return "网络：Air 已连接（\(iface)），推流 \(server.codecDescription)"
        }
    }

    private func displayStatus() -> String {
        let count = DisplayInfo.online().count
        if virtualDisplay.isRunning, let c = virtualDisplay.config {
            var s = "虚拟屏运行中：\(c.pointWidth)×\(c.pointHeight) @2x，\(Int(c.refreshRate))Hz · 在线显示器 \(count) 块"
            if loopback.isRunning { s += "\n回环编码：\(loopback.codecDescription)" }
            return s + "\n" + serverStatus()
        }
        return "虚拟屏未开启 · 在线显示器 \(count) 块\n" + serverStatus()
    }

    private func refreshPanel() {
        controlPanel.update(display: displayStatus(), displayRunning: virtualDisplay.isRunning,
                            loopbackRunning: loopback.isRunning, stats: lastStats)
    }

    private var statsTicks = 0
    private func tickStats() {
        let streaming: Bool
        if case .streaming = server.state { streaming = true } else { streaming = false }
        guard loopback.isRunning || streaming else { return }
        let s = streaming ? server.stats.take() : loopback.stats.take()
        lastStats = streaming ? String(format: "推流：抓屏 %.0f fps · 发送 %.0f fps · 编码 %.1f ms · %.1f Mbps · 关键帧 %d",
                                       s.capturedFPS, s.encodedFPS, s.encodeAvgMs, s.mbps, s.keyframes) : s.summary
        refreshPanel()
        statsTicks += 1
        if statsTicks % 5 == 0 { Log.info("统计：" + (lastStats ?? "").replacingOccurrences(of: "\n", with: " | ")) }
    }

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
