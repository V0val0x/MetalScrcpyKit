import Foundation
import Metal
import QuartzCore
import CoreVideo
import simd

/// Zero-copy 120Hz ProMotion Metal video renderer backed by `CAMetalLayer` (`displaySyncEnabled = true`)
/// and `CVMetalTextureCache`. Supports both 32-bit BGRA and bi-planar NV12 (video & full range) `CVPixelBuffer` inputs
/// and drops stale queued pixel buffers so only the newest frame is presented.
public final class MetalVideoRenderer: @unchecked Sendable {
    /// Backing `CAMetalLayer` configured for 120Hz ProMotion triple-buffered presentation.
    public let metalLayer: CAMetalLayer
    /// Metal device used for texture cache and pipeline execution.
    public let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let bgraPipelineState: MTLRenderPipelineState
    private let nv12PipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private var textureCache: CVMetalTextureCache?

    private let frameLock = NSLock()
    private var pendingPixelBuffer: CVPixelBuffer?
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0
    private var _renderedFrameCount: UInt64 = 0

    /// Returns `true` if a newly submitted `CVPixelBuffer` is waiting to be presented on the next vsync.
    public var hasPendingFrame: Bool {
        frameLock.lock()
        defer { frameLock.unlock() }
        return pendingPixelBuffer != nil
    }

    /// Dimensions of the most recently submitted `CVPixelBuffer`, or `.zero` if none has been submitted.
    public var currentVideoSize: CGSize {
        frameLock.lock()
        defer { frameLock.unlock() }
        return CGSize(width: videoWidth, height: videoHeight)
    }

    /// Total number of frames encoded and committed by this renderer.
    public var renderedFrameCount: UInt64 {
        frameLock.lock()
        defer { frameLock.unlock() }
        return _renderedFrameCount
    }

    private struct NV12Params {
        var fullRange: UInt32
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    struct NV12Params {
        uint fullRange;
    };

