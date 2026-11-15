import SwiftUI
import AppKit
import CoreVideo
import VideoToolbox
import QuartzCore
import os

/// Coalesces fallback `CGImage` rendering on the main queue when Metal is unavailable.
private final class FallbackCGImageCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingImage: CGImage?
    private var isScheduled = false
    private weak var target: MetalDisplayView?

    init(target: MetalDisplayView) {
        self.target = target
    }

    func enqueue(_ image: CGImage) {
        lock.lock()
        pendingImage = image
        let shouldSchedule = !isScheduled
        if shouldSchedule {
            isScheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushOnMain()
        }
    }

    private func flushOnMain() {
        lock.lock()
        let nextImage = pendingImage
        pendingImage = nil
        isScheduled = false
        lock.unlock()

        if let nextImage {
            MainActor.assumeIsolated {
                target?.renderCGImage(nextImage)
            }
        }
    }
}

/// Hardware-synchronized AppKit `NSView` driven by a 120Hz `CADisplayLink` and `MetalVideoRenderer`.
/// Automatically pauses display-link ticks when its hosting `NSWindow` is occluded to minimize GPU/CPU overhead.
public final class MetalDisplayView: NSView {
    /// Underlying zero-copy Metal renderer, or `nil` if Metal initialization failed.
    public nonisolated let renderer: MetalVideoRenderer?

    /// Corner radius applied to both the hosting layer and `renderer.metalLayer`.
    public var cornerRadius: CGFloat = 0 {
        didSet {
            layer?.cornerRadius = cornerRadius
            renderer?.metalLayer.cornerRadius = cornerRadius
        }
    }

    /// Preferred `CADisplayLink` frame rate range (defaults to 60–120Hz ProMotion).
    public var preferredFrameRateRange: CAFrameRateRange = CAFrameRateRange(
        minimum: 60,
        maximum: 120,
        preferred: 120
    ) {
        didSet {
            displayLink?.preferredFrameRateRange = preferredFrameRateRange
        }
    }

    /// `true` once at least one frame has been rendered or submitted for display.
    public private(set) var hasRenderedFrame: Bool = false

    /// Invoked on the main thread when the first frame arrives.
    public var onFirstFrameRendered: (() -> Void)?

    override public var isFlipped: Bool { true }

    private nonisolated let firstFrameFlag = OSAllocatedUnfairLock(initialState: false)
    private nonisolated let fallbackCoalescerLock = NSLock()
    private nonisolated(unsafe) var fallbackCoalescer: FallbackCGImageCoalescer?

    private nonisolated(unsafe) var displayLink: CADisplayLink?
    private nonisolated(unsafe) var occlusionObserver: NSObjectProtocol?
    private var latestFallbackImage: CGImage?
    private weak var attachedDecoder: VideoToolboxStreamDecoder?

    /// Creates a `MetalDisplayView` with an optional custom `MetalVideoRenderer`.
    public init(
        frame frameRect: NSRect = .zero,
        renderer: MetalVideoRenderer? = MetalVideoRenderer()
    ) {
        self.renderer = renderer
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayLink?.invalidate()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspect

        fallbackCoalescerLock.lock()
        fallbackCoalescer = FallbackCGImageCoalescer(target: self)
        fallbackCoalescerLock.unlock()

        if let renderer {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            renderer.updateDrawableGeometry(bounds: bounds, scale: scale, cornerRadius: cornerRadius)
            renderer.metalLayer.masksToBounds = true
            layer?.addSublayer(renderer.metalLayer)
        }
    }

    /// Submits a decoded `CVPixelBuffer` from any thread with zero main-thread dispatch jitter.
    public nonisolated func submit(pixelBuffer: CVPixelBuffer) {
        if let renderer {
            renderer.submit(pixelBuffer: pixelBuffer)
            let isFirst = firstFrameFlag.withLock { notified -> Bool in
                if notified { return false }
                notified = true
                return true
            }
            if isFirst {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.hasRenderedFrame = true
                    self.ensureDisplayLink()
                    self.renderer?.renderLatestFrameIfAvailable()
                    self.onFirstFrameRendered?()
                }
            }
            return
        }

