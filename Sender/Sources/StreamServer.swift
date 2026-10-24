import AppKit
import Network

/// M3：监听 TCP（Bonjour 广播 _airdisplay._tcp），接收端连上后开始抓屏 + 编码 + 发送。
/// 同一时间只服务一个接收端；新连接会顶掉旧的。
final class StreamServer {
    enum State: Equatable {
        case stopped
        case listening
        case streaming(peer: String, interface: String)
    }

    var onStateChange: ((State) -> Void)?
    /// 需要虚拟屏的 displayID 和配置；虚拟屏没开时返回 nil
    var displayProvider: (() -> (CGDirectDisplayID, VirtualDisplay.Config)?)?

    let stats = PipelineStats()
    private(set) var state: State = .stopped { didSet { if state != oldValue { notify() } } }
    private(set) var codecDescription = ""

    private let queue = DispatchQueue(label: "airdisplay.server", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var reader: MessageReader?
    private let capturer = ScreenCapturer()
    private var encoder: VideoEncoder?

    /// 用户开关：用 4:4:4（还要接收端支持）
    var prefer444: () -> Bool = { false }
    /// M5：Air 发来的键鼠事件
    var onInput: ((InputEvent) -> Void)?
    /// 接收端断开或被顶替：用来让键鼠注入补发抬起事件
    var onInputPeerGone: (() -> Void)?
    private var peerSupports444 = false
    private var helloTimeout: DispatchWorkItem?
    private var streamingPeer: (peer: String, interface: String)?
    private(set) var using444 = false

    /// 已提交但还没写进 socket 的帧数；太多说明网络跟不上，开始丢帧（关键帧也丢）
    private var inFlight = 0
    private let maxInFlight = 3
    /// 丢过帧，下一个发出去的必须是关键帧
    private var droppedSinceKeyframe = false
    /// 这一轮丢帧已经向编码器要过关键帧（积压消化后只要一次）
    private var keyframeRequested = false

    // MARK: - 监听

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: AirNet.tcpParameters())
            l.service = NWListener.Service(name: "AirDisplay", type: AirNet.serviceType)
            l.stateUpdateHandler = { [weak self] s in
                Log.info("监听状态：\(s)")
                if case .ready = s { self?.setState(.listening) }
                if case .failed = s { self?.restartListener() }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
        } catch {
            Log.info("监听失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        queue.async { [self] in
            stopStreaming(reason: "停止服务")
            listener?.cancel()
            listener = nil
            setState(.stopped)
        }
    }

    private func restartListener() {
        listener?.cancel()
        listener = nil
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }

    // MARK: - 连接

