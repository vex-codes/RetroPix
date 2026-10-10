// AestheticProfile.swift
// RetroPix — Digicam & Analog Film Simulation Profiles.
// Derived strictly from research document: aesthetic-camera-deep-dive.md.

import Foundation
import simd

/// CPU-side uniform structure matching AestheticShader.metal (288 bytes, 16-byte aligned).
public struct AestheticUniforms {
    public var cropUV: SIMD4<Float>          // sensor crop: u0, v0, u1, v1
    public var curveA: SIMD4<Float>          // tone curve knots at x = 0.0, 0.25, 0.50, 0.75
    public var curveB: SIMD4<Float>          // x: knot at 1.0, y: highlight rolloff to white
    public var hueA: SIMD4<Float>            // HSL hue shifts (deg): R, O, Y, G
    public var hueB: SIMD4<Float>            // HSL hue shifts (deg): A, B, P, M
    public var satA: SIMD4<Float>            // HSL sat deltas (-1...1): R, O, Y, G
    public var satB: SIMD4<Float>            // HSL sat deltas (-1...1): A, B, P, M
    public var lumA: SIMD4<Float>            // HSL lum deltas (-1...1): R, O, Y, G
    public var lumB: SIMD4<Float>            // HSL lum deltas (-1...1): A, B, P, M
    public var wbGain: SIMD4<Float>          // rgb: linear WB gains, w: global saturation
    public var shadowTint: SIMD4<Float>      // rgb: split-tone shadow offset, w: pad
    public var highlightTint: SIMD4<Float>   // rgb: split-tone highlight offset, w: pad
    public var m0: SIMD4<Float>              // 3x3 color matrix row 0
    public var m1: SIMD4<Float>              // 3x3 color matrix row 1
    public var m2: SIMD4<Float>              // 3x3 color matrix row 2
    public var fx: SIMD4<Float>              // x: grainAmt, y: grainSize(px), z: halationStrength, w: halationThreshold
    public var fx2: SIMD4<Float>             // x: vignette, y: softness (<0 sharpens), z: CA, w: chromaNoise
    public var outputSize: SIMD2<UInt32>     // render target width, height
    public var seed: Float                   // procedural noise seed
    public var pixelScale: Float             // resolution normalizer: min(outW, outH) / 720
}

public enum AestheticCategory: String, CaseIterable, Identifiable, Codable {
    case digicam = "DIGICAM"
    case filmSimulation = "FILM SIM"
    case analogStock = "ANALOG FILM"

    public var id: String { rawValue }
}

