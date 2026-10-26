import AppKit

/// 只实例化本进程内未显示的面板；所有控制器操作均为计数替身。
@main
@MainActor
enum ControlPanelTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(value(), message)
    }

    static func find(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for child in view.subviews { if let match = find(id, in: child) { return match } }
        return nil
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        let control = ControlPanel()
        var automaticRecovery = true
        control.toggles = [
            .init(title: "自动恢复随航连接", detail: "iPad 重连后自动重置显示连接，最后仍需核对画面。", get: { automaticRecovery }, set: { automaticRecovery = $0 }),
            .init(title: "断开 Air 时收回桌面", detail: "约 3 秒后关闭扩展屏，将窗口移回主屏。", get: { true }, set: { _ in }),
            .init(title: "更清晰的彩色小字（4:4:4）", detail: "可能增加延迟和带宽，默认关闭。", section: .advanced, get: { false }, set: { _ in }),
            .init(title: "使用 Air 的键盘和触控板", detail: "将输入发送到扩展桌面，首次使用需要辅助功能权限。", get: { true }, set: { _ in }),
            .init(title: "登录时启动", get: { false }, set: { _ in })
        ]
        var starts = 0, confirms = 0
        control.recoveryActions = .init(begin: { starts += 1 }, cancel: {}, resumeOnly: {},
                                       confirm: { confirms += 1 }, failed: {}, showMarkers: {})
        let connected = ControlPanel.Status(connection: .streaming, specification: "雷雳网桥 · 1440 × 932 点 @2x · 60 Hz",
                                            input: .enabled, automaticRecovery: "监测中，iPad 重连后将自动恢复",
                                            diagnostic: "HEVC · 三块显示器在线")
        control.update(status: connected, displayRunning: true, loopbackRunning: false, stats: "抓屏 58 fps · 编码 11.0 ms · 150 Mbps")
        let panel = NSApp.windows.first { $0.title == "AirDisplay" }!
        panel.setContentSize(NSSize(width: 520, height: 520))
        let root = panel.contentView!
        let advanced = find("advanced.content", in: root)!
        let disclose = find("advanced.toggle", in: root) as! NSButton
        let chroma = find("setting.2", in: root) as! NSButton
        let title = find("status.title", in: root) as! NSTextField
        let input = find("status.input", in: root) as! NSTextField
        expect(advanced.isHidden && chroma.isHiddenOrHasHiddenAncestor, "advanced diagnostics start collapsed")
        expect(disclose.accessibilityLabel() == "高级与诊断", "collapsed disclosure announces its action instead of the symbol direction")
        expect(title.stringValue == "Air 已连接", "explicit connection status provides concise header")
        try render(root, name: "normal-light")
        disclose.performClick(nil)
        expect(!advanced.isHidden && !chroma.isHiddenOrHasHiddenAncestor, "all advanced settings remain reachable")
        expect(disclose.accessibilityLabel() == "收起高级与诊断", "expanded disclosure announces its current action")
        control.update(status: connected, displayRunning: true, loopbackRunning: false, stats: "新的统计数据")
        expect(!advanced.isHidden, "frequent status refresh preserves disclosure choice")
        try render(root, name: "advanced-light")
        disclose.performClick(nil)
        expect(advanced.isHidden, "diagnostics can collapse again")
        let dark = NSAppearance(named: .darkAqua)!
        panel.appearance = dark
        NSApp.appearance = dark
        try render(root, name: "normal-dark")
        panel.appearance = NSAppearance(named: .aqua)
        NSApp.appearance = NSAppearance(named: .aqua)

        control.update(status: .init(connection: .waiting, specification: nil, input: .permissionRequired),
                       displayRunning: false, loopbackRunning: false, stats: nil)
        expect(title.stringValue == "等待 Air 连接" && input.stringValue.contains("权限"), "waiting and missing permission remain distinct")
        control.update(status: .init(connection: .stopped, specification: nil, input: .disabled),
                       displayRunning: false, loopbackRunning: false, stats: nil)
        expect(title.stringValue == "连接服务未启动" && input.stringValue.contains("关闭"), "stopped service and disabled input are explicit")
        control.update(status: connected, displayRunning: true, loopbackRunning: false, stats: nil)
        control.revealRecovery()
        let automatic = find("setting.0", in: root) as! NSButton
        automatic.performClick(nil)
        expect(!automaticRecovery && automatic.state == .off, "automatic recovery setting invokes its controller action")
        automaticRecovery = true
        control.refreshToggleValues()
        expect(automatic.state == .on, "controller rejection or external setting change is reflected in checkbox")
        let begin = find("recovery.begin", in: root) as! NSButton
        let environment = find("recovery.environment", in: root) as! NSButton
        let confirm = find("recovery.confirm", in: root) as! NSButton
        let method = find("recovery.method", in: root) as! NSPopUpButton
        expect(control.recoveryMethod == .manual, "proven manual recovery remains initial default")
        var policy = RecoveryPolicy()
        control.updateRecovery(RecoveryPresentation(policy: policy, frameID: nil), operation: 0)
        expect(!begin.isEnabled, "must explicitly confirm environment")
        begin.performClick(nil)
        expect(starts == 0, "disabled begin cannot start a recovery")
        environment.performClick(nil)
        expect(begin.isEnabled && control.confirmedSidecar, "environment enables begin")
        expect(begin.keyEquivalent == "\r" && begin.acceptsFirstMouse(for: nil), "start retains keyboard default action and first click")
        begin.performClick(nil)
        expect(starts == 1, "one click invokes one controller operation")
        for choice in RecoveryMethod.allCases {
            method.selectItem(at: choice.rawValue)
            expect(control.recoveryMethod == choice, "picker selects exact recovery method")
        }
        method.selectItem(at: RecoveryMethod.manual.rawValue)
        try render(root, name: "intro")

        let builtin = TopologyDisplay(id: 1, builtin: true, main: true)
        let owned = TopologyDisplay(id: 8, builtin: false)
        let sidecar = TopologyDisplay(id: 12, builtin: false, x: 100)
        expect(policy.begin(TopologySnapshot([builtin, owned, sidecar]), ownedID: 8, now: 0), "fixture baseline")
        control.updateRecovery(RecoveryPresentation(policy: policy, frameID: nil), operation: 1)
        expect(begin.isHidden, "no duplicate start during stop")
        expect(!(find("display.toggle", in: root) as! NSButton).isEnabled, "recovery presentation disables ordinary display controls")
        expect(input.stringValue.contains("暂停"), "recovery always overrides optimistic input presentation")
        try render(root, name: "stopping-light")
        expect(method.isHidden && !method.isEnabled, "method cannot change during an active recovery")
        expect(confirm.superview!.isHidden, "no confirmation during stop")
        policy.stopped(now: 0)
        observe(&policy, TopologySnapshot([builtin]), from: 1)
        control.updateRecovery(RecoveryPresentation(policy: policy, frameID: nil), operation: 1)
        try render(root, name: "reconnect")
        observe(&policy, TopologySnapshot([builtin, sidecar]), from: 3)
        policy.created(20, now: 5)
        var recreated = owned; recreated.id = 20
        let complete = TopologySnapshot([builtin, sidecar, recreated])
        observe(&policy, complete, from: 5)
        policy.frameDelivered(now: 7)
        observe(&policy, complete, from: 7)
        control.updateRecovery(RecoveryPresentation(policy: policy, frameID: 42), operation: 1)
        expect(!confirm.isEnabled, "frame delivery alone cannot confirm")
        for i in 0..<3 {
            let box = find("recovery.screen.\(i)", in: root) as! NSButton
            expect(box.isEnabled && !box.isHidden, "all three real screens require verification")
            box.performClick(nil)
            if i < 2 { expect(!confirm.isEnabled, "partial screen verification cannot confirm") }
        }
        expect(confirm.isEnabled, "three checks enable confirmation")
        expect(confirm.keyEquivalent == "\r" && begin.keyEquivalent.isEmpty, "only current confirmation owns Return shortcut")
        confirm.performClick(nil)
        expect(confirms == 1, "explicit confirmation reaches controller")
        try render(root, name: "confirm")
        panel.appearance = dark; NSApp.appearance = dark
        try render(root, name: "confirm-dark")
        panel.appearance = NSAppearance(named: .aqua); NSApp.appearance = NSAppearance(named: .aqua)
        control.updateRecovery(RecoveryPresentation(policy: policy, frameID: 43), operation: 1)
        expect(!confirm.isEnabled, "receiver replacement clears old verification")
        expect(!control.confirmationMatches(operation: 1, frameID: 42), "stale stream cannot use previous checks")

        policy.pause("显示器配置改变，请确认没有连接其他显示器后重新开始", now: 10)
        control.updateRecovery(RecoveryPresentation(policy: policy, frameID: nil), operation: 2)
        expect(!begin.isHidden && begin.isEnabled, "paused recovery offers a retry")
        expect(confirm.superview!.isHidden, "paused recovery cannot claim completion")
        try render(root, name: "paused")
        panel.setContentSize(NSSize(width: 480, height: 700))
        let longNotice = String(repeating: "连接尚未稳定，请检查 iPad 和 Air 的连接状态。", count: 12)
        control.updateRecovery(RecoveryPresentation(policy: policy, frameID: nil), operation: 2, notice: longNotice)
        try render(root, name: "narrow-error")
        expect((find("recovery.detail", in: root) as! NSTextField).stringValue.contains(longNotice), "long error remains complete at minimum width")
        policy.resumeManually(now: 11)
        policy.frameDelivered(now: 12)
        observe(&policy, complete, from: 12)
        control.updateRecovery(RecoveryPresentation(policy: policy, frameID: 44), operation: 3)
        let ipad = find("recovery.screen.1", in: root) as! NSButton
        expect(ipad.isHidden, "AirDisplay-only restoration does not demand a nonexistent iPad check")
        for index in [0, 2] {
            let box = find("recovery.screen.\(index)", in: root) as! NSButton
            box.performClick(nil)
        }
        expect(confirm.isEnabled && control.confirmationMatches(operation: 3, frameID: 44), "manual restoration verifies Mac and Air")
        expect(!panel.isVisible, "layout checks never present the window")
        print("PASS: \(checks) offscreen control-panel checks; no Sender or display connection started")
    }

    static func observe(_ policy: inout RecoveryPolicy, _ snapshot: TopologySnapshot, from: Double) {
        for i in 0...6 { _ = policy.observe(snapshot, now: from + Double(i) * 0.25, reconfiguredAt: from) }
    }

    static func render(_ root: NSView, name: String) throws {
        root.layoutSubtreeIfNeeded()
        if let scroll = root.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView,
           let document = scroll.documentView {
            root.window?.setContentSize(NSSize(width: root.bounds.width, height: min(1000, max(300, document.fittingSize.height))))
            root.layoutSubtreeIfNeeded()
        }
        expect(!root.hasAmbiguousLayout, "root layout has explicit constraints")
        // PDF 绘制遍历离屏视图；cacheDisplay 对未显示的合成层可能只给出透明位图。
        var pdf = Data()
        let appearance = root.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance { pdf = root.dataWithPDF(inside: root.bounds) }
        try pdf.write(to: URL(fileURLWithPath: "build/recovery-guide-\(name).pdf"))
        let document = CGPDFDocument(CGDataProvider(data: pdf as CFData)!)!
        let page = document.page(at: 1)!
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(root.bounds.width),
                                      pixelsHigh: Int(root.bounds.height), bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        appearance.performAsCurrentDrawingAppearance {
            context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.cgContext.fill(root.bounds)
            context.cgContext.drawPDFPage(page)
        }
        // 现代 NSButton 的合成层不会出现在离屏 PDF；直接绘制原生 cell，位置来自实际约束结果。
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance { drawButtons(in: root, root: root, log: name == "confirm") }
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: "build/recovery-guide-\(name).png"))
    }

    static func drawButtons(in view: NSView, root: NSView, log: Bool) {
        guard !view.isHidden else { return }
        if let button = view as? NSButton {
            let rect = root.convert(button.bounds, from: button)
            if log { print("CONTROL \(button.identifier?.rawValue ?? button.title) \(rect)") }
            expect(rect.width > 0 && rect.height > 0, "visible controls have usable dimensions")
            // draw 会改变 cell.controlView，使用副本，避免预览破坏后续交互检查。
            (button.cell?.copy() as? NSCell)?.draw(withFrame: rect, in: root)
        }
        for child in view.subviews { drawButtons(in: child, root: root, log: log) }
    }
}
