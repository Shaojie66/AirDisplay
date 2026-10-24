import AppKit

/// 在指定屏幕上放一个测试窗口：标出屏幕名、尺寸，并带一段不同字号的文字，
/// 用来确认窗口能放到虚拟屏上，后面 M2/M3 也用它看文字清晰度。
enum TestPattern {
    private static var windows: [NSWindow] = []

    static func show(on screens: [NSScreen]) {
        close()
        for screen in screens {
            let size = NSSize(width: 640, height: 400)
            let f = screen.visibleFrame
            let origin = NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2)
            let win = NSWindow(
                contentRect: NSRect(origin: origin, size: size),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false, screen: screen
            )
            win.title = "AirDisplay 测试窗口 — \(screen.localizedName)"
            win.isReleasedWhenClosed = false
            win.contentView = makeContent(for: screen, size: size)
            win.setFrameOrigin(origin)
            // 浮在最上层、所有桌面空间都显示，避免被挡住或落在别的空间
            win.level = .floating
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.orderFrontRegardless()
            windows.append(win)
            Log.info("测试窗口放到：\(screen.localizedName) frame=\(NSStringFromRect(win.frame))")
        }
    }

    static func close() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    private static func makeContent(for screen: NSScreen, size: NSSize) -> NSView {
        let pts = screen.frame.size
        let scale = screen.backingScaleFactor
        var text = "\(screen.localizedName)\n\(Int(pts.width))×\(Int(pts.height)) 点  @\(Int(scale))x\n\n"
        for s in [9, 11, 13, 16, 20] {
            text += "\(s)pt  The quick brown fox 敏捷的棕色狐狸 0123456789 ilI1| O0\n"
        }
        let tv = NSTextView(frame: NSRect(origin: .zero, size: size))
        tv.isEditable = false
        tv.textContainerInset = NSSize(width: 16, height: 16)
        let attr = NSMutableAttributedString()
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let fontSize: CGFloat = i == 0 ? 24 : (Int(line.prefix(2)).map { CGFloat($0) } ?? 14)
            attr.append(NSAttributedString(string: line + "\n", attributes: [.font: NSFont.systemFont(ofSize: fontSize)]))
        }
        tv.textStorage?.setAttributedString(attr)
        return tv
    }
}
