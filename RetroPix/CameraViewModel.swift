// CameraViewModel.swift
// RetroPix — Centralized state hub for the retro GUI.
// @Observable = SwiftUI auto-tracks which properties each view reads; no manual objectWillChange.

import SwiftUI

@Observable
final class CameraViewModel {
    var activePaletteIndex: Int = 0
    var evBias: Float = 0.0          // clamped -2.0 … +2.0 in 0.5 steps
    var ditherIntensity: Float = 0.75 // 0 … 1.0; settable from deck toggle or settings slider
    var activeRatio: AspectRatio = .ratio2_1
    var isPortrait: Bool = false
    var orientation: UInt32 = 0      // 0: landscape right, 1: portrait, 2: landscape left

    var customPalettes: [Palette] = Palette.loadCustomPalettes()

    var allPalettes: [Palette] {
        Palette.all + customPalettes
    }

    var activePalette: Palette {
        let list = allPalettes
        guard !list.isEmpty else { return Palette.def }
        let safeIdx = (activePaletteIndex % list.count + list.count) % list.count
        return list[safeIdx]
    }

    /// Internal rendering resolution for active ratio and orientation
    var outputSize: (w: Int, h: Int) {
        activeRatio.outputSize(portrait: isPortrait)
    }

    /// Human-readable label for the current dither value — snaps to nearest preset label.
    var ditherLabel: String {
        switch ditherIntensity {
        case 0:        return "OFF"
        case ..<0.6:   return "50%"
        case ..<0.88:  return "75%"
        default:       return "100%"
        }
    }

    // MARK: — Actions (all include selection haptic)

    func cyclePalette(forward: Bool) {
        let count = allPalettes.count
        guard count > 0 else { return }
        activePaletteIndex = (activePaletteIndex + (forward ? 1 : count - 1)) % count
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func generateRandomPalette() {
        let pal = HarmonicPaletteGenerator.generate(count: Int.random(in: 5...8))
        customPalettes.append(pal)
        Palette.saveCustomPalettes(customPalettes)
        activePaletteIndex = allPalettes.count - 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func addCustomPalette(_ palette: Palette) {
        customPalettes.append(palette)
        Palette.saveCustomPalettes(customPalettes)
        activePaletteIndex = allPalettes.count - 1
    }

    func deleteCustomPalette(id: String) {
        customPalettes.removeAll { $0.id == id }
        Palette.saveCustomPalettes(customPalettes)
        if activePaletteIndex >= allPalettes.count {
            activePaletteIndex = max(0, allPalettes.count - 1)
        }
    }

    func reloadCustomPalettes() {
        customPalettes = Palette.loadCustomPalettes()
        if activePaletteIndex >= allPalettes.count {
            activePaletteIndex = max(0, allPalettes.count - 1)
        }
    }

    func stepEV(up: Bool) {
        evBias = max(-2.0, min(2.0, evBias + (up ? 0.5 : -0.5)))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cycleRatio() {
        let all = AspectRatio.allCases
        if let idx = all.firstIndex(of: activeRatio) {
            activeRatio = all[(idx + 1) % all.count]
        } else {
            activeRatio = .ratio2_1
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Cycles dither through OFF → 50% → 75% → 100% snap points.
    func cycleDither() {
        let steps: [Float] = [0, 0.5, 0.75, 1.0]
        let nearestIdx = steps.indices.min(by: { abs(steps[$0] - ditherIntensity) < abs(steps[$1] - ditherIntensity) }) ?? 2
        ditherIntensity = steps[(nearestIdx + 1) % steps.count]
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
