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
    /// 已注入「按下」但还没注入「抬起」的键和鼠标键；断线时要补发抬起，否则 Pro 上会一直按住
    private let lock = NSLock()
    private var pressedKeys = Set<UInt16>()
    private var pressedButtons = Set<UInt32>()
    private var modifiersHeld = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 在任意线程调用
    func handle(_ e: InputEvent) {
        guard isEnabled() else { return }
        guard let bounds = displayBounds(), !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
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
            postMouse(e, bounds: bounds)
        case .scrollPixel, .scrollLine:
            let units: CGScrollEventUnit = e.kind == .scrollPixel ? .pixel : .line
            CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2,
                    wheel1: Int32(e.dy.rounded()), wheel2: Int32(e.dx.rounded()), wheel3: 0)?
                .post(tap: .cghidEventTap)
        case .keyDown, .keyUp:
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: e.keyCode, keyDown: e.kind == .keyDown) else { return }
            ev.flags = CGEventFlags(rawValue: UInt64(e.flags))
            lock.withLock {
                if e.kind == .keyDown { pressedKeys.insert(e.keyCode) } else { pressedKeys.remove(e.keyCode) }
            }
            ev.post(tap: .cghidEventTap)
        case .flagsChanged:
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: e.keyCode, keyDown: true) else { return }
            ev.type = .flagsChanged
            ev.flags = CGEventFlags(rawValue: UInt64(e.flags))
            let held = CGEventFlags(rawValue: UInt64(e.flags)).intersection(Self.modifierMask)
            lock.withLock { modifiersHeld = !held.isEmpty }
            ev.post(tap: .cghidEventTap)
        }
    }

    private static let modifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn, .maskAlphaShift]

    /// 接收端断开时调用（任意线程）：把还按着的键、鼠标键、修饰键全部补发抬起
    func releaseAll() {
        let (keys, buttons, mods, point) = lock.withLock {
            defer { pressedKeys.removeAll(); pressedButtons.removeAll(); modifiersHeld = false }
            return (pressedKeys, pressedButtons, modifiersHeld, lastPoint)
        }
        guard !keys.isEmpty || !buttons.isEmpty || mods else { return }
        Log.info("接收端断开，补发抬起：键 \(keys.count) 个，鼠标键 \(buttons.count) 个，修饰键 \(mods ? "有" : "无")")
        for k in keys {
            CGEvent(keyboardEventSource: source, virtualKey: k, keyDown: false)?.post(tap: .cghidEventTap)
        }
        for raw in buttons {
            guard let button = CGMouseButton(rawValue: raw) else { continue }
            let type: CGEventType = button == .left ? .leftMouseUp : (button == .right ? .rightMouseUp : .otherMouseUp)
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
                .post(tap: .cghidEventTap)
        }
        if mods, let ev = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            ev.type = .flagsChanged
            ev.flags = []
            ev.post(tap: .cghidEventTap)
        }
    }

    private func postMouse(_ e: InputEvent, bounds b: CGRect) {
        let x = b.minX + CGFloat(min(max(e.x, 0), 0.9999)) * b.width
        let y = b.minY + CGFloat(min(max(e.y, 0), 0.9999)) * b.height
        let p = CGPoint(x: x, y: y)

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
        lock.withLock {
            lastPoint = p
            if e.kind == .mouseDown { pressedButtons.insert(button.rawValue) }
            if e.kind == .mouseUp { pressedButtons.remove(button.rawValue) }
        }
        if e.kind == .mouseDown || e.kind == .mouseUp {
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(max(e.clickCount, 1)))
        }
        ev.flags = CGEventFlags(rawValue: UInt64(e.flags))
        ev.post(tap: .cghidEventTap)
    }
}
