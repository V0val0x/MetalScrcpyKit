import Foundation

/// Video compression codec supported by `AnnexBParser` and `VideoToolboxStreamDecoder`.
public enum VideoCodec: String, Sendable, Equatable, CaseIterable {
    /// H.264 / AVC (`avc1`).
    case h264
    /// H.265 / HEVC (`hvc1`).
    case hevc

    /// Alias for `.hevc` matching scrcpy CLI naming.
    public static let h265: VideoCodec = .hevc
}

/// Decoded 12-byte scrcpy frame metadata packet (`pts_and_flags` + `packet_size` + payload).
public struct ScrcpyFramePacket: Sendable, Equatable {
    /// Raw 64-bit `pts_and_flags` header from scrcpy (`send_frame_meta=true`).
    public let ptsAndFlags: UInt64
    /// Whether the packet carries codec configuration data (SPS/PPS/VPS).
    public var isConfig: Bool { (ptsAndFlags & (1 << 63)) != 0 }
    /// Whether the packet marks a keyframe / IDR access unit.
    public var isKeyFrame: Bool { (ptsAndFlags & (1 << 62)) != 0 }
    /// Presentation timestamp in microseconds (lower 62 bits).
    public var pts: UInt64 { ptsAndFlags & 0x3FFF_FFFF_FFFF_FFFF }
    /// Raw compressed video payload (typically Annex-B NAL units).
    public let payload: Data

    /// Creates a `ScrcpyFramePacket`.
    public init(ptsAndFlags: UInt64, payload: Data) {
        self.ptsAndFlags = ptsAndFlags
        self.payload = payload
    }
}

/// Zero-dependency Annex-B H.264/HEVC NAL unit parser and scrcpy packet framing helper.
public enum AnnexBParser {
    /// Default stream buffer cap (16 MiB) used to protect against unbounded growth on malformed streams.
    public static let defaultMaxStreamBufferBytes = 16 * 1024 * 1024

    /// Finds the next Annex-B start code (`0x000001` or `0x00000001`) in `data` starting at `offset`.
    /// - Parameters:
    ///   - data: Byte buffer to scan.
    ///   - offset: Zero-based byte offset within `data` where scanning begins.
    /// - Returns: The zero-based start index and start-code length (`3` or `4`), or `nil` if not found.
    public static func findStartCode(in data: Data, startingAt offset: Int = 0) -> (index: Int, length: Int)? {
        guard offset >= 0, offset + 3 <= data.count else { return nil }

        return data.withUnsafeBytes { rawBuffer -> (Int, Int)? in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let count = data.count
            var index = offset
            while index + 3 <= count {
                if ptr[index] == 0 && ptr[index + 1] == 0 {
                    if ptr[index + 2] == 1 {
                        return (index, 3)
                    } else if index + 4 <= count && ptr[index + 2] == 0 && ptr[index + 3] == 1 {
                        return (index, 4)
                    }
                }
                index += 1
            }
            return nil
        }
    }

    /// Splits a complete Annex-B access unit or config packet into individual NAL unit payloads (start codes stripped).
    /// - Parameter data: Raw Annex-B byte buffer.
    /// - Returns: Array of normalized `Data` slices (each with `startIndex == 0`).
    public static func parseNALUnits(from data: Data) -> [Data] {
        var nals: [Data] = []
        var offset = 0
        while let start = findStartCode(in: data, startingAt: offset) {
            let nalStart = start.index + start.length
            let nalEnd = findStartCode(in: data, startingAt: nalStart)?.index ?? data.count
            if nalEnd > nalStart {
                let slice = Data(data.dropFirst(nalStart).prefix(nalEnd - nalStart))
                nals.append(slice)
            }
            offset = nalEnd
        }
        return nals
    }