public struct AestheticProfile: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let code: String
    public let subtitle: String
    public let category: AestheticCategory
    public let eraYear: String

    // Tone Curve (0.0, 0.25, 0.50, 0.75, 1.0, rolloff)
    public var curveKnots: [Float]
    public var highlightRolloff: Float

    // HSL Bands: [Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta]
    public var hueDeltas: [Float]
    public var satDeltas: [Float]
    public var lumDeltas: [Float]

    // White Balance & Color
    public var wbRGB: [Float]
    public var globalSaturation: Float
    public var shadowTintRGB: [Float]
    public var highlightTintRGB: [Float]
    public var colorMatrix: [Float] // 9 elements row-major

    // Effects
    public var grainAmount: Float
    public var grainSize: Float
    public var halationStrength: Float
    public var halationThreshold: Float
    public var vignette: Float
    public var opticalSoftness: Float
    public var chromaticAberration: Float
    public var chromaNoise: Float

    public init(
        id: String,
        name: String,
        code: String,
        subtitle: String,
        category: AestheticCategory,
        eraYear: String,
        curveKnots: [Float],
        highlightRolloff: Float,
        hueDeltas: [Float],
        satDeltas: [Float],
        lumDeltas: [Float],
        wbRGB: [Float],
        globalSaturation: Float,
        shadowTintRGB: [Float],
        highlightTintRGB: [Float],
        colorMatrix: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1],
        grainAmount: Float,
        grainSize: Float,
        halationStrength: Float,
        halationThreshold: Float,
        vignette: Float,
        opticalSoftness: Float,
        chromaticAberration: Float,
        chromaNoise: Float
    ) {
        self.id = id
        self.name = name
        self.code = code
        self.subtitle = subtitle
        self.category = category
        self.eraYear = eraYear
        self.curveKnots = curveKnots
        self.highlightRolloff = highlightRolloff
        self.hueDeltas = hueDeltas
        self.satDeltas = satDeltas
        self.lumDeltas = lumDeltas
        self.wbRGB = wbRGB
        self.globalSaturation = globalSaturation
        self.shadowTintRGB = shadowTintRGB
        self.highlightTintRGB = highlightTintRGB
        self.colorMatrix = colorMatrix
        self.grainAmount = grainAmount
        self.grainSize = grainSize
        self.halationStrength = halationStrength
        self.halationThreshold = halationThreshold
        self.vignette = vignette
        self.opticalSoftness = opticalSoftness
        self.chromaticAberration = chromaticAberration
        self.chromaNoise = chromaNoise
    }

    /// Converts profile into GPU shader uniforms
    public func makeUniforms(
        cropUV: SIMD4<Float>,
        outputWidth: Int,
        outputHeight: Int,
        seed: Float
    ) -> AestheticUniforms {
        let ck = curveKnots.count >= 5 ? curveKnots : [0.0, 0.25, 0.50, 0.75, 1.0]
        let h = hueDeltas.count >= 8 ? hueDeltas : Array(repeating: 0.0, count: 8)
        let s = satDeltas.count >= 8 ? satDeltas : Array(repeating: 0.0, count: 8)
        let l = lumDeltas.count >= 8 ? lumDeltas : Array(repeating: 0.0, count: 8)
        let wb = wbRGB.count >= 3 ? wbRGB : [1.0, 1.0, 1.0]
        let st = shadowTintRGB.count >= 3 ? shadowTintRGB : [0.0, 0.0, 0.0]
        let ht = highlightTintRGB.count >= 3 ? highlightTintRGB : [0.0, 0.0, 0.0]
        let m = colorMatrix.count >= 9 ? colorMatrix : [1, 0, 0, 0, 1, 0, 0, 0, 1]

        let minDim = Float(min(outputWidth, outputHeight))
        let pixelScale = max(0.5, minDim / 720.0)

        return AestheticUniforms(
            cropUV: cropUV,
            curveA: SIMD4<Float>(ck[0], ck[1], ck[2], ck[3]),
            curveB: SIMD4<Float>(ck[4], highlightRolloff, 0.0, 0.0),
            hueA: SIMD4<Float>(h[0], h[1], h[2], h[3]),
            hueB: SIMD4<Float>(h[4], h[5], h[6], h[7]),
            satA: SIMD4<Float>(s[0], s[1], s[2], s[3]),
            satB: SIMD4<Float>(s[4], s[5], s[6], s[7]),
            lumA: SIMD4<Float>(l[0], l[1], l[2], l[3]),
            lumB: SIMD4<Float>(l[4], l[5], l[6], l[7]),
            wbGain: SIMD4<Float>(wb[0], wb[1], wb[2], globalSaturation),
            shadowTint: SIMD4<Float>(st[0], st[1], st[2], 0.0),
            highlightTint: SIMD4<Float>(ht[0], ht[1], ht[2], 0.0),
            m0: SIMD4<Float>(m[0], m[1], m[2], 0.0),
            m1: SIMD4<Float>(m[3], m[4], m[5], 0.0),
            m2: SIMD4<Float>(m[6], m[7], m[8], 0.0),
            fx: SIMD4<Float>(grainAmount, grainSize, halationStrength, halationThreshold),
            fx2: SIMD4<Float>(vignette, opticalSoftness, chromaticAberration, chromaNoise),
            outputSize: SIMD2<UInt32>(UInt32(outputWidth), UInt32(outputHeight)),
            seed: seed,
            pixelScale: pixelScale
        )
    }
}

// MARK: — Presets from Deep Dive Document

