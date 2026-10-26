import AppKit
import ApplicationServices

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let virtualDisplay = VirtualDisplay()
    private let operationGate = OperationGate()
    private lazy var loopback = Loopback(gate: operationGate)
    private lazy var server = StreamServer(gate: operationGate)
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
    private var recovery = RecoveryPolicy()
    private let sidecarController = SidecarController()
    private lazy var sidecarAutomation = SidecarAutomation(transport: sidecarController)
    private var reconnectTrigger = SidecarReconnectTrigger()
    private var eventBindingStability = TopologyStability()
    private var eventBindingAttempted = false
    private var automaticRecoveryStatus = "等待稳定三屏环境"
    private var autoRecoverSidecar: Bool { UserDefaults.standard.bool(forKey: "autoRecoverSidecar") }
    private var recoveryToken: UInt64 = 0
    private var recoveryTimer: Timer?
    private var changingDisplay = false
    private var manualStopStartedAt: TimeInterval?
    private var manualStopToken: UInt64?
    private var recoveryNotice: String?
    private var recoveryBaseline: TopologySnapshot?
    private let processRun = UUID().uuidString.prefix(8)
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

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
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        virtualDisplay.onTerminated = { [weak self] in
            self?.pauseRecovery("系统主动移除虚拟屏，已暂停输入和推流")
        }
        loopback.onStopped = { [weak self] in
            self?.lastStats = nil
            self?.refreshPanel()
        }
        controlPanel.toggles = [
            .init(title: "自动恢复随航连接",
                  detail: "iPad 重连后自动重置显示连接，最后仍需核对画面。",
                  get: { [weak self] in self?.autoRecoverSidecar ?? false },
                  set: { [weak self] value in self?.setAutomaticSidecarRecovery(value) }),
            .init(title: "断开 Air 时收回桌面",
                  detail: "约 3 秒后关闭扩展屏，将窗口移回主屏。",
                  get: { [weak self] in self?.autoManageDisplay ?? true },
                  set: { [weak self] v in self?.autoManageDisplay = v }),
            .init(title: "更清晰的彩色小字（4:4:4）",
                  detail: "可能增加延迟和带宽，默认关闭。", section: .advanced,
                  get: { UserDefaults.standard.bool(forKey: "chroma444") },
                  set: { [weak self] v in
                      UserDefaults.standard.set(v, forKey: "chroma444")
                      self?.server.restartStreamingIfActive()
                  }),
            .init(title: "使用 Air 的键盘和触控板",
                  detail: "将输入发送到扩展桌面，首次使用需要辅助功能权限。",
                  get: { UserDefaults.standard.object(forKey: "allowAirInput") as? Bool ?? true },
                  set: { v in
                      UserDefaults.standard.set(v, forKey: "allowAirInput")
                      if v && !InputInjector.isTrusted {
                          let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                          _ = AXIsProcessTrustedWithOptions(opts)
                      }
                  }),
            .init(title: "登录时启动",
                  get: { LoginItem.isEnabled },
                  set: { v in LoginItem.set(v) }),
        ]
        controlPanel.actions = .init(
            toggleDisplay: { [weak self] in
                guard let self else { return }
                self.virtualDisplay.isRunning ? self.stopDisplay() : self.startDisplay()
            },
            toggleLoopback: { [weak self] in
                guard let self, self.recovery.isIdle, !self.changingDisplay else { return }
                self.loopback.isRunning ? self.loopback.stop() : self.startLoopback()
            }
        )

        controlPanel.recoveryActions = .init(
            begin: { [weak self] in self?.beginRecovery() },
            cancel: { [weak self] in self?.cancelRecovery() },
            resumeOnly: { [weak self] in self?.resumeDisplayOnly() },
            confirm: { [weak self] in self?.confirmRecovery() },
            failed: { [weak self] in self?.reportRecoveryFailure() },
            showMarkers: { [weak self] in self?.showTestWindows() }
        )

        server.displayProvider = { [weak self] in
            guard let self, !self.changingDisplay, self.operationGate.ticket != nil else { return nil }
            if !self.virtualDisplay.isRunning {
                guard self.recovery.isIdle else { return nil }
                self.startDisplay()
            }
            guard let id = self.virtualDisplay.displayID, let c = self.virtualDisplay.config else { return nil }
            return (id, c)
        }
        server.prefer444 = { UserDefaults.standard.bool(forKey: "chroma444") }
        // M5：Air 的键鼠 → 注入到虚拟屏
        injector.isEnabled = { UserDefaults.standard.object(forKey: "allowAirInput") as? Bool ?? true }
        injector.displayBounds = { [weak self] in
            guard let id = self?.virtualDisplay.displayID, CGDisplayIsOnline(id) != 0,
                  CGDisplayIsActive(id) != 0 else { return nil }
            return CGDisplayBounds(id)
        }
        let injector = self.injector
        server.onInput = { ev in injector.handle(ev) }
        server.onInputPeerGone = { injector.releaseAll() }
        server.onStateChange = { [weak self] state in
            self?.handleServerState(state)
            self?.refreshPanel()
        }
        server.onFailure = { [weak self] message in
            guard let self else { return }
            if !self.recovery.isIdle && !self.isRecoveryPaused { self.pauseRecovery(message) }
            else { self.lastStats = message; self.refreshPanel() }
        }
        server.start()
        VirtualDisplay.watchReconfiguration()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.logDisplays()
                self?.refreshPanel()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.logDisplays()
                if !self.recovery.isIdle && !self.isRecoveryPaused {
                    self.pauseRecovery("Mac 已从睡眠唤醒，请重新开始恢复并核对画面")
                }
            }
        }

        // 测试用启动参数
        let args = CommandLine.arguments
        let launchTicket = operationGate.ticket
        if args.contains("--start") || args.contains("--loopback") { startDisplay() }
        logDisplays()
        if args.contains("--test-windows") || args.contains("--loopback") {
            // 等新屏幕登记进 NSScreen 再放窗口
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let launchTicket, self.operationGate.isCurrent(launchTicket), self.recovery.isIdle else { return }
                self.showTestWindows()
            }
        }
        if args.contains("--loopback") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard let launchTicket, self.operationGate.isCurrent(launchTicket), self.recovery.isIdle else { return }
                self.startLoopback()
            }
        }
        // 测试用：-snapshot <tag> 在回环开始 6 秒后保存一组对比截图
        if let tag = UserDefaults.standard.string(forKey: "snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                guard let launchTicket, self.operationGate.isCurrent(launchTicket), self.recovery.isIdle else { return }
                self.loopback.snapshot.request(tag: tag)
            }
        }

        // 两个 Timer 都在主线程 RunLoop 创建；通知也明确指定了 .main 队列。
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickStats() }
        }
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickRecovery() }
        }
        Log.info("Sender 进程会话 \(processRun)；恢复入口为实验状态")
        refreshPanel()
        controlPanel.show()
    }

    /// 再次打开 App（双击、Spotlight）时把控制面板叫出来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controlPanel.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        sidecarAutomation.cancel()
        operationGate.block { injector.releaseAll() }
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
        for item in menu.items where item.action != nil { item.isEnabled = recovery.isIdle && !changingDisplay }
        menu.addItem(.separator())
        menu.addItem(withTitle: "恢复显示连接…", action: #selector(openRecovery), keyEquivalent: "")
        menu.items.last?.isEnabled = !changingDisplay
        menu.addItem(withTitle: "核对三屏画面…", action: #selector(openRecovery), keyEquivalent: "")
        menu.items.last?.isEnabled = recovery.phase == .awaitingConfirmation && recovery.canConfirm && server.hasDeliveredFrame
        menu.addItem(withTitle: "取消恢复（保持暂停）", action: #selector(cancelRecovery), keyEquivalent: "")
        menu.items.last?.isEnabled = !recovery.isIdle && !isRecoveryPaused
        menu.addItem(withTitle: "仅恢复 AirDisplay（不代表随航已修复）", action: #selector(resumeDisplayOnly), keyEquivalent: "")
        menu.items.last?.isEnabled = isRecoveryPaused
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
        guard recovery.isIdle, !changingDisplay, operationGate.ticket != nil else { return }
        pendingRemoval?.cancel(); pendingRemoval = nil
        virtualDisplay.cancelPendingRemoval()
        do {
            try virtualDisplay.start(.air15)
        } catch {
            Log.info("开启失败：\(error.localizedDescription)")
        }
        if virtualDisplay.isRunning { server.resume() }
        refreshPanel()
    }

    @objc private func stopDisplay() {
        guard recovery.isIdle, !changingDisplay else { return }
        changingDisplay = true
        let ticket = operationGate.block { injector.releaseAll() }
        manualStopStartedAt = now; manualStopToken = ticket
        pendingRemoval?.cancel(); virtualDisplay.cancelPendingRemoval()
        Task { @MainActor in
            do {
                guard operationGate.owns(ticket) else { return }
                try await server.pauseAndWait()
                guard operationGate.owns(ticket) else { return }
                try await loopback.stopAndWait()
                guard operationGate.owns(ticket) else { return }
                virtualDisplay.stop()
                operationGate.reopenAfterManualStop(ticket)
                changingDisplay = false; manualStopStartedAt = nil; manualStopToken = nil
                refreshPanel()
            } catch {
                guard operationGate.owns(ticket) else { return }
                changingDisplay = false; manualStopStartedAt = nil; manualStopToken = nil
                pauseRecovery("停止抓屏失败，虚拟屏已保留")
            }
        }
        refreshPanel()
    }

    @objc private func toggleLoopbackFromMenu() {
        guard recovery.isIdle, !changingDisplay else { return }
        loopback.isRunning ? loopback.stop() : startLoopback()
    }

    private func startLoopback() {
        guard recovery.isIdle, !changingDisplay, let ticket = operationGate.ticket else { return }
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
                guard operationGate.isCurrent(ticket), recovery.isIdle else { return }
                try await loopback.start(displayID: id, config: config)
            } catch {
                guard operationGate.isCurrent(ticket), recovery.isIdle else { return }
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
        guard recovery.isIdle, !changingDisplay else { return }
        switch state {
        case .streaming:
            pendingRemoval?.cancel()
            pendingRemoval = nil
            virtualDisplay.cancelPendingRemoval()
        case .listening, .stopped:
            guard autoManageDisplay, virtualDisplay.isRunning, !loopback.isActive, !server.hasPeer else { return }
            pendingRemoval?.cancel()
            let instance = virtualDisplay.instanceToken
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.virtualDisplay.instanceToken == instance else { return }
                guard self.recovery.isIdle, !self.changingDisplay else { return }
                guard !self.server.hasPeer, !self.loopback.isActive else { return }
                Log.info("Air 已断开 \(Int(self.removalDelay)) 秒，等显示器配置稳定后移除虚拟屏")
                self.virtualDisplay.stopWhenDisplaysSettle(shouldProceed: { [weak self] in
                    guard let self else { return false }
                    guard !self.server.hasPeer else { return false }
                    return self.recovery.isIdle && !self.changingDisplay && self.autoManageDisplay && !self.loopback.isActive
                }, done: { [weak self] in
                    self?.refreshPanel()
                }, onTimeout: { [weak self] in
                    self?.lastStats = "显示器配置未稳定，保留虚拟屏；可稍后手动关闭"
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
        if !recovery.isIdle { return recoveryStatus }
        if changingDisplay { return "正在停止抓屏，启动与远程输入已暂停" }
        let count = DisplayInfo.online().count
        if virtualDisplay.isRunning, let c = virtualDisplay.config {
            var s = "虚拟屏运行中：\(c.pointWidth)×\(c.pointHeight) @2x，\(Int(c.refreshRate))Hz · 在线显示器 \(count) 块"
            if loopback.isRunning { s += "\n回环编码：\(loopback.codecDescription)" }
            return s + "\n" + serverStatus()
        }
        return "虚拟屏未开启 · 在线显示器 \(count) 块\n" + serverStatus()
    }

    private func refreshPanel() {
        controlPanel.refreshToggleValues()
        let connection: ControlPanel.Status.Connection
        if changingDisplay { connection = .stopping }
        else {
            switch server.state {
            case .streaming: connection = .streaming
            case .listening: connection = .waiting
            case .stopped: connection = .stopped
            }
        }
        let input: ControlPanel.Status.Input
        if !recovery.isIdle || changingDisplay { input = .paused }
        else if !(UserDefaults.standard.object(forKey: "allowAirInput") as? Bool ?? true) { input = .disabled }
        else if !InputInjector.isTrusted { input = .permissionRequired }
        else if server.deliveryID == nil { input = .waiting }
        else { input = .enabled }
        let specification = virtualDisplay.config.map { config in
            let transport = connection == .streaming ? "雷雳网桥" : "扩展屏已开启"
            return "\(transport) · \(config.pointWidth) × \(config.pointHeight) 点 @2x · \(Int(config.refreshRate)) Hz"
        }
        let status = ControlPanel.Status(connection: connection, specification: specification, input: input,
                                         automaticRecovery: autoRecoverSidecar ? automaticRecoveryStatus : nil,
                                         diagnostic: displayStatus())
        controlPanel.update(status: status, displayRunning: virtualDisplay.isRunning,
                            loopbackRunning: loopback.isRunning, stats: lastStats,
                            actionsEnabled: recovery.isIdle && !changingDisplay)
        controlPanel.updateRecovery(
            RecoveryPresentation(policy: recovery, frameID: server.deliveryID,
                                 changingDisplay: changingDisplay),
            operation: recoveryToken, notice: recoveryNotice
        )
    }

    private var statsTicks = 0
    private func tickStats() {
        guard recovery.isIdle, !changingDisplay else { return }
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
        guard let snapshot = DisplayInfo.topology() else { Log.info("显示器快照无效"); return }
        Log.info("在线显示器：" + snapshot.displays.map {
            "id=\($0.id) builtin=\($0.builtin) main=\($0.main) \($0.width)x\($0.height) at=(\($0.x),\($0.y))"
        }.joined(separator: "; "))
    }

    // MARK: - 最小恢复实验（系统随航连接仍由用户操作）

    private var isRecoveryPaused: Bool { if case .paused = recovery.phase { return true }; return false }
    private var recoveryStatus: String {
        let model = RecoveryPresentation(policy: recovery, frameID: server.deliveryID)
        return "显示连接恢复 · 远程输入已暂停\n" + model.title
    }

    @objc private func openRecovery() {
        refreshPanel()
        controlPanel.showRecovery()
    }

    @objc private func beginRecovery() {
        guard controlPanel.confirmedSidecar else { return }
        startRecovery(method: controlPanel.recoveryMethod)
    }

    private func setAutomaticSidecarRecovery(_ enabled: Bool) {
        if enabled {
            var baseline = RecoveryPolicy()
            guard recovery.isIdle, !changingDisplay, virtualDisplay.displayID != nil,
                  baseline.begin(DisplayInfo.topology(), ownedID: virtualDisplay.displayID, now: now) else {
                recoveryNotice = "尚未开启自动恢复：请在内建主屏、AirDisplay 和一台 iPad 随航均在线时开启。"
                refreshPanel(); controlPanel.showRecovery(); return
            }
        }
        UserDefaults.standard.set(enabled, forKey: "autoRecoverSidecar")
        reconnectTrigger.reset(); eventBindingStability.reset()
        sidecarController.clearEventTarget(); eventBindingAttempted = false
        automaticRecoveryStatus = enabled ? "正在绑定当前 iPad 并建立稳定基线" : "已关闭"
        refreshPanel()
    }

    private func tickSidecarReconnect() {
        guard autoRecoverSidecar else { return }
        let previousStatus = automaticRecoveryStatus
        defer { if previousStatus != automaticRecoveryStatus { refreshPanel() } }
        guard !sidecarAutomation.hasUnresolvedRequest else {
            reconnectTrigger.reset(); eventBindingStability.reset()
            automaticRecoveryStatus = "系统连接请求尚未返回，暂停自动触发"
            return
        }
        let snapshot = DisplayInfo.topology()
        let owned = virtualDisplay.displayID
        if !sidecarController.hasWatchedTarget {
            guard !eventBindingAttempted else { return }
            guard let owned, eventBindingStability.observe(snapshot, now: now, reconfiguredAt: VirtualDisplay.lastReconfigAt) else { return }
            var baseline = RecoveryPolicy()
            guard baseline.begin(snapshot, ownedID: owned, now: now) else { return }
            eventBindingAttempted = true
            do {
                try sidecarController.bindEventTarget()
                automaticRecoveryStatus = "正在建立监测基线"
                Log.info("随航自动恢复：已绑定唯一已连接目标；身份仅保留在内存")
            } catch {
                automaticRecoveryStatus = "无法绑定目标，请关闭再开启此开关，或使用手动恢复"
                Log.info("随航自动恢复：绑定失败，未发出系统连接请求")
                return
            }
        }
        let presence = sidecarController.eventPresence()
        let trigger = reconnectTrigger.observe(snapshot, presence: presence, ownedID: owned,
                                               suspended: false, now: now, reconfiguredAt: VirtualDisplay.lastReconfigAt)
        if presence == .other { automaticRecoveryStatus = "目标不一致，已停止监测；请关闭再开启开关" }
        else if presence == .unknown { automaticRecoveryStatus = "目标状态暂不可读，等待重新核验" }
        else if reconnectTrigger.awaitsReconnect { automaticRecoveryStatus = "已确认 iPad 离线，等待重新接入" }
        else if reconnectTrigger.isArmed { automaticRecoveryStatus = "监测中，iPad 重连后将自动恢复" }
        else { automaticRecoveryStatus = "等待稳定三屏环境建立基线" }
        guard trigger else { return }
        automaticRecoveryStatus = "已检测到随航重新上线，正在自动恢复"
        Log.info("随航自动恢复：消费一次外部重连事件，启动完整恢复")
        startRecovery(method: .automaticSidecar, fromEvent: true)
    }

    private func startRecovery(method: RecoveryMethod, fromEvent: Bool = false) {
        guard !changingDisplay else { return }
        if fromEvent { guard autoRecoverSidecar, recovery.isIdle else { return } }
        var queryFailure: String?
        let snapshot = DisplayInfo.topology { queryFailure = $0 }
        Log.info("请求开始恢复 phase=\(recovery.phase) owned=\(virtualDisplay.displayID.map(String.init) ?? "nil") snapshot=\(snapshot.map { String($0.displays.count) } ?? "nil") reason=\(queryFailure ?? "none")")
        var accepted = recovery.begin(snapshot, ownedID: virtualDisplay.displayID, now: now, method: method)
        if !accepted && isRecoveryPaused && recovery.hasBaseline {
            accepted = recovery.retry(ownedID: virtualDisplay.displayID, now: now, method: method)
        }
        guard accepted else {
            let reason = queryFailure ?? "当前在线显示器不符合内建主屏、AirDisplay 和一台 iPad 的环境要求"
            recoveryNotice = "尚未开始恢复：" + reason + "。请保持 iPad 随航在线后重试。"
            refreshPanel(); return
        }
        // 无 await：先锁所有入口、作废旧代号、排空正在执行的输入，再补发抬起。
        recoveryToken = operationGate.block { injector.releaseAll() }
        let ticket = recoveryToken
        recoveryBaseline = snapshot
        pendingRemoval?.cancel(); pendingRemoval = nil
        virtualDisplay.cancelPendingRemoval()
        TestPattern.close()
        recoveryNotice = nil
        lastStats = nil
        sidecarAutomation.cancel()
        reconnectTrigger.reset(); eventBindingStability.reset()
        if method == .automaticSidecar {
            do {
                sidecarController.requiresWatchedTarget = fromEvent
                defer { sidecarController.requiresWatchedTarget = false }
                try sidecarAutomation.start(operation: ticket, isCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.operationGate.owns(ticket) && !self.recovery.isIdle && !self.isRecoveryPaused
                }, onFailure: { [weak self] reason in
                    guard let self, self.operationGate.owns(ticket) else { return }
                    self.pauseRecovery(reason)
                })
                sidecarAutomation.onAction = { action in Log.info("自动随航请求：\(action)") }
            } catch {
                pauseRecovery(error.localizedDescription)
                controlPanel.showRecovery()
                return
            }
        }
        logRecovery()
        Task { @MainActor in
            do {
                guard recoveryToken == ticket, recovery.phase == .stopping else { return }
                try await server.pauseAndWait()
                guard recoveryToken == ticket, recovery.phase == .stopping else { return }
                try await loopback.stopAndWait()
                guard recoveryToken == ticket, recovery.phase == .stopping else { return }
                virtualDisplay.stop()
                recovery.stopped(now: now)
                logRecovery(); refreshPanel()
            } catch {
                guard recoveryToken == ticket else { return }
                pauseRecovery("停止旧抓屏失败，未移除虚拟屏")
            }
        }
        refreshPanel(); controlPanel.showRecovery()
    }

    private func tickRecovery() {
        if changingDisplay, let started = manualStopStartedAt, let token = manualStopToken,
           now - started >= 10, operationGate.owns(token) {
            changingDisplay = false; manualStopStartedAt = nil; manualStopToken = nil
            pauseRecovery("停止旧画面超过 10 秒，已保留虚拟屏")
            return
        }
        if !recovery.isIdle || changingDisplay {
            reconnectTrigger.reset(); eventBindingStability.reset()
        }
        if recovery.isIdle {
            if !changingDisplay { tickSidecarReconnect() }
            return
        }
        guard !isRecoveryPaused else { return }
        if recovery.phase == .awaitingConfirmation && server.deliveryID == nil {
            recovery.streamLost(now: now)
        }
        let before = recovery.phase
        recovery.checkDeadline(now: now)
        if case .paused(let reason) = recovery.phase { pauseRecovery(reason); return }
        sidecarAutomation.checkDeadline(now: now)
        guard !isRecoveryPaused else { return }
        let snapshot = DisplayInfo.topology()
        if recovery.method == .automaticSidecar {
            do {
                if recovery.phase == .waitingBuiltin {
                    // 停流结束且系统实际不再列出旧 AirDisplay 后，才调用系统随航断开。
                    guard let snapshot, snapshot.valid,
                          !snapshot.displays.contains(where: { $0.id == recovery.originalDisplayID }) else {
                        refreshPanel(); return
                    }
                    guard snapshot.displays.contains(where: { $0.id == recovery.builtinID && $0.builtin && $0.main }),
                          snapshot.displays.allSatisfy({ $0.id == recovery.builtinID || $0.id == recovery.originalSidecarID }) else {
                        pauseRecovery("自动断开前出现未知显示器，已停止自动操作"); return
                    }
                    recovery.recordOwnRemoval(snapshot)
                    guard try sidecarAutomation.ensure(.disconnect, operation: recoveryToken, now: now) else {
                        refreshPanel(); return
                    }
                } else if recovery.phase == .waitingSidecar {
                    if !sidecarAutomation.hasRequested(.connect) {
                        guard let snapshot, snapshot.valid, snapshot.displays.count == 1,
                              snapshot.displays[0].id == recovery.builtinID else {
                            pauseRecovery("自动连接前显示器状态已改变，已停止自动操作"); return
                        }
                    }
                    guard try sidecarAutomation.ensure(.connect, operation: recoveryToken, now: now) else {
                        refreshPanel(); return
                    }
                }
            } catch { pauseRecovery(error.localizedDescription); return }
        }
        let create = recovery.observe(snapshot, now: now, reconfiguredAt: VirtualDisplay.lastReconfigAt)
        if case .paused(let reason) = recovery.phase { pauseRecovery(reason); return }
        if create {
            do {
                try virtualDisplay.start(.air15)
                guard let id = virtualDisplay.displayID else { throw VirtualDisplay.Failure.createFailed }
                recovery.created(id, now: now)
            } catch { pauseRecovery("重建虚拟屏失败"); return }
        }
        if before != .waitingStream, recovery.phase == .waitingStream {
            guard operationGate.allowRecoveryStart(recoveryToken) else { return }
            server.resume()
        }
        if recovery.phase == .waitingStream, server.hasDeliveredFrame { recovery.frameDelivered(now: now) }
        if before != .awaitingConfirmation, recovery.phase == .awaitingConfirmation,
           let baseline = recoveryBaseline, let current = snapshot {
            let pairs: [(UInt32, UInt32?)] = [
                (recovery.builtinID, recovery.builtinID),
                (recovery.originalSidecarID, current.displays.first(where: { !$0.builtin && $0.id != virtualDisplay.displayID })?.id),
                (recovery.originalDisplayID, virtualDisplay.displayID)
            ]
            let changed = pairs.contains { oldID, newID in
                guard let old = baseline.displays.first(where: { $0.id == oldID }),
                      let new = current.displays.first(where: { $0.id == newID }) else { return false }
                return old.x != new.x || old.y != new.y || old.width != new.width || old.height != new.height
            }
            if changed { recoveryNotice = "显示器位置或尺寸与恢复前不同，请核对三屏排列；软件没有自动改写布局。" }
        }
        if before != recovery.phase { logRecovery() }
        refreshPanel()
    }

    private func pauseRecovery(_ reason: String) {
        sidecarAutomation.cancel()
        if sidecarAutomation.hasUnresolvedRequest {
            recoveryNotice = "已发出的系统连接请求无法撤回，可能稍后完成。自动请求返回前不会再次自动重连；请等待连接稳定后再操作。"
        }
        recovery.pause(reason, now: now)
        recoveryToken = operationGate.block { injector.releaseAll() }
        let ticket = recoveryToken
        pendingRemoval?.cancel(); virtualDisplay.cancelPendingRemoval()
        Task { @MainActor in
            do {
                guard recoveryToken == ticket else { return }
                try await server.pauseAndWait()
                guard recoveryToken == ticket else { return }
                try await loopback.stopAndWait()
            }
            catch { Log.info("暂停期间停止抓屏失败，保留显示器") }
        }
        logRecovery(); refreshPanel()
    }

    @objc private func cancelRecovery() {
        guard !recovery.isIdle, !isRecoveryPaused else { return }
        pauseRecovery("用户取消；推流和输入仍暂停")
    }

    private func reportRecoveryFailure() {
        guard recovery.phase == .awaitingConfirmation else { return }
        pauseRecovery("逐屏检查仍发现画面重复，本轮恢复未通过")
    }

    @objc private func resumeDisplayOnly() {
        guard isRecoveryPaused else { return }
        guard !sidecarAutomation.hasUnresolvedRequest else {
            recoveryNotice = SidecarControlFailure.pending.localizedDescription
            refreshPanel(); return
        }
        sidecarAutomation.cancel()
        recoveryNotice = nil
        recoveryToken = operationGate.block { injector.releaseAll() }
        let ticket = recoveryToken
        recovery.resumeManually(now: now)
        Task { @MainActor in
            do {
                guard recoveryToken == ticket, recovery.phase == .waitingStream else { return }
                try await server.pauseAndWait()
                guard recoveryToken == ticket, recovery.phase == .waitingStream else { return }
                try await loopback.stopAndWait()
                guard recoveryToken == ticket, recovery.phase == .waitingStream else { return }
                try virtualDisplay.start(.air15)
                guard operationGate.allowRecoveryStart(ticket) else { return }
                server.resume()
            } catch { if recoveryToken == ticket { pauseRecovery("手动恢复 AirDisplay 失败") } }
        }
        lastStats = "仅恢复 AirDisplay；未验证随航错配已修复"
        refreshPanel()
    }

    @objc private func confirmRecovery() {
        tickRecovery()
        guard recovery.phase == .awaitingConfirmation, recovery.canConfirm,
              let frameID = server.deliveryID,
              controlPanel.confirmationMatches(operation: recoveryToken, frameID: frameID),
              server.confirmInput(operation: recoveryToken, frameID: frameID), recovery.confirm() else { return }
        TestPattern.close()
        sidecarAutomation.cancel()
        controlPanel.finishRecovery()
        recoveryNotice = nil
        reconnectTrigger.reset(); eventBindingStability.reset()
        if autoRecoverSidecar { automaticRecoveryStatus = "正在重新建立监测基线" }
        lastStats = "本轮画面已由用户确认；重复恢复可靠性仍需设备验收"
        logRecovery(); refreshPanel()
    }

    private func logRecovery() {
        Log.info("恢复进程=\(processRun) 操作=\(recoveryToken) 方式=\(recovery.method) 阶段=\(recovery.phase)")
        logDisplays()
    }

}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
