// CaptureService.swift
// RetroPix — Photo capture, upscale, orientation mapping, and save pipeline.
//
// Flow: MetalRenderer readback (active resolution UIImage)
//     → CoreGraphics 8× nearest-neighbor upscale with device-orientation physical rotation
//     → PHPhotoLibrary save
//     → UIImpactFeedbackGenerator(.rigid) haptic pop

import CoreGraphics
import Photos
import UIKit

enum CaptureService {

    /// Captures the current pixel texture, upscales 8× with strictly
    /// nearest-neighbor interpolation, orientates matching how user held device,
    /// saves to the Photo Library, and fires haptic.
    @MainActor
    static func capture(from renderer: MetalRenderer, orientation: DeviceOrientation = .portrait) async throws {
        // 1. Readback — runs synchronously but only briefly (GPU flush + memcpy of pixel texture)
        guard let source = renderer.capturePixelImage() else { return }
        guard let cgSource = source.cgImage else { return }

        let outW = renderer.outputWidth
        let outH = renderer.outputHeight
        guard outW > 0, outH > 0 else { return }

        // 2. Map target dimensions and rotation from physical device orientation
        let targetW: Int
        let targetH: Int
        let angle: CGFloat
        let drawW = outW * 8
        let drawH = outH * 8

        switch orientation {
        case .landscapeLeft:
            targetW = outH * 8
            targetH = outW * 8
            angle = .pi / 2.0
        case .landscapeRight:
            targetW = outH * 8
            targetH = outW * 8
            angle = -.pi / 2.0
        case .portraitUpsideDown:
            targetW = outW * 8
            targetH = outH * 8
            angle = .pi
        case .portrait:
            targetW = outW * 8
            targetH = outH * 8
            angle = 0
        }

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

        if angle != 0 {
            ctx.translateBy(x: CGFloat(targetW) / 2.0, y: CGFloat(targetH) / 2.0)
            ctx.rotate(by: angle)
            ctx.draw(cgSource, in: CGRect(x: -CGFloat(drawW) / 2.0, y: -CGFloat(drawH) / 2.0, width: CGFloat(drawW), height: CGFloat(drawH)))
        } else {
            ctx.draw(cgSource, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        }

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