extension AestheticProfile {

    /// 1. Canon PowerShot G7 X Mark II ("TikTok / Instagram It-Girl")
    public static let canonG7X = AestheticProfile(
        id: "canon_g7x",
        name: "CANON G7 X",
        code: "G7X-II",
        subtitle: "TikTok It-Girl / Peach Skin / Warm Flash Glow",
        category: .digicam,
        eraYear: "'16",
        curveKnots: [0.024, 0.243, 0.518, 0.784, 0.988],
        highlightRolloff: 0.25,
        hueDeltas: [-6.0, 4.0, -10.0, -15.0, 5.0, -8.0, 0.0, -5.0],
        satDeltas: [0.08, 0.06, -0.08, -0.10, -0.10, 0.05, -0.05, -0.05],
        lumDeltas: [0.05, 0.12, 0.08, -0.08, 0.0, -0.10, 0.0, 0.0],
        wbRGB: [1.04, 1.00, 0.97],
        globalSaturation: 1.04,
        shadowTintRGB: [0.025, 0.012, 0.0],
        highlightTintRGB: [0.020, 0.015, 0.005],
        grainAmount: 0.22,
        grainSize: 1.4,
        halationStrength: 0.35,
        halationThreshold: 0.78,
        vignette: 0.18,
        opticalSoftness: 0.22,
        chromaticAberration: 0.0008,
        chromaNoise: 0.0
    )

    /// 2. Kodak Pixpro FZ55 ("Budget Disposable Replacement")
    public static let kodakPixpro = AestheticProfile(
        id: "kodak_pixpro",
        name: "PIXPRO FZ55",
        code: "FZ55",
        subtitle: "Harsh Flash / High Saturation / Plastic Lens Edge",
        category: .digicam,
        eraYear: "'22",
        curveKnots: [0.000, 0.204, 0.541, 0.839, 1.000],
        highlightRolloff: 0.02,
        hueDeltas: [-3.0, 0.0, 0.0, -8.0, 6.0, 4.0, 0.0, -4.0],
        satDeltas: [0.22, 0.10, 0.18, 0.12, 0.20, 0.30, 0.10, 0.10],
        lumDeltas: [0.0, 0.05, 0.0, -0.05, -0.05, -0.08, 0.0, 0.0],
        wbRGB: [1.06, 1.01, 0.95],
        globalSaturation: 1.25,
        shadowTintRGB: [0.0, 0.0, 0.0],
        highlightTintRGB: [0.02, 0.01, 0.0],
        grainAmount: 0.35,
        grainSize: 1.6,
        halationStrength: 0.20,
        halationThreshold: 0.84,
        vignette: 0.48,
        opticalSoftness: 0.45,
        chromaticAberration: 0.0035,
        chromaNoise: 0.40
    )

    /// 3. Fujifilm Classic Chrome ("Analog Documentary Slide")
    public static let fujiClassicChrome = AestheticProfile(
        id: "fuji_classic_chrome",
        name: "CLASSIC CHROME",
        code: "CC-F",
        subtitle: "Documentary Slide / Steel-Cyan Sky / Hard Contrast",
        category: .filmSimulation,
        eraYear: "'14",
        curveKnots: [0.039, 0.220, 0.502, 0.745, 0.973],
        highlightRolloff: 0.20,
        hueDeltas: [4.0, 2.0, -8.0, -20.0, 10.0, 12.0, 0.0, 0.0],
        satDeltas: [0.04, -0.06, -0.20, -0.38, -0.18, -0.25, -0.20, -0.15],
        lumDeltas: [-0.05, -0.05, -0.08, -0.20, -0.12, -0.18, 0.0, 0.0],
        wbRGB: [1.00, 1.00, 1.00],
        globalSaturation: 0.88,
        shadowTintRGB: [0.0, 0.015, 0.035],
        highlightTintRGB: [0.030, 0.020, 0.005],
        colorMatrix: [
             1.04, -0.02, -0.02,
            -0.06,  0.92,  0.04,
            -0.10,  0.05,  1.00
        ],
        grainAmount: 0.40,
        grainSize: 1.8,
        halationStrength: 0.15,
        halationThreshold: 0.82,
        vignette: 0.25,
        opticalSoftness: 0.0,
        chromaticAberration: 0.0005,
        chromaNoise: 0.0
    )

