import XCTest
import CoreVideo
import CoreMedia
import Metal
import VideoToolbox
@testable import MetalScrcpyKit

final class MetalScrcpyKitTests: XCTestCase {

    // MARK: - Annex-B NAL Parsing & Scrcpy Framing

    func testAnnexBNALUnitParsing() {
        // Typical scrcpy config packet: 4-byte start code + SPS (0x67...), 4-byte start code + PPS (0x68...)
        var stream = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x28, 0xDA]) // SPS (nalType = 7)
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x3C, 0x80]) // PPS (nalType = 8)

        let nals = AnnexBParser.parseNALUnits(from: stream)
        XCTAssertEqual(nals.count, 2)
        XCTAssertEqual(AnnexBParser.h264NALType(for: nals[0]), 7) // SPS
        XCTAssertEqual(AnnexBParser.h264NALType(for: nals[1]), 8) // PPS
        XCTAssertTrue(AnnexBParser.isParameterSet(nals[0], codec: .h264))
        XCTAssertTrue(AnnexBParser.isParameterSet(nals[1], codec: .h264))

        // 3-byte start code test
        let stream3Byte = Data([0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00]) // IDR (nalType = 5)
        let nals3 = AnnexBParser.parseNALUnits(from: stream3Byte)
        XCTAssertEqual(nals3.count, 1)
        XCTAssertEqual(AnnexBParser.h264NALType(for: nals3[0]), 5) // IDR Slice
        XCTAssertFalse(AnnexBParser.isParameterSet(nals3[0], codec: .h264))
    }

    func testHEVCNALTypeDetection() {
        // HEVC NAL header byte: (nalType << 1)
        XCTAssertEqual(AnnexBParser.hevcNALType(for: Data([32 << 1, 0x01])), 32) // VPS
        XCTAssertEqual(AnnexBParser.hevcNALType(for: Data([33 << 1, 0x01])), 33) // SPS
        XCTAssertEqual(AnnexBParser.hevcNALType(for: Data([34 << 1, 0x01])), 34) // PPS
        XCTAssertEqual(AnnexBParser.hevcNALType(for: Data([19 << 1, 0x01])), 19) // IDR
        XCTAssertNil(AnnexBParser.hevcNALType(for: Data()))

        XCTAssertTrue(AnnexBParser.isParameterSet(Data([32 << 1, 0x01]), codec: .hevc))
        XCTAssertTrue(AnnexBParser.isParameterSet(Data([33 << 1, 0x01]), codec: .hevc))
        XCTAssertTrue(AnnexBParser.isParameterSet(Data([34 << 1, 0x01]), codec: .hevc))
        XCTAssertFalse(AnnexBParser.isParameterSet(Data([19 << 1, 0x01]), codec: .hevc))
    }

    func testIncrementalNALExtractionAndScrcpyPacketFraming() {
        // Incremental extraction requires two start codes before yielding first NAL
        var partial = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x28])
        XCTAssertNil(AnnexBParser.extractNextNAL(from: partial))

        partial.append(contentsOf: [0x00, 0x00, 0x01, 0x68, 0xCE])
        let extracted = AnnexBParser.extractNextNAL(from: partial)
        XCTAssertNotNil(extracted)
        XCTAssertEqual(extracted?.nal, Data([0x67, 0x42, 0x28]))
        XCTAssertEqual(extracted?.nextOffset, 7)

        // Scrcpy 12-byte framed packet: config flag (bit 63) + keyframe flag (bit 62) + pts=1234
        let ptsAndFlags: UInt64 = (1 << 63) | (1 << 62) | 1234
        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x64, 0x00, 0x28])
        var framed = Data()
        var ptsBE = ptsAndFlags.bigEndian
        var lenBE = UInt32(payload.count).bigEndian
        framed.append(Data(bytes: &ptsBE, count: 8))
        framed.append(Data(bytes: &lenBE, count: 4))
        framed.append(payload)

        let packet = AnnexBParser.extractScrcpyFramedPacket(from: &framed)
        XCTAssertNotNil(packet)
        XCTAssertTrue(packet?.isConfig ?? false)
        XCTAssertTrue(packet?.isKeyFrame ?? false)
        XCTAssertEqual(packet?.pts, 1234)
        XCTAssertEqual(packet?.payload, payload)
        XCTAssertTrue(framed.isEmpty)

        // Oversized buffer protection
        var huge = Data(repeating: 0xAA, count: 128)
        XCTAssertFalse(AnnexBParser.trimOversizedStreamBuffer(&huge, maxBytes: 128))
        XCTAssertTrue(AnnexBParser.trimOversizedStreamBuffer(&huge, maxBytes: 64))
        XCTAssertTrue(huge.isEmpty)
    }

    // MARK: - PerformanceEngine ABR & Telemetry

    @MainActor
    func testPerformanceEngineABRStepDownAndRecovery() {
        final class TransitionsBox: @unchecked Sendable {
            var items: [(Int, Int, Bool)] = []
        }
        let engine = PerformanceEngine()
        let transitions = TransitionsBox()
        engine.onABRStepChange = { bitRate, maxSize, reduced in
            transitions.items.append((bitRate, maxSize, reduced))
        }

        // 3 high-RTT samples should not trigger ABR yet
        for _ in 0..<3 {
            let res = engine.ingestProbeSample(rttMs: 145)
            XCTAssertFalse(res.changed)
            XCTAssertFalse(engine.isABRReduced)
        }
        // 4th consecutive sample >120ms (>2s) triggers step-down to 6M / 1280
        let stepDown = engine.ingestProbeSample(rttMs: 150)
        XCTAssertTrue(stepDown.changed)
        XCTAssertEqual(stepDown.bitRate, 6_000_000)
        XCTAssertEqual(stepDown.maxSize, 1280)
        XCTAssertTrue(engine.isABRReduced)
        XCTAssertEqual(engine.rttMs, 150)
        XCTAssertEqual(engine.jitterMs, 5)

        // 7 low-RTT samples should not restore yet
        for _ in 0..<7 {
            let res = engine.ingestProbeSample(rttMs: 25)
            XCTAssertFalse(res.changed)
            XCTAssertTrue(engine.isABRReduced)
        }
        // 8th consecutive sample <60ms (4s) restores 16M / 1440
        let restore = engine.ingestProbeSample(rttMs: 22)
        XCTAssertTrue(restore.changed)
        XCTAssertEqual(restore.bitRate, 16_000_000)
        XCTAssertEqual(restore.maxSize, 1440)
        XCTAssertFalse(engine.isABRReduced)

        XCTAssertEqual(transitions.items.count, 2)
        XCTAssertEqual(transitions.items[0].0, 6_000_000)
        XCTAssertEqual(transitions.items[0].2, true)
        XCTAssertEqual(transitions.items[1].0, 16_000_000)
        XCTAssertEqual(transitions.items[1].2, false)
    }

    @MainActor
    func testPerformanceEngineSessionAndTransportLabels() {
        XCTAssertEqual(ProbeTarget.usb.transportLabel, "USB")
        XCTAssertNil(ProbeTarget.usb.extractHostAndPort())

        let wifiTarget = ProbeTarget.wifi(host: "192.168.1.42", port: 5555)
        XCTAssertEqual(wifiTarget.transportLabel, "Wi-Fi")
        XCTAssertEqual(wifiTarget.extractHostAndPort()?.0, "192.168.1.42")
        XCTAssertEqual(wifiTarget.extractHostAndPort()?.1, 5555)

        let hotspotTarget = ProbeTarget.wifi(host: "192.168.43.1", port: 5555)
        XCTAssertEqual(hotspotTarget.transportLabel, "Direct Hotspot")

        let btTarget = ProbeTarget.wifi(host: "192.168.44.128", port: 5555)
        XCTAssertEqual(btTarget.transportLabel, "BT PAN")

        let engine = PerformanceEngine()
        engine.beginMirroringSession(target: .usb, codec: .hevc)
        XCTAssertTrue(engine.isSessionActive)
        XCTAssertEqual(engine.transportLabel, "USB")
        XCTAssertEqual(engine.activeCodec, .hevc)
        XCTAssertEqual(engine.rttMs, 1)

        engine.updateActiveCodec(.h264)
        XCTAssertEqual(engine.activeCodec, .h264)

        PerformanceEngine.recordPresentedFrame()
        engine.endMirroringSession()
        XCTAssertFalse(engine.isSessionActive)
        XCTAssertEqual(engine.liveFPS, 0)
        XCTAssertEqual(engine.rttMs, 0)
    }

    // MARK: - MetalVideoRenderer Offscreen PixelBuffer Submission & Rendering

    func testMetalVideoRendererSubmissionAndOffscreenRender() throws {
        guard let renderer = MetalVideoRenderer() else {
            throw XCTSkip("Metal device unavailable in test environment")
        }

        // Create two BGRA CVPixelBuffers with different sizes to test latest-frame coalescing
        let pb1 = try makeTestPixelBuffer(width: 128, height: 256, pixelFormat: kCVPixelFormatType_32BGRA)
        let pb2 = try makeTestPixelBuffer(width: 160, height: 320, pixelFormat: kCVPixelFormatType_32BGRA)

        renderer.submit(pixelBuffer: pb1)
        XCTAssertTrue(renderer.hasPendingFrame)
        XCTAssertEqual(renderer.currentVideoSize, CGSize(width: 128, height: 256))

        // Submitting pb2 before rendering overwrites pb1 (zero queue lag)
        renderer.submit(pixelBuffer: pb2)
        XCTAssertTrue(renderer.hasPendingFrame)
        XCTAssertEqual(renderer.currentVideoSize, CGSize(width: 160, height: 320))

        // Verify offscreen Metal render pass for BGRA
        let targetTexture = try makeOffscreenTexture(device: renderer.device, width: 160, height: 320)
        XCTAssertTrue(renderer.render(pixelBuffer: pb2, to: targetTexture))
        XCTAssertEqual(renderer.renderedFrameCount, 1)

        // Verify offscreen Metal render pass for NV12 video-range and full-range
        let nv12Video = try makeTestPixelBuffer(
            width: 160,
            height: 320,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertTrue(renderer.render(pixelBuffer: nv12Video, to: targetTexture))
        XCTAssertEqual(renderer.renderedFrameCount, 2)

        let nv12Full = try makeTestPixelBuffer(
            width: 160,
            height: 320,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        XCTAssertTrue(renderer.render(pixelBuffer: nv12Full, to: targetTexture))
        XCTAssertEqual(renderer.renderedFrameCount, 3)

        // Clear pending frame & geometry update
        renderer.clearPendingFrame()
        XCTAssertFalse(renderer.hasPendingFrame)
        XCTAssertFalse(renderer.renderLatestFrameIfAvailable())

        renderer.updateDrawableGeometry(bounds: CGRect(x: 0, y: 0, width: 200, height: 400), scale: 2.0, cornerRadius: 24)
        XCTAssertEqual(renderer.metalLayer.drawableSize, CGSize(width: 400, height: 800))
        XCTAssertEqual(renderer.metalLayer.cornerRadius, 24)
    }

    // MARK: - VideoToolboxStreamDecoder Lifecycle & Hardware Decode

    func testVideoToolboxStreamDecoderResetAndLifecycle() throws {
        let decoder = VideoToolboxStreamDecoder(codec: .h264, pixelFormat: .bgra32, recordPerformanceMetrics: false)
        XCTAssertEqual(decoder.codec, .h264)
        XCTAssertFalse(decoder.hasActiveSession)
        XCTAssertFalse(decoder.hasDecodedAnyFrame)
        XCTAssertEqual(decoder.videoWidth, 0)
        XCTAssertEqual(decoder.videoHeight, 0)

        // Encode a single real H.264 Annex-B IDR frame using VideoToolbox encoder to obtain valid SPS/PPS/IDR
        let annexBFrame = try encodeSingleH264AnnexBFrame(width: 128, height: 128)
        let decodedExpectation = expectation(description: "VideoToolbox decoded CVPixelBuffer")
        final class Box: @unchecked Sendable {
            var pixelBuffer: CVPixelBuffer?
        }
        let box = Box()
        decoder.onFrameDecoded = { pb in
            box.pixelBuffer = pb
            decodedExpectation.fulfill()
        }

        decoder.feedPacketPayload(annexBFrame)
        wait(for: [decodedExpectation], timeout: 5.0)

        XCTAssertTrue(decoder.hasActiveSession)
        XCTAssertTrue(decoder.hasDecodedAnyFrame)
        XCTAssertEqual(decoder.videoWidth, 128)
        XCTAssertEqual(decoder.videoHeight, 128)
        XCTAssertNotNil(box.pixelBuffer)
        XCTAssertNotNil(decoder.latestPixelBuffer)
        XCTAssertNotNil(decoder.latestFrameImage)

        // Reset & switch codec to HEVC
        decoder.reset(codec: .hevc)
        XCTAssertEqual(decoder.codec, .hevc)
        XCTAssertFalse(decoder.hasActiveSession)
        XCTAssertFalse(decoder.hasDecodedAnyFrame)
        XCTAssertEqual(decoder.videoWidth, 0)
        XCTAssertEqual(decoder.videoHeight, 0)
        XCTAssertNil(decoder.latestPixelBuffer)
    }

    func testVideoToolboxStreamDecoderIncrementalAnnexBAndScrcpyFramed() throws {
        let annexBFrame = try encodeSingleH264AnnexBFrame(width: 96, height: 96)
        let decoder = VideoToolboxStreamDecoder(codec: .h264, pixelFormat: .nv12VideoRange, recordPerformanceMetrics: false)

        let decodedExpectation = expectation(description: "Incremental Annex-B stream decoded")
        decoder.onFrameDecoded = { pb in
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            decodedExpectation.fulfill()
        }

        // Feed split across two chunks, then flush trailing NAL
        let midpoint = annexBFrame.count / 2
        decoder.feedAnnexBStream(Data(annexBFrame[..<midpoint]))
        decoder.feedAnnexBStream(Data(annexBFrame[midpoint...]))
        decoder.flushAnnexBStream()
        wait(for: [decodedExpectation], timeout: 5.0)

        XCTAssertTrue(decoder.hasActiveSession)
        XCTAssertEqual(decoder.videoWidth, 96)
        XCTAssertEqual(decoder.videoHeight, 96)

        // Now test scrcpy 12-byte framed stream after reset
        decoder.reset(codec: .h264)
        let framedExpectation = expectation(description: "Scrcpy framed stream decoded")
        decoder.onFrameDecoded = { _ in
            framedExpectation.fulfill()
        }

        var framed = Data()
        var ptsBE = UInt64((1 << 62) | 5000).bigEndian
        var lenBE = UInt32(annexBFrame.count).bigEndian
        framed.append(Data(bytes: &ptsBE, count: 8))
        framed.append(Data(bytes: &lenBE, count: 4))
        framed.append(annexBFrame)
        decoder.feedScrcpyFramedStream(framed)
        wait(for: [framedExpectation], timeout: 5.0)
        XCTAssertTrue(decoder.hasDecodedAnyFrame)
    }

    // MARK: - MetalDisplayView & SwiftUI Wrapper

    @MainActor
    func testMetalDisplayViewLifecycleAndAttachment() {
        let decoder = VideoToolboxStreamDecoder(codec: .hevc, recordPerformanceMetrics: false)
        let view = MetalDisplayView(frame: NSRect(x: 0, y: 0, width: 320, height: 640))
        view.cornerRadius = 32
        XCTAssertEqual(view.layer?.cornerRadius, 32)
        XCTAssertFalse(view.hasRenderedFrame)

        view.attach(to: decoder)
        XCTAssertNotNil(decoder.onFrameDecoded)

        view.teardown()
        XCTAssertNil(decoder.onFrameDecoded)

        // SwiftUI wrapper construction
        let swiftUIView = MetalVideoDisplayView(decoder: decoder, cornerRadius: 24)
        XCTAssertEqual(swiftUIView.cornerRadius, 24)
    }

    // MARK: - ProcessLifecycleManager

    func testProcessLifecycleManagerRegistrationAndCleanup() throws {
        let manager = ProcessLifecycleManager()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["5"]
        try proc.run()

        let trackedId = manager.register(proc, tag: "unit-test")
        XCTAssertTrue(manager.isTracking(trackedId))
        XCTAssertGreaterThanOrEqual(manager.activeCount, 1)

        manager.terminateProcess(proc, gracePeriodMs: 100)
        proc.waitUntilExit()
        manager.unregister(trackedId)

        XCTAssertFalse(proc.isRunning)
        XCTAssertFalse(manager.isTracking(trackedId))
        XCTAssertEqual(manager.activeCount, 0)
    }

    func testProcessLifecycleManagerTerminateByTagAndAll() throws {
        let manager = ProcessLifecycleManager()

        let procA = Process()
        procA.executableURL = URL(fileURLWithPath: "/bin/sleep")
        procA.arguments = ["5"]
        try procA.run()

        let procB = Process()
        procB.executableURL = URL(fileURLWithPath: "/bin/sleep")
        procB.arguments = ["5"]
        try procB.run()

        manager.register(procA, tag: "group-a")
        manager.register(procB, tag: "group-b")
        XCTAssertEqual(manager.activeCount, 2)

        manager.terminateProcesses(withTag: "group-a", gracePeriodMs: 100)
        procA.waitUntilExit()
        XCTAssertFalse(procA.isRunning)
        XCTAssertTrue(procB.isRunning)
        XCTAssertEqual(manager.activeCount, 1)

        manager.terminateAllProcesses(synchronousWait: true, gracePeriodMs: 300)
        procB.waitUntilExit()
        XCTAssertFalse(procB.isRunning)
        XCTAssertEqual(manager.activeCount, 0)
    }

    // MARK: - Test Helpers

    private func makeTestPixelBuffer(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            throw NSError(domain: "MetalScrcpyKitTests", code: Int(status))
        }
        return pb
    }

    private func makeOffscreenTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw NSError(domain: "MetalScrcpyKitTests", code: -1)
        }
        return texture
    }

    private func encodeSingleH264AnnexBFrame(width: Int, height: Int) throws -> Data {
        var compressionSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &compressionSession
        )
        guard status == noErr, let session = compressionSession else {
            throw XCTSkip("VTCompressionSession H.264 encoder unavailable (\(status))")
        }
        defer { VTCompressionSessionInvalidate(session) }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(session)

        let pb = try makeTestPixelBuffer(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        final class EncodedBox: @unchecked Sendable {
            var annexBData: Data?
        }
        let box = EncodedBox()
        let sema = DispatchSemaphore(value: 0)

        let encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pb,
            presentationTimeStamp: CMTime(value: 0, timescale: 60),
            duration: CMTime(value: 1, timescale: 60),
            frameProperties: nil,
            infoFlagsOut: nil
        ) { cbStatus, _, sampleBuffer in
            defer { sema.signal() }
            guard cbStatus == noErr, let sampleBuffer,
                  let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                return
            }

            var output = Data()
            var paramCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &paramCount,
                nalUnitHeaderLengthOut: nil
            )
            for idx in 0..<paramCount {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc,
                    parameterSetIndex: idx,
                    parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                ) == noErr, let ptr {
                    output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    output.append(ptr, count: size)
                }
            }

            var totalLen = 0
            var dataPtr: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLen, dataPointerOut: &dataPtr) == noErr,
               let dataPtr {
                var offset = 0
                while offset + 4 <= totalLen {
                    var nalLenBE: UInt32 = 0
                    memcpy(&nalLenBE, dataPtr.advanced(by: offset), 4)
                    let nalLen = Int(UInt32(bigEndian: nalLenBE))
                    offset += 4
                    guard nalLen > 0, offset + nalLen <= totalLen else { break }
                    output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    output.append(UnsafeRawPointer(dataPtr.advanced(by: offset)).assumingMemoryBound(to: UInt8.self), count: nalLen)
                    offset += nalLen
                }
            }

            box.annexBData = output
        }

        guard encodeStatus == noErr else {
            throw XCTSkip("VTCompressionSessionEncodeFrame failed (\(encodeStatus))")
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        _ = sema.wait(timeout: .now() + 5.0)

        guard let data = box.annexBData, !data.isEmpty else {
            throw XCTSkip("No Annex-B frame produced by VTCompressionSession")
        }
        return data
    }
}
