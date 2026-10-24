import CoreMedia
import VideoToolbox

/// VideoToolbox 硬件编码，低延迟设置：实时、无 B 帧、低延迟码率控制。
/// 优先 HEVC，不支持就退回 H.264。
final class VideoEncoder {
    struct Settings {
        var preferredCodec: VideoCodec = .hevc
        var width: Int32
        var height: Int32
        var fps: Int = 60
        var bitrate: Int = 150_000_000
        /// 实验开关：MaxFrameDelayCount = 0，要求编码器不攒帧
        var zeroFrameDelay = false
        /// 实验开关
        /// M2 实测：低延迟码率控制在 M4 Max 上编码反而更慢（15ms vs 11ms），文字画质无差别，默认关
        var allowLowLatency = false
        var prioritizeSpeed = false
        var setExpectedFrameRate = true
    }

    struct Output {
        let frame: EncodedFrame
        let encodeMs: Double
    }

    var onEncoded: ((Output) -> Void)?

    private(set) var codec: VideoCodec = .hevc
    private(set) var lowLatency = false
    private var session: VTCompressionSession?
    private let settings: Settings
    private var frameNumber: UInt64 = 0
    private let keyframeLock = NSLock()
    private var keyframePending = true

    init(_ settings: Settings) throws {
        self.settings = settings
        let order: [(VideoCodec, Bool)] = settings.preferredCodec == .hevc
            ? [(.hevc, true), (.hevc, false), (.h264, true), (.h264, false)]
            : [(.h264, true), (.h264, false)]
        for (c, ll) in order where settings.allowLowLatency || !ll {
            if let s = Self.makeSession(settings, codec: c, lowLatency: ll) {
                session = s
                codec = c
                lowLatency = ll
                break
            }
        }
        guard session != nil else {
            throw NSError(domain: "AirDisplay", code: 1, userInfo: [NSLocalizedDescriptionKey: "硬件编码器创建失败"])
        }
        Log.info("编码器：\(codec.name)，低延迟码率控制=\(lowLatency)，\(settings.width)×\(settings.height)，\(settings.bitrate / 1_000_000) Mbps")
    }

    deinit {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
    }

    /// 下一帧强制编成关键帧（客户端刚连上或请求时）
    func requestKeyframe() {
        keyframeLock.lock(); keyframePending = true; keyframeLock.unlock()
    }

    /// 在抓屏队列上调用
    func encode(_ pb: CVPixelBuffer, pts: CMTime, captureNs: UInt64) {
        guard let session else { return }
        keyframeLock.lock()
        let forceKey = keyframePending
        keyframePending = false
        keyframeLock.unlock()

        let props: CFDictionary? = forceKey
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let number = frameNumber
        frameNumber += 1
        let start = Clock.nowNs()
        let codec = self.codec
        let w = UInt16(settings.width), h = UInt16(settings.height)

        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sb in
            guard let self, status == noErr, let sb,
                  let frame = Self.makeFrame(sb, codec: codec, number: number, captureNs: captureNs, width: w, height: h)
            else { return }
            self.onEncoded?(Output(frame: frame, encodeMs: Double(Clock.nowNs() - start) / 1e6))
        }
    }

    // MARK: -

    private static func makeSession(_ s: Settings, codec: VideoCodec, lowLatency: Bool) -> VTCompressionSession? {
        var spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        if lowLatency {
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: s.width, height: s.height,
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let session else { return nil }

        func set(_ key: CFString, _ value: CFTypeRef) -> Bool {
            VTSessionSetProperty(session, key: key, value: value) == noErr
        }
        var ok = true
        ok = ok && set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        ok = ok && set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        ok = ok && set(kVTCompressionPropertyKey_AverageBitRate, s.bitrate as CFNumber)
        if s.setExpectedFrameRate {
            _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, s.fps as CFNumber)
        }
        if s.prioritizeSpeed {
            let r = set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
            Log.info("PrioritizeEncodingSpeedOverQuality \(r ? "已设置" : "不支持")")
        }
        // 关键帧只在需要时发；这里给一个很长的兜底间隔
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (s.fps * 60) as CFNumber)
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 60 as CFNumber)
        _ = set(kVTCompressionPropertyKey_ProfileLevel,
                codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        if s.zeroFrameDelay {
            let r = set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber)
            Log.info("MaxFrameDelayCount=0 \(r ? "已设置" : "不支持")")
        }
        _ = set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        _ = set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        _ = set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        guard ok, VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            return nil
        }
        return session
    }

    private static func makeFrame(_ sb: CMSampleBuffer, codec: VideoCodec, number: UInt64,
                                  captureNs: UInt64, width: UInt16, height: UInt16) -> EncodedFrame? {
        guard let block = sb.dataBuffer, let fd = sb.formatDescription else { return nil }

        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = arr.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }

        var sets: [Data] = []
        if isKey {
            var count = 0
            let getter = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex
            _ = getter(fd, 0, nil, nil, &count, nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if getter(fd, i, &ptr, &size, nil, nil) == noErr, let ptr {
                    sets.append(Data(bytes: ptr, count: size))
                }
            }
        }

        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard status == noErr else { return nil }

        let header = FrameHeader(isKeyframe: isKey, codec: codec, frameNumber: number,
                                 captureTimeNs: captureNs, width: width, height: height, payloadLength: 0)
        return EncodedFrame(header: header, parameterSets: sets, data: data)
    }
}
