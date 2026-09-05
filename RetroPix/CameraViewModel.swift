// CameraViewModel.swift
// RetroPix — Centralized state hub for the retro GUI.
// @Observable = SwiftUI auto-tracks which properties each view reads; no manual objectWillChange.

import SwiftUI

@Observable
final class CameraViewModel {
    var activePaletteIndex: Int = 0
    var evBias: Float = 0.0          // clamped -2.0 … +2.0 in 0.5 steps
    var ditherIntensity: Float = 0.75 // 0 … 1.0; settable from deck toggle or settings slider

    var activePalette: Palette { Palette.all[activePaletteIndex] }

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
        activePaletteIndex = (activePaletteIndex + (forward ? 1 : Palette.all.count - 1)) % Palette.all.count
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func stepEV(up: Bool) {
        evBias = max(-2.0, min(2.0, evBias + (up ? 0.5 : -0.5)))
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
