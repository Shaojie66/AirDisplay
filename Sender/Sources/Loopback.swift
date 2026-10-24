import AppKit

/// M2 本机回环：抓虚拟屏 → 编码 → 打包成线上格式 → 解包 → 解码 → 在主屏窗口里显示。
/// 打包/解包这一步和 M3 走网络时完全一样，只是不经过网络。
final class Loopback: NSObject, NSWindowDelegate {
    let stats = PipelineStats()
    let snapshot = FrameSnapshot()
    private(set) var isRunning = false
    private(set) var codecDescription = ""
    var onStopped: (() -> Void)?

    private let capturer = ScreenCapturer()
    private var encoder: VideoEncoder?
    private let decoder = VideoDecoder()
    private let decodeQueue = DispatchQueue(label: "airdisplay.decode", qos: .userInteractive)
    private var window: NSWindow?
    private var videoView: VideoView?

    @MainActor
    func start(displayID: CGDirectDisplayID, config: VirtualDisplay.Config, bitrate: Int = 150_000_000) async throws {
        guard !isRunning else { return }
        let w = Int(config.pixelWidth), h = Int(config.pixelHeight)

        // 实验参数可以用启动参数覆盖：-codec h264  -frameDelay0 NO  -bitrate 200
        let ud = UserDefaults.standard
        var es = VideoEncoder.Settings(width: Int32(w), height: Int32(h), fps: Int(config.refreshRate), bitrate: bitrate)
        if ud.string(forKey: "codec") == "h264" { es.preferredCodec = .h264 }
        if ud.object(forKey: "frameDelay0") != nil { es.zeroFrameDelay = ud.bool(forKey: "frameDelay0") }
        if ud.object(forKey: "lowLatency") != nil { es.allowLowLatency = ud.bool(forKey: "lowLatency") }
        if ud.bool(forKey: "speed") { es.prioritizeSpeed = true }
        if ud.object(forKey: "expectedFPS") != nil { es.setExpectedFrameRate = ud.bool(forKey: "expectedFPS") }
        let chroma444 = ud.bool(forKey: "chroma444")
        es.chroma444 = chroma444
        if ud.integer(forKey: "bitrate") > 0 { es.bitrate = ud.integer(forKey: "bitrate") * 1_000_000 }
        let encoder = try VideoEncoder(es)
        self.encoder = encoder
        codecDescription = "\(encoder.codec.name)\(chroma444 ? " 4:4:4" : "")\(encoder.lowLatency ? "（低延迟）" : "") \(es.bitrate / 1_000_000) Mbps"

        let view = showWindow(pointSize: NSSize(width: CGFloat(config.pointWidth), height: CGFloat(config.pointHeight)))
        let stats = self.stats
        let decoder = self.decoder

        encoder.onEncoded = { [decodeQueue] out in
            let wire = out.frame.serialized()
            stats.addEncoded(bytes: wire.count, ms: out.encodeMs, keyframe: out.frame.header.isKeyframe)
            // 模拟接收端：从字节流还原
            decodeQueue.async {
                guard let header = FrameHeader(wire.prefix(WireFormat.headerSize)),
                      let frame = EncodedFrame(header: header, payload: wire.dropFirst(WireFormat.headerSize))
                else { return }
                decoder.decode(frame)
            }
        }
        let snapshot = self.snapshot
        decoder.onDecoded = { out in
            view.display(out.pixelBuffer)
            snapshot.offerDecoded(out.pixelBuffer, captureNs: out.header.captureTimeNs)
            let latency = Double(Int64(bitPattern: Clock.nowNs() &- out.header.captureTimeNs)) / 1e6
            stats.addDecoded(ms: out.decodeMs, latencyMs: latency)
        }
        decoder.onNeedKeyframe = { [weak encoder] in encoder?.requestKeyframe() }

        capturer.onFrame = { [weak encoder] f in
            stats.addCaptured(arrivalDelayMs: Double(Int64(bitPattern: Clock.nowNs() &- f.captureNs)) / 1e6)
            // 系统给的 displayTime 指向下一次刷新（比回调晚 5–8ms），用回调到达时刻当抓屏时刻
            let now = Clock.nowNs()
            snapshot.offerSource(f.pixelBuffer, captureNs: now)
            encoder?.encode(f.pixelBuffer, pts: f.pts, captureNs: now)
        }
        capturer.onStopped = { [weak self] _ in
            DispatchQueue.main.async { self?.stop() }
        }

        _ = stats.take()
        try await capturer.start(displayID: displayID, pixelWidth: w, pixelHeight: h, fps: Int(config.refreshRate), chroma444: chroma444)
        isRunning = true
        Log.info("本机回环已开始：\(codecDescription)")
    }

    func stop() {
        guard isRunning || window != nil else { return }
        isRunning = false
        let capturer = self.capturer
        Task { await capturer.stop() }
        encoder = nil
        decodeQueue.async { [decoder] in decoder.invalidate() }
        window?.delegate = nil
        window?.close()
        window = nil
        videoView = nil
        Log.info("本机回环已停止")
        onStopped?()
    }

    /// 预览窗口放在主屏，内容 1440×932 点；在 Retina 主屏上正好 1:1 像素，方便看文字清晰度
    private func showWindow(pointSize: NSSize) -> VideoView {
        let screen = NSScreen.screens.first!
        let vf = screen.visibleFrame
        let size = NSSize(width: min(pointSize.width, vf.width - 40), height: min(pointSize.height, vf.height - 40))
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "AirDisplay 本机回环预览（显示的是虚拟屏的画面）"
        win.isReleasedWhenClosed = false
        win.contentAspectRatio = pointSize
        let view = VideoView(frame: NSRect(origin: .zero, size: size))
        win.contentView = view
        win.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        win.delegate = self
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.orderFrontRegardless()
        window = win
        videoView = view
        return view
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        stop()
    }
}
