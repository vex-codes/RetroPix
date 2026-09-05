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
    /// applies optional frame borders and 90s date/time stamp, saves to the Photo Library.
    @MainActor
    static func capture(
        from renderer: MetalRenderer,
        orientation: DeviceOrientation = .portrait,
        dateStampMode: DateStampMode = .off,
        frameBorderEnabled: Bool = false
    ) async throws {
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
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        ctx.interpolationQuality = .none   // CRITICAL — hard pixel edges, never blurry

        let borderInset: CGFloat = frameBorderEnabled ? max(24.0, CGFloat(min(targetW, targetH)) * 0.045) : 0.0

        // Fill background with warm vintage photo-paper if border enabled
        if frameBorderEnabled {
            ctx.setFillColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
        }

        // Draw pixel art photo
        let photoRect = CGRect(
            x: borderInset,
            y: borderInset,
            width: CGFloat(targetW) - borderInset * 2.0,
            height: CGFloat(targetH) - borderInset * 2.0
        )

        ctx.saveGState()
        if angle != 0 {
            ctx.translateBy(x: CGFloat(targetW) / 2.0, y: CGFloat(targetH) / 2.0)
            ctx.rotate(by: angle)

            let isQuarterTurn = (orientation == .landscapeLeft || orientation == .landscapeRight)
            let drawWidth: CGFloat
            let drawHeight: CGFloat

            if frameBorderEnabled {
                drawWidth  = isQuarterTurn ? photoRect.height : photoRect.width
                drawHeight = isQuarterTurn ? photoRect.width : photoRect.height
            } else {
                drawWidth  = CGFloat(drawW)
                drawHeight = CGFloat(drawH)
            }

            ctx.draw(cgSource, in: CGRect(
                x: -drawWidth / 2.0,
                y: -drawHeight / 2.0,
                width: drawWidth,
                height: drawHeight
            ))
        } else {
            ctx.draw(cgSource, in: photoRect)
        }
        ctx.restoreGState()

        // Draw vintage border keyline & corner brackets
        if frameBorderEnabled {
            ctx.setStrokeColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 0.8)
            ctx.setLineWidth(2.0)
            ctx.stroke(photoRect)

            let tickLen: CGFloat = 10.0
            let corners = [
                (photoRect.minX, photoRect.minY, 1.0, 1.0),
                (photoRect.maxX, photoRect.minY, -1.0, 1.0),
                (photoRect.minX, photoRect.maxY, 1.0, -1.0),
                (photoRect.maxX, photoRect.maxY, -1.0, -1.0)
            ]
            for (cx, cy, dx, dy) in corners {
                ctx.move(to: CGPoint(x: cx, y: cy + tickLen * dy))
                ctx.addLine(to: CGPoint(x: cx, y: cy))
                ctx.addLine(to: CGPoint(x: cx + tickLen * dx, y: cy))
            }
            ctx.strokePath()
        }

        // 3. Draw 90s Orange or Green date/time stamp
        if dateStampMode != .off {
            UIGraphicsPushContext(ctx)
            ctx.saveGState()

            // Invert coordinate space to UIKit top-left origin
            ctx.translateBy(x: 0, y: CGFloat(targetH))
            ctx.scaleBy(x: 1.0, y: -1.0)

            let formatter = DateFormatter()
            formatter.dateFormat = "''yy MM dd  HH:mm"
            let stampText = formatter.string(from: Date())

            let fontSize = max(24.0, CGFloat(targetW) * 0.026)
            let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .heavy)

            let stampColor: UIColor = (dateStampMode == .orange)
                ? UIColor(red: 1.0, green: 0.58, blue: 0.05, alpha: 0.95)
                : UIColor(red: 0.0, green: 1.0, blue: 0.35, alpha: 0.95)

            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.85)
            shadow.shadowOffset = CGSize(width: 1.5, height: 1.5)
            shadow.shadowBlurRadius = 3.0

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: stampColor,
                .shadow: shadow
            ]

            let textSize = (stampText as NSString).size(withAttributes: attrs)
            let padX: CGFloat = frameBorderEnabled ? borderInset + 16.0 : 36.0
            let padY: CGFloat = frameBorderEnabled ? borderInset + 16.0 : 36.0

            let textOrigin = CGPoint(
                x: CGFloat(targetW) - textSize.width - padX,
                y: CGFloat(targetH) - textSize.height - padY
            )

            (stampText as NSString).draw(at: textOrigin, withAttributes: attrs)

            ctx.restoreGState()
            UIGraphicsPopContext()
        }

        guard let upscaledCG = ctx.makeImage() else { return }
        let upscaled = UIImage(cgImage: upscaledCG)

        // 4. Save to Photo Library
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: upscaled)
        }

        // 5. Haptic pop
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
