// CaptureService.swift
// RetroPix — Photo capture, upscale, orientation mapping, and save pipeline.
//
// Flow: MetalRenderer readback (active resolution UIImage)
//     → CoreGraphics 8× nearest-neighbor upscale with device-orientation physical rotation
//     → PHPhotoLibrary save
//     → UIImpactFeedbackGenerator(.rigid) haptic pop

import CoreGraphics
import CoreText
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

enum PhotoCaptureError: LocalizedError {
    case permissionDenied
    case renderFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Photo library access is not granted. Please allow access in Settings."
        case .renderFailed:
            return "Failed to render pixel art image."
        case .encodingFailed:
            return "Failed to encode sanitized image data."
        }
    }
}

enum CaptureService {

    /// Captures the current pixel texture, upscales 8× with strictly
    /// nearest-neighbor interpolation, orientates matching how user held device,
    /// applies optional frame borders and 90s date/time stamp, sanitizes metadata, and saves to the Photo Library.
    @MainActor
    static func capture(
        from renderer: MetalRenderer,
        orientation: DeviceOrientation = .portrait,
        dateStampMode: DateStampMode = .off,
        frameBorderEnabled: Bool = false,
        filmFrameStyle: FilmFrameStyle = .classicKeyline
    ) async throws {
        guard await verifyPhotoPermission() else {
            throw PhotoCaptureError.permissionDenied
        }

        // 1. Readback — runs synchronously but only briefly (GPU flush + memcpy of active texture)
        guard let activeCapture = renderer.captureActiveImage() else { throw PhotoCaptureError.renderFailed }
        let source = activeCapture.image
        let isAesthetic = activeCapture.isAesthetic
        guard let cgSource = source.cgImage else { throw PhotoCaptureError.renderFailed }

        let outW = renderer.outputWidth
        let outH = renderer.outputHeight
        guard outW > 0, outH > 0 else { throw PhotoCaptureError.renderFailed }

        // 2. Map target dimensions and rotation from physical device orientation
        let maxOutputDim = max(outW, outH)
        let targetLongEdge: CGFloat = 3840.0

        let scale: CGFloat
        if isAesthetic {
            scale = max(2.0, targetLongEdge / CGFloat(maxOutputDim))
        } else {
            scale = CGFloat(max(1, Int(round(targetLongEdge / CGFloat(maxOutputDim)))))
        }

        let drawW = Int(round(CGFloat(outW) * scale))
        let drawH = Int(round(CGFloat(outH) * scale))

        let targetW: Int
        let targetH: Int
        let angle: CGFloat

        switch orientation {
        case .landscapeLeft:
            targetW = drawH
            targetH = drawW
            angle = .pi / 2.0
        case .landscapeRight:
            targetW = drawH
            targetH = drawW
            angle = -.pi / 2.0
        case .portraitUpsideDown:
            targetW = drawW
            targetH = drawH
            angle = .pi
        case .portrait:
            targetW = drawW
            targetH = drawH
            angle = 0
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = ((targetW * 4 + 63) / 64) * 64
        guard let ctx = CGContext(
            data: nil,
            width: targetW, height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PhotoCaptureError.renderFailed }

        // Hard pixel edges for 8-bit, smooth bicubic for aesthetic analog
        ctx.interpolationQuality = isAesthetic ? .high : .none

        let activeStyle: FilmFrameStyle = frameBorderEnabled ? filmFrameStyle : .off
        let photoRect: CGRect

        switch activeStyle {
        case .off:
            photoRect = CGRect(x: 0, y: 0, width: targetW, height: targetH)

        case .classicKeyline:
            // Uniform percentage inset preserves exact capture aspect ratio without any warping
            let marginFrac: CGFloat = 0.045
            let photoW = CGFloat(targetW) * (1.0 - 2.0 * marginFrac)
            let photoH = CGFloat(targetH) * (1.0 - 2.0 * marginFrac)
            let photoX = (CGFloat(targetW) - photoW) * 0.5
            let photoY = (CGFloat(targetH) - photoH) * 0.5
            ctx.setFillColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
            photoRect = CGRect(x: photoX, y: photoY, width: photoW, height: photoH)

        case .sprocket35:
            // Top/bottom rebate with aspect-fit maintains exact capture aspect ratio
            let rebateH = max(64.0, CGFloat(targetH) * 0.082)
            let rebateW = max(28.0, CGFloat(targetW) * 0.036)
            let maxW = CGFloat(targetW) - rebateW * 2.0
            let maxH = CGFloat(targetH) - rebateH * 2.0
            let fitScale = min(maxW / CGFloat(targetW), maxH / CGFloat(targetH))
            let photoW = CGFloat(targetW) * fitScale
            let photoH = CGFloat(targetH) * fitScale
            let photoX = (CGFloat(targetW) - photoW) * 0.5
            let photoY = (CGFloat(targetH) - photoH) * 0.5
            ctx.setFillColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
            photoRect = CGRect(x: photoX, y: photoY, width: photoW, height: photoH)

        case .instantCard:
            // Instant card with iconic bottom chin — aspect-fit into upper frame with zero warping
            let sideMargin = max(36.0, CGFloat(targetW) * 0.055)
            let topMargin = sideMargin
            let bottomChin = sideMargin * 2.7
            let availW = CGFloat(targetW) - sideMargin * 2.0
            let availH = CGFloat(targetH) - topMargin - bottomChin
            let fitScale = min(availW / CGFloat(targetW), availH / CGFloat(targetH))
            let photoW = CGFloat(targetW) * fitScale
            let photoH = CGFloat(targetH) * fitScale
            let photoX = (CGFloat(targetW) - photoW) * 0.5
            let photoY = bottomChin + (availH - photoH) * 0.5
            ctx.setFillColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
            photoRect = CGRect(x: photoX, y: photoY, width: photoW, height: photoH)
        }

        ctx.saveGState()
        if angle != 0 {
            // Rotate around photoRect's center so photo stays strictly inside photoRect with zero warping
            ctx.translateBy(x: photoRect.midX, y: photoRect.midY)
            ctx.rotate(by: angle)

            let isQuarterTurn = (orientation == .landscapeLeft || orientation == .landscapeRight)
            let drawWidth  = isQuarterTurn ? photoRect.height : photoRect.width
            let drawHeight = isQuarterTurn ? photoRect.width : photoRect.height

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

        // Draw vintage film frames & sprockets
        FilmFrameRenderer.draw(
            style: activeStyle,
            targetW: targetW,
            targetH: targetH,
            photoRect: photoRect,
            in: ctx
        )

        // 3. Draw authentic 7-segment quartz LED date/time stamp
        if dateStampMode != .off {
            UIGraphicsPushContext(ctx)
            ctx.saveGState()

            // Invert coordinate space to UIKit top-left origin
            ctx.translateBy(x: 0, y: CGFloat(targetH))
            ctx.scaleBy(x: 1.0, y: -1.0)

            let formatter = DateFormatter()
            formatter.dateFormat = "''yy MM dd  HH:mm"
            let stampText = formatter.string(from: Date())

            let digitHeight = max(26.0, CGFloat(min(targetW, targetH)) * 0.038)
            let stampSize = QuartzDateStampRenderer.calculateSize(text: stampText, digitHeight: digitHeight)

            let stampColor: UIColor = (dateStampMode == .orange)
                ? UIColor(red: 1.0, green: 0.48, blue: 0.02, alpha: 0.98)
                : UIColor(red: 0.10, green: 0.98, blue: 0.38, alpha: 0.98)

            let padX: CGFloat = max(20.0, photoRect.width * 0.035)
            let padY: CGFloat = max(20.0, photoRect.height * 0.035)

            let origin = CGPoint(
                x: photoRect.maxX - stampSize.width - padX,
                y: CGFloat(targetH) - photoRect.minY - stampSize.height - padY
            )

            QuartzDateStampRenderer.draw(
                text: stampText,
                in: ctx,
                origin: origin,
                digitHeight: digitHeight,
                color: stampColor
            )

            ctx.restoreGState()
            UIGraphicsPopContext()
        }

        guard let upscaledCG = ctx.makeImage() else { throw PhotoCaptureError.renderFailed }

        // 4. Sanitize metadata (strip GPS, device model, serial numbers)
        guard let cleanData = createSanitizedImageData(from: upscaledCG) else {
            throw PhotoCaptureError.encodingFailed
        }

        // 5. Save sanitized image to Photo Library
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: cleanData, options: nil)
        }

        // 6. Haptic pop
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// Verifies or requests Photo Library add-only permission, supporting iOS 14+ Limited access.
    @MainActor
    static func verifyPhotoPermission() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return newStatus == .authorized || newStatus == .limited
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Requests Photo Library add permission if not yet determined. Call on first launch.
    @MainActor
    static func requestPhotoPermissionIfNeeded() async {
        _ = await verifyPhotoPermission()
    }

    /// Strips GPS, camera serials, and device hardware identifiers before writing to Photo Library.
    private static func createSanitizedImageData(from cgImage: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }

        // Explicitly empty dictionaries: zero GPS, zero camera serial, zero device ID
        let cleanProperties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [:] as [String: Any],
            kCGImagePropertyExifDictionary: [:] as [String: Any],
            kCGImagePropertyGPSDictionary: [:] as [String: Any]
        ]

