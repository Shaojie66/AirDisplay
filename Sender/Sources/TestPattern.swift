import AppKit

/// 在指定屏幕上放一个测试窗口：标出屏幕名、尺寸，带一段不同字号的文字（看清晰度），
/// 以及一个 60Hz 刷新的毫秒时钟（让画面一直在动，测帧率；M4 拍照对比延迟也用它）。
enum TestPattern {
    private static var windows: [NSWindow] = []
    private static var clocks: [NSTextField] = []
    private static var counters: [NSTextField] = []
    private static var ticks: UInt64 = 0
    private static var timer: Timer?
    private static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func show(on screens: [NSScreen]) {
        close()
        for (index, screen) in screens.enumerated() {
            let size = NSSize(width: 660, height: 420)
            let f = screen.visibleFrame
            let origin = NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2)
            let win = NSWindow(
                contentRect: NSRect(origin: origin, size: size),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false, screen: screen
            )
            win.title = "AirDisplay 测试窗口 — \(screen.localizedName)"
            win.isReleasedWhenClosed = false
            win.contentView = makeContent(for: screen, size: size, index: index)
            win.setFrameOrigin(origin)
            // 浮在最上层、所有桌面空间都显示，避免被挡住或落在别的空间
            win.level = .floating
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.orderFrontRegardless()
            windows.append(win)
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            Log.info("测试窗口标记 \(index + 1) displayID=\(id) frame=\(NSStringFromRect(win.frame))")
        }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            let s = clockFormat.string(from: Date())
            clocks.forEach { $0.stringValue = s }
            ticks &+= 1
            for (index, label) in counters.enumerated() {
                label.stringValue = "标记 \(index + 1) · 计数 \(ticks * UInt64(index + 1))"
            }
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
        counters.removeAll()
        ticks = 0
    }

    private static func makeContent(for screen: NSScreen, size: NSSize, index: Int) -> NSView {
        let counter = NSTextField(labelWithString: "标记 \(index + 1) · 等待计数")
        counter.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        counter.textColor = [.systemBlue, .systemOrange, .systemPurple, .systemGreen][index % 4]
        counters.append(counter)
        let clock = NSTextField(labelWithString: "00:00:00.000")
        clock.font = .monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        clock.textColor = .labelColor
        clocks.append(clock)

        let pts = screen.frame.size
        let scale = screen.backingScaleFactor
        let attr = NSMutableAttributedString()
        func add(_ str: String, _ font: NSFont, _ color: NSColor = .labelColor) {
            attr.append(NSAttributedString(string: str + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        add("\(screen.localizedName)  \(Int(pts.width))×\(Int(pts.height)) 点 @\(Int(scale))x", .systemFont(ofSize: 15, weight: .medium))
        add("", .systemFont(ofSize: 6))
        for sz in [9, 11, 13, 16, 20] {
            add("\(sz)pt  The quick brown fox 敏捷的棕色狐狸 0123456789 ilI1| O0", .systemFont(ofSize: CGFloat(sz)))
        }
        add("", .systemFont(ofSize: 6))
        // 彩色小字（模拟代码高亮），看 4:2:0 / 4:4:4 的差别
        let palette: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemPurple, .systemOrange]
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for line in ["let value = items.map { $0 * 2 } // 红蓝绿紫",
                     "func render(_ frame: Frame) -> Bool { return true }",
                     "\"字符串\" 0x1F2E3D  /* comment 注释 */"] {
            for (n, word) in line.split(separator: " ").enumerated() {
                attr.append(NSAttributedString(string: String(word) + " ",
                                               attributes: [.font: mono, .foregroundColor: palette[n % palette.count]]))
            }
            attr.append(NSAttributedString(string: "\n", attributes: [.font: mono]))
        }

        let body = NSTextField(labelWithAttributedString: attr)
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byClipping

        let stack = NSStackView(views: [counter, clock, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }
}
