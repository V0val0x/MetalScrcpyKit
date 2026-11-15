import Foundation
import Network

/// Physical transport underlying a mirroring session.
public enum TransportKind: String, Sendable, Equatable {
    case usb
    case wifi
    case bluetoothPAN
    case directHotspot
}

/// Decoupled connection descriptor used by `PerformanceEngine` for transport labeling and wireless TCP RTT probing.
public struct ProbeTarget: Sendable, Equatable {
    /// Transport medium.
    public let kind: TransportKind
    /// Optional IP address or hostname for wireless TCP RTT probing.
    public let host: String?
    /// TCP port used for wireless RTT probing (default `5555`).
    public let port: Int

    /// Default wired USB target (no wireless TCP probing needed).
    public static let usb = ProbeTarget(kind: .usb, host: nil, port: 0)

    /// Creates a wireless `ProbeTarget` from a host and port.
    public static func wifi(host: String, port: Int = 5555) -> ProbeTarget {
        ProbeTarget(kind: .wifi, host: host, port: port)
    }

    /// Creates a `ProbeTarget`.
    public init(kind: TransportKind, host: String? = nil, port: Int = 5555) {
        self.kind = kind
        self.host = host
        self.port = port
    }

    /// Human-readable transport label (`"USB"`, `"BT PAN"`, `"Direct Hotspot"`, or `"Wi-Fi"`).
    public var transportLabel: String {
        switch kind {
        case .usb:
            return "USB"
        case .bluetoothPAN:
            return "BT PAN"
        case .directHotspot:
            return "Direct Hotspot"
        case .wifi:
            if let host {
                if host.hasPrefix("192.168.44.") {
                    return "BT PAN"
                }
                if host.hasPrefix("192.168.43.") {
                    return "Direct Hotspot"
                }
            }
            return "Wi-Fi"
        }
    }

    /// Returns `(host, port)` when wireless probing is applicable and the port is valid.
    public func extractHostAndPort() -> (String, Int)? {
        guard kind != .usb, let host, !host.isEmpty, (1...65535).contains(port) else {
            return nil
        }
        return (host, port)
    }
}

/// Thresholds and target encoding parameters for `PerformanceEngine` Adaptive Bitrate (ABR).
public struct ABRConfiguration: Sendable, Equatable {
    /// Default configuration tuned for 120Hz scrcpy mirroring (16 Mbps / 1440px <-> 6 Mbps / 1280px).
    public static let `default` = ABRConfiguration()

    public let normalBitRate: Int
    public let normalMaxSize: Int
    public let reducedBitRate: Int
    public let reducedMaxSize: Int
    public let highRTTThresholdMs: Int
    public let lowRTTThresholdMs: Int
    public let highRTTSamplesRequired: Int
    public let lowRTTSamplesRequired: Int
    public let probeIntervalNanoseconds: UInt64

    /// Creates an `ABRConfiguration`.
    public init(
        normalBitRate: Int = 16_000_000,
        normalMaxSize: Int = 1440,
        reducedBitRate: Int = 6_000_000,
        reducedMaxSize: Int = 1280,
        highRTTThresholdMs: Int = 120,
        lowRTTThresholdMs: Int = 60,
        highRTTSamplesRequired: Int = 4,
        lowRTTSamplesRequired: Int = 8,
        probeIntervalNanoseconds: UInt64 = 500_000_000
    ) {
        self.normalBitRate = normalBitRate
        self.normalMaxSize = normalMaxSize
        self.reducedBitRate = reducedBitRate
        self.reducedMaxSize = reducedMaxSize
        self.highRTTThresholdMs = highRTTThresholdMs
        self.lowRTTThresholdMs = lowRTTThresholdMs
        self.highRTTSamplesRequired = highRTTSamplesRequired
        self.lowRTTSamplesRequired = lowRTTSamplesRequired
        self.probeIntervalNanoseconds = probeIntervalNanoseconds
    }
}