    /// Extracts the next complete NAL unit delimited by two Annex-B start codes from a streaming buffer.
    /// Useful for incremental byte streams where the trailing NAL may still be incomplete.
    /// - Parameter data: Accumulated stream buffer.
    /// - Returns: The extracted NAL payload and the byte offset of the following start code, or `nil` if incomplete.
    public static func extractNextNAL(from data: Data) -> (nal: Data, nextOffset: Int)? {
        guard data.count > 4 else { return nil }
        guard let firstStart = findStartCode(in: data, startingAt: 0) else { return nil }
        let payloadStart = firstStart.index + firstStart.length
        guard let nextStart = findStartCode(in: data, startingAt: payloadStart) else {
            return nil
        }
        let nalPayload = Data(data.dropFirst(payloadStart).prefix(nextStart.index - payloadStart))
        return (nalPayload, nextStart.index)
    }

    /// Extracts the 5-bit H.264 NAL unit type (`nal[0] & 0x1F`).
    /// - Parameter nal: Single NAL unit payload without Annex-B start code.
    /// - Returns: H.264 NAL unit type (`7` = SPS, `8` = PPS, `5` = IDR, `1` = non-IDR), or `nil` if empty.
    public static func h264NALType(for nal: Data) -> UInt8? {
        guard let first = nal.first else { return nil }
        return first & 0x1F
    }

    /// Extracts the 6-bit HEVC NAL unit type (`(nal[0] >> 1) & 0x3F`).
    /// - Parameter nal: Single NAL unit payload without Annex-B start code.
    /// - Returns: HEVC NAL unit type (`32` = VPS, `33` = SPS, `34` = PPS, `19`/`20` = IDR), or `nil` if empty.
    public static func hevcNALType(for nal: Data) -> UInt8? {
        guard let first = nal.first else { return nil }
        return (first >> 1) & 0x3F
    }

    /// Returns `true` when `nal` is a parameter set (H.264 SPS/PPS or HEVC VPS/SPS/PPS) for `codec`.
    public static func isParameterSet(_ nal: Data, codec: VideoCodec) -> Bool {
        switch codec {
        case .h264:
            guard let type = h264NALType(for: nal) else { return false }
            return type == 7 || type == 8
        case .hevc:
            guard let type = hevcNALType(for: nal) else { return false }
            return type == 32 || type == 33 || type == 34
        }
    }

    /// Caps a streaming buffer at `maxBytes` to prevent unbounded memory growth on malformed streams.
    /// - Returns: `true` if the buffer exceeded `maxBytes` and was cleared.
    @discardableResult
    public static func trimOversizedStreamBuffer(
        _ buffer: inout Data,
        maxBytes: Int = defaultMaxStreamBufferBytes
    ) -> Bool {
        guard buffer.count > maxBytes else { return false }
        buffer.removeAll(keepingCapacity: false)
        return true
    }

    /// Attempts to consume a 12-byte scrcpy framed packet (`8-byte pts_and_flags` + `4-byte size` + payload)
    /// from the front of `buffer`.
    /// - Parameters:
    ///   - buffer: Mutable stream buffer (re-zeroed on consumption so `startIndex` remains `0`).
    ///   - maxPacketBytes: Sanity limit for a single packet payload (default 10 MB).
    /// - Returns: Decoded `ScrcpyFramePacket` if complete, or `nil` if more bytes are needed or header is not scrcpy-framed.
    public static func extractScrcpyFramedPacket(
        from buffer: inout Data,
        maxPacketBytes: Int = 10_000_000
    ) -> ScrcpyFramePacket? {
        if buffer.startIndex != 0 {
            buffer = Data(buffer)
        }
        guard buffer.count >= 12 else { return nil }

        let (ptsAndFlags, packetSize) = buffer.withUnsafeBytes { rawPtr -> (UInt64, UInt32) in
            let pts = rawPtr.loadUnaligned(fromByteOffset: 0, as: UInt64.self).bigEndian
            let size = rawPtr.loadUnaligned(fromByteOffset: 8, as: UInt32.self).bigEndian
            return (pts, size)
        }

        guard packetSize > 0, Int(packetSize) <= maxPacketBytes else { return nil }
        let totalSize = 12 + Int(packetSize)
        guard buffer.count >= totalSize else { return nil }

        let payload = Data(buffer[12..<totalSize])
        if totalSize >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else {
            buffer = Data(buffer[totalSize...])
        }
        return ScrcpyFramePacket(ptsAndFlags: ptsAndFlags, payload: payload)
    }
}
