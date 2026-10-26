import AppKit

/// 主控制面板。恢复操作与菜单共用控制器，不直接操作显示器或网络。
final class ControlPanel: NSObject {
    struct Status {
        enum Connection { case waiting, streaming, stopped, stopping }
        enum Input { case enabled, paused, disabled, permissionRequired, waiting }
        var connection: Connection
        var specification: String?
        var input: Input
        var automaticRecovery: String? = nil
        var diagnostic: String? = nil
    }
    struct Actions {
        var toggleDisplay: () -> Void
        var toggleLoopback: () -> Void
    }
    struct RecoveryActions {
        var begin: () -> Void
        var cancel: () -> Void
        var resumeOnly: () -> Void
        var confirm: () -> Void
        var failed: () -> Void
        var showMarkers: () -> Void
    }
    struct Toggle {
        enum Section { case daily, advanced }
        var title: String
        var detail: String? = nil
        var section: Section = .daily
        var get: () -> Bool
        var set: (Bool) -> Void
    }

    private let panel: NSPanel
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let specificationLabel = NSTextField(wrappingLabelWithString: "")
    private let inputLabel = NSTextField(wrappingLabelWithString: "")
    private let automaticLabel = NSTextField(wrappingLabelWithString: "")
    private let diagnosticLabel = NSTextField(wrappingLabelWithString: "")
    private let connectionIcon = NSImageView()
    private var status = Status(connection: .waiting, specification: nil, input: .waiting)
    private var actionsEnabled = true
    private let statsLabel = NSTextField(wrappingLabelWithString: "")
    private let displayButton = FirstClickButton(title: "", target: nil, action: nil)
    private let loopbackButton = FirstClickButton(title: "", target: nil, action: nil)
    private let recoveryLauncher = FirstClickButton(title: "恢复显示连接…", target: nil, action: nil)
    private let recoveryStack = NSStackView()
    private let recoveryTitle = NSTextField(wrappingLabelWithString: "")
    private let recoveryDetail = NSTextField(wrappingLabelWithString: "")
    private let recoveryProgress = NSProgressIndicator()
    private let environment = FirstClickButton(checkboxWithTitle: "我确认：除 AirDisplay 外，只有内建屏和一台 iPad 随航", target: nil, action: nil)
    private let methodPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let beginButton = FirstClickButton(title: "开始恢复", target: nil, action: nil)
    private let cancelButton = FirstClickButton(title: "取消并保持暂停", target: nil, action: nil)
    private let resumeButton = FirstClickButton(title: "仅恢复 AirDisplay", target: nil, action: nil)
    private let markerButton = FirstClickButton(title: "显示核对标记", target: nil, action: nil)
    private let confirmButton = FirstClickButton(title: "画面正确，恢复输入", target: nil, action: nil)
    private let failureButton = FirstClickButton(title: "画面仍重复", target: nil, action: nil)
    private let verificationStack = NSStackView()
    private var screenChecks: [NSButton] = []
    private var verification = RecoveryVerification()
    private var presentation: RecoveryPresentation?
    private var lastNotice: String?
    private var recoveryVisible = false
    private var operation: UInt64 = 0
    private let toggleStack = NSStackView()
    private let advancedToggleStack = NSStackView()
    private let advancedStack = NSStackView()
    private let advancedButton = FirstClickButton(title: "高级与诊断", target: nil, action: nil)
    private var advancedExpanded = false
    private var checkboxes: [NSButton] = []
    private let document = PanelDocumentView()
    private let scroll = NSScrollView()

