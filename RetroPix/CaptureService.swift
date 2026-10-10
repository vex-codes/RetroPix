// CaptureService.swift
// RetroPix — Photo capture, upscale, orientation mapping, and save pipeline.
//
// Flow: MetalRenderer readback (active resolution UIImage)
//     → CoreGraphics 8× nearest-neighbor upscale with device-orientation physical rotation
//     → PHPhotoLibrary save
//     → UIImpactFeedbackGenerator(.rigid) haptic pop

import CoreGraphics
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
        filmFrameStyle: FilmFrameStyle = .classicKeyline,
        exposureCount: Int = 1
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
            let inset = max(24.0, CGFloat(min(targetW, targetH)) * 0.045)
            ctx.setFillColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
            photoRect = CGRect(x: inset, y: inset, width: CGFloat(targetW) - inset * 2.0, height: CGFloat(targetH) - inset * 2.0)

        case .sprocket35:
            let rebateH = max(72.0, CGFloat(min(targetW, targetH)) * 0.088)
            let rebateW = max(24.0, CGFloat(min(targetW, targetH)) * 0.032)
            ctx.setFillColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
            photoRect = CGRect(x: rebateW, y: rebateH, width: CGFloat(targetW) - rebateW * 2.0, height: CGFloat(targetH) - rebateH * 2.0)

        case .instantCard:
            let margin = max(36.0, CGFloat(min(targetW, targetH)) * 0.052)
            let bottomChin = margin * 2.6
            ctx.setFillColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
            photoRect = CGRect(x: margin, y: bottomChin, width: CGFloat(targetW) - margin * 2.0, height: CGFloat(targetH) - margin - bottomChin)
        }

        ctx.saveGState()
        if angle != 0 {
            ctx.translateBy(x: CGFloat(targetW) / 2.0, y: CGFloat(targetH) / 2.0)
            ctx.rotate(by: angle)

            let isQuarterTurn = (orientation == .landscapeLeft || orientation == .landscapeRight)
            let drawWidth: CGFloat
            let drawHeight: CGFloat

            if activeStyle != .off {
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

        // Draw vintage film frames & sprockets
        FilmFrameRenderer.draw(
            style: activeStyle,
            targetW: targetW,
            targetH: targetH,
            photoRect: photoRect,
            exposureCount: exposureCount,
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
            let totalWidth = QuartzDateStampRenderer.calculateWidth(text: stampText, digitHeight: digitHeight)

            let stampColor: UIColor = (dateStampMode == .orange)
                ? UIColor(red: 1.0, green: 0.48, blue: 0.02, alpha: 0.98)
                : UIColor(red: 0.10, green: 0.98, blue: 0.38, alpha: 0.98)

            let padX: CGFloat = max(20.0, photoRect.width * 0.035)
            let padY: CGFloat = max(20.0, photoRect.height * 0.035)

            let origin = CGPoint(
                x: photoRect.maxX - totalWidth - padX,
                y: CGFloat(targetH) - photoRect.minY - digitHeight - padY
            )

            QuartzDateStampRenderer.draw(
                text: stampText,
                in: ctx,
                origin: origin,
                digitHeight: digitHeight,
                color: stampColor,
                withGhosting: true
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
// Models vintage 1980s-90s Japanese point-and-shoot camera quartz date backs
// (Olympus Mju-II, Contax T2, Canon Sure Shot, Minolta Riva Zoom)

enum QuartzDateStampRenderer {
    // 7-segment bitmask:
    //      aaa
    //    f     b
    //    f     b
    //      ggg
    //    e     c
    //    e     c
    //      ddd
    //
    // bit 0: a (top)
    // bit 1: b (top-right)
    // bit 2: c (bottom-right)
    // bit 3: d (bottom)
    // bit 4: e (bottom-left)
    // bit 5: f (top-left)
    // bit 6: g (center)

    private static let digitMasks: [Character: UInt8] = [
        "0": 0b0011_1111,
        "1": 0b0000_0110,
        "2": 0b0101_1011,
        "3": 0b0100_1111,
        "4": 0b0110_0110,
        "5": 0b0110_1101,
        "6": 0b0111_1101,
        "7": 0b0000_0111,
        "8": 0b0111_1111,
        "9": 0b0110_1111,
        "-": 0b0100_0000
    ]

    static func calculateWidth(text: String, digitHeight: CGFloat) -> CGFloat {
        let digitW = digitHeight * 0.54
        let spacing = digitHeight * 0.16
        let spaceW = digitHeight * 0.38
        let colonW = digitHeight * 0.24
        let tickW = digitHeight * 0.22
        let dotW = digitHeight * 0.18
        let shear = tan(7.0 * .pi / 180.0)

        var total: CGFloat = 0
        for ch in text {
            switch ch {
            case " ":
                total += spaceW
            case ":":
                total += colonW + spacing
            case "'", "’", "`":
                total += tickW + spacing
            case ".", ",":
                total += dotW + spacing
            case "/":
                total += digitW * 0.7 + spacing
            default:
                total += digitW + spacing
            }
        }
        let base = total > spacing ? total - spacing : total
        return base + shear * digitHeight
    }

    static func draw(
        text: String,
        in ctx: CGContext,
        origin: CGPoint,
        digitHeight: CGFloat,
        color: UIColor,
        withGhosting: Bool = true
    ) {
        let digitW = digitHeight * 0.54
        let spacing = digitHeight * 0.16
        let spaceW = digitHeight * 0.38
        let colonW = digitHeight * 0.24
        let tickW = digitHeight * 0.22
        let dotW = digitHeight * 0.18
        let thickness = max(2.0, digitHeight * 0.115)
        let gap = thickness * 0.18

        let slantAngle: CGFloat = 7.0 * .pi / 180.0
        let shear = tan(slantAngle)

        var currentX = origin.x
        let y = origin.y

        for ch in text {
            if ch == " " {
                currentX += spaceW
                continue
            }

            ctx.saveGState()

            // Apply 7-degree forward italic slant with bottom-anchored baseline
            ctx.translateBy(x: currentX, y: y)
            let shearTransform = CGAffineTransform(a: 1.0, b: 0.0, c: -shear, d: 1.0, tx: shear * digitHeight, ty: 0.0)
            ctx.concatenate(shearTransform)

            if let mask = digitMasks[ch] {
                // 1. Ghosting pass: unlit segments at 4.5% opacity (vintage LED/LCD substrate)
                if withGhosting {
                    let ghostColor = color.withAlphaComponent(0.045).cgColor
                    ctx.setFillColor(ghostColor)
                    let unlit = (~mask) & 0b0111_1111
                    drawSegments(mask: unlit, in: ctx, width: digitW, height: digitHeight, thickness: thickness, gap: gap)
                }

                // 2. Phosphor bloom pass (warm luminous halation)
                ctx.saveGState()
                ctx.setShadow(
                    offset: .zero,
                    blur: digitHeight * 0.26,
                    color: color.withAlphaComponent(0.60).cgColor
                )
                ctx.setFillColor(color.withAlphaComponent(0.92).cgColor)
                drawSegments(mask: mask, in: ctx, width: digitW, height: digitHeight, thickness: thickness, gap: gap)
                ctx.restoreGState()

                // 3. Crisp core emission pass
                ctx.setFillColor(color.withAlphaComponent(0.98).cgColor)
                drawSegments(mask: mask, in: ctx, width: digitW, height: digitHeight, thickness: thickness, gap: gap)

                currentX += digitW + spacing

            } else if ch == ":" {
                // Colon: two glowing square/diamond dots
                drawColon(in: ctx, height: digitHeight, thickness: thickness, color: color)
                currentX += colonW + spacing

            } else if ch == "'" || ch == "’" || ch == "`" {
                // Apostrophe for era year ('98)
                drawApostrophe(in: ctx, height: digitHeight, thickness: thickness, color: color)
                currentX += tickW + spacing

            } else if ch == "." || ch == "," {
                // Decimal dot
                drawDot(in: ctx, height: digitHeight, thickness: thickness, color: color)
                currentX += dotW + spacing

            } else if ch == "/" {
                // Date separator slash
                drawSlash(in: ctx, width: digitW * 0.7, height: digitHeight, thickness: thickness, color: color)
                currentX += digitW * 0.7 + spacing

            } else {
                currentX += digitW + spacing
            }

            ctx.restoreGState()
        }
    }

    private static func drawSegments(
        mask: UInt8,
        in ctx: CGContext,
        width W: CGFloat,
        height H: CGFloat,
        thickness T: CGFloat,
        gap G: CGFloat
    ) {
        let H2 = H / 2.0
        let T2 = T / 2.0

        // Segment a (top horizontal)
        if (mask & (1 << 0)) != 0 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: T + G, y: T2))
            path.addLine(to: CGPoint(x: T + G + T2, y: 0))
            path.addLine(to: CGPoint(x: W - T - G - T2, y: 0))
            path.addLine(to: CGPoint(x: W - T - G, y: T2))
            path.addLine(to: CGPoint(x: W - T - G - T2, y: T))
            path.addLine(to: CGPoint(x: T + G + T2, y: T))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }

        // Segment b (upper right vertical)
        if (mask & (1 << 1)) != 0 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: W - T2, y: T + G))
            path.addLine(to: CGPoint(x: W, y: T + G + T2))
            path.addLine(to: CGPoint(x: W, y: H2 - G - T2))
            path.addLine(to: CGPoint(x: W - T2, y: H2 - G))
            path.addLine(to: CGPoint(x: W - T, y: H2 - G - T2))
            path.addLine(to: CGPoint(x: W - T, y: T + G + T2))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }

        // Segment c (lower right vertical)
        if (mask & (1 << 2)) != 0 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: W - T2, y: H2 + G))
            path.addLine(to: CGPoint(x: W, y: H2 + G + T2))
            path.addLine(to: CGPoint(x: W, y: H - T - G - T2))
            path.addLine(to: CGPoint(x: W - T2, y: H - T - G))
            path.addLine(to: CGPoint(x: W - T, y: H - T - G - T2))
            path.addLine(to: CGPoint(x: W - T, y: H2 + G + T2))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }

        // Segment d (bottom horizontal)
        if (mask & (1 << 3)) != 0 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: T + G, y: H - T2))
            path.addLine(to: CGPoint(x: T + G + T2, y: H - T))
            path.addLine(to: CGPoint(x: W - T - G - T2, y: H - T))
            path.addLine(to: CGPoint(x: W - T - G, y: H - T2))
            path.addLine(to: CGPoint(x: W - T - G - T2, y: H))
            path.addLine(to: CGPoint(x: T + G + T2, y: H))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }

        // Segment e (lower left vertical)
        if (mask & (1 << 4)) != 0 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: T2, y: H2 + G))
            path.addLine(to: CGPoint(x: T, y: H2 + G + T2))
            path.addLine(to: CGPoint(x: T, y: H - T - G - T2))
            path.addLine(to: CGPoint(x: T2, y: H - T - G))
            path.addLine(to: CGPoint(x: 0, y: H - T - G - T2))
            path.addLine(to: CGPoint(x: 0, y: H2 + G + T2))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }

        // Segment f (upper left vertical)
        if (mask & (1 << 5)) != 0 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: T2, y: T + G))
            path.addLine(to: CGPoint(x: T, y: T + G + T2))
            path.addLine(to: CGPoint(x: T, y: H2 - G - T2))
            path.addLine(to: CGPoint(x: T2, y: H2 - G))
            path.addLine(to: CGPoint(x: 0, y: H2 - G - T2))
            path.addLine(to: CGPoint(x: 0, y: T + G + T2))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }

        // Segment g (center horizontal)
        if (mask & (1 << 6)) != 0 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: T + G, y: H2))
            path.addLine(to: CGPoint(x: T + G + T2, y: H2 - T2))
            path.addLine(to: CGPoint(x: W - T - G - T2, y: H2 - T2))
            path.addLine(to: CGPoint(x: W - T - G, y: H2))
            path.addLine(to: CGPoint(x: W - T - G - T2, y: H2 + T2))
            path.addLine(to: CGPoint(x: T + G + T2, y: H2 + T2))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    private static func drawColon(
        in ctx: CGContext,
        height H: CGFloat,
        thickness T: CGFloat,
        color: UIColor
    ) {
        let dotSize = T * 0.95
        let x: CGFloat = 1.0
        let y1 = H * 0.32 - dotSize / 2.0
        let y2 = H * 0.68 - dotSize / 2.0

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: H * 0.22, color: color.withAlphaComponent(0.60).cgColor)
        ctx.setFillColor(color.withAlphaComponent(0.95).cgColor)
        ctx.fill(CGRect(x: x, y: y1, width: dotSize, height: dotSize))
        ctx.fill(CGRect(x: x, y: y2, width: dotSize, height: dotSize))
        ctx.restoreGState()
    }

    private static func drawApostrophe(
        in ctx: CGContext,
        height H: CGFloat,
        thickness T: CGFloat,
        color: UIColor
    ) {
        let path = CGMutablePath()
        let topY: CGFloat = 1.0
        let tickH = H * 0.28
        path.move(to: CGPoint(x: 2.0, y: topY))
        path.addLine(to: CGPoint(x: 2.0 + T * 0.9, y: topY))
        path.addLine(to: CGPoint(x: 1.0 + T * 0.5, y: topY + tickH))
        path.addLine(to: CGPoint(x: 0.5, y: topY + tickH))
        path.closeSubpath()

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: H * 0.22, color: color.withAlphaComponent(0.60).cgColor)
        ctx.setFillColor(color.withAlphaComponent(0.95).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawDot(
        in ctx: CGContext,
        height H: CGFloat,
        thickness T: CGFloat,
        color: UIColor
    ) {
        let dotSize = T * 0.95
        let rect = CGRect(x: 1.0, y: H - dotSize - 1.0, width: dotSize, height: dotSize)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: H * 0.22, color: color.withAlphaComponent(0.60).cgColor)
        ctx.setFillColor(color.withAlphaComponent(0.95).cgColor)
        ctx.fill(rect)
        ctx.restoreGState()
    }

    private static func drawSlash(
        in ctx: CGContext,
        width W: CGFloat,
        height H: CGFloat,
        thickness T: CGFloat,
        color: UIColor
    ) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: W - T, y: 0))
        path.addLine(to: CGPoint(x: W, y: 0))
        path.addLine(to: CGPoint(x: T, y: H))
        path.addLine(to: CGPoint(x: 0, y: H))
        path.closeSubpath()

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: H * 0.22, color: color.withAlphaComponent(0.60).cgColor)
        ctx.setFillColor(color.withAlphaComponent(0.95).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

// MARK: — Vintage Film Frame & Sprocket Renderer

enum FilmFrameRenderer {
    static func draw(
        style: FilmFrameStyle,
        targetW: Int,
        targetH: Int,
        photoRect: CGRect,
        exposureCount: Int,
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

