// CaptureService.swift
// RetroPix — Photo capture, upscale, and save pipeline.
//
// Flow: MetalRenderer readback (active resolution UIImage)
//     → CoreGraphics 8× nearest-neighbor upscale
//     → PHPhotoLibrary save
//     → UIImpactFeedbackGenerator(.rigid) haptic pop

import CoreGraphics
import Photos
import UIKit

enum CaptureService {

    /// Captures the current pixel texture, upscales 8× with strictly
    /// nearest-neighbor interpolation, saves to the Photo Library, and fires haptic.
    @MainActor
    static func capture(from renderer: MetalRenderer) async throws {
        // 1. Readback — runs synchronously but only briefly (GPU flush + memcpy of pixel texture)
        guard let source = renderer.capturePixelImage() else { return }
        guard let cgSource = source.cgImage else { return }

        // 2. Upscale 8×, nearest-neighbor (no blurring, pure pixel blocks)
        let outW = renderer.outputWidth
        let outH = renderer.outputHeight
        guard outW > 0, outH > 0 else { return }

        let targetW = outW * 8
        let targetH = outH * 8

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: targetW, height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return }

        ctx.interpolationQuality = .none   // CRITICAL — hard pixel edges, never blurry
        ctx.draw(cgSource, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        guard let upscaledCG = ctx.makeImage() else { return }
        let upscaled = UIImage(cgImage: upscaledCG)

        // 3. Save to Photo Library
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: upscaled)
        }

        // 4. Haptic pop
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// Requests Photo Library add permission. Call on first launch.
    @MainActor
    static func requestPhotoPermissionIfNeeded() async {
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
    }
}
