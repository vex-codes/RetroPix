// MetalRenderer.swift
// RetroPix — MTKViewDelegate driving the dynamic render loop.
//
// Each frame:
//   1. Compute pass: camera texture → dithered pixel texture (GPU-only)
//      Supports Bayer 8x8, Blue Noise 16x16, Atkinson (Mac '84), and Floyd-Steinberg.
//   2. Render pass:  pixel texture → MTKView drawable (nearest-neighbor, letterboxed)
//
// On capture: reads back the active resolution texture with 64-byte row alignment and immutable CFData.

import MetalKit
import UIKit

private struct ShaderUniforms {
    var cropUV: SIMD4<Float>
    var outputSize: SIMD2<UInt32>
    var ditherSpread: Float
    var paletteCount: UInt32
    var ditherAlgorithm: UInt32
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
    var _pad2: UInt32 = 0
}

final class MetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {

    // MARK: — Metal objects

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private var computePipeline:        MTLComputePipelineState?
    private var errorDiffusionPipeline: MTLComputePipelineState?
    private var renderPipeline:         MTLRenderPipelineState?

    // MARK: — Aesthetic Pipeline
    var engineMode: CameraEngineMode = .pixel8Bit
    var activeAestheticProfile: AestheticProfile = .canonG7X

    private var aestheticComputePipeline: MTLComputePipelineState?
    private var brightPipeline:           MTLComputePipelineState?
    private var blurPipeline:             MTLComputePipelineState?
    private var aestheticRenderPipeline:  MTLRenderPipelineState?

    /// Active resolution dithered output — shared storage so CPU can read it for capture.
    private var pixelTexture: MTLTexture?

    /// High-resolution graded output and halation intermediate textures
    private var aestheticTexture: MTLTexture?
    private var brightTexture:    MTLTexture?
    private var blurPingTexture:  MTLTexture?
    private var blurPongTexture:  MTLTexture?
    private var aestheticUniformBuffer: MTLBuffer?
    private var frameSeed: Float = 0.0

    // MARK: — Active dimensions and configuration

    private(set) var outputWidth: Int = 256
    private(set) var outputHeight: Int = 128
    private var cropUV: SIMD4<Float> = SIMD4<Float>(0.0, 40.0 / 720.0, 1.0, 680.0 / 720.0)
    private var orientation: UInt32 = 0

    // MARK: — Lifecycle & Suspension

    var isSuspended: Bool = false

    // MARK: — Palette

    private var paletteBuffer: MTLBuffer?
    private var paletteCount: UInt32 = 0

    // MARK: — Dither engine settings

    var ditherSpread: Float = 0.50
    var ditherAlgorithm: UInt32 = 0

    // MARK: — Viewport scale (letterbox)

    private var viewportScale = SIMD2<Float>(1, 1)
    private var lastDrawableSize: CGSize = .zero

    // MARK: — Camera feed

    private weak var cameraManager: CameraManager?

    // MARK: — Init & Deinit

    init?(device: MTLDevice, cameraManager: CameraManager) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.cameraManager = cameraManager
        super.init()
        guard buildPipelines() else { return nil }
        paletteBuffer = device.makeBuffer(
            length: 8 * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared
        )
        aestheticUniformBuffer = device.makeBuffer(
            length: MemoryLayout<AestheticUniforms>.stride,
            options: .storageModeShared
        )
        buildTextures(width: outputWidth, height: outputHeight)
        updatePalette(Palette.midnight)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleBackground() {
        isSuspended = true
    }

    @objc private func handleForeground() {
        isSuspended = false
    }

    // MARK: — Configuration update

    func updateConfig(width: Int, height: Int, cropUV: SIMD4<Float>, orientation: UInt32) {
        if outputWidth != width || outputHeight != height {
            outputWidth = width
            outputHeight = height
            buildTextures(width: width, height: height)
            updateViewportScale(lastDrawableSize)
        }
        self.cropUV = cropUV
        self.orientation = orientation
    }

    // MARK: — Pipeline setup

