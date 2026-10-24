import AppKit
import Network

/// 接收端：Bonjour 找 Sender（只认 bridge0 上发现的）→ TCP 连接钉在 bridge0 → 读帧 → 解码 → 显示。
/// 断线后自动重连。每秒 ping 一次，用最小 RTT 的样本估算两台机器的时钟差，算端到端延迟。
final class StreamClient {
    enum State: Equatable {
        case searching(hint: String)
        case connecting(String)
        case connected(String)
    }

    struct Stats {
        var fps = 0.0, mbps = 0.0, decodeMs = 0.0, latencyMs: Double?, latencyMaxMs: Double?, rttMs: Double?
        var summary: String {
            var s = String(format: "%.0f fps · %.1f Mbps · 解码 %.1f ms", fps, mbps, decodeMs)
            if let l = latencyMs, let m = latencyMaxMs { s += String(format: " · 抓屏→解码完 %.1f ms (最大 %.1f)", l, m) }
            if let r = rttMs { s += String(format: " · RTT %.2f ms", r) }
            return s
        }
    }

    var onState: ((State) -> Void)?
    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    private let queue = DispatchQueue(label: "airdisplay.client", qos: .userInteractive)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var reader: MessageReader?
    private let decoder = VideoDecoder()
    private var pingTimer: DispatchSourceTimer?
    private var lastKeyframeRequest: UInt64 = 0

    // 时钟同步：offset = 发送端时钟 - 接收端时钟
    private var syncSamples: [(rtt: UInt64, offset: Int64)] = []
    private var clockOffset: Int64?

    // 统计（只在 queue 上改）
    private var windowStart = Clock.nowNs()
    private var frames = 0, bytes = 0, decSum = 0.0, latSum = 0.0, latMax = 0.0, latCount = 0
    private var lastRtt: Double?

    private(set) var state: State = .searching(hint: "") {
        didSet {
            guard state != oldValue else { return }
            let s = state
            DispatchQueue.main.async { self.onState?(s) }
        }
    }

    init() {
        decoder.onDecoded = { [weak self] out in self?.handleDecoded(out) }
        decoder.onNeedKeyframe = { [weak self] in self?.requestKeyframe() }
    }

    func start() {
        queue.async { self.startBrowsing() }
    }

    // MARK: - 发现