    /// 4. Fujifilm Nostalgic Neg ("1970s American Color")
    public static let fujiNostalgicNeg = AestheticProfile(
        id: "fuji_nostalgic_neg",
        name: "NOSTALGIC NEG",
        code: "NN-F",
        subtitle: "1970s Eggleston Amber / Soft Tones / Cyan Shadows",
        category: .filmSimulation,
        eraYear: "'21",
        curveKnots: [0.063, 0.259, 0.510, 0.745, 0.957],
        highlightRolloff: 0.35,
        hueDeltas: [2.0, 5.0, -5.0, -12.0, 5.0, -5.0, 0.0, 0.0],
        satDeltas: [0.05, 0.08, 0.05, -0.15, -0.10, -0.12, -0.10, -0.05],
        lumDeltas: [0.0, 0.05, 0.02, -0.10, -0.05, -0.10, 0.0, 0.0],
        wbRGB: [1.06, 1.02, 0.94],
        globalSaturation: 0.92,
        shadowTintRGB: [0.005, 0.020, 0.022],
        highlightTintRGB: [0.040, 0.026, 0.006],
        grainAmount: 0.36,
        grainSize: 2.0,
        halationStrength: 0.30,
        halationThreshold: 0.75,
        vignette: 0.22,
        opticalSoftness: 0.18,
        chromaticAberration: 0.0008,
        chromaNoise: 0.0
    )

    /// 5. Early 2000s CCD ("Cyber-shot & PowerShot SD")
    public static let ccdDigicam2005 = AestheticProfile(
        id: "ccd_2005",
        name: "CYBER-SHOT CCD",
        code: "CCD-05",
        subtitle: "Y2K Digital / Electric Blues / Shadow Chroma Noise",
        category: .digicam,
        eraYear: "'05",
        curveKnots: [0.000, 0.188, 0.502, 0.831, 1.000],
        highlightRolloff: 0.0,
        hueDeltas: [-3.0, 0.0, 0.0, -8.0, 6.0, 4.0, 0.0, -4.0],
        satDeltas: [0.25, 0.10, 0.20, 0.15, 0.25, 0.35, 0.10, 0.10],
        lumDeltas: [0.0, 0.05, 0.0, -0.05, -0.05, -0.08, 0.0, 0.0],
        wbRGB: [1.08, 1.02, 0.93],
        globalSaturation: 1.22,
        shadowTintRGB: [0.015, 0.005, 0.035],
        highlightTintRGB: [0.035, 0.022, 0.005],
        grainAmount: 0.20,
        grainSize: 1.2,
        halationStrength: 0.25,
        halationThreshold: 0.80,
        vignette: 0.25,
        opticalSoftness: -0.35, // crunchy edge sharpening
        chromaticAberration: 0.0022,
        chromaNoise: 0.55
    )

    /// 6. CineStill 800T ("Tungsten Cinematography & Red Halation")
    public static let cinestill800T = AestheticProfile(
        id: "cinestill_800t",
        name: "CINESTILL 800T",
        code: "CS-800",
        subtitle: "Tungsten Cine Stock / Intense Red Halos / Teal Shadows",
        category: .analogStock,
        eraYear: "'12",
        curveKnots: [0.031, 0.235, 0.494, 0.765, 0.980],
        highlightRolloff: 0.30,
        hueDeltas: [-4.0, -2.0, -5.0, 5.0, -5.0, -8.0, 0.0, 5.0],
        satDeltas: [0.15, 0.05, -0.05, -0.10, 0.15, 0.20, 0.0, 0.10],
        lumDeltas: [0.05, 0.02, 0.0, -0.05, -0.05, -0.08, 0.0, 0.0],
        wbRGB: [0.92, 0.98, 1.14],
        globalSaturation: 1.05,
        shadowTintRGB: [0.005, 0.030, 0.040],
        highlightTintRGB: [0.045, 0.018, 0.005],
        grainAmount: 0.45,
        grainSize: 1.8,
        halationStrength: 0.88,
        halationThreshold: 0.70,
        vignette: 0.30,
        opticalSoftness: 0.15,
        chromaticAberration: 0.0012,
        chromaNoise: 0.0
    )

