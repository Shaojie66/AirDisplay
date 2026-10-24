import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 保存同一帧"编码前"和"解码后"的 PNG，用来比较文字清晰度。
/// 存到 ~/Library/Logs/AirDisplay/snapshots/（本机，不进仓库）。
final class FrameSnapshot {
    private let lock = NSLock()
    private var pendingTag: String?
    private var sourceCaptureNs: UInt64?
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AirDisplay/snapshots", isDirectory: true)
    }

    func request(tag: String) {
        lock.lock(); pendingTag = tag; sourceCaptureNs = nil; lock.unlock()
    }

    /// 抓屏端调用；如果有待保存请求，记下这一帧
    func offerSource(_ pb: CVPixelBuffer, captureNs: UInt64) {
        lock.lock()
        guard let tag = pendingTag, sourceCaptureNs == nil else { lock.unlock(); return }
        sourceCaptureNs = captureNs
        lock.unlock()
        save(pb, name: "\(tag)-source.png")
    }

    /// 解码端调用；等到同一帧解码出来时保存
    func offerDecoded(_ pb: CVPixelBuffer, captureNs: UInt64) {
        lock.lock()
        guard let tag = pendingTag, sourceCaptureNs == captureNs else { lock.unlock(); return }
        pendingTag = nil
        lock.unlock()
        save(pb, name: "\(tag)-decoded.png")
        Log.info("对比截图已保存：snapshots/\(tag)-source.png / -decoded.png")
    }

    private func save(_ pb: CVPixelBuffer, name: String) {
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let url = Self.directory.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }
}