    private func buildPipelines() -> Bool {
        guard let library = device.makeDefaultLibrary() else { return false }

        // Compute: parallel spatial kernel (Bayer & Blue Noise)
        if let fn = library.makeFunction(name: "pixelKernel") {
            computePipeline = try? device.makeComputePipelineState(function: fn)
        }

        // Compute: scanline error diffusion kernel (Atkinson & Floyd-Steinberg)
        if let fnErr = library.makeFunction(name: "errorDiffusionKernel") {
            errorDiffusionPipeline = try? device.makeComputePipelineState(function: fnErr)
        }

        // Render: blitVertex + blitFragment
        if let vert = library.makeFunction(name: "blitVertex"),
           let frag = library.makeFunction(name: "blitFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction   = vert
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            renderPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        // Aesthetic Compute: bright highlight extraction, Gaussian blur passes, and full grade
        if let fnBright = library.makeFunction(name: "aestheticBrightKernel") {
            brightPipeline = try? device.makeComputePipelineState(function: fnBright)
        }
        if let fnBlur = library.makeFunction(name: "aestheticBlurKernel") {
            blurPipeline = try? device.makeComputePipelineState(function: fnBlur)
        }
        if let fnAesthetic = library.makeFunction(name: "aestheticKernel") {
            aestheticComputePipeline = try? device.makeComputePipelineState(function: fnAesthetic)
        }
        if let vert = library.makeFunction(name: "blitVertex"),
           let frag = library.makeFunction(name: "aestheticBlitFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction   = vert
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            aestheticRenderPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        return computePipeline != nil && renderPipeline != nil
    }

    private func buildTextures(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }

        // 1. 8-Bit Pixel Texture (Shared for CPU capture readback)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage       = [.shaderWrite, .shaderRead]
        desc.storageMode = .shared
        pixelTexture = device.makeTexture(descriptor: desc)

        // 2. High-Res Graded Aesthetic Texture (Shared for CPU capture readback)
        aestheticTexture = device.makeTexture(descriptor: desc)

        // 3. Quarter-Res intermediate textures for halation extraction and separable blur
        let qw = max(16, width / 4)
        let qh = max(16, height / 4)
        let qDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: qw, height: qh, mipmapped: false)
        qDesc.usage       = [.shaderWrite, .shaderRead]
        qDesc.storageMode = .private
        brightTexture   = device.makeTexture(descriptor: qDesc)
        blurPingTexture = device.makeTexture(descriptor: qDesc)
        blurPongTexture = device.makeTexture(descriptor: qDesc)
    }

    // MARK: — Palette hot-swap

