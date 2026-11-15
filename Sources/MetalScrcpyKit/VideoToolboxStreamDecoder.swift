import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Output pixel format produced by `VideoToolboxStreamDecoder`.
public enum DecoderPixelFormat: Sendable, Equatable {
    /// 32-bit BGRA (`kCVPixelFormatType_32BGRA`), directly compatible with `CAMetalLayer` and `VTCreateCGImageFromCVPixelBuffer`.
    case bgra32
    /// Bi-planar YCbCr 4:2:0 video range (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`), half the memory bandwidth of BGRA.
    case nv12VideoRange
    /// Bi-planar YCbCr 4:2:0 full range (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`).
    case nv12FullRange

    var cvPixelFormat: OSType {
        switch self {
        case .bgra32:
            return kCVPixelFormatType_32BGRA
        case .nv12VideoRange:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .nv12FullRange:
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }
}

/// Errors reported by `VideoToolboxStreamDecoder` via `onError`.
public enum VideoToolboxDecoderError: Error, Sendable, Equatable {
    case formatDescriptionCreationFailed(OSStatus)
    case decompressionSessionCreationFailed(OSStatus)
    case blockBufferCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case decodeFailed(OSStatus)
}

/// Standalone, socket-agnostic hardware video decoder powered by Apple `VideoToolbox` (`VTDecompressionSession`).
/// Accepts raw Annex-B byte streams, discrete Annex-B packet payloads, single NAL units, or scrcpy 12-byte framed packets,
/// and outputs Metal-compatible `CVPixelBuffer` frames (and optional `CGImage` snapshots) with zero main-thread dispatch jitter.
public final class VideoToolboxStreamDecoder: @unchecked Sendable {
    /// Active video codec (`.h264` or `.hevc`).
    public private(set) var codec: VideoCodec {
        get {
            decoderLock.lock()
            defer { decoderLock.unlock() }
            return _codec
        }
        set {
            decoderLock.lock()
            _codec = newValue
            decoderLock.unlock()
        }
    }

    /// Output pixel format requested from `VTDecompressionSession`.
    public let pixelFormat: DecoderPixelFormat

    /// When `true`, each decoded frame increments `PerformanceEngine.recordPresentedFrame()`.
    public var recordPerformanceMetrics: Bool

    /// Called immediately on the VideoToolbox decompression thread when a frame is decoded.
    public var onFrameDecoded: (@Sendable (CVPixelBuffer) -> Void)?

    /// Optional callback that converts each decoded `CVPixelBuffer` into a `CGImage` and dispatches it on the main queue.
    /// Leave `nil` during high-FPS Metal rendering to avoid CPU readback overhead.
    public var onFrameImageDecoded: (@Sendable (CGImage) -> Void)?

    /// Called on the main queue whenever SPS/PPS/VPS changes the decoded stream dimensions.
    public var onVideoSizeChanged: (@Sendable (_ width: Int, _ height: Int) -> Void)?

    /// Optional error callback for diagnostics.
    public var onError: (@Sendable (VideoToolboxDecoderError) -> Void)?

    /// Most recently parsed video width in pixels (`0` until parameter sets are processed).
    public var videoWidth: Int {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        return _videoWidth
    }

    /// Most recently parsed video height in pixels (`0` until parameter sets are processed).
    public var videoHeight: Int {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        return _videoHeight
    }

    /// `true` once at least one frame has been successfully decoded since initialization or the last `reset()`.
    public var hasDecodedAnyFrame: Bool {
        pixelBufferLock.lock()
        defer { pixelBufferLock.unlock() }
        return _hasDecodedAnyFrame
    }

    /// `true` when a `VTDecompressionSession` is currently configured and ready to decode slice NAL units.
    public var hasActiveSession: Bool {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        return decompressionSession != nil
    }

    /// Most recently decoded `CVPixelBuffer`, if any.
    public var latestPixelBuffer: CVPixelBuffer? {
        pixelBufferLock.lock()
        defer { pixelBufferLock.unlock() }
        return _latestPixelBuffer
    }

    /// Lazily converts `latestPixelBuffer` into a `CGImage` on demand (e.g. for Vision OCR or screenshots),
    /// avoiding per-frame GPU-to-CPU readbacks during 120Hz streaming.
    public var latestFrameImage: CGImage? {
        guard let pb = latestPixelBuffer else { return nil }
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cgImage)
        return cgImage
    }

    private let decoderLock = NSLock()
    private let streamLock = NSLock()
    private let pixelBufferLock = NSLock()

    private var _codec: VideoCodec
    private var _videoWidth: Int = 0
    private var _videoHeight: Int = 0
    private var _hasDecodedAnyFrame: Bool = false
    private var _latestPixelBuffer: CVPixelBuffer?

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var activeVPS: Data?
    private var activeSPS: Data?
    private var activePPS: Data?