    /// 7. Kodak Gold 200 ("Golden Warmth & Film Grain")
    public static let kodakGold200 = AestheticProfile(
        id: "kodak_gold_200",
        name: "KODAK GOLD 200",
        code: "GOLD-200",
        subtitle: "Golden Highlights / Warm Saturated Reds / Tactile Grain",
        category: .analogStock,
        eraYear: "'97",
        curveKnots: [0.047, 0.243, 0.518, 0.753, 0.965],
        highlightRolloff: 0.25,
        hueDeltas: [2.0, 4.0, -4.0, -10.0, 5.0, -5.0, 0.0, 0.0],
        satDeltas: [0.15, 0.12, 0.18, -0.08, -0.05, -0.08, 0.0, 0.0],
        lumDeltas: [0.02, 0.06, 0.04, -0.05, -0.05, -0.10, 0.0, 0.0],
        wbRGB: [1.08, 1.03, 0.92],
        globalSaturation: 1.10,
        shadowTintRGB: [0.035, 0.022, 0.005],
        highlightTintRGB: [0.035, 0.025, 0.005],
        grainAmount: 0.42,
        grainSize: 1.7,
        halationStrength: 0.35,
        halationThreshold: 0.76,
        vignette: 0.28,
        opticalSoftness: 0.10,
        chromaticAberration: 0.0010,
        chromaNoise: 0.0
    )

    /// 8. Kodak Portra 400 ("The Definitive 35mm Portrait Film")
    public static let kodakPortra400 = AestheticProfile(
        id: "kodak_portra_400",
        name: "PORTRA 400",
        code: "PORTRA-400",
        subtitle: "Warm Creamy Skin / Pastel Highlights / Muted Greens",
        category: .analogStock,
        eraYear: "'98",
        curveKnots: [0.035, 0.238, 0.505, 0.772, 0.970],
        highlightRolloff: 0.32,
        hueDeltas: [-2.0, 3.0, -8.0, -18.0, 8.0, 5.0, 0.0, -2.0],
        satDeltas: [0.06, 0.04, -0.06, -0.22, -0.12, -0.15, -0.10, -0.05],
        lumDeltas: [0.04, 0.08, 0.05, -0.06, 0.0, -0.05, 0.0, 0.0],
        wbRGB: [1.05, 1.01, 0.96],
        globalSaturation: 0.96,
        shadowTintRGB: [0.010, 0.020, 0.025],
        highlightTintRGB: [0.030, 0.020, 0.005],
        grainAmount: 0.32,
        grainSize: 1.5,
        halationStrength: 0.28,
        halationThreshold: 0.78,
        vignette: 0.16,
        opticalSoftness: 0.12,
        chromaticAberration: 0.0006,
        chromaNoise: 0.0
    )

    /// 9. Fujifilm Velvia 50 ("High-Vibrancy Slide Film")
    public static let fujiVelvia50 = AestheticProfile(
        id: "fuji_velvia_50",
        name: "VELVIA 50",
        code: "VEL-50",
        subtitle: "Ultra-Saturated Slide / Electric Blues / Deep Inky Blacks",
        category: .filmSimulation,
        eraYear: "'90",
        curveKnots: [0.000, 0.190, 0.515, 0.810, 1.000],
        highlightRolloff: 0.05,
        hueDeltas: [0.0, 2.0, -4.0, 6.0, -4.0, 4.0, 5.0, 8.0],
        satDeltas: [0.35, 0.20, 0.25, 0.40, 0.30, 0.45, 0.25, 0.30],
        lumDeltas: [-0.05, 0.0, -0.05, 0.05, -0.05, -0.12, 0.0, 0.0],
        wbRGB: [1.00, 1.02, 1.06],
        globalSaturation: 1.30,
        shadowTintRGB: [0.005, 0.005, 0.020],
        highlightTintRGB: [0.015, 0.010, 0.002],
        grainAmount: 0.22,
        grainSize: 1.3,
        halationStrength: 0.18,
        halationThreshold: 0.82,
        vignette: 0.32,
        opticalSoftness: -0.10,
        chromaticAberration: 0.0004,
        chromaNoise: 0.0
    )