    func updatePalette(_ palette: Palette) {
        let gpu = palette.gpuColors
        paletteCount = UInt32(palette.count)
        if paletteBuffer == nil {
            paletteBuffer = device.makeBuffer(
                length: 8 * MemoryLayout<SIMD4<Float>>.stride,
                options: .storageModeShared
            )
        }
        guard let paletteBuffer else { return }
        gpu.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                paletteBuffer.contents().copyMemory(from: base, byteCount: min(raw.count, 8 * MemoryLayout<SIMD4<Float>>.stride))
            }
        }
    }

    // MARK: — MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lastDrawableSize = size
        updateViewportScale(size)
    }

    private func updateViewportScale(_ size: CGSize) {
        guard size.width > 0, size.height > 0, outputWidth > 0, outputHeight > 0 else { return }
        let screen = Float(size.width / size.height)
        let content = Float(outputWidth) / Float(outputHeight)
        if screen > content {
            viewportScale = SIMD2(content / screen, 1.0)
        } else {
            viewportScale = SIMD2(1.0, screen / content)
        }
    }

    func draw(in view: MTKView) {
        guard
            !isSuspended,
            let commandBuffer  = commandQueue.makeCommandBuffer(),
            let drawable       = view.currentDrawable,
            let rpd            = view.currentRenderPassDescriptor
        else { return }

        switch engineMode {
        case .pixel8Bit:
            guard
                let cameraTexture = cameraManager?.cameraTexture,
                let pixelTexture,
                let computePipeline,
                let renderPipeline,
                let paletteBuffer
            else { return }

            // ── 1. Compute pass (8-Bit Dither & Quantize) ────────────────────────
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                let useErrorDiffusion = (ditherAlgorithm >= 2 && errorDiffusionPipeline != nil)
                let pipeline = useErrorDiffusion ? errorDiffusionPipeline! : computePipeline
                enc.setComputePipelineState(pipeline)
                enc.setTexture(cameraTexture, index: 0)
                enc.setTexture(pixelTexture,  index: 1)
                enc.setBuffer(paletteBuffer, offset: 0, index: 0)
                var uniforms = ShaderUniforms(
                    cropUV: cropUV,
                    outputSize: SIMD2<UInt32>(UInt32(outputWidth), UInt32(outputHeight)),
                    ditherSpread: ditherSpread,
                    paletteCount: paletteCount,
                    ditherAlgorithm: ditherAlgorithm
                )
                enc.setBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 1)

                if useErrorDiffusion {
                    let tg = MTLSize(width: 1, height: 1, depth: 1)
                    enc.dispatchThreadgroups(tg, threadsPerThreadgroup: tg)
                } else {
                    let tg    = MTLSize(width: 8, height: 8, depth: 1)
                    let tgrid = MTLSize(width: (outputWidth + 7) / 8, height: (outputHeight + 7) / 8, depth: 1)
                    enc.dispatchThreadgroups(tgrid, threadsPerThreadgroup: tg)
                }
                enc.endEncoding()
            }

            // ── 2. Render pass (nearest-neighbor blit to screen) ─────────────────
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                enc.setRenderPipelineState(renderPipeline)
                enc.setFragmentTexture(pixelTexture, index: 0)
                var scale = viewportScale
                enc.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                enc.endEncoding()
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()

        case .aesthetic:
            guard
                let cameraTexture = cameraManager?.cameraTexture,
                let aestheticTexture,
                let brightTexture,
                let blurPingTexture,
                let blurPongTexture,
                let brightPipeline,
                let blurPipeline,
                let aestheticComputePipeline,
                let aestheticRenderPipeline,
                let aestheticUniformBuffer
            else { return }

            frameSeed = Float((Int(frameSeed) + 1) % 65536)
            var uniforms = activeAestheticProfile.makeUniforms(
                cropUV: cropUV,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                seed: frameSeed
            )
            aestheticUniformBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<AestheticUniforms>.stride)

            // Pass 1: Highlight extraction (¼ res)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.setComputePipelineState(brightPipeline)
                enc.setTexture(cameraTexture, index: 0)
                enc.setTexture(brightTexture, index: 1)
                enc.setBuffer(aestheticUniformBuffer, offset: 0, index: 0)
                let qw = brightTexture.width
                let qh = brightTexture.height
                let tg = MTLSize(width: 8, height: 8, depth: 1)
                let tgrid = MTLSize(width: (qw + 7) / 8, height: (qh + 7) / 8, depth: 1)
                enc.dispatchThreadgroups(tgrid, threadsPerThreadgroup: tg)
                enc.endEncoding()
            }

            // Pass 2: Horizontal blur (R > G > B channel dispersion)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.setComputePipelineState(blurPipeline)
                enc.setTexture(brightTexture, index: 0)
                enc.setTexture(blurPingTexture, index: 1)
                var pH = SIMD4<Float>(16.0, 6.0, 2.0, 1.0)
                enc.setBytes(&pH, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                let qw = brightTexture.width
                let qh = brightTexture.height
                let tg = MTLSize(width: 8, height: 8, depth: 1)
                let tgrid = MTLSize(width: (qw + 7) / 8, height: (qh + 7) / 8, depth: 1)
                enc.dispatchThreadgroups(tgrid, threadsPerThreadgroup: tg)
                enc.endEncoding()
            }

            // Pass 3: Vertical blur
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.setComputePipelineState(blurPipeline)
                enc.setTexture(blurPingTexture, index: 0)
                enc.setTexture(blurPongTexture, index: 1)
                var pV = SIMD4<Float>(16.0, 6.0, 2.0, 0.0)
                enc.setBytes(&pV, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                let qw = brightTexture.width
                let qh = brightTexture.height
                let tg = MTLSize(width: 8, height: 8, depth: 1)
                let tgrid = MTLSize(width: (qw + 7) / 8, height: (qh + 7) / 8, depth: 1)
                enc.dispatchThreadgroups(tgrid, threadsPerThreadgroup: tg)
                enc.endEncoding()
            }

            // Pass 4: Full-resolution grade & film grain synthesis
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.setComputePipelineState(aestheticComputePipeline)
                enc.setTexture(cameraTexture, index: 0)
                enc.setTexture(blurPongTexture, index: 1)
                enc.setTexture(aestheticTexture, index: 2)
                enc.setBuffer(aestheticUniformBuffer, offset: 0, index: 0)
                let tg = MTLSize(width: 8, height: 8, depth: 1)
                let tgrid = MTLSize(width: (outputWidth + 7) / 8, height: (outputHeight + 7) / 8, depth: 1)
                enc.dispatchThreadgroups(tgrid, threadsPerThreadgroup: tg)
                enc.endEncoding()
            }

            // Pass 5: Render pass (smooth bilinear blit to screen)
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                enc.setRenderPipelineState(aestheticRenderPipeline)
                enc.setFragmentTexture(aestheticTexture, index: 0)
                var scale = viewportScale
                enc.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                enc.endEncoding()
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    // MARK: — Capture readback

    /// Reads the current 8-bit pixel texture into a UIImage synchronously.
    func capturePixelImage() -> UIImage? {
        let sem = DispatchSemaphore(value: 0)
        guard let flush = commandQueue.makeCommandBuffer() else { return nil }
        flush.addCompletedHandler { _ in sem.signal() }
        flush.commit()
        sem.wait()

        guard let texture = pixelTexture else { return nil }
        let w = outputWidth, h = outputHeight
        guard w > 0, h > 0 else { return nil }

        let bytesPerRow = ((w * 4 + 63) / 64) * 64
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)

        pixels.withUnsafeMutableBytes { rawPtr in
            guard let baseAddress = rawPtr.baseAddress else { return }
            texture.getBytes(
                baseAddress,
                bytesPerRow: bytesPerRow,
                from: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                                size:   .init(width: w, height: h, depth: 1)),
                mipmapLevel: 0)
        }

        guard
            let data = CFDataCreate(kCFAllocatorDefault, pixels, pixels.count),
            let provider = CGDataProvider(data: data),
            let cgImage = CGImage(
                width: w,
                height: h,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else { return nil }

        return UIImage(cgImage: cgImage)
    }

    /// Reads the current high-res graded aesthetic texture into a UIImage synchronously.
    func captureAestheticImage() -> UIImage? {
        let sem = DispatchSemaphore(value: 0)
        guard let flush = commandQueue.makeCommandBuffer() else { return nil }
        flush.addCompletedHandler { _ in sem.signal() }
        flush.commit()
        sem.wait()

        guard let texture = aestheticTexture else { return nil }
        let w = outputWidth, h = outputHeight
        guard w > 0, h > 0 else { return nil }

        let bytesPerRow = ((w * 4 + 63) / 64) * 64
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)

        pixels.withUnsafeMutableBytes { rawPtr in
            guard let baseAddress = rawPtr.baseAddress else { return }
            texture.getBytes(
                baseAddress,
                bytesPerRow: bytesPerRow,
                from: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                                size:   .init(width: w, height: h, depth: 1)),
                mipmapLevel: 0)
        }

        guard
            let data = CFDataCreate(kCFAllocatorDefault, pixels, pixels.count),
            let provider = CGDataProvider(data: data),
            let cgImage = CGImage(
                width: w,
                height: h,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else { return nil }

        return UIImage(cgImage: cgImage)
    }

    /// Unified capture call returning the active image and whether it was an aesthetic capture.
    func captureActiveImage() -> (image: UIImage, isAesthetic: Bool)? {
        switch engineMode {
        case .pixel8Bit:
            guard let img = capturePixelImage() else { return nil }
            return (img, false)
        case .aesthetic:
            guard let img = captureAestheticImage() else { return nil }
            return (img, true)
        }
    }
}
