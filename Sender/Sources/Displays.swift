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

    /// 查询失败、枚举中热插拔、模式暂不可读都返回 nil，而不是空集合。
    static func topology(onFailure: ((String) -> Void)? = nil) -> TopologySnapshot? {
        func fail(_ reason: String) -> TopologySnapshot? { onFailure?(reason); return nil }
        let event = VirtualDisplay.lastReconfigAt
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0, count <= 32 else { return fail("无法取得有效的在线显示器数量") }
        let capacity = count
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
        guard CGGetOnlineDisplayList(capacity, &ids, &count) == .success, count == capacity else { return fail("首次枚举显示器失败或数量发生变化") }
        var after: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &after) == .success, after == count else { return fail("复核显示器数量失败或数量发生变化") }
        var verification = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
        guard CGGetOnlineDisplayList(capacity, &verification, &after) == .success, after == count,
              Set(verification) == Set(ids) else { return fail("两次枚举的在线显示器集合不一致") }
        var records: [TopologyDisplay] = []
        for id in ids {
            let rect = CGDisplayBounds(id)
            guard rect.width > 0, rect.height > 0 else { return fail("显示器 \(id) 的尺寸暂时无效") }
            var record = TopologyDisplay(
                id: id, builtin: CGDisplayIsBuiltin(id) != 0, active: CGDisplayIsActive(id) != 0,
                main: CGDisplayIsMain(id) != 0, mirrored: CGDisplayIsInMirrorSet(id) != 0,
                x: rect.origin.x, y: rect.origin.y
            )
            if let mode = CGDisplayCopyDisplayMode(id) {
                record.width = mode.width; record.height = mode.height
                record.pixelWidth = mode.pixelWidth; record.pixelHeight = mode.pixelHeight
                record.refreshRate = mode.refreshRate
            } else {
                // Sidecar 可在线且显示几何可读，但当前进程的模式接口返回 nil。
                // 必须从两个实时来源交叉核验；不使用上次模式，也不猜测刷新率。
                guard let screen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
                }) else { return fail("显示器 \(id) 的模式与 AppKit 屏幕信息均不可读") }
                let frame = screen.frame
                let pixels = screen.convertRectToBacking(frame).size
                let geometry = VerifiedDisplayGeometry(
                    x: frame.minX, y: CGDisplayBounds(CGMainDisplayID()).height - frame.maxY,
                    width: frame.width, height: frame.height,
                    pixelWidth: pixels.width, pixelHeight: pixels.height
                )
                guard geometry.matches(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
                                      framebufferWidth: CGDisplayPixelsWide(id), framebufferHeight: CGDisplayPixelsHigh(id),
                                      scale: screen.backingScaleFactor) else {
                    return fail("显示器 \(id) 的 AppKit 与 CoreGraphics 实时几何信息不一致")
                }
                record.width = Int(frame.width); record.height = Int(frame.height)
                record.pixelWidth = Int(pixels.width); record.pixelHeight = Int(pixels.height)
                record.refreshRate = nil; record.geometryFallback = true
            }
            records.append(record)
        }
        let snapshot = TopologySnapshot(records)
        guard snapshot.valid else { return fail("显示器未激活、处于镜像或显示模式无效") }
        var finalCount = capacity
        var finalIDs = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
        guard CGGetOnlineDisplayList(capacity, &finalIDs, &finalCount) == .success,
              finalCount == capacity, Set(finalIDs) == Set(ids) else { return fail("读取显示信息期间在线集合发生变化") }
        guard event == VirtualDisplay.lastReconfigAt else { return fail("查询期间发生了显示器配置变化，请待连接稳定后重试") }
        return snapshot
    }
}
