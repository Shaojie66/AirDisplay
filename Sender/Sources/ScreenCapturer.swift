import CoreMedia
import ScreenCaptureKit

/// 用 ScreenCaptureKit 只抓一块显示器。画面不变时系统不送新帧（只送 .idle），这里直接忽略。
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let pts: CMTime
        /// 这一帧在屏幕上出现的时刻（CLOCK_UPTIME_RAW 纳秒）
        let captureNs: UInt64
    }

    enum Failure: LocalizedError {
        case displayNotFound
        var errorDescription: String? { "ScreenCaptureKit 找不到目标显示器" }
    }

    var onFrame: ((Frame) -> Void)?
    var onStopped: ((Error) -> Void)?

    private var stream: SCStream?
    let queue = DispatchQueue(label: "airdisplay.capture", qos: .userInteractive)

    /// chroma444 = true 时抓 4:4:4（彩色小字更干净，码率更高）
    func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, fps: Int, chroma444: Bool = false) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = pixelWidth
        cfg.height = pixelHeight
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = chroma444
            ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // NV12，编码器直接吃
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.queueDepth = 3
        cfg.capturesAudio = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        Log.info("开始抓屏 displayID=\(displayID) \(pixelWidth)×\(pixelHeight) @\(fps)fps \(chroma444 ? "4:4:4" : "4:2:0")")
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
        Log.info("停止抓屏")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer
        else { return }

        let displayTime = (info[.displayTime] as? UInt64).map(Clock.machToNs) ?? Clock.nowNs()
        onFrame?(Frame(pixelBuffer: pb, pts: sb.presentationTimeStamp, captureNs: displayTime))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("抓屏意外停止：\(error.localizedDescription)")
        self.stream = nil
        onStopped?(error)
    }
}