    private func accept(_ c: NWConnection) {
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c else { return }
            switch s {
            case .ready:
                let iface = AirNet.interface(of: c)
                let name = iface?.name ?? "?"
                if iface?.type == .wifi {
                    Log.info("拒绝来自 Wi‑Fi（\(name)）的连接，只接受雷雳网桥")
                    c.cancel()
                    return
                }
                Log.info("接收端已连接：\(c.endpoint)，网卡 \(name)")
                if let old = self.connection, old !== c {
                    old.cancel()
                    self.onInputPeerGone?()
                    self.stopStreaming(reason: "新接收端顶替")
                }
                self.connection = c
                self.peerSupports444 = false
                self.streamingPeer = ("\(c.endpoint)", name)
                self.startReading(c)
                // 等接收端报能力（hello），旧版接收端不发，300ms 后按 4:2:0 开始
                let work = DispatchWorkItem { [weak self] in self?.beginStreamingIfNeeded() }
                self.helloTimeout = work
                self.queue.asyncAfter(deadline: .now() + 0.3, execute: work)
            case .failed(let e):
                Log.info("连接失败：\(e)")
                self.connectionEnded(c)
            case .cancelled:
                self.connectionEnded(c)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func connectionEnded(_ c: NWConnection) {
        guard c === connection else { return }
        helloTimeout?.cancel()
        helloTimeout = nil
        streamingPeer = nil
        connection = nil
        reader = nil
        onInputPeerGone?()
        stopStreaming(reason: "接收端断开")
    }

    private func startReading(_ c: NWConnection) {
        let reader = MessageReader(connection: c, onMessage: { [weak self] msg in
            guard let self else { return }
            if case .input(let ev) = msg { self.onInput?(ev); return }
            guard case .control(let m) = msg else { return }
            switch m.kind {
            case .requestKeyframe:
                self.encoder?.requestKeyframe()
            case .ping:
                self.send(ControlMessage(kind: .pong, a: m.a, b: Clock.nowNs()).encoded(), on: c)
            case .pong:
                break
            case .hello:
                self.peerSupports444 = m.a & ControlMessage.Capability.hevc444 != 0
                Log.info("接收端能力：HEVC 4:4:4 \(self.peerSupports444 ? "支持" : "不支持")")
                self.helloTimeout?.cancel()
                self.beginStreamingIfNeeded()
            }
        }, onClose: { [weak c] _ in c?.cancel() })
        self.reader = reader   // 必须持有，否则读取回调里的 weak self 立刻变 nil
        reader.start()
    }

    // MARK: - 推流

    private func beginStreamingIfNeeded() {
        helloTimeout = nil
        guard connection != nil, encoder == nil, let p = streamingPeer else { return }
        startStreaming(peer: p.peer, interface: p.interface)
    }

    /// 设置变了（比如 4:4:4 开关），在推流中就重启编码
    func restartStreamingIfActive() {
        queue.async { [self] in
            guard connection != nil, encoder != nil, let p = streamingPeer else { return }
            stopStreaming(reason: "设置变更，重启编码")
            queue.asyncAfter(deadline: .now() + 0.3) { [self] in
                guard connection != nil, encoder == nil else { return }
                startStreaming(peer: p.peer, interface: p.interface)
            }
        }
    }

    private func startStreaming(peer: String, interface: String) {
        DispatchQueue.main.async { [self] in
            guard let (id, config) = displayProvider?() else {
                Log.info("虚拟屏没开，无法推流")
                connection?.cancel()
                return
            }
            let w = Int(config.pixelWidth), h = Int(config.pixelHeight)
            let use444 = prefer444() && queue.sync { peerSupports444 }
            using444 = use444
            do {
                var es = VideoEncoder.Settings(width: Int32(w), height: Int32(h), fps: Int(config.refreshRate))
                es.chroma444 = use444
                if use444 { es.bitrate = 300_000_000 }
                let enc = try VideoEncoder(es)
                codecDescription = "\(enc.codec.name) \(use444 ? "4:4:4" : "4:2:0") \(es.bitrate / 1_000_000) Mbps"
                enc.onEncoded = { [weak self] out in self?.sendFrame(out) }
                queue.sync {
                    encoder = enc
                    inFlight = 0
                    droppedSinceKeyframe = false
                    keyframeRequested = false
                }
                let stats = self.stats
                capturer.onFrame = { [weak enc] f in
                    stats.addCaptured(arrivalDelayMs: 0)
                    enc?.encode(f.pixelBuffer, pts: f.pts, captureNs: Clock.nowNs())
                }
            } catch {
                Log.info("编码器创建失败：\(error.localizedDescription)")
                return
            }
            _ = stats.take()
            Task {
                do {
                    try await capturer.start(displayID: id, pixelWidth: w, pixelHeight: h, fps: Int(config.refreshRate), chroma444: use444)
                    self.queue.async { self.setState(.streaming(peer: peer, interface: interface)) }
                } catch {
                    Log.info("抓屏启动失败：\(error.localizedDescription)")
                    self.queue.async { self.connection?.cancel() }
                }
            }
        }
    }

    private func stopStreaming(reason: String) {
        guard encoder != nil else { return }
        Log.info("停止推流：\(reason)")
        encoder = nil
        let capturer = self.capturer
        Task { await capturer.stop() }
        if listener != nil { setState(.listening) }
    }

    /// 编码器回调线程 → 切到 server 队列发送
    ///
    /// 网络跟不上时（积压 ≥ maxInFlight）关键帧也一起丢：关键帧最大，堵的时候硬塞只会越堵越多。
    /// 积压消化到阈值以下后只请求一次关键帧，发出去后恢复正常。
    private func sendFrame(_ out: VideoEncoder.Output) {
        queue.async { [self] in
            guard let c = connection, encoder != nil else { return }
            let key = out.frame.header.isKeyframe
            if inFlight >= maxInFlight {
                if !droppedSinceKeyframe { Log.info("发送积压 \(inFlight) 帧，开始丢帧，等积压消化后请求关键帧") }
                droppedSinceKeyframe = true
                // 这个关键帧没发出去，消化后要重新请求
                if key { keyframeRequested = false }
                return
            }
            if droppedSinceKeyframe && !key {
                // 积压已经消化：要一次关键帧，期间的普通帧丢掉，避免花屏
                requestKeyframeOnceAfterDrop()
                return
            }
            if key {
                droppedSinceKeyframe = false
                keyframeRequested = false
            }
            let wire = out.frame.serialized()
            stats.addEncoded(bytes: wire.count, ms: out.encodeMs, keyframe: key)
            inFlight += 1
            c.send(content: wire, completion: .contentProcessed { [weak self] err in
                guard let self else { return }
                self.inFlight = max(0, self.inFlight - 1)
                if let err { Log.info("发送失败：\(err)"); return }
                if self.inFlight < self.maxInFlight { self.requestKeyframeOnceAfterDrop() }
            })
        }
    }

    /// 在 server 队列调用
    private func requestKeyframeOnceAfterDrop() {
        guard droppedSinceKeyframe, !keyframeRequested, let encoder else { return }
        keyframeRequested = true
        encoder.requestKeyframe()
    }

    private func send(_ data: Data, on c: NWConnection) {
        c.send(content: data, completion: .contentProcessed { _ in })
    }

    private func setState(_ s: State) {
        state = s
    }

    private func notify() {
        let s = state
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(s) }
    }
}
