import CoreGraphics
import Foundation

/// M5：接收端（Air）→ 发送端（Pro）的键鼠事件。固定 32 字节，和帧头/控制消息一样先读 32 字节再按 magic 分流。
///   magic u32 "ADI1" | kind u8 | button u8 | clickCount u8 | pad u8
///   x f32 | y f32 （0…1，相对虚拟屏，左上角为原点）
///   dx f32 | dy f32 （滚动量）
///   keyCode u16 | pad u16 | flags u32
struct InputEvent {
    enum Kind: UInt8 {
        case mouseMove = 1
        case mouseDown = 2
        case mouseUp = 3
        case mouseDrag = 4
        case scrollPixel = 5
        case scrollLine = 6
        case keyDown = 7
        case keyUp = 8
        case flagsChanged = 9
    }

    static let magic: UInt32 = 0x4144_4931  // "ADI1"
    static let size = 32

    var kind: Kind
    /// 0 左键，1 右键，2+ 其他
    var button: UInt8 = 0
    var clickCount: UInt8 = 1
    var x: Float = 0
    var y: Float = 0
    var dx: Float = 0
    var dy: Float = 0
    var keyCode: UInt16 = 0
    var flags: UInt32 = 0

    func encoded() -> Data {
        var d = Data(capacity: Self.size)
        d.appendBE(Self.magic)
        d.append(kind.rawValue)
        d.append(button)
        d.append(clickCount)
        d.append(0)
        d.appendBE(x.bitPattern)
        d.appendBE(y.bitPattern)
        d.appendBE(dx.bitPattern)
        d.appendBE(dy.bitPattern)
        d.appendBE(keyCode)
        d.appendBE(UInt16(0))
        d.appendBE(flags)
        return d
    }

    init(kind: Kind) { self.kind = kind }

    init?(_ d: Data) {
        guard d.count >= Self.size else { return nil }
        var r = ByteReader(d)
        guard r.readBE(UInt32.self) == Self.magic, let k = Kind(rawValue: r.readU8()) else { return nil }
        kind = k
        button = r.readU8()
        clickCount = r.readU8()
        _ = r.readU8()
        x = Float(bitPattern: r.readBE(UInt32.self))
        y = Float(bitPattern: r.readBE(UInt32.self))
        dx = Float(bitPattern: r.readBE(UInt32.self))
        dy = Float(bitPattern: r.readBE(UInt32.self))
        keyCode = r.readBE(UInt16.self)
        _ = r.readBE(UInt16.self)
        flags = r.readBE(UInt32.self)
    }

    static func isInput(_ header: Data) -> Bool {
        guard header.count >= 4 else { return false }
        var r = ByteReader(header)
        return r.readBE(UInt32.self) == magic
    }
}