        CGImageDestinationAddImage(destination, cgImage, cleanProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}

// MARK: — Authentic 7-Segment Quartz LED Date Stamp Renderer
// MARK: — Vintage Film Date Stamp Renderer (Apple Chancery)

enum QuartzDateStampRenderer {
    private static let registerFontOnce: Void = {
        if let url = Bundle.main.url(forResource: "Apple Chancery", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func font(size: CGFloat) -> UIFont {
        _ = registerFontOnce
        if let f = UIFont(name: "Apple-Chancery", size: size) {
            return f
        }
        if let f = UIFont(name: "Apple Chancery", size: size) {
            return f
        }
        return UIFont.italicSystemFont(ofSize: size)
    }

    static func calculateSize(text: String, digitHeight: CGFloat) -> CGSize {
        let f = font(size: digitHeight)
        let attr: [NSAttributedString.Key: Any] = [.font: f]
        let size = (text as NSString).size(withAttributes: attr)
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    static func calculateWidth(text: String, digitHeight: CGFloat) -> CGFloat {
        calculateSize(text: text, digitHeight: digitHeight).width
    }

    static func draw(
        text: String,
        in ctx: CGContext,
        origin: CGPoint,
        digitHeight: CGFloat,
        color: UIColor,
        withGhosting: Bool = false
    ) {
        let f = font(size: digitHeight)

        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.65)
        shadow.shadowBlurRadius = max(2.0, digitHeight * 0.18)
        shadow.shadowOffset = .zero

        let attributes: [NSAttributedString.Key: Any] = [
            .font: f,
            .foregroundColor: color,
            .shadow: shadow
        ]

        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

// MARK: — Vintage Film Frame & Sprocket Renderer

enum FilmFrameRenderer {
    static func draw(
        style: FilmFrameStyle,
        targetW: Int,
        targetH: Int,
        photoRect: CGRect,
        in ctx: CGContext
    ) {
        switch style {
        case .off:
            break

        case .classicKeyline:
            // Vintage photo-paper keyline & corner bracket marks
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

        case .sprocket35:
            // Authentic 35mm negative sprocket perforations + DX edge rebate
            let spkW: CGFloat = max(24.0, CGFloat(targetW) * 0.022)
            let spkH: CGFloat = max(34.0, CGFloat(targetH) * 0.038)
            let spkPitch: CGFloat = spkW * 2.1
            let spkRadius: CGFloat = 4.0
            let numSpk = Int(CGFloat(targetW) / spkPitch)

            ctx.saveGState()
            ctx.setFillColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1.0) // sprocket hole punch

            let topSpkY = photoRect.maxY + (CGFloat(targetH) - photoRect.maxY - spkH) * 0.5
            let botSpkY = (photoRect.minY - spkH) * 0.5

            for i in 0..<numSpk {
                let x = CGFloat(i) * spkPitch + (CGFloat(targetW) - CGFloat(numSpk - 1) * spkPitch - spkW) / 2.0
                let topRect = CGRect(x: x, y: max(4.0, topSpkY), width: spkW, height: spkH)
                let botRect = CGRect(x: x, y: max(4.0, botSpkY), width: spkW, height: spkH)

                let topPath = CGPath(roundedRect: topRect, cornerWidth: spkRadius, cornerHeight: spkRadius, transform: nil)
                let botPath = CGPath(roundedRect: botRect, cornerWidth: spkRadius, cornerHeight: spkRadius, transform: nil)
                ctx.addPath(topPath)
                ctx.addPath(botPath)
            }
            ctx.fillPath()

            // DX Rebate Gold Barcode Ticks & Frame Number
            ctx.setStrokeColor(red: 0.92, green: 0.62, blue: 0.12, alpha: 0.70)
            ctx.setLineWidth(1.5)

            // Barcode hash ticks along bottom rebate
            let barStartX = photoRect.minX + 20.0
            let barY = max(2.0, botSpkY - 8.0)
            for b in 0..<16 {
                let bx = barStartX + CGFloat(b) * 7.0
                let h: CGFloat = (b % 3 == 0) ? 9.0 : 5.0
                ctx.move(to: CGPoint(x: bx, y: barY))
                ctx.addLine(to: CGPoint(x: bx, y: barY + h))
            }
            ctx.strokePath()

            // Frame border inner keyline
            ctx.setStrokeColor(red: 0.22, green: 0.22, blue: 0.26, alpha: 0.7)
            ctx.setLineWidth(1.5)
            ctx.stroke(photoRect)
            ctx.restoreGState()

        case .instantCard:
            // Polaroid / Instax photo frame keyline & card drop-shadow
            ctx.saveGState()
            ctx.setStrokeColor(red: 0.86, green: 0.84, blue: 0.80, alpha: 0.95)
            ctx.setLineWidth(2.0)
            ctx.stroke(photoRect)

            // Inner dark frame line around emulsion
            ctx.setStrokeColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 0.45)
            ctx.setLineWidth(1.0)
            ctx.stroke(photoRect.insetBy(dx: 1.0, dy: 1.0))
            ctx.restoreGState()
        }
    }
}

