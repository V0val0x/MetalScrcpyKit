# MetalScrcpyKit

Zero-copy **120Hz ProMotion** `VideoToolbox` H.264/HEVC stream decoder and `CAMetalLayer` renderer for macOS, extracted from [**AndOnMac**](https://github.com/V0val0x/AndOnMac).

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-blue.svg)](https://github.com/V0val0x/MetalScrcpyKit)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![CI](https://github.com/V0val0x/MetalScrcpyKit/actions/workflows/ci.yml/badge.svg)](https://github.com/V0val0x/MetalScrcpyKit/actions/workflows/ci.yml)

**English** | [Русская версия (Russian)](README_RU.md)

---

## Features

- **Socket-Agnostic Hardware Video Decoding (`VideoToolboxStreamDecoder`):** Decodes raw Annex-B byte streams, discrete packet payloads, single NAL units, or 12-byte scrcpy framed streams (`H.264` & `HEVC`) into Metal-compatible `CVPixelBuffer`s (`.bgra32`, `.nv12VideoRange`, `.nv12FullRange`) via `VTDecompressionSession`.
- **Zero-Copy 120Hz ProMotion Metal Renderer (`MetalVideoRenderer`):** `CAMetalLayer` (`displaySyncEnabled = true`, `maximumDrawableCount = 3`) + `CVMetalTextureCache` with dedicated BGRA and BT.709 NV12 shaders and latest-frame coalescing (drops stale unpresented frames to eliminate queue lag).
- **AppKit & SwiftUI Display Surfaces (`MetalDisplayView` / `MetalVideoDisplayView`):** `NSView` synchronized to `CADisplayLink` (`60–120Hz`), automatically pausing on window occlusion (`didChangeOcclusionStateNotification`), plus a drop-in SwiftUI `NSViewRepresentable`.
- **Latency-Critical Telemetry & ABR (`PerformanceEngine`):** Acquires macOS `latencyCritical` + `userInitiated` activity assertions, tracks live FPS, probes wireless TCP RTT/jitter every 500ms, and runs hysteresis-guarded Adaptive Bitrate (ABR) step-down/recovery.
- **Orphan-Free Child Process Supervisor (`ProcessLifecycleManager`):** Thread-safe registry for child processes (`scrcpy-server`, `adb`, etc.) with `SIGTERM` → `SIGKILL` escalation and synchronous teardown support on app quit.

---

## Installation (Swift Package Manager)

Add `MetalScrcpyKit` to your `Package.swift` (macOS 14+, Swift 5.9+):

```swift
dependencies: [
    .package(url: "https://github.com/V0val0x/MetalScrcpyKit.git", from: "1.0.0")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: ["MetalScrcpyKit"]
    )
]
```

Or in Xcode: **File → Add Package Dependencies…** and enter `https://github.com/V0val0x/MetalScrcpyKit`.

---

## Quick Start

### 1. SwiftUI 120Hz Display View

```swift
import SwiftUI
import MetalScrcpyKit

struct MirrorScreenView: View {
    @State private var decoder = VideoToolboxStreamDecoder(codec: .hevc, pixelFormat: .nv12VideoRange)
    @ObservedObject private var perf = PerformanceEngine.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalVideoDisplayView(decoder: decoder, cornerRadius: 36)
                .aspectRatio(9.0 / 20.0, contentMode: .fit)

            Text("\(perf.liveFPS) FPS · \(perf.activeCodec.rawValue) · \(perf.rttMs)ms")
                .font(.caption.monospacedDigit())
                .padding(8)
        }
        .onAppear {
            perf.beginMirroringSession(target: .usb, codec: .hevc)
        }
        .onDisappear {
            perf.endMirroringSession()
            decoder.invalidate()
        }
    }
}
```

### 2. Raw VideoToolbox Decoding & Offscreen Metal Rendering

```swift
import Foundation
import MetalScrcpyKit

let decoder = VideoToolboxStreamDecoder(codec: .h264, pixelFormat: .bgra32)
let renderer = MetalVideoRenderer()

decoder.onVideoSizeChanged = { width, height in
    print("Stream dimensions: \(width)x\(height)")
}

decoder.onFrameDecoded = { pixelBuffer in
    // Coalesces to newest frame with zero main-thread dispatch jitter
    renderer?.submit(pixelBuffer: pixelBuffer)
}

// Feed raw Annex-B stream chunks from any socket, pipe, or file:
func didReceiveVideoBytes(_ chunk: Data) {
    decoder.feedAnnexBStream(chunk)
}

// Or feed scrcpy 12-byte framed packets (`send_frame_meta=true`):
func didReceiveScrcpyBytes(_ chunk: Data) {
    decoder.feedScrcpyFramedStream(chunk)
}
```

---

## API Overview

| Component | Responsibility |
| :--- | :--- |
| `AnnexBParser` | Scans `0x000001` / `0x00000001` start codes, splits NAL units, detects H.264/HEVC parameter sets, parses 12-byte scrcpy frame headers, and caps oversized buffers. |
| `VideoToolboxStreamDecoder` | Manages `CMVideoFormatDescription` (H.264 SPS/PPS, HEVC VPS/SPS/PPS) and asynchronous `VTDecompressionSession` output (`CVPixelBuffer` & optional `CGImage`). |
| `MetalVideoRenderer` | Zero-copy `CVMetalTextureCache` + `CAMetalLayer` triple-buffered renderer supporting `32BGRA` and bi-planar BT.709 `NV12` (`420v` / `420f`). |
| `MetalDisplayView` | `NSView` with 120Hz `CADisplayLink`, window-occlusion auto-pause, and fallback `CGImage` rendering. |
| `MetalVideoDisplayView` | SwiftUI `NSViewRepresentable` wrapper around `MetalDisplayView`. |
| `PerformanceEngine` | macOS `latencyCritical` activity token, atomic FPS counter, 500ms TCP RTT/jitter probing, and ABR bitrate adaptation. |
| `ProcessLifecycleManager` | Thread-safe child `Process` tracker with tag-based and synchronous `SIGTERM` → `SIGKILL` cleanup. |

---

## AndOnMac Ecosystem

`MetalScrcpyKit` is part of the modular [**AndOnMac**](https://github.com/V0val0x/AndOnMac) open-source ecosystem for macOS ↔ Android tooling:

- [**AndOnMac**](https://github.com/V0val0x/AndOnMac) — Full native macOS Android mirroring, Continuity, file/photo transfer, and AI suite.
- **MetalScrcpyKit** — Zero-copy 120Hz ProMotion VideoToolbox decoder & Metal renderer (this package).
- [**ADBConnectKit**](https://github.com/V0val0x/ADBConnectKit) — Pure Swift ADB client, QR/mDNS wireless pairing & Direct Hotspot/BT PAN bypass.
- [**AndroidMCPKit**](https://github.com/V0val0x/AndroidMCPKit) — Model Context Protocol (MCP) server & self-healing UI automation tools for Android.
- [**VisionScreenRecallKit**](https://github.com/V0val0x/VisionScreenRecallKit) — Apple Silicon Vision OCR & local SQLite FTS5 screen memory search.

---

## License

MIT License © 2026 Kirill Zaitsev. See [LICENSE](./LICENSE).
