// Palettes.swift
// RetroPix — curated retro color palettes passed to the Metal compute shader.
// Each palette is packed as [SIMD4<Float>] (rgb + padding) — avoids float3 alignment
// issues on the GPU. Always 8 entries; unused slots are zero-padded.

import simd

struct RetroColor {
    let r, g, b: Float

    init(hex: UInt32) {
        r = Float((hex >> 16) & 0xFF) / 255.0
        g = Float((hex >> 8) & 0xFF) / 255.0
        b = Float(hex & 0xFF) / 255.0
    }
}

struct Palette: Identifiable {
    let id: String
    let name: String
    let colors: [RetroColor]

    var count: Int { colors.count }

    /// 8 × SIMD4<Float> ready for MTLBuffer upload (rgb + w=0 padding).
    var gpuColors: [SIMD4<Float>] {
        var result = colors.map { SIMD4<Float>($0.r, $0.g, $0.b, 0) }
        while result.count < 8 { result.append(.zero) }
        return result
    }

    // MARK: — Built-in palettes

    /// Classic 4-color Game Boy green.
    static let original = Palette(id: "original", name: "ORIGINAL", colors: [
        RetroColor(hex: 0x0f380f),
        RetroColor(hex: 0x306230),
        RetroColor(hex: 0x8bac0f),
        RetroColor(hex: 0x9bbc0f),
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

    /// 8-color military olive / ammunition tan palette.
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

    static let all: [Palette] = [.original, .midnight, .ammo]
}
