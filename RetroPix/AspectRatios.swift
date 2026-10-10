// AspectRatios.swift
// RetroPix — Selectable aspect ratios and grid sizes.

import simd

enum AspectRatio: String, CaseIterable, Identifiable, Codable {
    case ratio2_1  = "2:1"
    case ratio1_1  = "1:1"
    case ratio4_3  = "4:3"
    case ratio16_9 = "16:9"

    var id: String { rawValue }
    var displayLabel: String { rawValue }

    var outputSize: (w: Int, h: Int) {
        switch self {
        case .ratio2_1:  return (128, 256)
        case .ratio1_1:  return (192, 192)
        case .ratio4_3:  return (180, 240)
        case .ratio16_9: return (144, 256)
        }
    }

    /// Full-resolution render target for AESTHETIC (Digicam/Film) mode
    var aestheticOutputSize: (w: Int, h: Int) {
        switch self {
        case .ratio2_1:  return (960, 1920)
        case .ratio1_1:  return (1080, 1080)
        case .ratio4_3:  return (1080, 1440)
        case .ratio16_9: return (1080, 1920)
        }
    }

    /// Crop UV bounds (u0, v0, u1, v1) for 16:9 camera buffer (normalized [0, 1])
    var cropUV: SIMD4<Float> {
        cropUV(isFrontCamera: false)
    }

    /// Front-camera aware crop bounds.
    /// On iPhone, front sensor is mounted 180° physically inverted and requires horizontal mirroring for natural selfie framing.
    func cropUV(isFrontCamera: Bool) -> SIMD4<Float> {
        if isFrontCamera {
            // Front camera locked to 4:3 portrait inside native 9:16 sensor buffer.
            // Horizontal u: full width [0.0, 1.0].
            // Vertical v: centered 4:3 crop (1440/1920) => [0.125, 0.875].
            return SIMD4<Float>(0.0, 0.125, 1.0, 0.875)
        }

        switch self {
        case .ratio2_1:
            // 2:1 crop inside 16:9 buffer
            return SIMD4<Float>(0.0, 40.0 / 720.0, 1.0, 680.0 / 720.0)
        case .ratio1_1:
            // 1:1 center square crop
            return SIMD4<Float>(280.0 / 1280.0, 0.0, 1000.0 / 1280.0, 1.0)
        case .ratio4_3:
            // 4:3 center crop (0.125 to 0.875)
            return SIMD4<Float>(160.0 / 1280.0, 0.0, 1120.0 / 1280.0, 1.0)
        case .ratio16_9:
            // Full sensor frame
            return SIMD4<Float>(0.0, 0.0, 1.0, 1.0)
        }
    }
}