/// Manages macOS `latencyCritical` activity assertions, 500ms wireless RTT/jitter probing,
/// Adaptive Bitrate (ABR) step-down/recovery, and live Performance HUD telemetry.
@MainActor
public final class PerformanceEngine: ObservableObject {
    /// Shared singleton instance used by default by `VideoToolboxStreamDecoder`.
    public static let shared = PerformanceEngine()

    /// Display codec label reported in telemetry.
    public enum CodecLabel: String, Sendable, Equatable {
        case hevc = "HEVC"
        case h264 = "H264"

        /// Maps a `VideoCodec` to its telemetry `CodecLabel`.
        public init(codec: VideoCodec) {
            switch codec {
            case .hevc: self = .hevc
            case .h264: self = .h264
            }
        }
    }

    /// Most recently measured presented frames per second.
    @Published public private(set) var liveFPS: Int = 0
    /// Most recently measured TCP RTT in milliseconds (`1` for USB).
    @Published public private(set) var rttMs: Int = 0
    /// Absolute consecutive RTT delta in milliseconds.
    @Published public private(set) var jitterMs: Int = 0
    /// Active video codec label.
    @Published public private(set) var activeCodec: CodecLabel = .hevc
    /// Active transport label (`"USB"`, `"Wi-Fi"`, `"Direct Hotspot"`, `"BT PAN"`).
    @Published public private(set) var transportLabel: String = "USB"
    /// `true` while ABR has stepped down bitrate/resolution due to elevated wireless RTT.
    @Published public private(set) var isABRReduced: Bool = false
    /// `true` while a mirroring session is active.
    @Published public private(set) var isSessionActive: Bool = false

    /// ABR thresholds and bitrates used by this engine instance.
    public let abrConfiguration: ABRConfiguration

    /// Invoked whenever ABR transitions between normal and reduced profiles.
    public var onABRStepChange: (@Sendable (_ bitRate: Int, _ maxSize: Int, _ reduced: Bool) -> Void)?

    private var activityToken: NSObjectProtocol?
    private var probeTask: Task<Void, Never>?
    private var fpsTimer: Timer?

    private final class AtomicFrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count: Int = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func resetAndRead() -> Int {
            lock.lock()
            let val = count
            count = 0
            lock.unlock()
            return val
        }

