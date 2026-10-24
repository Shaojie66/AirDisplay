import AppKit
import CoreGraphics

/// 当前在线显示器的快照，用来确认虚拟屏和随航是否共存。
struct DisplayInfo {
    let id: CGDirectDisplayID
    let name: String
    let points: CGSize
    let pixels: CGSize
    let refreshRate: Double
    let isMain: Bool

    var summary: String {
        let scale = points.width > 0 ? pixels.width / points.width : 0
        return "\(name)  \(Int(points.width))×\(Int(points.height)) @\(Int(scale))x  \(Int(refreshRate))Hz\(isMain ? "  [主屏]" : "")"
    }

    static func online() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        let names: [CGDirectDisplayID: String] = Dictionary(
            NSScreen.screens.compactMap { s in
                guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return (n.uint32Value, s.localizedName)
            },
            uniquingKeysWith: { a, _ in a }
        )

        return ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            return DisplayInfo(
                id: id,
                name: names[id] ?? "Display \(id)",
                points: CGSize(width: mode?.width ?? 0, height: mode?.height ?? 0),
                pixels: CGSize(width: mode?.pixelWidth ?? 0, height: mode?.pixelHeight ?? 0),
                refreshRate: mode?.refreshRate ?? 0,
                isMain: CGDisplayIsMain(id) != 0
            )
        }
    }
}
