import Foundation

/// 视频帧的线上格式（Sender → Receiver）。所有整数大端序。
///
/// 帧头 32 字节：
///   magic u32 "ADF1" | version u8 | flags u8 (bit0 关键帧) | codec u8 | reserved u8
///   frameNumber u64 | captureTimeNs u64 | width u16 | height u16 | payloadLength u32
///
/// payload：
///   关键帧：paramSetCount u8，然后每个参数集 (len u16 + bytes)（H.264: SPS/PPS；HEVC: VPS/SPS/PPS）
///   之后是编码数据，AVCC 格式（每个 NAL 前 4 字节长度）
enum WireFormat {
    static let magic: UInt32 = 0x4144_4631  // "ADF1"
    static let version: UInt8 = 1
    static let headerSize = 32
}

enum VideoCodec: UInt8 {
    case h264 = 1
    case hevc = 2

    var name: String { self == .h264 ? "H.264" : "HEVC" }
}

struct FrameHeader {
    var isKeyframe: Bool
    var codec: VideoCodec
    var frameNumber: UInt64
    /// 抓屏时刻（发送端 CLOCK_UPTIME_RAW，纳秒）
    var captureTimeNs: UInt64
    var width: UInt16
    var height: UInt16
    var payloadLength: UInt32

    func encoded() -> Data {
        var d = Data(capacity: WireFormat.headerSize)
        d.appendBE(WireFormat.magic)
        d.append(WireFormat.version)
        d.append(isKeyframe ? 1 : 0)
        d.append(codec.rawValue)
        d.append(0)
        d.appendBE(frameNumber)
        d.appendBE(captureTimeNs)
        d.appendBE(width)
        d.appendBE(height)
        d.appendBE(payloadLength)
        return d
    }

    init(isKeyframe: Bool, codec: VideoCodec, frameNumber: UInt64, captureTimeNs: UInt64,
         width: UInt16, height: UInt16, payloadLength: UInt32) {
        self.isKeyframe = isKeyframe; self.codec = codec; self.frameNumber = frameNumber
        self.captureTimeNs = captureTimeNs; self.width = width; self.height = height
        self.payloadLength = payloadLength
    }

    /// 解析 32 字节帧头；格式不对返回 nil。
    init?(_ d: Data) {
        guard d.count >= WireFormat.headerSize else { return nil }
        var r = ByteReader(d)
        guard r.readBE(UInt32.self) == WireFormat.magic,
              r.readU8() == WireFormat.version else { return nil }
        let flags = r.readU8()
        guard let codec = VideoCodec(rawValue: r.readU8()) else { return nil }
        _ = r.readU8()
        self.isKeyframe = flags & 1 != 0
        self.codec = codec
        self.frameNumber = r.readBE(UInt64.self)
        self.captureTimeNs = r.readBE(UInt64.self)
        self.width = r.readBE(UInt16.self)
        self.height = r.readBE(UInt16.self)
        self.payloadLength = r.readBE(UInt32.self)
    }
}

/// 一帧编码后的数据。
struct EncodedFrame {
    var header: FrameHeader
    /// 只有关键帧带
    var parameterSets: [Data]
    /// AVCC 格式（4 字节长度前缀的 NAL 单元）
    var data: Data

    /// 帧头 + payload，直接写到网络上
    func serialized() -> Data {
        var payload = Data()
        if header.isKeyframe {
            payload.append(UInt8(parameterSets.count))
            for ps in parameterSets {
                payload.appendBE(UInt16(ps.count))
                payload.append(ps)
            }
        }
        payload.append(data)
        var h = header
        h.payloadLength = UInt32(payload.count)
        return h.encoded() + payload
    }

    /// 由帧头和 payload 还原
    init?(header: FrameHeader, payload: Data) {
        guard payload.count == Int(header.payloadLength) else { return nil }
        var sets: [Data] = []
        var offset = 0
        if header.isKeyframe {
            guard payload.count >= 1 else { return nil }
            let n = Int(payload[payload.startIndex])
            offset = 1
            for _ in 0..<n {
                guard offset + 2 <= payload.count else { return nil }
                let s = payload.startIndex + offset
                let len = Int(payload[s]) << 8 | Int(payload[s + 1])
                offset += 2
                guard offset + len <= payload.count else { return nil }
                sets.append(payload.subdata(in: (payload.startIndex + offset)..<(payload.startIndex + offset + len)))
                offset += len
            }
        }
        self.header = header
        self.parameterSets = sets
        self.data = payload.subdata(in: (payload.startIndex + offset)..<payload.endIndex)
    }

    init(header: FrameHeader, parameterSets: [Data], data: Data) {
        self.header = header; self.parameterSets = parameterSets; self.data = data
    }
}

// MARK: - 字节工具

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = data; self.offset = data.startIndex }

    mutating func readU8() -> UInt8 {
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readBE<T: FixedWidthInteger>(_: T.Type) -> T {
        var v: T = 0
        for _ in 0..<MemoryLayout<T>.size {
            v = v << 8 | T(data[offset])
            offset += 1
        }
        return v
    }
}