        func reset() {
            lock.lock()
            count = 0
            lock.unlock()
        }
    }

    private nonisolated static let frameCounter = AtomicFrameCounter()

    private var highRTTConsecutiveCount: Int = 0
    private var lowRTTConsecutiveCount: Int = 0
    private var previousRTTMs: Int?

    /// Creates an isolated `PerformanceEngine` instance (useful for multi-stream apps or unit testing).
    public init(abrConfiguration: ABRConfiguration = .default) {
        self.abrConfiguration = abrConfiguration
    }

    /// Starts a latency-critical macOS activity assertion (preventing App Nap & Wi-Fi radio sleep)
    /// and begins live FPS + wireless RTT probing.
    public func beginMirroringSession(target: ProbeTarget = .usb, codec: CodecLabel = .hevc) {
        endMirroringSession()

        self.isSessionActive = true
        self.activeCodec = codec
        self.transportLabel = target.transportLabel
        self.isABRReduced = false
        self.highRTTConsecutiveCount = 0
        self.lowRTTConsecutiveCount = 0
        self.previousRTTMs = nil

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "120Hz Low-Latency Mirroring"
        )

        Self.frameCounter.reset()

        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let count = Self.frameCounter.resetAndRead()
            Task { @MainActor in
                self.liveFPS = count
            }
        }
        fpsTimer?.tolerance = 0.2

        if let (host, port) = target.extractHostAndPort() {
            let interval = abrConfiguration.probeIntervalNanoseconds
            probeTask = Task { [weak self] in
                while !Task.isCancelled {
                    let measured = await Self.measureTCPRTTMilliseconds(host: host, port: port)
                    guard !Task.isCancelled else { break }
                    _ = await MainActor.run {
                        self?.ingestProbeSample(rttMs: measured)
                    }
                    try? await Task.sleep(nanoseconds: interval)
                }
            }
        } else {
            self.rttMs = 1
            self.jitterMs = 0
        }
    }

    /// Stops FPS/RTT probing, releases the `latencyCritical` activity token, and resets telemetry counters.
    public func endMirroringSession() {
        probeTask?.cancel()
        probeTask = nil
        fpsTimer?.invalidate()
        fpsTimer = nil

        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }

        isSessionActive = false
        liveFPS = 0
        rttMs = 0
        jitterMs = 0
        isABRReduced = false
        highRTTConsecutiveCount = 0
        lowRTTConsecutiveCount = 0
        previousRTTMs = nil
    }

    /// Updates the reported active codec label.
    public func updateActiveCodec(_ codec: CodecLabel) {
        self.activeCodec = codec
    }

    /// Thread-safe frame presentation counter called from the video decoder / Metal display loop.
    public nonisolated static func recordPresentedFrame() {
        frameCounter.increment()
    }

    /// Evaluates ABR step-down (`> highRTTThresholdMs` for `highRTTSamplesRequired` samples)
    /// and recovery (`< lowRTTThresholdMs` for `lowRTTSamplesRequired` samples).
    /// - Parameter measured: Measured RTT in milliseconds (`nil` is treated as a 200ms timeout penalty).
    /// - Returns: Tuple `(changed, bitRate, maxSize, reduced)` indicating whether an ABR transition occurred.
    @discardableResult
    public func ingestProbeSample(rttMs measured: Int?) -> (changed: Bool, bitRate: Int, maxSize: Int, reduced: Bool) {
        let sample = measured ?? 200
        if let prev = previousRTTMs {
            jitterMs = abs(sample - prev)
        }
        previousRTTMs = sample
        rttMs = sample

        if !isABRReduced {
            if sample > abrConfiguration.highRTTThresholdMs {
                highRTTConsecutiveCount += 1
                lowRTTConsecutiveCount = 0
                if highRTTConsecutiveCount >= abrConfiguration.highRTTSamplesRequired {
                    isABRReduced = true
                    highRTTConsecutiveCount = 0
                    onABRStepChange?(abrConfiguration.reducedBitRate, abrConfiguration.reducedMaxSize, true)
                    return (true, abrConfiguration.reducedBitRate, abrConfiguration.reducedMaxSize, true)
                }
            } else {
                highRTTConsecutiveCount = 0
            }
        } else {
            if sample < abrConfiguration.lowRTTThresholdMs {
                lowRTTConsecutiveCount += 1
                highRTTConsecutiveCount = 0
                if lowRTTConsecutiveCount >= abrConfiguration.lowRTTSamplesRequired {
                    isABRReduced = false
                    lowRTTConsecutiveCount = 0
                    onABRStepChange?(abrConfiguration.normalBitRate, abrConfiguration.normalMaxSize, false)
                    return (true, abrConfiguration.normalBitRate, abrConfiguration.normalMaxSize, false)
                }
            } else {
                lowRTTConsecutiveCount = 0
            }
        }

        return (
            false,
            isABRReduced ? abrConfiguration.reducedBitRate : abrConfiguration.normalBitRate,
            isABRReduced ? abrConfiguration.reducedMaxSize : abrConfiguration.normalMaxSize,
            isABRReduced
        )
    }

    private nonisolated static func measureTCPRTTMilliseconds(host: String, port: Int) async -> Int? {
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return nil
        }

        final class ProbeDoneFlag: @unchecked Sendable {
            var done = false
        }

        let start = CFAbsoluteTimeGetCurrent()
        return await withCheckedContinuation { continuation in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "com.metalscrcpykit.rttprobe")
            let lock = NSLock()
            let stateFlag = ProbeDoneFlag()

            let finish: @Sendable (Int?) -> Void = { ms in
                lock.lock()
                defer { lock.unlock() }
                guard !stateFlag.done else { return }
                stateFlag.done = true
                conn.stateUpdateHandler = nil
                conn.cancel()
                continuation.resume(returning: ms)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000.0).rounded())
                    finish(max(1, elapsed))
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 0.45) {
                finish(nil)
            }
        }
    }
}