    vertex VertexOut videoVertex(uint vid [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
        const float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        const float2 uvs[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };
        VertexOut out;
        out.position = float4(positions[vid] * scale, 0.0, 1.0);
        out.texCoord = uvs[vid];
        return out;
    }

    fragment float4 videoFragmentBGRA(VertexOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      sampler samp [[sampler(0)]]) {
        return tex.sample(samp, in.texCoord);
    }

    fragment float4 videoFragmentNV12(VertexOut in [[stage_in]],
                                      texture2d<float> lumaTex [[texture(0)]],
                                      texture2d<float> chromaTex [[texture(1)]],
                                      sampler samp [[sampler(0)]],
                                      constant NV12Params &params [[buffer(0)]]) {
        float yRaw = lumaTex.sample(samp, in.texCoord).r;
        float2 uvRaw = chromaTex.sample(samp, in.texCoord).rg;

        float y;
        float cb;
        float cr;
        if (params.fullRange != 0) {
            y = yRaw;
            cb = uvRaw.x - 0.5;
            cr = uvRaw.y - 0.5;
        } else {
            y = (yRaw - (16.0 / 255.0)) * (255.0 / 219.0);
            cb = (uvRaw.x - (128.0 / 255.0)) * (255.0 / 224.0);
            cr = (uvRaw.y - (128.0 / 255.0)) * (255.0 / 224.0);
        }

        // BT.709 YCbCr -> RGB conversion
        float r = y + 1.5748 * cr;
        float g = y - 0.187324 * cb - 0.468124 * cr;
        float b = y + 1.8556 * cb;
        return float4(clamp(float3(r, g, b), 0.0, 1.0), 1.0);
    }
    """

    /// Creates a Metal renderer using the default system GPU device, or `nil` if Metal is unavailable.
    public init?(mtlDevice: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let mtlDevice,
              let queue = mtlDevice.makeCommandQueue() else {
            return nil
        }

        let library: MTLLibrary
        do {
            library = try mtlDevice.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            return nil
        }

        guard let vertFunc = library.makeFunction(name: "videoVertex"),
              let bgraFunc = library.makeFunction(name: "videoFragmentBGRA"),
              let nv12Func = library.makeFunction(name: "videoFragmentNV12") else {
            return nil
        }

        let bgraDesc = MTLRenderPipelineDescriptor()
        bgraDesc.vertexFunction = vertFunc
        bgraDesc.fragmentFunction = bgraFunc
        bgraDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        let nv12Desc = MTLRenderPipelineDescriptor()
        nv12Desc.vertexFunction = vertFunc
        nv12Desc.fragmentFunction = nv12Func
        nv12Desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let bgraPipeline = try? mtlDevice.makeRenderPipelineState(descriptor: bgraDesc),
              let nv12Pipeline = try? mtlDevice.makeRenderPipelineState(descriptor: nv12Desc) else {
            return nil
        }

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge
        guard let sampler = mtlDevice.makeSamplerState(descriptor: sampDesc) else {
            return nil
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, mtlDevice, nil, &cache) == kCVReturnSuccess else {
            return nil
        }

        let layer = CAMetalLayer()
        layer.device = mtlDevice
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.displaySyncEnabled = true
        layer.maximumDrawableCount = 3
        layer.presentsWithTransaction = false
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        self.device = mtlDevice
        self.commandQueue = queue
        self.bgraPipelineState = bgraPipeline
        self.nv12PipelineState = nv12Pipeline
        self.samplerState = sampler
        self.textureCache = cache
        self.metalLayer = layer
    }

    /// Stores only the newest `CVPixelBuffer`, overwriting any unpresented frame to guarantee zero queue lag.
    public func submit(pixelBuffer: CVPixelBuffer) {
        frameLock.lock()
        pendingPixelBuffer = pixelBuffer
        videoWidth = CVPixelBufferGetWidth(pixelBuffer)
        videoHeight = CVPixelBufferGetHeight(pixelBuffer)
        frameLock.unlock()
    }

    /// Drops any queued unpresented `CVPixelBuffer`.
    public func clearPendingFrame() {
        frameLock.lock()
        pendingPixelBuffer = nil
        frameLock.unlock()
    }

    /// Updates `metalLayer` bounds, backing scale factor, drawable pixel size, and optional corner radius without implicit CoreAnimation animations.
    public func updateDrawableGeometry(bounds: CGRect, scale: CGFloat, cornerRadius: CGFloat? = nil) {
        let clampedScale = max(1.0, scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = clampedScale
        metalLayer.drawableSize = CGSize(
            width: bounds.width * clampedScale,
            height: bounds.height * clampedScale
        )
        if let cornerRadius {
            metalLayer.cornerRadius = cornerRadius
        }
        CATransaction.commit()
    }

    /// Renders the latest pending pixel buffer onto `metalLayer` if one is available and `drawableSize` is non-zero.
    /// - Returns: `true` if a frame was encoded and presented to `metalLayer`.
    @discardableResult
    public func renderLatestFrameIfAvailable() -> Bool {
        autoreleasepool {
            guard textureCache != nil,
                  metalLayer.drawableSize.width > 0,
                  metalLayer.drawableSize.height > 0 else {
                return false
            }

            frameLock.lock()
            let hasPending = (pendingPixelBuffer != nil && videoWidth > 0 && videoHeight > 0)
            frameLock.unlock()

            guard hasPending,
                  let drawable = metalLayer.nextDrawable() else {
                return false
            }

            frameLock.lock()
            guard let pb = pendingPixelBuffer else {
                frameLock.unlock()
                return false
            }
            pendingPixelBuffer = nil
            frameLock.unlock()

            return encode(
                pixelBuffer: pb,
                to: drawable.texture,
                drawableSize: metalLayer.drawableSize,
                presentableDrawable: drawable
            )
        }
    }

    /// Renders `pixelBuffer` directly into an arbitrary offscreen `MTLTexture` (useful for headless tests or compositing).
    /// - Returns: `true` if the render pass was committed successfully.
    @discardableResult
    public func render(pixelBuffer: CVPixelBuffer, to targetTexture: MTLTexture) -> Bool {
        let targetSize = CGSize(width: targetTexture.width, height: targetTexture.height)
        return encode(
            pixelBuffer: pixelBuffer,
            to: targetTexture,
            drawableSize: targetSize,
            presentableDrawable: nil
        )
    }

    // MARK: - Private Metal Encoding

    private func encode(
        pixelBuffer pb: CVPixelBuffer,
        to targetTexture: MTLTexture,
        drawableSize: CGSize,
        presentableDrawable: CAMetalDrawable?
    ) -> Bool {
        guard let cache = textureCache else { return false }
        let vw = CVPixelBufferGetWidth(pb)
        let vh = CVPixelBufferGetHeight(pb)
        guard vw > 0, vh > 0, drawableSize.width > 0, drawableSize.height > 0 else {
            return false
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pb)
        let isNV12Video = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let isNV12Full = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        let dw = Float(drawableSize.width)
        let dh = Float(drawableSize.height)
        let viewAspect = dw / max(1.0, dh)
        let videoAspect = Float(vw) / Float(max(1, vh))
        var scale: SIMD2<Float>
        if viewAspect > videoAspect {
            scale = SIMD2<Float>(videoAspect / viewAspect, 1.0)
        } else {
            scale = SIMD2<Float>(1.0, viewAspect / videoAspect)
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = targetTexture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return false
        }

        if isNV12Video || isNV12Full {
            let lumaW = CVPixelBufferGetWidthOfPlane(pb, 0)
            let lumaH = CVPixelBufferGetHeightOfPlane(pb, 0)
            let chromaW = CVPixelBufferGetWidthOfPlane(pb, 1)
            let chromaH = CVPixelBufferGetHeightOfPlane(pb, 1)

            var lumaCVTex: CVMetalTexture?
            var chromaCVTex: CVMetalTexture?
            let lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pb,
                nil,
                .r8Unorm,
                lumaW,
                lumaH,
                0,
                &lumaCVTex
            )
            let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pb,
                nil,
                .rg8Unorm,
                chromaW,
                chromaH,
                1,
                &chromaCVTex
            )
            guard lumaStatus == kCVReturnSuccess,
                  chromaStatus == kCVReturnSuccess,
                  let lumaTex = lumaCVTex.flatMap(CVMetalTextureGetTexture),
                  let chromaTex = chromaCVTex.flatMap(CVMetalTextureGetTexture) else {
                encoder.endEncoding()
                return false
            }

            var params = NV12Params(fullRange: isNV12Full ? 1 : 0)
            encoder.setRenderPipelineState(nv12PipelineState)
            encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            encoder.setFragmentTexture(lumaTex, index: 0)
            encoder.setFragmentTexture(chromaTex, index: 1)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout<NV12Params>.size, index: 0)
        } else {
            var cvTex: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pb,
                nil,
                .bgra8Unorm,
                vw,
                vh,
                0,
                &cvTex
            )
            guard status == kCVReturnSuccess,
                  let cvTexture = cvTex,
                  let mtlTexture = CVMetalTextureGetTexture(cvTexture) else {
                encoder.endEncoding()
                return false
            }

            encoder.setRenderPipelineState(bgraPipelineState)
            encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            encoder.setFragmentTexture(mtlTexture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
        }

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        if let presentableDrawable {
            cmdBuffer.present(presentableDrawable)
        }
        cmdBuffer.commit()

        frameLock.lock()
        _renderedFrameCount &+= 1
        frameLock.unlock()

        return true
    }
}