    /// 10. Ricoh GR Digital High-Contrast B&W ("Daido Moriyama Street Style")
    public static let ricohGrMono = AestheticProfile(
        id: "ricoh_gr_mono",
        name: "RICOH GR B&W",
        code: "GRD-BW",
        subtitle: "Cult High-Contrast Monochrome / Crushed Shadows / Gritty Grain",
        category: .digicam,
        eraYear: "'05",
        curveKnots: [0.000, 0.120, 0.480, 0.860, 1.000],
        highlightRolloff: 0.02,
        hueDeltas: [0, 0, 0, 0, 0, 0, 0, 0],
        satDeltas: [0, 0, 0, 0, 0, 0, 0, 0],
        lumDeltas: [0.10, 0.05, -0.05, -0.15, -0.10, -0.20, 0, 0],
        wbRGB: [1.0, 1.0, 1.0],
        globalSaturation: 0.00,
        shadowTintRGB: [0.0, 0.0, 0.0],
        highlightTintRGB: [0.0, 0.0, 0.0],
        colorMatrix: [
            0.299, 0.587, 0.114,
            0.299, 0.587, 0.114,
            0.299, 0.587, 0.114
        ],
        grainAmount: 0.65,
        grainSize: 2.2,
        halationStrength: 0.22,
        halationThreshold: 0.80,
        vignette: 0.55,
        opticalSoftness: -0.40,
        chromaticAberration: 0.0,
        chromaNoise: 0.0
    )

    /// 11. Olympus Mju-II / Stylus Epic ("Cult 35mm Point-and-Shoot Flash")
    public static let olympusMjuII = AestheticProfile(
        id: "olympus_mju_ii",
        name: "OLYMPUS MJU II",
        code: "MJU-II",
        subtitle: "Cult 35mm Point & Shoot / Flash Falloff / Warm Flare",
        category: .analogStock,
        eraYear: "'91",
        curveKnots: [0.020, 0.225, 0.510, 0.790, 0.990],
        highlightRolloff: 0.15,
        hueDeltas: [-3.0, 2.0, -5.0, -10.0, 4.0, 2.0, 0.0, -3.0],
        satDeltas: [0.18, 0.12, 0.15, -0.05, 0.05, 0.10, 0.0, 0.05],
        lumDeltas: [0.06, 0.10, 0.04, -0.08, -0.02, -0.10, 0.0, 0.0],
        wbRGB: [1.06, 1.01, 0.94],
        globalSaturation: 1.12,
        shadowTintRGB: [0.015, 0.010, 0.002],
        highlightTintRGB: [0.038, 0.024, 0.006],
        grainAmount: 0.38,
        grainSize: 1.6,
        halationStrength: 0.42,
        halationThreshold: 0.74,
        vignette: 0.45,
        opticalSoftness: 0.15,
        chromaticAberration: 0.0018,
        chromaNoise: 0.0
    )

