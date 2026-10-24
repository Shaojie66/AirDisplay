import CoreMedia
import Foundation
import VideoToolbox

/// 硬件解码：EncodedFrame → CVPixelBuffer。
/// 收到第一个带参数集的关键帧之前，其他帧直接丢弃。
final class VideoDecoder {
    struct Output {
        let pixelBuffer: CVPixelBuffer
        let header: FrameHeader
        let decodeMs: Double
    }

    var onDecoded: ((Output) -> Void)?
    /// 解码出错时调用（一般应请求发送端补一个关键帧）
    var onNeedKeyframe: (() -> Void)?

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentParameterSets: [Data] = []

    deinit { invalidate() }

    func invalidate() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        formatDescription = nil
        currentParameterSets = []
    }

    func decode(_ frame: EncodedFrame) {
        if frame.header.isKeyframe, !frame.parameterSets.isEmpty,
           frame.parameterSets != currentParameterSets {
            guard rebuildSession(codec: frame.header.codec, parameterSets: frame.parameterSets) else { return }
        }
        guard let session, let fd = formatDescription,
              let sample = makeSampleBuffer(frame.data, format: fd) else { return }

        let start = Clock.nowNs()
        let header = frame.header
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let pb = imageBuffer else {
                self.onNeedKeyframe?()
                return
            }
            let ms = Double(Clock.nowNs() - start) / 1e6
            self.onDecoded?(Output(pixelBuffer: pb, header: header, decodeMs: ms))
        }
        if status != noErr {
            // 会话失效（比如系统睡眠后），丢掉等下一个关键帧
            invalidate()
            onNeedKeyframe?()
        }
    }

    private func rebuildSession(codec: VideoCodec, parameterSets: [Data]) -> Bool {
        invalidate()
        guard let fd = Self.makeFormatDescription(codec: codec, parameterSets: parameterSets) else {
            return false
        }
        // 4:4:4 码流直接解成 BGRA（显示层稳妥支持），4:2:0 保持 NV12
        let is444 = Self.chromaFormat(fd) == 3
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: is444 ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var s: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: fd, decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &s
        )
        guard status == noErr, let s else { return false }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        formatDescription = fd
        currentParameterSets = parameterSets
        return true
    }

    /// HEVC 码流的 chroma_format_idc（1 = 4:2:0，3 = 4:4:4），拿不到返回 nil
    static func chromaFormat(_ fd: CMVideoFormatDescription) -> Int? {
        guard let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any],
              let atoms = ext["SampleDescriptionExtensionAtoms"] as? [String: Any],
              let hvcc = atoms["hvcC"] as? Data, hvcc.count > 16 else { return nil }
        return Int(hvcc[hvcc.startIndex + 16] & 0x3)
    }

    /// 本机能不能硬件解 HEVC 4:4:4：用一小段现编的 4:4:4 码流实测
    static let supportsHEVC444: Bool = {
        var enc: VTCompressionSession?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: 256, kCVPixelBufferHeightKey: 144,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard VTCompressionSessionCreate(allocator: nil, width: 256, height: 144, codecType: kCMVideoCodecType_HEVC,
                                         encoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                                         compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                         compressionSessionOut: &enc) == noErr, let enc else { return false }
        defer { VTCompressionSessionInvalidate(enc) }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 256, 144, kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
        guard let pb else { return false }
        var sample: CMSampleBuffer?
        _ = VTCompressionSessionEncodeFrame(enc, imageBuffer: pb, presentationTimeStamp: .zero, duration: .invalid,
                                            frameProperties: nil, infoFlagsOut: nil) { _, _, sb in sample = sb }
        VTCompressionSessionCompleteFrames(enc, untilPresentationTimeStamp: .invalid)
        guard let sample, let fd = sample.formatDescription, chromaFormat(fd) == 3 else { return false }
        var dec: VTDecompressionSession?
        let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: spec,
                                           imageBufferAttributes: nil, outputCallback: nil,
                                           decompressionSessionOut: &dec) == noErr, let dec else { return false }
        defer { VTDecompressionSessionInvalidate(dec) }
        var ok = false
        _ = VTDecompressionSessionDecodeFrame(dec, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { st, _, img, _, _ in
            ok = st == noErr && img != nil
        }
        VTDecompressionSessionWaitForAsynchronousFrames(dec)
        return ok
    }()

    static func makeFormatDescription(codec: VideoCodec, parameterSets: [Data]) -> CMVideoFormatDescription? {
        // 把每个参数集拷到连续内存，拿稳定指针
        let buffers = parameterSets.map { [UInt8]($0) }
        var fd: CMVideoFormatDescription?
        let status: OSStatus = buffers.withUnsafePointers { ptrs, sizes in
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: ptrs.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: ptrs.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                    formatDescriptionOut: &fd)
            }
        }
        return status == noErr ? fd : nil
    }

    private func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0,
            blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}

private extension Array where Element == [UInt8] {
    /// 给 CoreMedia 的 C 接口提供 (指针数组, 长度数组)
    func withUnsafePointers<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        var ptrs: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        func recurse(_ i: Int) -> R {
            if i == count { return body(ptrs, sizes) }
            return self[i].withUnsafeBufferPointer { bp in
                ptrs.append(bp.baseAddress!)
                sizes.append(bp.count)
                return recurse(i + 1)
            }
        }
        return recurse(0)
    }
}
