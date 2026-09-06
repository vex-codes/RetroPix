// HarmonicPaletteGenerator.swift
// RetroPix — Procedural palette engine backed by classical color harmony.

import Foundation

enum HarmonicPaletteGenerator {

    enum Style: CaseIterable {
        case warmToCool    // 7MDNIGHT style: cool shadows -> warm magenta -> gold highlight -> cyan accent
        case warmAnalogous // 8BRKFST style: espresso -> terracotta -> amber -> sage accent
        case neoTokyo      // deep navy -> magenta -> amber -> electric cyan
        case vaporwave     // indigo -> violet -> peach -> mint
        case retroEarth    // dark olive -> moss -> khaki -> brick red accent
    }

    static func generate(count: Int = 8) -> Palette {
        let n = max(5, min(8, count))
        let style = Style.allCases.randomElement() ?? .warmToCool

        var baseColors: [RetroColor] = []

        switch style {
        case .warmToCool:
            // 7MDNIGHT pattern: Cool dark shadow -> warm vibrant midtone -> bright highlight + 1 cool accent
            let shadowHue = Float.random(in: 250...285)
            let highlightHue = Float.random(in: 40...60)
            let accentHue = Float.random(in: 175...200)

            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue = normalizeHue(shadowHue + t * (highlightHue - shadowHue + (highlightHue < shadowHue ? 360 : 0)))
                let lum = 0.05 + 0.90 * pow(t, 1.25)
                let sat = sin(t * .pi) * 0.50 + 0.45
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: accentHue, s: 0.80, l: 0.58))

        case .warmAnalogous:
            // 8BRKFST pattern: Rich coffee dark -> warm terracotta -> amber -> cream + 1 sage/earth accent
            let baseHue = Float.random(in: 15...35)
            let accentHue = normalizeHue(baseHue + 140)

            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue = normalizeHue(baseHue + t * 25.0)
                let lum = 0.06 + 0.88 * pow(t, 1.20)
                let sat = sin(t * .pi) * 0.45 + 0.40
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: accentHue, s: 0.35, l: 0.42))

        case .neoTokyo:
            let darkHue: Float = 245
            let brightHue: Float = 330
            let accentHue: Float = 180
            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue = (t < 0.45) ? darkHue : brightHue
                let lum = 0.04 + 0.92 * pow(t, 1.2)
                let sat = 0.50 + 0.45 * sin(t * .pi)
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: accentHue, s: 0.90, l: 0.60))

        case .vaporwave:
            let startHue = Float.random(in: 270...310)
            let accentHue = Float.random(in: 160...190)
            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue = normalizeHue(startHue + t * 45)
                let lum = 0.08 + 0.86 * t
                let sat = 0.45 + 0.45 * sin(t * .pi)
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: accentHue, s: 0.70, l: 0.65))

        case .retroEarth:
            let baseHue = Float.random(in: 60...90)
            let accentHue = Float.random(in: 0...20)
            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue = normalizeHue(baseHue + (t > 0.6 ? 20 : 0))
                let lum = 0.06 + 0.88 * t
                let sat = 0.30 + 0.35 * sin(t * .pi)
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: accentHue, s: 0.65, l: 0.45))
        }

        // BT.709 luminance sort ensures darkest to lightest gradation
        let sorted = baseColors.sorted { $0.luminance < $1.luminance }
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
