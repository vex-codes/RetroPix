// HarmonicPaletteGenerator.swift
// RetroPix — Procedural palette engine backed by classical color harmony.

import Foundation

enum HarmonicPaletteGenerator {

    enum Archetype: String, CaseIterable {
        case midnightSynth = "MIDNIGHT"  // 7MDNIGHT style: violet shadow -> coral/gold -> cyan accent
        case warmCafe      = "CAFE"      // 8BRKFST style: espresso -> terracotta -> amber -> sage accent
        case deepOcean     = "OCEAN"     // abyssal navy -> teal -> seafoam -> sunset coral accent
        case emeraldGrove  = "EMERALD"   // deep pine -> moss -> chartreuse -> copper accent
        case solarFlare    = "SOLAR"     // burgundy -> vermillion -> sulfur yellow -> deep violet accent
        case cyberLime     = "CYBER"     // pitch onyx -> graphite -> acid lime -> hot magenta accent
        case amethystDusk  = "AMETHYST"  // velvet plum -> royal violet -> periwinkle -> goldenrod accent
        case desertOasis   = "OASIS"     // dark umber -> dune sand -> terracotta -> electric turquoise accent
        case arcticFrost   = "ARCTIC"    // twilight navy -> cobalt -> glacial white -> fiery amber accent
    }

    private static var deck: [Archetype] = []

    static func generate(existingPalettes: [Palette] = [], count: Int = 8) -> Palette {
        for _ in 0..<12 {
            let candidate = generateCandidate(count: count)
            if !isTooSimilar(candidate.colors, to: existingPalettes) {
                return candidate
            }
        }
        return generateCandidate(count: count)
    }

    private static func isTooSimilar(_ candidate: [RetroColor], to existing: [Palette]) -> Bool {
        for pal in existing {
            let other = pal.colors
            guard !other.isEmpty else { continue }
            let compareCount = min(candidate.count, other.count)
            var totalDiff: Float = 0
            for i in 0..<compareCount {
                let c1 = candidate[i]
                let c2 = other[i]
                let dr = c1.r - c2.r
                let dg = c1.g - c2.g
                let db = c1.b - c2.b
                totalDiff += sqrt(dr * dr + dg * dg + db * db)
            }
            let avgDiff = totalDiff / Float(compareCount)
            if avgDiff < 0.22 {
                return true
            }
        }
        return false
    }

    private static func generateCandidate(count: Int) -> Palette {
        let n = max(5, min(8, count))
        if deck.isEmpty {
            deck = Archetype.allCases.shuffled()
        }
        let archetype = deck.removeFirst()

        var baseColors: [RetroColor] = []

        switch archetype {
        case .midnightSynth:
            let shadowHue = Float.random(in: 255...285)
            let highlightHue = Float.random(in: 45...65)
            let accentHue = Float.random(in: 180...195)

            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue = normalizeHue(shadowHue + t * (highlightHue - shadowHue + (highlightHue < shadowHue ? 360 : 0)))
                let lum = 0.05 + 0.90 * pow(t, 1.25)
                let sat = sin(t * .pi) * 0.50 + 0.45
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: accentHue, s: 0.85, l: 0.55))

        case .warmCafe:
            let baseHue = Float.random(in: 16...32)
            let accentHue = normalizeHue(baseHue + 140)

            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue = normalizeHue(baseHue + t * 24.0)
                let lum = 0.06 + 0.88 * pow(t, 1.20)
                let sat = sin(t * .pi) * 0.45 + 0.40
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: accentHue, s: 0.35, l: 0.42))

        case .deepOcean:
            let shadowHue: Float = 225
            let highlightHue: Float = 155
            let accentHue: Float = 15

            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue = normalizeHue(shadowHue - t * (shadowHue - highlightHue))
                let lum = 0.04 + 0.90 * pow(t, 1.30)
                let sat = sin(t * .pi) * 0.50 + 0.40
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: accentHue, s: 0.85, l: 0.58))

        case .emeraldGrove:
            let shadowHue: Float = 145
            let highlightHue: Float = 75
            let accentHue: Float = 10

            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue = normalizeHue(shadowHue - t * (shadowHue - highlightHue))
                let lum = 0.05 + 0.88 * pow(t, 1.25)
                let sat = sin(t * .pi) * 0.45 + 0.40
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: accentHue, s: 0.70, l: 0.48))

        case .solarFlare:
            let shadowHue: Float = 345
            let accentHue: Float = 275

            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue = normalizeHue(shadowHue + t * 67.0)
                let lum = 0.05 + 0.90 * pow(t, 1.20)
                let sat = sin(t * .pi) * 0.55 + 0.45
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: accentHue, s: 0.80, l: 0.45))

        case .cyberLime:
            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue: Float = (t < 0.4) ? 210 : 80
                let lum = 0.04 + 0.92 * pow(t, 1.25)
                let sat = (t < 0.4) ? 0.25 : (sin(t * .pi) * 0.55 + 0.45)
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: 320, s: 0.95, l: 0.55))

        case .amethystDusk:
            let shadowHue: Float = 295
            let highlightHue: Float = 240
            let accentHue: Float = 48

            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue = normalizeHue(shadowHue - t * (shadowHue - highlightHue))
                let lum = 0.05 + 0.88 * pow(t, 1.25)
                let sat = sin(t * .pi) * 0.50 + 0.40
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: accentHue, s: 0.85, l: 0.60))

        case .desertOasis:
            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue: Float = 30 + t * 20
                let lum = 0.06 + 0.88 * pow(t, 1.20)
                let sat = sin(t * .pi) * 0.40 + 0.35
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: 185, s: 0.85, l: 0.52))

        case .arcticFrost:
            for i in 0..<(n - 1) {
                let t = Float(i) / Float(n - 2)
                let hue: Float = 235 - t * 40
                let lum = 0.05 + 0.92 * pow(t, 1.25)
                let sat = sin(t * .pi) * 0.45 + 0.40
                baseColors.append(hslToRgb(h: hue, s: sat, l: lum))
            }
            baseColors.append(hslToRgb(h: 35, s: 0.90, l: 0.55))
        }

        // BT.709 luminance sort ensures darkest to lightest gradation
        let sorted = baseColors.sorted { $0.luminance < $1.luminance }
        let id = "gen_\(UUID().uuidString.prefix(8))"
        let name = "\(archetype.rawValue)_\(Int.random(in: 10...99))"
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