    /// 12. Fujifilm Superia X-TRA 400 ("4th Color Layer Consumer Negative")
    public static let fujiSuperia400 = AestheticProfile(
        id: "fuji_superia_400",
        name: "SUPERIA 400",
        code: "SUP-400",
        subtitle: "Emerald Shadow Cast / Vivid Warm Skin / 90s Negative",
        category: .analogStock,
        eraYear: "'00",
        curveKnots: [0.050, 0.245, 0.505, 0.760, 0.965],
        highlightRolloff: 0.28,
        hueDeltas: [3.0, 4.0, -6.0, -8.0, -10.0, -4.0, 0.0, 4.0],
        satDeltas: [0.12, 0.08, 0.10, 0.12, -0.05, 0.08, 0.0, 0.05],
        lumDeltas: [0.02, 0.05, 0.02, 0.04, -0.05, -0.08, 0.0, 0.0],
        wbRGB: [1.02, 1.04, 0.97],
        globalSaturation: 1.08,
        shadowTintRGB: [0.002, 0.035, 0.020],
        highlightTintRGB: [0.025, 0.015, 0.002],
        grainAmount: 0.44,
        grainSize: 1.8,
        halationStrength: 0.25,
        halationThreshold: 0.78,
        vignette: 0.24,
        opticalSoftness: 0.08,
        chromaticAberration: 0.0009,
        chromaNoise: 0.0
    )

    /// 13. CPM 35MM ("Dazz Cam Classic 35mm Point-and-Shoot")
    public static let dazzCPM35 = AestheticProfile(
        id: "cpm_35",
        name: "CPM 35MM",
        code: "CPM-35",
        subtitle: "Vintage 35mm Compact / Soft Pastels / Warm Lifestyle Glow",
        category: .analogStock,
        eraYear: "'95",
        curveKnots: [0.045, 0.240, 0.510, 0.770, 0.965],
        highlightRolloff: 0.30,
        hueDeltas: [2.0, 4.0, -5.0, -15.0, 6.0, -4.0, 0.0, 0.0],
        satDeltas: [0.12, 0.06, 0.08, -0.18, -0.12, -0.15, -0.05, 0.0],
        lumDeltas: [0.03, 0.06, 0.04, -0.06, -0.02, -0.08, 0.0, 0.0],
        wbRGB: [1.05, 1.01, 0.95],
        globalSaturation: 0.98,
        shadowTintRGB: [0.025, 0.015, 0.005],
        highlightTintRGB: [0.032, 0.022, 0.005],
        grainAmount: 0.30,
        grainSize: 1.5,
        halationStrength: 0.32,
        halationThreshold: 0.76,
        vignette: 0.20,
        opticalSoftness: 0.15,
        chromaticAberration: 0.0008,
        chromaNoise: 0.0
    )

    /// 14. Instant 600 ("Polaroid / Instax Chemical Emulsion")
    public static let polaroid600 = AestheticProfile(
        id: "polaroid_600",
        name: "INSTANT 600",
        code: "INST-600",
        subtitle: "Instant Chemical Film / Milky Cyan Shadows / Soft Pastels",
        category: .analogStock,
        eraYear: "'81",
        curveKnots: [0.075, 0.260, 0.505, 0.735, 0.940],
        highlightRolloff: 0.38,
        hueDeltas: [-3.0, 2.0, -6.0, 8.0, 12.0, 8.0, 0.0, -4.0],
        satDeltas: [0.05, 0.04, -0.05, -0.15, 0.10, 0.08, 0.0, 0.0],
        lumDeltas: [0.02, 0.04, 0.02, -0.04, 0.02, -0.06, 0.0, 0.0],
        wbRGB: [0.98, 1.02, 1.04],
        globalSaturation: 0.92,
        shadowTintRGB: [0.010, 0.038, 0.045],
        highlightTintRGB: [0.035, 0.028, 0.010],
        grainAmount: 0.40,
        grainSize: 1.8,
        halationStrength: 0.36,
        halationThreshold: 0.72,
        vignette: 0.35,
        opticalSoftness: 0.25,
        chromaticAberration: 0.0014,
        chromaNoise: 0.0
    )

    public static let allBuiltIn: [AestheticProfile] = [
        .canonG7X,
        .kodakPixpro,
        .fujiClassicChrome,
        .fujiNostalgicNeg,
        .ccdDigicam2005,
        .cinestill800T,
        .kodakGold200,
        .kodakPortra400,
        .fujiVelvia50,
        .ricohGrMono,
        .olympusMjuII,
        .fujiSuperia400,
        .dazzCPM35,
        .polaroid600
    ]
}

