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

    /// 已提交但还没写进 socket 的帧数；太多说明网络跟不上，丢非关键帧
    private var inFlight = 0
    private let maxInFlight = 3
    private var droppedSinceKeyframe = false

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
                    self.stopStreaming(reason: "新接收端顶替")
                }
                self.connection = c
                self.startReading(c)
                self.startStreaming(peer: "\(c.endpoint)", interface: name)
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
        connection = nil
        reader = nil
        stopStreaming(reason: "接收端断开")
    }

    private func startReading(_ c: NWConnection) {
        let reader = MessageReader(connection: c, onMessage: { [weak self] msg in
            guard let self, case .control(let m) = msg else { return }
            switch m.kind {
            case .requestKeyframe:
                self.encoder?.requestKeyframe()
            case .ping:
                self.send(ControlMessage(kind: .pong, a: m.a, b: Clock.nowNs()).encoded(), on: c)
            case .pong:
                break
            }
        }, onClose: { [weak c] _ in c?.cancel() })
        self.reader = reader   // 必须持有，否则读取回调里的 weak self 立刻变 nil
        reader.start()
    }

    // MARK: - 推流

    private func startStreaming(peer: String, interface: String) {
        DispatchQueue.main.async { [self] in
            guard let (id, config) = displayProvider?() else {
                Log.info("虚拟屏没开，无法推流")
                connection?.cancel()
                return
            }
            let w = Int(config.pixelWidth), h = Int(config.pixelHeight)
            do {
                let enc = try VideoEncoder(.init(width: Int32(w), height: Int32(h), fps: Int(config.refreshRate)))
                codecDescription = "\(enc.codec.name) 150 Mbps"
                enc.onEncoded = { [weak self] out in self?.sendFrame(out) }
                queue.sync {
                    encoder = enc
                    inFlight = 0
                    droppedSinceKeyframe = false
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
                    try await capturer.start(displayID: id, pixelWidth: w, pixelHeight: h, fps: Int(config.refreshRate))
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
    private func sendFrame(_ out: VideoEncoder.Output) {
        queue.async { [self] in
            guard let c = connection, encoder != nil else { return }
            let key = out.frame.header.isKeyframe
            if !key && (inFlight >= maxInFlight || droppedSinceKeyframe) {
                // 网络堵了：丢帧，等下一个关键帧恢复，避免花屏
                if !droppedSinceKeyframe { Log.info("发送积压 \(inFlight) 帧，开始丢帧并请求关键帧") }
                droppedSinceKeyframe = true
                encoder?.requestKeyframe()
                return
            }
            if key { droppedSinceKeyframe = false }
            let wire = out.frame.serialized()
            stats.addEncoded(bytes: wire.count, ms: out.encodeMs, keyframe: key)
            inFlight += 1
            c.send(content: wire, completion: .contentProcessed { [weak self] err in
                guard let self else { return }
                self.inFlight -= 1
                if let err { Log.info("发送失败：\(err)") }
            })
        }
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
