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

    /// Crop UV bounds (u0, v0, u1, v1) for 1280×720 camera buffer
    var cropUV: SIMD4<Float> {
        switch self {
        case .ratio2_1:
            // 1280×640 on 1280×720 -> v margin 40px
            return SIMD4<Float>(0.0, 40.0 / 720.0, 1.0, 680.0 / 720.0)
        case .ratio1_1:
            // 720×720 on 1280×720 -> u margin 280px
            return SIMD4<Float>(280.0 / 1280.0, 0.0, 1000.0 / 1280.0, 1.0)
        case .ratio4_3:
            // 960×720 on 1280×720 -> u margin 160px
            return SIMD4<Float>(160.0 / 1280.0, 0.0, 1120.0 / 1280.0, 1.0)
        case .ratio16_9:
            // Full 1280×720
            return SIMD4<Float>(0.0, 0.0, 1.0, 1.0)
        }
    }
}
