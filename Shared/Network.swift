import Foundation
import Network

/// 网络约定：Bonjour 服务类型、TCP 参数、控制消息、接收端拆包。
enum AirNet {
    static let serviceType = "_airdisplay._tcp"
    /// 雷雳网桥接口名。视频只走这块网卡，不走 Wi‑Fi。
    static let bridgeInterfaceName = "bridge0"

    /// requiredInterface 不为空时连接被钉死在这块网卡上（接收端传 bridge0）
    static func tcpParameters(requiredInterface: NWInterface? = nil) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        if let requiredInterface {
            params.requiredInterface = requiredInterface
        }
        return params
    }

    /// 连接实际走的网卡（拿不到返回 nil）
    static func interface(of connection: NWConnection) -> NWInterface? {
        connection.currentPath?.availableInterfaces.first
    }
}

/// 控制消息，固定 32 字节，和视频帧头一样长，接收端先读 32 字节再按 magic 分流。
///   magic u32 "ADC1" | type u8 | pad 3 | a u64 | b u64 | pad 8
struct ControlMessage {
    enum Capability {
        static let hevc444: UInt64 = 1 << 0
    }

    enum Kind: UInt8 {
        /// 接收端 → 发送端：请补一个关键帧
        case requestKeyframe = 1
        /// 接收端 → 发送端：a = 接收端时间
        case ping = 2
        /// 发送端 → 接收端：a = 原样带回的接收端时间，b = 发送端时间
        case pong = 3
        /// 接收端 → 发送端，连上后第一条：a = 能力位（bit0 = 能硬件解 HEVC 4:4:4）
        case hello = 4
    }

    static let magic: UInt32 = 0x4144_4331  // "ADC1"
    static let size = 32

    var kind: Kind
    var a: UInt64 = 0
    var b: UInt64 = 0

    func encoded() -> Data {
        var d = Data(capacity: Self.size)
        d.appendBE(Self.magic)
        d.append(kind.rawValue)
        d.append(contentsOf: [0, 0, 0])
        d.appendBE(a)
        d.appendBE(b)
        d.append(contentsOf: [UInt8](repeating: 0, count: 8))
        return d
    }

    init(kind: Kind, a: UInt64 = 0, b: UInt64 = 0) {
        self.kind = kind; self.a = a; self.b = b
    }

    init?(_ d: Data) {
        guard d.count >= Self.size else { return nil }
        var r = ByteReader(d)
        guard r.readBE(UInt32.self) == Self.magic, let k = Kind(rawValue: r.readU8()) else { return nil }
        _ = r.readU8(); _ = r.readU8(); _ = r.readU8()
        kind = k
        a = r.readBE(UInt64.self)
        b = r.readBE(UInt64.self)
    }

    static func isControl(_ header: Data) -> Bool {
        guard header.count >= 4 else { return false }
        var r = ByteReader(header)
        return r.readBE(UInt32.self) == magic
    }
}

/// 从 NWConnection 连续读取：32 字节头 → 控制消息，或帧头 + payload。
final class MessageReader {
    enum Message {
        case control(ControlMessage)
        case input(InputEvent)
        case frame(EncodedFrame, wireBytes: Int)
    }

    private let connection: NWConnection
    private let onMessage: (Message) -> Void
    private let onClose: (Error?) -> Void

    init(connection: NWConnection, onMessage: @escaping (Message) -> Void, onClose: @escaping (Error?) -> Void) {
        self.connection = connection
        self.onMessage = onMessage
        self.onClose = onClose
    }

    func start() { readHeader() }

    private func readHeader() {
        let size = WireFormat.headerSize
        connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] data, _, done, error in
            guard let self else { return }
            guard let data, data.count == size, error == nil else {
                self.onClose(error)
                return
            }
            if ControlMessage.isControl(data) {
                if let msg = ControlMessage(data) { self.onMessage(.control(msg)) }
                self.readHeader()
            } else if InputEvent.isInput(data) {
                if let ev = InputEvent(data) { self.onMessage(.input(ev)) }
                self.readHeader()
            } else if let header = FrameHeader(data) {
                self.readPayload(header)
            } else {
                self.onClose(NSError(domain: "AirDisplay", code: 2,
                                     userInfo: [NSLocalizedDescriptionKey: "收到无法识别的数据，断开"]))
            }
            if done { self.onClose(nil) }
        }
    }

    private func readPayload(_ header: FrameHeader) {
        let len = Int(header.payloadLength)
        guard len > 0 else { readHeader(); return }
        connection.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, data.count == len, error == nil else {
                self.onClose(error)
                return
            }
            if let frame = EncodedFrame(header: header, payload: data) {
                self.onMessage(.frame(frame, wireBytes: WireFormat.headerSize + len))
            }
            self.readHeader()
        }
    }
}
