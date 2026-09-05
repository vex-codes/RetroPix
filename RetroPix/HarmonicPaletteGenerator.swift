// HarmonicPaletteGenerator.swift
// RetroPix — Procedural palette engine backed by classical color harmony.

import Foundation

enum HarmonicPaletteGenerator {

    enum Harmony: CaseIterable {
        case monochromatic
        case analogous
        case complementary
        case splitComplementary
        case triadic
    }

    static func generate(count: Int = 6) -> Palette {
        let n = max(4, min(8, count))
        let harmony = Harmony.allCases.randomElement() ?? .analogous
        let baseHue = Float.random(in: 0..<360)

        var hues: [Float] = []
        switch harmony {
        case .monochromatic:
            hues = Array(repeating: baseHue, count: n)
        case .analogous:
            let step: Float = 15.0
            hues = (0..<n).map { i in
                normalizeHue(baseHue + Float(i - n / 2) * step)
            }
        case .complementary:
            let comp = normalizeHue(baseHue + 180)
            hues = (0..<n).map { i in
                (i % 2 == 0) ? baseHue : comp
            }
        case .splitComplementary:
            let c1 = normalizeHue(baseHue + 150)
            let c2 = normalizeHue(baseHue + 210)
            let options = [baseHue, c1, c2]
            hues = (0..<n).map { i in options[i % options.count] }
        case .triadic:
            let c1 = normalizeHue(baseHue + 120)
            let c2 = normalizeHue(baseHue + 240)
            let options = [baseHue, c1, c2]
            hues = (0..<n).map { i in options[i % options.count] }
        }

        var colors: [RetroColor] = []
        for i in 0..<n {
            let t = Float(i) / Float(max(1, n - 1))
            let l = 0.08 + 0.84 * t
            let s: Float = (harmony == .monochromatic) ? Float.random(in: 0.2...0.9) : Float.random(in: 0.5...0.95)
            colors.append(hslToRgb(h: hues[i], s: s, l: l))
        }

        // BT.709 luminance sort ensures darkest to lightest gradation
        let sorted = colors.sorted { $0.luminance < $1.luminance }
        let id = "gen_\(UUID().uuidString.prefix(8))"
        let name = "GEN_\(Int.random(in: 100...999))"
        return Palette(id: id, name: name, colors: sorted)
    }

    private static func normalizeHue(_ h: Float) -> Float {
        var res = h.truncatingRemainder(dividingBy: 360)
        if res < 0 { res += 360 }
        return res
    }

    private static func hslToRgb(h: Float, s: Float, l: Float) -> RetroColor {
        let c = (1.0 - abs(2.0 * l - 1.0)) * s
        let hp = h / 60.0
        let x = c * (1.0 - abs(hp.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = l - c / 2.0
        var r: Float = 0, g: Float = 0, b: Float = 0

        if hp < 1 { (r, g, b) = (c, x, 0) }
        else if hp < 2 { (r, g, b) = (x, c, 0) }
        else if hp < 3 { (r, g, b) = (0, c, x) }
        else if hp < 4 { (r, g, b) = (0, x, c) }
        else if hp < 5 { (r, g, b) = (x, 0, c) }
        else { (r, g, b) = (c, 0, x) }

        return RetroColor(r: r + m, g: g + m, b: b + m)
    }
}