    // Incremental stream & parameter-set accumulator
    private var streamBuffer = Data()
    private var pendingVPS: Data?
    private var pendingSPS: Data?
    private var pendingPPS: Data?

    /// Creates a new `VideoToolboxStreamDecoder`.
    /// - Parameters:
    ///   - codec: Video codec of incoming NAL units (default `.hevc`).
    ///   - pixelFormat: Destination `CVPixelBuffer` format (default `.bgra32`).
    ///   - recordPerformanceMetrics: Whether decoded frames increment `PerformanceEngine.recordPresentedFrame()`.
    public init(
        codec: VideoCodec = .hevc,
        pixelFormat: DecoderPixelFormat = .bgra32,
        recordPerformanceMetrics: Bool = true
    ) {
        self._codec = codec
        self.pixelFormat = pixelFormat
        self.recordPerformanceMetrics = recordPerformanceMetrics
    }

    deinit {
        invalidate()
    }

    /// Feeds a discrete access-unit payload (containing one or more Annex-B NAL units, or a single raw NAL unit without start codes).
    /// Parameter sets (H.264 SPS/PPS or HEVC VPS/SPS/PPS) are extracted to initialize/reconfigure `VTDecompressionSession`,
    /// and slice NAL units are packed into 4-byte big-endian AVCC/HVCC length-prefixed buffers for decoding.
    public func feedPacketPayload(_ payload: Data) {
        guard !payload.isEmpty else { return }

        let currentCodec = codec
        let nals = AnnexBParser.parseNALUnits(from: payload)
        var avccBuffer = Data()

        streamLock.lock()
        defer { streamLock.unlock() }

        if nals.isEmpty {
            appendOrConfigureSingleNAL(payload, codec: currentCodec, avccBuffer: &avccBuffer)
        } else {
            var paramsUpdated = false
            for nal in nals where !nal.isEmpty {
                if handleParameterSetIfPresent(nal, codec: currentCodec) {
                    paramsUpdated = true
                } else if shouldDecodeNAL(nal, codec: currentCodec) {
                    if paramsUpdated {
                        configureSessionIfReadyLocked(codec: currentCodec)
                        paramsUpdated = false
                    }
                    appendLengthPrefixedNAL(nal, to: &avccBuffer)
                }
            }
            if paramsUpdated {
                configureSessionIfReadyLocked(codec: currentCodec)
            }
        }

        if !avccBuffer.isEmpty {
            decodeAVCCBlock(avccBuffer)
        }
    }

    /// Feeds an arbitrary chunk from a continuous Annex-B byte stream.
    /// Buffers incomplete trailing NAL units until the next start code arrives; call `flushAnnexBStream()` at end-of-stream.
    public func feedAnnexBStream(_ chunk: Data) {
        guard !chunk.isEmpty else { return }

        var readyNALs: [Data] = []
        streamLock.lock()
        streamBuffer.append(chunk)
        if AnnexBParser.trimOversizedStreamBuffer(&streamBuffer) {
            streamLock.unlock()
            return
        }
        while let (nal, nextOffset) = AnnexBParser.extractNextNAL(from: streamBuffer) {
            streamBuffer = Data(streamBuffer.dropFirst(nextOffset))
            if !nal.isEmpty {
                readyNALs.append(nal)
            }
        }
        streamLock.unlock()

        for nal in readyNALs {
            feedNALUnit(nal)
        }
    }

    /// Flushes any trailing complete NAL unit remaining in the incremental Annex-B stream buffer.
    public func flushAnnexBStream() {
        streamLock.lock()
        let remaining = streamBuffer
        streamBuffer.removeAll(keepingCapacity: false)
        streamLock.unlock()

        guard !remaining.isEmpty else { return }
        let nals = AnnexBParser.parseNALUnits(from: remaining)
        for nal in nals where !nal.isEmpty {
            feedNALUnit(nal)
        }
    }

    /// Feeds a single raw NAL unit (without Annex-B start codes).
    public func feedNALUnit(_ nal: Data) {
        guard !nal.isEmpty else { return }
        let currentCodec = codec
        var avccBuffer = Data()

        streamLock.lock()
        appendOrConfigureSingleNAL(nal, codec: currentCodec, avccBuffer: &avccBuffer)
        streamLock.unlock()

        if !avccBuffer.isEmpty {
            decodeAVCCBlock(avccBuffer)
        }
    }

