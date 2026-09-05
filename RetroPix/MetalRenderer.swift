// MetalRenderer.swift
// RetroPix — MTKViewDelegate driving the full render loop.
//
// Each frame:
//   1. Compute pass: camera texture → 256×128 dithered pixel texture (GPU-only)
//   2. Render pass:  256×128 pixel texture → MTKView drawable (nearest-neighbor, letterboxed)
//
// On capture: reads back the 256×128 texture from CPU-accessible memory.

import MetalKit

final class MetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {

    // MARK: — Metal objects

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private var computePipeline: MTLComputePipelineState?
    private var renderPipeline:  MTLRenderPipelineState?

    /// 256×128 dithered output — shared storage so CPU can read it for capture.
    private var pixelTexture: MTLTexture?

    // MARK: — Palette

    private var paletteBuffer: MTLBuffer?
    private var paletteCount: UInt32 = 0

    // MARK: — Viewport scale (letterbox)

    /// Applied in the vertex shader to maintain the 2:1 aspect inside the drawable.
    private var viewportScale = SIMD2<Float>(1, 1)

    // MARK: — Camera feed

    private weak var cameraManager: CameraManager?

    // MARK: — Init

    init?(device: MTLDevice, cameraManager: CameraManager) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.cameraManager = cameraManager
        super.init()
        guard buildPipelines() else { return nil }
        buildPixelTexture()
        updatePalette(Palette.all[0])
    }

    // MARK: — Pipeline setup

    private func buildPipelines() -> Bool {
        guard let library = device.makeDefaultLibrary() else { return false }

        // Compute: pixelKernel
        if let fn = library.makeFunction(name: "pixelKernel") {
            computePipeline = try? device.makeComputePipelineState(function: fn)
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

        return computePipeline != nil && renderPipeline != nil
    }

    private func buildPixelTexture() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 256, height: 128, mipmapped: false)
        desc.usage       = [.shaderWrite, .shaderRead]
        desc.storageMode = .shared   // CPU-readable for capture readback
        pixelTexture = device.makeTexture(descriptor: desc)
    }

    // MARK: — Palette hot-swap

    func updatePalette(_ palette: Palette) {
        var gpu = palette.gpuColors
        paletteCount = UInt32(palette.count)
        paletteBuffer = device.makeBuffer(
            bytes: &gpu,
            length: 8 * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared)
    }

    // MARK: — MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // Compute letterbox scale: fit 2:1 content inside the drawable.
        let screen:  Float = Float(size.width / size.height)
        let content: Float = 2.0
        if screen > content {
            viewportScale = SIMD2(content / screen, 1.0)
        } else {
            viewportScale = SIMD2(1.0, screen / content)
        }
    }

    func draw(in view: MTKView) {
        guard
            let commandBuffer  = commandQueue.makeCommandBuffer(),
            let drawable       = view.currentDrawable,
            let rpd            = view.currentRenderPassDescriptor,
            let cameraTexture  = cameraManager?.cameraTexture,
            let pixelTexture,
            let computePipeline,
            let renderPipeline,
            let paletteBuffer
        else { return }

        // ── 1. Compute pass ──────────────────────────────────────────────────
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(computePipeline)
            enc.setTexture(cameraTexture, index: 0)
            enc.setTexture(pixelTexture,  index: 1)
            enc.setBuffer(paletteBuffer, offset: 0, index: 0)
            enc.setBytes(&paletteCount, length: MemoryLayout<UInt32>.size, index: 1)

            // 8×8 threadgroup, ceil-divide 256×128
            let tg    = MTLSize(width: 8, height: 8, depth: 1)
            let tgrid = MTLSize(width: (256 + 7) / 8, height: (128 + 7) / 8, depth: 1)
            enc.dispatchThreadgroups(tgrid, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        // ── 2. Render pass (blit to screen) ──────────────────────────────────
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
    }

    // MARK: — Capture readback

    /// Reads the current 256×128 pixel texture into a UIImage synchronously.
    /// Blocks briefly while the GPU finishes the in-flight frame — only call on capture.
    func capturePixelImage() -> UIImage? {
        // Flush any in-flight work so the pixel texture is stable.
        let sem = DispatchSemaphore(value: 0)
        guard let flush = commandQueue.makeCommandBuffer() else { return nil }
        flush.addCompletedHandler { _ in sem.signal() }
        flush.commit()
        sem.wait()

        guard let texture = pixelTexture else { return nil }
        let w = 256, h = 128
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        texture.getBytes(
            &pixels,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                            size:   .init(width: w, height: h, depth: 1)),
            mipmapLevel: 0)

        // Build a UIImage from the raw RGBA bytes.
        guard
            let ctx = CGContext(
                data: &pixels,
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let cgImage = ctx.makeImage()
        else { return nil }

        return UIImage(cgImage: cgImage)
    }
}
