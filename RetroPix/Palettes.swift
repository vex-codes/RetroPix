// Palettes.swift
// RetroPix — Curated retro color palettes + persistence.
// Each palette packs to [SIMD4<Float>] (rgb + w=0) for Metal buffer upload.

import Foundation
import simd

struct RetroColor: Codable, Equatable, Sendable {
    let r, g, b: Float

    init(r: Float, g: Float, b: Float) {
        self.r = max(0, min(1, r))
        self.g = max(0, min(1, g))
        self.b = max(0, min(1, b))
    }

    init(hex: UInt32) {
        self.r = Float((hex >> 16) & 0xFF) / 255.0
        self.g = Float((hex >> 8) & 0xFF) / 255.0
        self.b = Float(hex & 0xFF) / 255.0
    }

    var hex: UInt32 {
        let ir = UInt32(round(r * 255.0))
        let ig = UInt32(round(g * 255.0))
        let ib = UInt32(round(b * 255.0))
        return (ir << 16) | (ig << 8) | ib
    }

    /// Rec. 709 relative luminance
    var luminance: Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

struct Palette: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let colors: [RetroColor]

    var count: Int { colors.count }

    /// 8 × SIMD4<Float> ready for MTLBuffer — avoids float3 GPU alignment issues.
    var gpuColors: [SIMD4<Float>] {
        var r = colors.map { SIMD4<Float>($0.r, $0.g, $0.b, 0) }
        while r.count < 8 { r.append(.zero) }
        return r
    }

    // MARK: — Palette definitions

    /// 4-color neutral grayscale — minimal, timeless.
    static let def = Palette(id: "default", name: "DEFAULT", colors: [
        RetroColor(hex: 0x0d0d0d),
        RetroColor(hex: 0x3d3d3d),
        RetroColor(hex: 0x8a8a8a),
        RetroColor(hex: 0xe8e8e8),
    ])

    /// 8-color synthwave / midnight purple–cyan palette.
    static let midnight = Palette(id: "7mdnight", name: "7MDNIGHT", colors: [
        RetroColor(hex: 0x0d0221),
        RetroColor(hex: 0x341a3a),
        RetroColor(hex: 0x6a2c70),
        RetroColor(hex: 0xb83b5e),
        RetroColor(hex: 0xf08a5d),
        RetroColor(hex: 0xf9ed69),
        RetroColor(hex: 0x3ec1d3),
        RetroColor(hex: 0xf7fff7),
    ])

    /// 8-color military olive / ammunition tan.
    static let ammo = Palette(id: "8ammo", name: "8AMMO", colors: [
        RetroColor(hex: 0x1a1a0f),
        RetroColor(hex: 0x3d3a2a),
        RetroColor(hex: 0x5c5636),
        RetroColor(hex: 0x8b8060),
        RetroColor(hex: 0xb5a97a),
        RetroColor(hex: 0xd4c896),
        RetroColor(hex: 0x4a3728),
        RetroColor(hex: 0xe8d5b0),
    ])

    /// 8-color ancient stone / terracotta / parchment.
    static let ancient = Palette(id: "8ancient", name: "8ANCIENT", colors: [
        RetroColor(hex: 0x1e1208),
        RetroColor(hex: 0x4a2c12),
        RetroColor(hex: 0x7d4e2a),
        RetroColor(hex: 0xb07238),
        RetroColor(hex: 0xc4944e),
        RetroColor(hex: 0xd8bc86),
        RetroColor(hex: 0xecdab4),
        RetroColor(hex: 0x8b2c1c),
    ])

    /// 8-color fall foliage — crimson, amber, gold.
    static let autumn = Palette(id: "8autumn", name: "8AUTUMN", colors: [
        RetroColor(hex: 0x1a0600),
        RetroColor(hex: 0x8b2500),
        RetroColor(hex: 0xc44200),
        RetroColor(hex: 0xe06c00),
        RetroColor(hex: 0xf09800),
        RetroColor(hex: 0xe8c840),
        RetroColor(hex: 0x6b3a10),
        RetroColor(hex: 0xc87050),
    ])

    /// 8-color warm morning cafe — espresso to cream.
    static let brkfst = Palette(id: "8brkfst", name: "8BRKFST", colors: [
        RetroColor(hex: 0x260e00),
        RetroColor(hex: 0x7a3010),
        RetroColor(hex: 0xc06030),
        RetroColor(hex: 0xe89050),
        RetroColor(hex: 0xf0c878),
        RetroColor(hex: 0x4e7854),
        RetroColor(hex: 0xc84438),
        RetroColor(hex: 0xf0c0a0),
    ])

    /// 8-color dreamwave — deep space to icy pastels.
    static let dream = Palette(id: "8dream", name: "8DREAM", colors: [
        RetroColor(hex: 0x080414),
        RetroColor(hex: 0x2e0c54),
        RetroColor(hex: 0x6820a0),
        RetroColor(hex: 0xa848d0),
        RetroColor(hex: 0xd888f0),
        RetroColor(hex: 0x50b8d8),
        RetroColor(hex: 0xf0c8ff),
        RetroColor(hex: 0xa8f0ff),
    ])

    /// Classic 4-color Game Boy green — the original.
    static let originalGB = Palette(id: "original", name: "ORIGINAL_GB", colors: [
        RetroColor(hex: 0x0f380f),
        RetroColor(hex: 0x306230),
        RetroColor(hex: 0x8bac0f),
        RetroColor(hex: 0x9bbc0f),
    ])

    static let all: [Palette] = [.def, .midnight, .ammo, .ancient, .autumn, .brkfst, .dream, .originalGB]

    // MARK: — Custom palette persistence

    static let customPalettesKey = "retropix_custom_palettes"

    static func loadCustomPalettes() -> [Palette] {
        guard let data = UserDefaults.standard.data(forKey: customPalettesKey),
              let list = try? JSONDecoder().decode([Palette].self, from: data) else { return [] }
        return list
    }

    static func saveCustomPalettes(_ palettes: [Palette]) {
        if let data = try? JSONEncoder().encode(palettes) {
            UserDefaults.standard.set(data, forKey: customPalettesKey)
        }
    }
}
