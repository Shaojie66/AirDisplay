import AppKit
import Network

/// M3：监听 TCP（Bonjour 广播 _airdisplay._tcp），接收端连上后开始抓屏 + 编码 + 发送。
/// 同一时间只服务一个接收端；新连接会顶掉旧的。
// 网络可变状态仅在 queue 上访问；UI 配置在 MainActor 上，编码描述由锁保护。
// 输入回调仅在 start 前配置；对外快照通过 queue.sync 读取。
// 跨队列启动/停止使用代号和 OperationGate 隔离。
final class StreamServer: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case listening
        case streaming(peer: String, interface: String)
    }

    @MainActor var onStateChange: ((State) -> Void)?
    /// 需要虚拟屏的 displayID 和配置；虚拟屏没开时返回 nil
    @MainActor var displayProvider: (() -> (CGDirectDisplayID, VirtualDisplay.Config)?)?

    let stats = PipelineStats()
    private var currentState: State = .stopped
    var state: State { queue.sync { currentState } }
    private let descriptionLock = NSLock()
    private var codecText = ""
    private(set) var codecDescription: String {
        get { descriptionLock.withLock { codecText } }
        set { descriptionLock.withLock { codecText = newValue } }
    }

    private let queue = DispatchQueue(label: "airdisplay.server", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var reader: MessageReader?
    private let capturer = ScreenCapturer()
    private var encoder: VideoEncoder?
    private let gate: OperationGate
    private var generation: UInt64 = 0
    private var starting = false
    private var suspended = false
    private var startupTask: Task<Void, Never>?
    private var stopTask: Task<Void, Error>?
    private var deliveredFrame = false
    @MainActor var onFailure: ((String) -> Void)?

    init(gate: OperationGate) { self.gate = gate }

    var deliveryID: UInt64? {
        queue.sync { connection != nil && deliveredFrame && encoder != nil && !starting && !suspended ? generation : nil }
    }
    var hasDeliveredFrame: Bool { deliveryID != nil }
    var hasPeer: Bool { queue.sync { connection != nil } }

    /// 与消息读取串行，先丢弃已排队的旧输入，再核对确切流代号并启用输入。
    func confirmInput(operation: UInt64, frameID: UInt64) -> Bool {
        queue.sync {
            let valid = generation == frameID && connection != nil && deliveredFrame && encoder != nil && !starting && !suspended
            return valid && gate.confirm(operation)
        }
    }

    /// 用户开关：用 4:4:4（还要接收端支持）
    @MainActor var prefer444: () -> Bool = { false }
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
        queue.async { self.startListener() }
    }

    private func startListener() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: AirNet.tcpParameters())
            l.service = NWListener.Service(name: "AirDisplay", type: AirNet.serviceType)
            l.stateUpdateHandler = { [weak self, weak l] s in
                guard let self, let l, self.listener === l else { return }
                Log.info("监听状态：\(s)")
                if case .ready = s { self.setState(.listening) }
                if case .failed = s { self.restartListener() }
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
                let work = DispatchWorkItem { [weak self, weak c] in
                    guard let self, let c, self.connection === c else { return }
                    self.beginStreamingIfNeeded()
                }
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
            guard let self, c === self.connection else { return }
            if case .input(let ev) = msg {
                self.gate.input { self.onInput?(ev) }
                return
            }
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
        guard !suspended, gate.ticket != nil, connection != nil, encoder == nil, !starting,
              let p = streamingPeer else { return }
        startStreaming(peer: p.peer, interface: p.interface)
    }

    /// 设置变了（比如 4:4:4 开关），在推流中就重启编码
    func restartStreamingIfActive() {
        queue.async { [self] in
            guard !suspended, gate.permitsOrdinaryRestart, connection != nil, encoder != nil else { return }
            let stopped = stopStreaming(reason: "设置变更，重启编码")
            let epoch = generation
            Task {
                do { try await stopped.value } catch { return }
                self.queue.async {
                    guard self.generation == epoch else { return }
                    self.beginStreamingIfNeeded()
                }
            }
        }
    }

    /// 调用方先关闭共享 gate；返回前等待旧启动、停止和回调会话退出。
    func pauseAndWait() async throws {
        let task: Task<Void, Error> = await withCheckedContinuation { continuation in
            queue.async { [self] in
                suspended = true
                helloTimeout?.cancel(); helloTimeout = nil
                continuation.resume(returning: stopStreaming(reason: "显示连接恢复，暂停推流"))
            }
        }
        try await task.value
    }

    func resume() {
        guard let ticket = gate.ticket else { return }
        queue.async { [self] in
            guard gate.isCurrent(ticket) else { return }
            suspended = false
            beginStreamingIfNeeded()
        }
    }

    private func startStreaming(peer: String, interface: String) {
        guard let ticket = gate.ticket, !suspended, !starting else { return }
        generation &+= 1
        let run = generation, previousStop = stopTask
        starting = true
        startupTask = Task { @MainActor [self] in
            do {
                try await previousStop?.value
                guard gate.isCurrent(ticket), queue.sync(execute: { generation == run && !suspended && connection != nil }) else { return }
                guard let (id, config) = displayProvider?() else { throw ScreenCapturer.Failure.displayNotFound }
                let w = Int(config.pixelWidth), h = Int(config.pixelHeight)
                let use444 = prefer444() && queue.sync { peerSupports444 }
                var es = VideoEncoder.Settings(width: Int32(w), height: Int32(h), fps: Int(config.refreshRate))
                es.chroma444 = use444
                if use444 { es.bitrate = 300_000_000 }
                let enc = try VideoEncoder(es)
                codecDescription = "\(enc.codec.name) \(use444 ? "4:4:4" : "4:2:0") \(es.bitrate / 1_000_000) Mbps"
                enc.onEncoded = { [weak self] out in self?.sendFrame(out, generation: run, ticket: ticket) }
                let installed = queue.sync { () -> Bool in
                    guard generation == run, !suspended, gate.isCurrent(ticket) else { return false }
                    using444 = use444
                    encoder = enc
                    deliveredFrame = false
                    inFlight = 0
                    droppedSinceKeyframe = false
                    keyframeRequested = false
                    return true
                }
                guard installed else { return }
                let stats = self.stats
                capturer.onFrame = { [weak enc, gate] f in
                    guard gate.isCurrent(ticket) else { return }
                    stats.addCaptured(arrivalDelayMs: 0)
                    enc?.encode(f.pixelBuffer, pts: f.pts, captureNs: Clock.nowNs())
                }
                capturer.onStopped = { [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        guard self.generation == run else { return }
                        self.gate.disableInput { self.onInputPeerGone?() }
                        self.connection?.cancel()
                    }
                }
                _ = stats.take()
                try await capturer.start(displayID: id, pixelWidth: w, pixelHeight: h, fps: Int(config.refreshRate), chroma444: use444)
                self.queue.async {
                    guard self.generation == run, self.gate.isCurrent(ticket), !self.suspended else { return }
                    self.starting = false
                    if self.deliveredFrame { self.gate.streamReady(ticket) }
                    self.setState(.streaming(peer: peer, interface: interface))
                }
            } catch {
                self.queue.async {
                    guard self.generation == run else { return }
                    self.starting = false
                    Log.info("推流启动失败：\(error.localizedDescription)")
                    DispatchQueue.main.async {
                        guard self.gate.isCurrent(ticket), self.queue.sync(execute: { self.encoder == nil && !self.starting }) else { return }
                        self.onFailure?("推流启动失败")
                    }
                    self.connection?.cancel()
                }
            }
        }
    }

    @discardableResult
    private func stopStreaming(reason: String) -> Task<Void, Error> {
        generation &+= 1
        let run = generation, startup = startupTask, previous = stopTask, gateEpoch = gate.epoch
        startupTask = nil; starting = false; deliveredFrame = false
        gate.disableInput { onInputPeerGone?() }
        Log.info("停止推流：\(reason)")
        encoder = nil
        let capturer = self.capturer
        let task = Task { @MainActor in
            _ = await previous?.result
            _ = await startup?.result
            try await capturer.stop()
        }
        stopTask = task
        Task {
            do {
                try await task.value
                self.queue.async {
                    guard self.generation == run, self.listener != nil else { return }
                    self.setState(.listening)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.gate.owns(gateEpoch), self.queue.sync(execute: { self.generation == run }) else { return }
                    self.onFailure?("停止抓屏失败，保持暂停")
                }
            }
        }
        return task
    }

    /// 编码器回调线程 → 切到 server 队列发送
    ///
    /// 网络跟不上时（积压 ≥ maxInFlight）关键帧也一起丢：关键帧最大，堵的时候硬塞只会越堵越多。
    /// 积压消化到阈值以下后只请求一次关键帧，发出去后恢复正常。
    private func sendFrame(_ out: VideoEncoder.Output, generation run: UInt64, ticket: UInt64) {
        queue.async { [self] in
            guard generation == run, gate.isCurrent(ticket), !suspended, let c = connection, encoder != nil else { return }
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
                guard self.generation == run, c === self.connection, self.gate.isCurrent(ticket) else { return }
                self.inFlight = max(0, self.inFlight - 1)
                if let err {
                    Log.info("发送失败：\(err)")
                    self.gate.disableInput { self.onInputPeerGone?() }
                    c.cancel()
                    return
                }
                if !self.deliveredFrame && key {
                    self.deliveredFrame = true
                    if !self.starting { self.gate.streamReady(ticket) }
                }
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
        // 启动失败后的断线可能仍是 listening，也需通知 UI 重新评估 hasPeer 和自动移除。
        currentState = s
        notify()
    }

    private func notify() {
        let s = currentState
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(s) }
    }
}