    /// Feeds a byte chunk from a scrcpy 12-byte framed video stream (`send_frame_meta=true`),
    /// automatically falling back to raw Annex-B NAL extraction if framing headers are absent.
    public func feedScrcpyFramedStream(_ chunk: Data) {
        guard !chunk.isEmpty else { return }

        var payloads: [Data] = []
        var rawNALs: [Data] = []

        streamLock.lock()
        streamBuffer.append(chunk)
        if AnnexBParser.trimOversizedStreamBuffer(&streamBuffer) {
            streamLock.unlock()
            return
        }

        while streamBuffer.count >= 12 {
            if let packet = AnnexBParser.extractScrcpyFramedPacket(from: &streamBuffer) {
                payloads.append(packet.payload)
            } else {
                // Check if header indicates non-framed raw Annex-B stream (invalid scrcpy packet size)
                let packetSize = streamBuffer.withUnsafeBytes { rawPtr -> UInt32 in
                    rawPtr.loadUnaligned(fromByteOffset: 8, as: UInt32.self).bigEndian
                }
                if packetSize == 0 || packetSize > 10_000_000 {
                    if let (nal, nextOffset) = AnnexBParser.extractNextNAL(from: streamBuffer) {
                        streamBuffer = Data(streamBuffer.dropFirst(nextOffset))
                        if !nal.isEmpty {
                            rawNALs.append(nal)
                        }
                        continue
                    }
                }
                break
            }
        }
        streamLock.unlock()

        for payload in payloads {
            feedPacketPayload(payload)
        }
        for nal in rawNALs {
            feedNALUnit(nal)
        }
    }

    /// Resets the decoder state, invalidates any active `VTDecompressionSession`, clears buffered parameter sets,
    /// and optionally switches the active `VideoCodec`.
    public func reset(codec newCodec: VideoCodec? = nil) {
        streamLock.lock()
        streamBuffer.removeAll(keepingCapacity: false)
        pendingVPS = nil
        pendingSPS = nil
        pendingPPS = nil
        streamLock.unlock()

        decoderLock.lock()
        if let newCodec {
            _codec = newCodec
        }
        let session = decompressionSession
        decompressionSession = nil
        formatDescription = nil
        activeVPS = nil
        activeSPS = nil
        activePPS = nil
        _videoWidth = 0
        _videoHeight = 0
        decoderLock.unlock()

        pixelBufferLock.lock()
        _latestPixelBuffer = nil
        _hasDecodedAnyFrame = false
        pixelBufferLock.unlock()

        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Invalidates the underlying `VTDecompressionSession` and releases all cached buffers.
    public func invalidate() {
        reset(codec: nil)
    }

    // MARK: - Private Parameter Set & Session Management

    private func appendOrConfigureSingleNAL(_ nal: Data, codec: VideoCodec, avccBuffer: inout Data) {
        if handleParameterSetIfPresent(nal, codec: codec) {
            configureSessionIfReadyLocked(codec: codec)
        } else if shouldDecodeNAL(nal, codec: codec) {
            appendLengthPrefixedNAL(nal, to: &avccBuffer)
        }
    }

    private func handleParameterSetIfPresent(_ nal: Data, codec: VideoCodec) -> Bool {
        switch codec {
        case .hevc:
            guard let nalType = AnnexBParser.hevcNALType(for: nal) else { return false }
            switch nalType {
            case 32:
                pendingVPS = nal
                return true
            case 33:
                pendingSPS = nal
                return true
            case 34:
                pendingPPS = nal
                return true
            default:
                return false
            }
        case .h264:
            guard let nalType = AnnexBParser.h264NALType(for: nal) else { return false }
            switch nalType {
            case 7:
                pendingSPS = nal
                return true
            case 8:
                pendingPPS = nal
                return true
            default:
                return false
            }
        }
    }

    private func shouldDecodeNAL(_ nal: Data, codec: VideoCodec) -> Bool {
        switch codec {
        case .hevc:
            guard let nalType = AnnexBParser.hevcNALType(for: nal) else { return false }
            return nalType != 32 && nalType != 33 && nalType != 34
        case .h264:
            guard let nalType = AnnexBParser.h264NALType(for: nal) else { return false }
            return nalType == 1 || nalType == 5 || nalType == 6
        }
    }

    private func appendLengthPrefixedNAL(_ nal: Data, to avccBuffer: inout Data) {
        var length = UInt32(nal.count).bigEndian
        avccBuffer.append(Data(bytes: &length, count: 4))
        avccBuffer.append(nal)
    }

    private func configureSessionIfReadyLocked(codec: VideoCodec) {
        switch codec {
        case .hevc:
            guard let vps = pendingVPS, let sps = pendingSPS, let pps = pendingPPS else { return }
            createHEVCDecompressionSession(vps: vps, sps: sps, pps: pps)
        case .h264:
            guard let sps = pendingSPS, let pps = pendingPPS else { return }
            createH264DecompressionSession(sps: sps, pps: pps)
        }
    }

    private func createHEVCDecompressionSession(vps: Data, sps: Data, pps: Data) {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        if decompressionSession != nil && activeVPS == vps && activeSPS == sps && activePPS == pps {
            return
        }

        var formatDesc: CMVideoFormatDescription?
        let vpsBytes = [UInt8](vps)
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        var status: OSStatus = noErr

        vpsBytes.withUnsafeBufferPointer { vpsBuf in
            spsBytes.withUnsafeBufferPointer { spsBuf in
                ppsBytes.withUnsafeBufferPointer { ppsBuf in
                    guard let vBase = vpsBuf.baseAddress,
                          let sBase = spsBuf.baseAddress,
                          let pBase = ppsBuf.baseAddress else { return }
                    let pointers: [UnsafePointer<UInt8>] = [vBase, sBase, pBase]
                    let sizes: [Int] = [vpsBuf.count, spsBuf.count, ppsBuf.count]
                    status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDesc
                    )
                }
            }
        }

        guard status == noErr, let format = formatDesc else {
            onError?(.formatDescriptionCreationFailed(status))
            return
        }

        if applyFormatDescriptionLocked(format) {
            activeVPS = vps
            activeSPS = sps
            activePPS = pps
        }
    }

