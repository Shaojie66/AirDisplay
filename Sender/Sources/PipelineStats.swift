import Foundation

/// 每秒汇总一次管线统计：帧率、编解码耗时、码率、抓屏到显示的延迟。线程安全。
final class PipelineStats {
    struct Snapshot {
        var seconds: Double = 0
        var capturedFPS: Double = 0
        var encodedFPS: Double = 0
        var decodedFPS: Double = 0
        var mbps: Double = 0
        var keyframes = 0
        var encodeAvgMs: Double = 0, encodeMaxMs: Double = 0
        var decodeAvgMs: Double = 0, decodeMaxMs: Double = 0
        /// 抓屏时刻 → 解码完交给显示层（不含合成和屏幕刷新）
        var latencyAvgMs: Double = 0, latencyMaxMs: Double = 0
        /// 抓屏时间戳 → 回调到达（调试用，看时间戳的含义）
        var arrivalAvgMs: Double = 0

        var summary: String {
            String(format: "抓屏 %.0f fps · 编码 %.0f fps · 解码 %.0f fps\n编码 %.1f ms (最大 %.1f) · 解码 %.1f ms (最大 %.1f)\n抓屏→显示 %.1f ms (最大 %.1f) · 抓屏回调延迟 %.1f ms · %.1f Mbps · 关键帧 %d",
                   capturedFPS, encodedFPS, decodedFPS, encodeAvgMs, encodeMaxMs,
                   decodeAvgMs, decodeMaxMs, latencyAvgMs, latencyMaxMs, arrivalAvgMs, mbps, keyframes)
        }
    }

    private let lock = NSLock()
    private var windowStart = Clock.nowNs()
    private var captured = 0, encoded = 0, decoded = 0, bytes = 0, keyframes = 0
    private var arrSum = 0.0
    private var encSum = 0.0, encMax = 0.0, decSum = 0.0, decMax = 0.0, latSum = 0.0, latMax = 0.0

    func addCaptured(arrivalDelayMs: Double) {
        lock.lock(); captured += 1; arrSum += arrivalDelayMs; lock.unlock()
    }

    func addEncoded(bytes n: Int, ms: Double, keyframe: Bool) {
        lock.lock()
        encoded += 1; bytes += n; encSum += ms; encMax = max(encMax, ms)
        if keyframe { keyframes += 1 }
        lock.unlock()
    }

    func addDecoded(ms: Double, latencyMs: Double) {
        lock.lock()
        decoded += 1; decSum += ms; decMax = max(decMax, ms)
        latSum += latencyMs; latMax = max(latMax, latencyMs)
        lock.unlock()
    }

    /// 取出这段时间的统计并清零
    func take() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let now = Clock.nowNs()
        let secs = max(Double(now - windowStart) / 1e9, 0.001)
        var s = Snapshot()
        s.seconds = secs
        s.capturedFPS = Double(captured) / secs
        s.encodedFPS = Double(encoded) / secs
        s.decodedFPS = Double(decoded) / secs
        s.mbps = Double(bytes) * 8 / secs / 1e6
        s.keyframes = keyframes
        s.encodeAvgMs = encoded > 0 ? encSum / Double(encoded) : 0
        s.encodeMaxMs = encMax
        s.decodeAvgMs = decoded > 0 ? decSum / Double(decoded) : 0
        s.decodeMaxMs = decMax
        s.latencyAvgMs = decoded > 0 ? latSum / Double(decoded) : 0
        s.latencyMaxMs = latMax
        s.arrivalAvgMs = captured > 0 ? arrSum / Double(captured) : 0
        windowStart = now
        captured = 0; encoded = 0; decoded = 0; bytes = 0; keyframes = 0
        arrSum = 0; encSum = 0; encMax = 0; decSum = 0; decMax = 0; latSum = 0; latMax = 0
        return s
    }
}