        // Software fallback if Metal is unavailable
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        if let cgImage {
            fallbackCoalescerLock.lock()
            let coalescer = fallbackCoalescer
            fallbackCoalescerLock.unlock()
            coalescer?.enqueue(cgImage)
        }
    }

    /// Binds this view to a `VideoToolboxStreamDecoder` so decoded frames automatically flow to `submit(pixelBuffer:)`.
    public func attach(to decoder: VideoToolboxStreamDecoder) {
        if attachedDecoder === decoder { return }
        detach()
        attachedDecoder = decoder
        decoder.onFrameDecoded = { [weak self] pixelBuffer in
            self?.submit(pixelBuffer: pixelBuffer)
        }
        if let cached = decoder.latestPixelBuffer {
            submit(pixelBuffer: cached)
        }
    }

    /// Detaches this view from its currently attached `VideoToolboxStreamDecoder`.
    public func detach() {
        attachedDecoder?.onFrameDecoded = nil
        attachedDecoder = nil
    }

    /// Renders a fallback `CGImage` directly onto the view's backing `CALayer`.
    public func renderCGImage(_ cgImage: CGImage) {
        let isFirst = !hasRenderedFrame
        latestFallbackImage = cgImage
        hasRenderedFrame = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = cgImage
        layer?.contentsGravity = .resizeAspect
        CATransaction.commit()
        if isFirst {
            onFirstFrameRendered?()
        }
    }

    /// Invalidates the `CADisplayLink`, removes window observers, and detaches any bound decoder.
    public func teardown() {
        displayLink?.invalidate()
        displayLink = nil
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        detach()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }

        if let win = window {
            ensureDisplayLink()
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: win,
                queue: .main
            ) { [weak self, weak win] _ in
                Task { @MainActor [weak self, weak win] in
                    let isVisible = win?.occlusionState.contains(.visible) ?? false
                    self?.displayLink?.isPaused = !isVisible
                }
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    override public func layout() {
        super.layout()
        ensureDisplayLink()
        if let renderer {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            renderer.updateDrawableGeometry(bounds: bounds, scale: scale, cornerRadius: cornerRadius)
        } else if let latestFallbackImage {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = latestFallbackImage
            layer?.contentsGravity = .resizeAspect
            CATransaction.commit()
        }
    }

    private func ensureDisplayLink() {
        guard window != nil, displayLink == nil, renderer != nil else { return }
        let link = self.displayLink(target: self, selector: #selector(handleDisplayLink))
        link.preferredFrameRateRange = preferredFrameRateRange
        link.add(to: .main, forMode: .common)
        link.isPaused = (window?.occlusionState.contains(.visible) == false)
        self.displayLink = link
    }

    @objc private func handleDisplayLink() {
        renderer?.renderLatestFrameIfAvailable()
    }
}

/// SwiftUI `NSViewRepresentable` wrapper around `MetalDisplayView` for zero-copy 120Hz ProMotion video playback.
public struct MetalVideoDisplayView: NSViewRepresentable {
    /// Optional `VideoToolboxStreamDecoder` to automatically attach to the display view.
    public let decoder: VideoToolboxStreamDecoder?
    /// Optional pre-built `MetalVideoRenderer`. When `nil`, a default renderer is created automatically.
    public let renderer: MetalVideoRenderer?
    /// Corner radius applied to the video surface.
    public var cornerRadius: CGFloat
    /// Preferred `CADisplayLink` frame rate range (defaults to 60–120Hz ProMotion).
    public var preferredFrameRateRange: CAFrameRateRange
    /// Optional callback invoked once the underlying `MetalDisplayView` is created.
    public var onViewReady: ((MetalDisplayView) -> Void)?

    /// Creates a SwiftUI `MetalVideoDisplayView`.
    public init(
        decoder: VideoToolboxStreamDecoder? = nil,
        renderer: MetalVideoRenderer? = nil,
        cornerRadius: CGFloat = 0,
        preferredFrameRateRange: CAFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120),
        onViewReady: ((MetalDisplayView) -> Void)? = nil
    ) {
        self.decoder = decoder
        self.renderer = renderer
        self.cornerRadius = cornerRadius
        self.preferredFrameRateRange = preferredFrameRateRange
        self.onViewReady = onViewReady
    }

    public func makeNSView(context: Context) -> MetalDisplayView {
        let view = MetalDisplayView(frame: .zero, renderer: renderer ?? MetalVideoRenderer())
        view.cornerRadius = cornerRadius
        view.preferredFrameRateRange = preferredFrameRateRange
        if let decoder {
            view.attach(to: decoder)
        }
        onViewReady?(view)
        return view
    }

    public func updateNSView(_ nsView: MetalDisplayView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.preferredFrameRateRange = preferredFrameRateRange
        if let decoder {
            nsView.attach(to: decoder)
        }
    }

    public static func dismantleNSView(_ nsView: MetalDisplayView, coordinator: ()) {
        nsView.teardown()
    }
}