    private func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: AirNet.serviceType, domain: nil), using: params)
        b.stateUpdateHandler = { s in Log.info("Bonjour 浏览状态：\(s)") }
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.pick(from: results) }
        b.start(queue: queue)
        browser = b
        state = .searching(hint: "正在寻找 Pro 上的 AirDisplay Sender…")
    }

    private func pick(from results: Set<NWBrowser.Result>) {
        guard connection == nil else { return }
        for r in results {
            Log.info("发现：\(r.endpoint) 网卡 \(r.interfaces.map(\.name))")
        }
        let bridge = AirNet.bridgeInterfaceName
        // 调试：-anyInterface YES 允许任意网卡（同一台机器上自测用）
        if UserDefaults.standard.bool(forKey: "anyInterface"), let r = results.first {
            connect(to: r.endpoint, via: nil)
            return
        }
        guard let r = results.first(where: { $0.interfaces.contains { $0.name == bridge } }),
              let iface = r.interfaces.first(where: { $0.name == bridge }) else {
            if !results.isEmpty {
                state = .searching(hint: "只在 Wi‑Fi 上找到 Sender，雷雳网桥上没有。\n请检查雷雳线是否插好、两台 Mac 的「雷雳网桥」是否已连接。")
            }
            return
        }
        connect(to: r.endpoint, via: iface)
    }

    // MARK: - 连接

    private func connect(to endpoint: NWEndpoint, via iface: NWInterface?) {
        let ifName = iface?.name ?? "任意网卡"
        Log.info("连接 \(endpoint) 经由 \(ifName)")
        state = .connecting(ifName)
        let c = NWConnection(to: endpoint, using: AirNet.tcpParameters(requiredInterface: iface))
        connection = c
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c else { return }
            switch s {
            case .ready:
                let name = AirNet.interface(of: c)?.name ?? ifName
                Log.info("已连接，网卡 \(name)")
                self.state = .connected(name)
                self.resetStats()
                self.startReading(c)
                self.startPing(c)
                self.requestKeyframe()
            case .failed(let e):
                Log.info("连接失败：\(e)")
                self.disconnected(c)
            case .waiting(let e):
                Log.info("连接等待：\(e)")
            case .cancelled:
                self.disconnected(c)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func disconnected(_ c: NWConnection) {
        guard c === connection else { return }
        c.cancel()
        connection = nil
        reader = nil
        pingTimer?.cancel()
        pingTimer = nil
        decoder.invalidate()
        syncSamples.removeAll()
        clockOffset = nil
        state = .searching(hint: "连接断开，正在重连…")
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let results = self.browser?.browseResults else { return }
            self.pick(from: results)
        }
    }

    private func startReading(_ c: NWConnection) {
        let r = MessageReader(connection: c, onMessage: { [weak self] msg in
            guard let self else { return }
            switch msg {
            case .frame(let f, let n):
                self.frames += 1
                self.bytes += n
                self.decoder.decode(f)
            case .control(let m):
                if m.kind == .pong { self.handlePong(m) }
            }
        }, onClose: { [weak self, weak c] err in
            if let err { Log.info("读取结束：\(err)") }
            if let c { self?.disconnected(c) }
        })
        reader = r
        r.start()
    }

    private func requestKeyframe() {
        let now = Clock.nowNs()
        guard now - lastKeyframeRequest > 200_000_000, let c = connection else { return }  // 最多 5 次/秒
        lastKeyframeRequest = now
        c.send(content: ControlMessage(kind: .requestKeyframe).encoded(), completion: .contentProcessed { _ in })
    }

    // MARK: - 时钟同步

    private func startPing(_ c: NWConnection) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.5)
        t.setEventHandler { [weak c] in
            c?.send(content: ControlMessage(kind: .ping, a: Clock.nowNs()).encoded(), completion: .contentProcessed { _ in })
        }
        t.resume()
        pingTimer = t
    }

    private func handlePong(_ m: ControlMessage) {
        let t1 = Clock.nowNs()
        let rtt = t1 &- m.a
        let offset = Int64(bitPattern: m.b) - Int64(bitPattern: m.a + rtt / 2)
        syncSamples.append((rtt, offset))
        if syncSamples.count > 20 { syncSamples.removeFirst() }
        if let best = syncSamples.min(by: { $0.rtt < $1.rtt }) { clockOffset = best.offset }
        lastRtt = Double(rtt) / 1e6
    }

    // MARK: - 解码输出

    private func handleDecoded(_ out: VideoDecoder.Output) {
        onPixelBuffer?(out.pixelBuffer)
        decSum += out.decodeMs
        if let off = clockOffset {
            let senderNow = Int64(bitPattern: Clock.nowNs()) + off
            let lat = Double(senderNow - Int64(bitPattern: out.header.captureTimeNs)) / 1e6
            latSum += lat; latMax = max(latMax, lat); latCount += 1
        }
    }

    private func resetStats() {
        windowStart = Clock.nowNs()
        frames = 0; bytes = 0; decSum = 0; latSum = 0; latMax = 0; latCount = 0
    }

    /// 取出这段时间的统计并清零（在主线程调用）
    func takeStats() -> Stats {
        queue.sync {
            let secs = max(Double(Clock.nowNs() - windowStart) / 1e9, 0.001)
            var s = Stats()
            s.fps = Double(frames) / secs
            s.mbps = Double(bytes) * 8 / secs / 1e6
            s.decodeMs = frames > 0 ? decSum / Double(frames) : 0
            if latCount > 0 { s.latencyMs = latSum / Double(latCount); s.latencyMaxMs = latMax }
            s.rttMs = lastRtt
            resetStats()
            return s
        }
    }
}
