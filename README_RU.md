# MetalScrcpyKit

Zero-copy **120Hz ProMotion** декодер `VideoToolbox` (H.264/HEVC) и Metal-рендерер на базе `CAMetalLayer` для macOS, выделенный из проекта [**AndOnMac**](https://github.com/V0val0x/AndOnMac).

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-blue.svg)](https://github.com/V0val0x/MetalScrcpyKit)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![CI](https://github.com/V0val0x/MetalScrcpyKit/actions/workflows/ci.yml/badge.svg)](https://github.com/V0val0x/MetalScrcpyKit/actions/workflows/ci.yml)

[English Version](README.md) | **Русская версия**

---

## Возможности

- **Аппаратный декодер без привязки к сокетам (`VideoToolboxStreamDecoder`):** декодирует сырые Annex-B потоки, отдельные пакеты, одиночные NAL-единицы и 12-байтные пакеты scrcpy (`H.264` и `HEVC`) в Metal-совместимые `CVPixelBuffer` (`.bgra32`, `.nv12VideoRange`, `.nv12FullRange`) через `VTDecompressionSession`.
- **Zero-Copy 120Hz ProMotion рендерер (`MetalVideoRenderer`):** `CAMetalLayer` (`displaySyncEnabled = true`, `maximumDrawableCount = 3`) + `CVMetalTextureCache` со встроенными шейдерами BGRA и BT.709 NV12 и коалесцингом кадров (устаревшие неотображённые кадры мгновенно отбрасываются для нулевой задержки очереди).
- **AppKit и SwiftUI компоненты (`MetalDisplayView` / `MetalVideoDisplayView`):** `NSView` с `CADisplayLink` (`60–120Hz`), автопаузой при перекрытии окна (`didChangeOcclusionStateNotification`) и готовой обёрткой для SwiftUI.
- **Низколатентная телеметрия и ABR (`PerformanceEngine`):** включает `latencyCritical` + `userInitiated` assertion macOS, считает реальный FPS, измеряет TCP RTT/jitter каждые 500 мс и управляет адаптивным битрейтом (ABR).
- **Контроль дочерних процессов (`ProcessLifecycleManager`):** потокобезопасный реестр дочерних `Process` (`scrcpy-server`, `adb` и др.) с эскалацией `SIGTERM` → `SIGKILL` и синхронным завершением при выходе из приложения.

---

## Установка (Swift Package Manager)

Добавьте `MetalScrcpyKit` в ваш `Package.swift` (macOS 14+, Swift 5.9+):

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

Или в Xcode: **File → Add Package Dependencies…** → `https://github.com/V0val0x/MetalScrcpyKit`.

---

## Быстрый старт

### 1. SwiftUI-вью для 120Hz трансляции

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

### 2. Прямое декодирование VideoToolbox и рендеринг в Metal

```swift
import Foundation
import MetalScrcpyKit

let decoder = VideoToolboxStreamDecoder(codec: .h264, pixelFormat: .bgra32)
let renderer = MetalVideoRenderer()

decoder.onVideoSizeChanged = { width, height in
    print("Разрешение потока: \(width)x\(height)")
}

decoder.onFrameDecoded = { pixelBuffer in
    // Сохраняет только самый свежий кадр без джиттера main thread
    renderer?.submit(pixelBuffer: pixelBuffer)
}

// Подача сырых фрагментов Annex-B из любого сокета, pipe или файла:
func didReceiveVideoBytes(_ chunk: Data) {
    decoder.feedAnnexBStream(chunk)
}

// Или подача пакетов scrcpy с 12-байтным заголовком (`send_frame_meta=true`):
func didReceiveScrcpyBytes(_ chunk: Data) {
    decoder.feedScrcpyFramedStream(chunk)
}
```

---

## Обзор API

| Компонент | Назначение |
| :--- | :--- |
| `AnnexBParser` | Поиск стартовых кодов `0x000001` / `0x00000001`, разбиение NAL-единиц, определение SPS/PPS/VPS (H.264/HEVC), разбор 12-байтных заголовков scrcpy и защита буфера от переполнения. |
| `VideoToolboxStreamDecoder` | Управление `CMVideoFormatDescription` (H.264 SPS/PPS, HEVC VPS/SPS/PPS) и асинхронным `VTDecompressionSession` (`CVPixelBuffer` и опциональный `CGImage`). |
| `MetalVideoRenderer` | Zero-copy рендерер на `CVMetalTextureCache` + `CAMetalLayer` с тройной буферизацией, поддержкой `32BGRA` и двухпланарного BT.709 `NV12` (`420v` / `420f`). |
| `MetalDisplayView` | `NSView` с 120Hz `CADisplayLink`, автопаузой при скрытии окна и резервным `CGImage`-рендерингом. |
| `MetalVideoDisplayView` | SwiftUI `NSViewRepresentable` обёртка для `MetalDisplayView`. |
| `PerformanceEngine` | Токен `latencyCritical` в macOS, потокобезопасный счётчик FPS, TCP RTT/jitter пробы каждые 500 мс и адаптивный битрейт (ABR). |
| `ProcessLifecycleManager` | Потокобезопасный трекер дочерних процессов `Process` с завершением по тегу и синхронной очисткой `SIGTERM` → `SIGKILL`. |

---

## Экосистема AndOnMac

`MetalScrcpyKit` входит в модульную open-source экосистему [**AndOnMac**](https://github.com/V0val0x/AndOnMac) для интеграции macOS и Android:

- [**AndOnMac**](https://github.com/V0val0x/AndOnMac) — Нативное macOS-приложение для зеркалирования Android, Continuity, переноса фото/файлов и локального ИИ.
- **MetalScrcpyKit** — Zero-copy 120Hz ProMotion декодер VideoToolbox и Metal-рендерер (этот пакет).
- [**ADBConnectKit**](https://github.com/V0val0x/ADBConnectKit) — Нативный Swift ADB-клиент, QR/mDNS Wi-Fi сопряжение и обход изоляции через Hotspot/BT PAN.
- [**AndroidMCPKit**](https://github.com/V0val0x/AndroidMCPKit) — MCP-сервер (Model Context Protocol) и самовосстанавливающиеся инструменты автоматизации Android UI.
- [**VisionScreenRecallKit**](https://github.com/V0val0x/VisionScreenRecallKit) — Apple Silicon Vision OCR и локальный поиск по истории экрана на базе SQLite FTS5.

---

## Лицензия

MIT License © 2026 Kirill Zaitsev. Подробнее в [LICENSE](./LICENSE).
