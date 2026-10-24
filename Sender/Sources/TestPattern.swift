import AppKit

/// 在指定屏幕上放一个测试窗口：标出屏幕名、尺寸，带一段不同字号的文字（看清晰度），
/// 以及一个 60Hz 刷新的毫秒时钟（让画面一直在动，测帧率；M4 拍照对比延迟也用它）。
enum TestPattern {
    private static var windows: [NSWindow] = []
    private static var clocks: [NSTextField] = []
    private static var timer: Timer?
    private static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func show(on screens: [NSScreen]) {
        close()
        for screen in screens {
            let size = NSSize(width: 640, height: 440)
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
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            let s = clockFormat.string(from: Date())
            clocks.forEach { $0.stringValue = s }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func close() {
        timer?.invalidate()
        timer = nil
        windows.forEach { $0.orderOut(nil); $0.close() }
        if !windows.isEmpty { Log.info("已关闭 \(windows.count) 个测试窗口") }
        windows.removeAll()
        clocks.removeAll()
    }

    private static func makeContent(for screen: NSScreen, size: NSSize) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))

        let clock = NSTextField(labelWithString: "00:00:00.000")
        clock.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        clock.frame = NSRect(x: 16, y: size.height - 64, width: size.width - 32, height: 50)
        clock.autoresizingMask = [.width, .minYMargin]
        container.addSubview(clock)
        clocks.append(clock)

        let pts = screen.frame.size
        let scale = screen.backingScaleFactor
        var text = "\(screen.localizedName)\n\(Int(pts.width))×\(Int(pts.height)) 点  @\(Int(scale))x\n\n"
        for s in [9, 11, 13, 16, 20] {
            text += "\(s)pt  The quick brown fox 敏捷的棕色狐狸 0123456789 ilI1| O0\n"
        }
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - 70))
        tv.autoresizingMask = [.width, .height]
        tv.isEditable = false
        tv.textContainerInset = NSSize(width: 16, height: 8)
        let attr = NSMutableAttributedString()
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let fontSize: CGFloat = i == 0 ? 22 : (Int(line.prefix(while: { $0.isNumber })).map { CGFloat($0) } ?? 14)
            attr.append(NSAttributedString(string: line + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.textColor,
            ]))
        }
        tv.textStorage?.setAttributedString(attr)
        container.addSubview(tv)
        return container
    }
}