    var actions: Actions?
    var recoveryActions: RecoveryActions?
    var toggles: [Toggle] = [] { didSet { rebuildToggles() } }
    var confirmedSidecar: Bool { environment.state == .on }
    var recoveryMethod: RecoveryMethod { RecoveryMethod(rawValue: methodPicker.indexOfSelectedItem) ?? .manual }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                        styleMask: [.titled, .closable, .utilityWindow, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = "AirDisplay"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 280)
        panel.backgroundColor = .windowBackgroundColor
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        let root = NSView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        document.orientation = .vertical
        document.alignment = .leading
        document.spacing = 20
        document.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        panel.contentView = root

        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("status.title")
        specificationLabel.font = .systemFont(ofSize: 12)
        specificationLabel.textColor = .secondaryLabelColor
        inputLabel.font = .systemFont(ofSize: 12)
        inputLabel.identifier = NSUserInterfaceItemIdentifier("status.input")
        automaticLabel.font = .systemFont(ofSize: 11)
        automaticLabel.textColor = .secondaryLabelColor
        diagnosticLabel.font = .systemFont(ofSize: 11)
        diagnosticLabel.textColor = .secondaryLabelColor
        connectionIcon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        connectionIcon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        connectionIcon.imageScaling = .scaleProportionallyDown
        connectionIcon.setAccessibilityElement(false)
        displayButton.target = self; displayButton.action = #selector(displayTapped)
        loopbackButton.target = self; loopbackButton.action = #selector(loopbackTapped)
        recoveryLauncher.target = self; recoveryLauncher.action = #selector(recoveryTapped)
        recoveryLauncher.identifier = NSUserInterfaceItemIdentifier("recovery.open")
        recoveryLauncher.isBordered = false; recoveryLauncher.bezelStyle = .inline
        recoveryLauncher.font = .systemFont(ofSize: 12)
        let testOn = FirstClickButton(title: "显示测试标记", target: self, action: #selector(testOnTapped))
        testOn.identifier = NSUserInterfaceItemIdentifier("diagnostic.markers")
        let testOff = FirstClickButton(title: "关闭测试标记", target: self, action: #selector(testOffTapped))
        let quit = FirstClickButton(title: "退出", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.isBordered = false; quit.bezelStyle = .inline; quit.font = .systemFont(ofSize: 12)
        quit.contentTintColor = .secondaryLabelColor
        for stack in [toggleStack, advancedToggleStack, advancedStack] {
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        }
        advancedButton.target = self; advancedButton.action = #selector(advancedTapped)
        advancedButton.identifier = NSUserInterfaceItemIdentifier("advanced.toggle")
        advancedButton.isBordered = false; advancedButton.bezelStyle = .inline
        advancedButton.font = .systemFont(ofSize: 12)
        advancedButton.contentTintColor = .secondaryLabelColor
        advancedStack.identifier = NSUserInterfaceItemIdentifier("advanced.content")
        loopbackButton.identifier = NSUserInterfaceItemIdentifier("diagnostic.loopback")

        let heading = vertical([statusLabel, specificationLabel], spacing: 5)
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [statusLabel, specificationLabel] {
            label.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true
        }
        let hero = NSStackView(views: [connectionIcon, heading, displayButton])
        hero.orientation = .horizontal; hero.alignment = .top; hero.spacing = 12
        hero.distribution = .fill
        displayButton.trailingAnchor.constraint(equalTo: hero.trailingAnchor).isActive = true
        displayButton.setContentHuggingPriority(.required, for: .horizontal)
        displayButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let connection = vertical([hero, inputLabel, automaticLabel], spacing: 8)
        for view in [hero, inputLabel, automaticLabel] {
            view.widthAnchor.constraint(equalTo: connection.widthAnchor).isActive = true
        }
        let settings = vertical([sectionTitle("连接设置"), toggleStack], spacing: 12)
        toggleStack.widthAnchor.constraint(equalTo: settings.widthAnchor).isActive = true

        for view in [advancedToggleStack, diagnosticLabel, statsLabel, loopbackButton,
                     NSStackView(views: [testOn, testOff])] { advancedStack.addArrangedSubview(view) }
        for view in [advancedToggleStack, diagnosticLabel, statsLabel] {
            view.widthAnchor.constraint(equalTo: advancedStack.widthAnchor).isActive = true
        }
        let advanced = vertical([advancedButton, advancedStack], spacing: 12)
        advancedStack.widthAnchor.constraint(equalTo: advanced.widthAnchor).isActive = true
        let footer = NSStackView(views: [recoveryLauncher, NSView(), quit])
        footer.orientation = .horizontal; footer.distribution = .fill; footer.spacing = 12

        buildRecoverySection()
        for view in [connection, recoveryStack, separator(), settings, advanced, separator(), footer] {
            document.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -48).isActive = true
        }
        recoveryStack.isHidden = true
        updateAdvancedDisclosure()
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSBox {
        let line = NSBox(); line.boxType = .separator
        return line
    }

    private func buildRecoverySection() {
        recoveryStack.orientation = .vertical; recoveryStack.alignment = .leading
        recoveryStack.spacing = 12
        recoveryTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        recoveryDetail.font = .systemFont(ofSize: 12)
        recoveryDetail.textColor = .secondaryLabelColor
        recoveryTitle.setAccessibilityElement(true)
        recoveryTitle.identifier = NSUserInterfaceItemIdentifier("recovery.title")
        recoveryDetail.identifier = NSUserInterfaceItemIdentifier("recovery.detail")
        recoveryProgress.style = .spinning; recoveryProgress.controlSize = .small
        recoveryProgress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        recoveryProgress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        environment.target = self; environment.action = #selector(environmentChanged)
        environment.identifier = NSUserInterfaceItemIdentifier("recovery.environment")
        environment.cell?.wraps = true
        methodPicker.addItems(withTitles: RecoveryMethod.allCases.map(\.title))
        methodPicker.identifier = NSUserInterfaceItemIdentifier("recovery.method")
        methodPicker.setAccessibilityLabel("恢复方式")
        beginButton.target = self; beginButton.action = #selector(beginTapped)
        beginButton.identifier = NSUserInterfaceItemIdentifier("recovery.begin")
        cancelButton.target = self; cancelButton.action = #selector(cancelTapped)
        cancelButton.identifier = NSUserInterfaceItemIdentifier("recovery.cancel")
        resumeButton.target = self; resumeButton.action = #selector(resumeTapped)
        resumeButton.identifier = NSUserInterfaceItemIdentifier("recovery.resumeOnly")
        markerButton.target = self; markerButton.action = #selector(markersTapped)
        confirmButton.target = self; confirmButton.action = #selector(confirmTapped)
        confirmButton.identifier = NSUserInterfaceItemIdentifier("recovery.confirm")
        failureButton.target = self; failureButton.action = #selector(failureTapped)
        for button in [beginButton, confirmButton, markerButton, failureButton, resumeButton, cancelButton] {
            button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 13)
        }
        verificationStack.orientation = .vertical; verificationStack.alignment = .leading; verificationStack.spacing = 7
        for (index, title) in ["Mac 主屏显示自己的编号和动态计数", "iPad 显示独立编号，计数持续变化", "Air 显示另一个独立编号，计数持续变化"].enumerated() {
            let check = FirstClickButton(checkboxWithTitle: title, target: self, action: #selector(screenChecked(_:)))
            check.tag = index
            check.identifier = NSUserInterfaceItemIdentifier("recovery.screen.\(index)")
            verificationStack.addArrangedSubview(check); screenChecks.append(check)
        }
        for view in [separator(), NSStackView(views: [recoveryTitle, recoveryProgress]), recoveryDetail, methodPicker, environment,
                     beginButton, markerButton, verificationStack,
                     NSStackView(views: [confirmButton, failureButton]), resumeButton, cancelButton] {
            recoveryStack.addArrangedSubview(view)
        }
        for view in [recoveryDetail, environment, verificationStack] {
            view.widthAnchor.constraint(equalTo: recoveryStack.widthAnchor).isActive = true
        }
        recoveryDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        environment.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func show() {
        fitPanelToContent(center: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil); panel.orderFrontRegardless()
    }

    private func fitPanelToContent(center: Bool = false) {
        panel.contentView?.layoutSubtreeIfNeeded()
        if let main = NSScreen.screens.first {
            let f = main.visibleFrame
            let top = panel.frame.maxY
            let width = min(max(480, panel.contentLayoutRect.width), f.width - 60)
            panel.setContentSize(NSSize(width: width, height: panel.contentLayoutRect.height))
            panel.contentView?.layoutSubtreeIfNeeded()
            let height = min(max(document.fittingSize.height, 300), max(300, f.height - 100))
            panel.setContentSize(NSSize(width: width, height: height))
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: center ? f.midX - size.width / 2 : panel.frame.minX,
                                        y: center ? f.maxY - size.height - 40 : top - size.height))
        }
    }

    func showRecovery() {
        revealRecovery()
        show()
    }

    func revealRecovery() {
        recoveryVisible = true
        recoveryStack.isHidden = false
        recoveryLauncher.isHidden = true
    }

    func finishRecovery() {
        recoveryVisible = false
        environment.state = .off
        recoveryStack.isHidden = true
        recoveryLauncher.isHidden = false
    }

    func confirmationMatches(operation: UInt64, frameID: UInt64?) -> Bool {
        verification.permitsConfirmation(operation: operation, frameID: frameID)
    }

    func updateRecovery(_ value: RecoveryPresentation, operation: UInt64, notice: String? = nil) {
        let layoutChanged = presentation?.phase != value.phase || lastNotice != notice
        presentation = value; self.operation = operation
        lastNotice = notice
        let confirming = value.phase == .awaitingConfirmation
        verification.update(operation: operation, frameID: confirming && value.canConfirm ? value.frameID : nil,
                            manualResume: value.manualResume)
        if value.phase != .idle { recoveryVisible = true }
        recoveryStack.isHidden = !recoveryVisible
        recoveryLauncher.isHidden = recoveryVisible
        if case .paused = value.phase { recoveryTitle.stringValue = "选择如何继续" }
        else { recoveryTitle.stringValue = value.title }
        recoveryDetail.stringValue = value.detail + (notice.map { "\n\n" + $0 } ?? "")
        recoveryProgress.isHidden = !value.busy
        if value.busy { recoveryProgress.startAnimation(nil) } else { recoveryProgress.stopAnimation(nil) }
        environment.isHidden = !value.canBegin
        methodPicker.isHidden = !value.canBegin
        methodPicker.isEnabled = value.canBegin
        beginButton.isHidden = !value.canBegin
        beginButton.title = value.phase == .idle ? "开始恢复" : "重新开始完整恢复"
        markerButton.isHidden = !confirming
        verificationStack.isHidden = !confirming
        confirmButton.superview?.isHidden = !confirming
        resumeButton.isHidden = !value.canResumeOnly
        cancelButton.isHidden = value.phase != .idle && !value.canCancel
        cancelButton.title = value.phase == .idle ? "收起" : "取消并保持暂停"
        for (i, check) in screenChecks.enumerated() {
            check.isHidden = value.manualResume && i == 1
            check.state = verification.isChecked(i) ? .on : .off
            check.isEnabled = value.canConfirm
        }
        refreshAvailability()
        renderStatus()
        if layoutChanged && panel.isVisible { fitPanelToContent() }
    }

    private func rebuildToggles() {
        for stack in [toggleStack, advancedToggleStack] {
            for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        }
        checkboxes = toggles.enumerated().map { i, t in
            let button = FirstClickButton(checkboxWithTitle: t.title, target: self, action: #selector(toggleTapped(_:)))
            button.tag = i; button.state = t.get() ? .on : .off
            button.identifier = NSUserInterfaceItemIdentifier("setting.\(i)")
            button.cell?.wraps = true
            button.font = .systemFont(ofSize: 13)
            button.setAccessibilityHelp(t.detail)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = vertical([button], spacing: 3)
            button.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            if let detail = t.detail {
                let label = NSTextField(wrappingLabelWithString: detail)
                label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                let detailView = NSView(); detailView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: detailView.leadingAnchor, constant: 20),
                    label.trailingAnchor.constraint(equalTo: detailView.trailingAnchor),
                    label.topAnchor.constraint(equalTo: detailView.topAnchor),
                    label.bottomAnchor.constraint(equalTo: detailView.bottomAnchor)
                ])
                row.addArrangedSubview(detailView)
                detailView.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            }
            let group = t.section == .daily ? toggleStack : advancedToggleStack
            group.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            return button
        }
    }

    func refreshToggleValues() {
        for (checkbox, toggle) in zip(checkboxes, toggles) {
            checkbox.state = toggle.get() ? .on : .off
        }
    }

    @objc private func toggleTapped(_ sender: NSButton) {
        let toggle = toggles[sender.tag]
        toggle.set(sender.state == .on); sender.state = toggle.get() ? .on : .off
    }

    func update(status: Status, displayRunning: Bool, loopbackRunning: Bool, stats: String?, actionsEnabled: Bool = true) {
        self.status = status
        self.actionsEnabled = actionsEnabled
        displayButton.title = displayRunning ? "关闭扩展屏" : "开启扩展屏"
        displayButton.identifier = NSUserInterfaceItemIdentifier("display.toggle")
        loopbackButton.title = loopbackRunning ? "停止本机回环" : "本机回环测试"
        displayButton.isEnabled = actionsEnabled; loopbackButton.isEnabled = actionsEnabled
        statsLabel.stringValue = stats ?? ""; statsLabel.isHidden = stats == nil
        diagnosticLabel.stringValue = status.diagnostic ?? ""
        diagnosticLabel.isHidden = status.diagnostic == nil
        renderStatus()
    }

    private func renderStatus() {
        let ordinaryActions = actionsEnabled && (presentation?.phase ?? .idle) == .idle
        displayButton.isEnabled = ordinaryActions; loopbackButton.isEnabled = ordinaryActions
        let title: String, symbol: String, color: NSColor
        var input = status.input
        if let presentation, presentation.phase != .idle {
            input = .paused
            if presentation.phase == .awaitingConfirmation { title = "画面待确认" }
            else if case .paused = presentation.phase { title = "恢复已暂停" }
            else { title = "正在恢复显示连接" }
            symbol = "exclamationmark.circle.fill"; color = .systemOrange
        } else {
            switch status.connection {
            case .streaming: title = "Air 已连接"; symbol = "checkmark.circle.fill"; color = .systemGreen
            case .waiting: title = "等待 Air 连接"; symbol = "circle.dashed"; color = .secondaryLabelColor
            case .stopped: title = "连接服务未启动"; symbol = "circle"; color = .secondaryLabelColor
            case .stopping: title = "正在关闭扩展屏"; symbol = "circle.dashed"; color = .secondaryLabelColor
            }
        }
        statusLabel.stringValue = title
        connectionIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        connectionIcon.contentTintColor = color
        specificationLabel.stringValue = status.specification ?? "在 Air 上打开接收端，通过雷雳网桥连接。"
        switch input {
        case .enabled: inputLabel.stringValue = "输入已开启 · 使用 Air 的键盘和触控板"
        case .paused: inputLabel.stringValue = "输入已暂停 · 画面确认后恢复"
        case .disabled: inputLabel.stringValue = "远程输入已关闭"
        case .permissionRequired: inputLabel.stringValue = "输入需要辅助功能权限"
        case .waiting: inputLabel.stringValue = "输入等待画面连接"
        }
        inputLabel.textColor = input == .paused ? .systemOrange : .secondaryLabelColor
        automaticLabel.stringValue = status.automaticRecovery.map { "随航自动恢复 · " + $0 } ?? ""
        automaticLabel.isHidden = status.automaticRecovery == nil
    }

    private func updateAdvancedDisclosure() {
        advancedStack.isHidden = !advancedExpanded
        advancedButton.title = advancedExpanded ? "收起高级与诊断" : "高级与诊断"
        advancedButton.setAccessibilityLabel(advancedButton.title)
        advancedButton.image = NSImage(systemSymbolName: advancedExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: "")
        advancedButton.imagePosition = .imageLeading
        advancedButton.setAccessibilityHelp(advancedExpanded ? "展开状态，按下可收起诊断选项" : "收起状态，按下可展开诊断选项")
    }

    @objc private func advancedTapped() {
        advancedExpanded.toggle(); updateAdvancedDisclosure()
        if panel.isVisible { fitPanelToContent() }
    }

    private func refreshAvailability() {
        guard let presentation else { return }
        beginButton.isEnabled = presentation.canBegin && confirmedSidecar
        confirmButton.isEnabled = presentation.canConfirm && confirmationMatches(operation: operation, frameID: presentation.frameID)
        beginButton.keyEquivalent = beginButton.isEnabled && !beginButton.isHidden ? "\r" : ""
        confirmButton.keyEquivalent = confirmButton.isEnabled && !confirmButton.superview!.isHidden ? "\r" : ""
    }

    @objc private func recoveryTapped() { showRecovery() }
    @objc private func environmentChanged() { refreshAvailability() }
    @objc private func screenChecked(_ sender: NSButton) {
        verification.set(sender.tag, checked: sender.state == .on); refreshAvailability()
    }
    @objc private func beginTapped() { if confirmedSidecar && presentation?.canBegin == true { recoveryActions?.begin() } }
    @objc private func cancelTapped() {
        if presentation?.phase == .idle { finishRecovery() }
        else if presentation?.canCancel == true { recoveryActions?.cancel() }
    }
    @objc private func resumeTapped() { if presentation?.canResumeOnly == true { recoveryActions?.resumeOnly() } }
    @objc private func confirmTapped() { if confirmButton.isEnabled { recoveryActions?.confirm() } }
    @objc private func failureTapped() { if presentation?.phase == .awaitingConfirmation { recoveryActions?.failed() } }
    @objc private func markersTapped() {
        if presentation?.phase == .awaitingConfirmation { recoveryActions?.showMarkers() }
    }
    @objc private func displayTapped() { actions?.toggleDisplay() }
    @objc private func loopbackTapped() { actions?.toggleLoopback() }
    @objc private func testOnTapped() { TestPattern.show(on: NSScreen.screens) }
    @objc private func testOffTapped() { TestPattern.close() }
}

/// 内容短于视口时也从顶端排版；接受第一次点击以匹配控制面板其他控件。
private final class PanelDocumentView: NSStackView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