    private func createH264DecompressionSession(sps: Data, pps: Data) {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        if decompressionSession != nil && activeSPS == sps && activePPS == pps {
            return
        }

        var formatDesc: CMVideoFormatDescription?
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        var status: OSStatus = noErr

        spsBytes.withUnsafeBufferPointer { spsBuf in
            ppsBytes.withUnsafeBufferPointer { ppsBuf in
                guard let sBase = spsBuf.baseAddress,
                      let pBase = ppsBuf.baseAddress else { return }
                let pointers: [UnsafePointer<UInt8>] = [sBase, pBase]
                let sizes: [Int] = [spsBuf.count, ppsBuf.count]
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
            }
        }

        guard status == noErr, let format = formatDesc else {
            onError?(.formatDescriptionCreationFailed(status))
            return
        }

        if applyFormatDescriptionLocked(format) {
            activeVPS = nil
            activeSPS = sps
            activePPS = pps
        }
    }

    @discardableResult
    private func applyFormatDescriptionLocked(_ format: CMVideoFormatDescription) -> Bool {
        self.formatDescription = format
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        self._videoWidth = width
        self._videoHeight = height

        if let sizeCallback = onVideoSizeChanged {
            DispatchQueue.main.async {
                sizeCallback(width, height)
            }
        }

        if let existing = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(existing)
            VTDecompressionSessionInvalidate(existing)
            decompressionSession = nil
        }

        let destinationAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat.cvPixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            decompressionSessionOut: &session
        )

        guard status == noErr, let createdSession = session else {
            onError?(.decompressionSessionCreationFailed(status))
            return false
        }

        self.decompressionSession = createdSession
        return true
    }

    private func decodeAVCCBlock(_ avccData: Data) {
        decoderLock.lock()
        guard let session = decompressionSession, let format = formatDescription else {
            decoderLock.unlock()
            return
        }
        decoderLock.unlock()

        let count = avccData.count
        guard count > 0, let memoryBlock = malloc(count) else { return }
        avccData.copyBytes(to: memoryBlock.assumingMemoryBound(to: UInt8.self), count: count)

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memoryBlock,
            blockLength: count,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard blockStatus == noErr, let buffer = blockBuffer else {
            free(memoryBlock)
            onError?(.blockBufferCreationFailed(blockStatus))
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [count]
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sample = sampleBuffer else {
            onError?(.sampleBufferCreationFailed(sampleStatus))
            return
        }

        var flags: VTDecodeInfoFlags = []
        let decodeCallStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._1xRealTimePlayback, ._EnableAsynchronousDecompression],
            infoFlagsOut: &flags
        ) { [weak self] decodeStatus, _, imageBuffer, _, _ in
            autoreleasepool {
                guard let self else { return }
                guard decodeStatus == noErr, let pixelBuffer = imageBuffer else {
                    if decodeStatus != noErr {
                        self.onError?(.decodeFailed(decodeStatus))
                    }
                    return
                }

                self.pixelBufferLock.lock()
                self._hasDecodedAnyFrame = true
                self._latestPixelBuffer = pixelBuffer
                self.pixelBufferLock.unlock()

                if self.recordPerformanceMetrics {
                    PerformanceEngine.recordPresentedFrame()
                }

                nonisolated(unsafe) let pb = pixelBuffer
                self.onFrameDecoded?(pb)

                if let imageCallback = self.onFrameImageDecoded {
                    var cgImage: CGImage?
                    VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
                    if let cgImage {
                        DispatchQueue.main.async {
                            imageCallback(cgImage)
                        }
                    }
                }
            }
        }

        if decodeCallStatus != noErr {
            onError?(.decodeFailed(decodeCallStatus))
        }
    }
}
