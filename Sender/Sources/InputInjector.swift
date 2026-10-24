import AppKit
import ApplicationServices

/// M5：把 Air 发来的键鼠事件注入到 Pro 上（落在虚拟屏范围内）。
/// 需要「辅助功能」权限；没有时第一次收到事件会让系统弹授权提示，然后忽略事件。
final class InputInjector {
    var displayBounds: () -> CGRect? = { nil }
    var isEnabled: () -> Bool = { true }

    private let source = CGEventSource(stateID: .hidSystemState)
    private var promptedForTrust = false
    private var lastPoint = CGPoint.zero
    private var pressedButton: CGMouseButton?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 在任意线程调用
    func handle(_ e: InputEvent) {
        guard isEnabled() else { return }
        guard AXIsProcessTrusted() else {
            if !promptedForTrust {
                promptedForTrust = true
                Log.info("没有辅助功能权限，无法注入 Air 的键鼠事件，请求授权")
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                DispatchQueue.main.async { _ = AXIsProcessTrustedWithOptions(opts) }
            }
            return
        }
        switch e.kind {
        case .mouseMove, .mouseDown, .mouseUp, .mouseDrag:
            postMouse(e)
        case .scrollPixel, .scrollLine:
            let units: CGScrollEventUnit = e.kind == .scrollPixel ? .pixel : .line
            CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2,
                    wheel1: Int32(e.dy.rounded()), wheel2: Int32(e.dx.rounded()), wheel3: 0)?
                .post(tap: .cghidEventTap)
        case .keyDown, .keyUp:
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: e.keyCode, keyDown: e.kind == .keyDown) else { return }
            ev.flags = CGEventFlags(rawValue: UInt64(e.flags))
            ev.post(tap: .cghidEventTap)
        case .flagsChanged:
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: e.keyCode, keyDown: true) else { return }
            ev.type = .flagsChanged
            ev.flags = CGEventFlags(rawValue: UInt64(e.flags))
            ev.post(tap: .cghidEventTap)
        }
    }

    private func postMouse(_ e: InputEvent) {
        guard let b = displayBounds() else { return }
        let x = b.minX + CGFloat(min(max(e.x, 0), 0.9999)) * b.width
        let y = b.minY + CGFloat(min(max(e.y, 0), 0.9999)) * b.height
        let p = CGPoint(x: x, y: y)
        lastPoint = p

        let button: CGMouseButton = e.button == 0 ? .left : (e.button == 1 ? .right : .center)
        let type: CGEventType
        switch (e.kind, button) {
        case (.mouseDown, .left): type = .leftMouseDown
        case (.mouseDown, .right): type = .rightMouseDown
        case (.mouseDown, _): type = .otherMouseDown
        case (.mouseUp, .left): type = .leftMouseUp
        case (.mouseUp, .right): type = .rightMouseUp
        case (.mouseUp, _): type = .otherMouseUp
        case (.mouseDrag, .left): type = .leftMouseDragged
        case (.mouseDrag, .right): type = .rightMouseDragged
        case (.mouseDrag, _): type = .otherMouseDragged
        default: type = .mouseMoved
        }
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if e.kind == .mouseDown || e.kind == .mouseUp {
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(max(e.clickCount, 1)))
        }
        ev.flags = CGEventFlags(rawValue: UInt64(e.flags))
        ev.post(tap: .cghidEventTap)
    }
}
