// CameraViewModel.swift
// RetroPix — Centralized state hub for the retro GUI.
// @Observable = SwiftUI auto-tracks which properties each view reads; no manual objectWillChange.

import SwiftUI

enum DateStampMode: String, CaseIterable, Identifiable, Codable {
    case off = "OFF"
    case orange = "ORANGE"
    case green = "GREEN"

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .off: return "OFF"
        case .orange: return "ORANGE ('98)"
        case .green: return "GREEN ('98)"
        }
    }
}

@Observable
final class CameraViewModel {
    var activePaletteIndex: Int = 0
    var evBias: Float = 0.0          // clamped -2.0 … +2.0 in 0.5 steps
    var ditherIntensity: Float = 0.75 // 0 … 1.0; settable from deck toggle or settings slider
    var activeRatio: AspectRatio = {
        if let saved = UserDefaults.standard.string(forKey: "activeRatio"),
           let ratio = AspectRatio(rawValue: saved) {
            return ratio
        }
        return .ratio4_3
    }() {
        didSet {
            UserDefaults.standard.set(activeRatio.rawValue, forKey: "activeRatio")
        }
    }
    var isPortrait: Bool = false
    var orientation: UInt32 = 0      // 0: landscape right, 1: portrait, 2: landscape left

    // Pinch-to-zoom state
    var zoomFactor: CGFloat = 1.0
    var baseZoomFactor: CGFloat = 1.0

    var palettes: [Palette] = Palette.loadPalettes()
    var isDarkMode: Bool = UserDefaults.standard.object(forKey: "isDarkMode") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isDarkMode, forKey: "isDarkMode")
        }
    }

    var dateStampMode: DateStampMode = {
        if let saved = UserDefaults.standard.string(forKey: "dateStampMode"),
           let mode = DateStampMode(rawValue: saved) {
            return mode
        }
        return .orange
    }() {
        didSet {
            UserDefaults.standard.set(dateStampMode.rawValue, forKey: "dateStampMode")
        }
    }

    var frameBorderEnabled: Bool = UserDefaults.standard.object(forKey: "frameBorderEnabled") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(frameBorderEnabled, forKey: "frameBorderEnabled")
        }
    }

    var timerDuration: Int = UserDefaults.standard.object(forKey: "timerDuration") as? Int ?? 0 {
        didSet {
            UserDefaults.standard.set(timerDuration, forKey: "timerDuration")
        }
    }

    var isFlashOn: Bool = false
    var isFrontCamera: Bool = false

    var activePalette: Palette {
        guard !palettes.isEmpty else { return Palette.def }
        let safeIdx = (activePaletteIndex % palettes.count + palettes.count) % palettes.count
        return palettes[safeIdx]
    }

    /// Internal rendering resolution for active ratio and orientation
    var outputSize: (w: Int, h: Int) {
        activeRatio.outputSize
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

    // MARK: — Zoom Actions

    func updateZoom(magnification: CGFloat) {
        let newZoom = max(1.0, min(baseZoomFactor * magnification, 6.0))
        zoomFactor = newZoom
    }

    func commitZoom() {
        baseZoomFactor = zoomFactor
    }

    // MARK: — Palette Actions

    func cyclePalette(forward: Bool) {
        let count = palettes.count
        guard count > 0 else { return }
        activePaletteIndex = (activePaletteIndex + (forward ? 1 : count - 1)) % count
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func generateRandomPalette() {
        let pal = HarmonicPaletteGenerator.generate(count: Int.random(in: 5...8))
        palettes.append(pal)
        Palette.savePalettes(palettes)
        activePaletteIndex = palettes.count - 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func addCustomPalette(_ palette: Palette) {
        palettes.append(palette)
        Palette.savePalettes(palettes)
        activePaletteIndex = palettes.count - 1
    }

    func deletePalette(id: String) {
        guard palettes.count > 1 else { return }
        palettes.removeAll { $0.id == id }
        Palette.savePalettes(palettes)
        if activePaletteIndex >= palettes.count {
            activePaletteIndex = max(0, palettes.count - 1)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    func updatePalette(_ palette: Palette) {
        if let idx = palettes.firstIndex(where: { $0.id == palette.id }) {
            palettes[idx] = palette
            Palette.savePalettes(palettes)
            activePaletteIndex = idx
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            addCustomPalette(palette)
        }
    }


    func renamePalette(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = palettes.firstIndex(where: { $0.id == id }) {
            palettes[idx] = palettes[idx].withName(trimmed)
            Palette.savePalettes(palettes)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    func resetPalettesToDefault() {
        palettes = Palette.resetToDefaults()
        activePaletteIndex = 0
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }


    // MARK: — Camera Controls

    func stepEV(up: Bool) {
        evBias = max(-2.0, min(2.0, evBias + (up ? 0.5 : -0.5)))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cycleRatio() {
        let all = AspectRatio.allCases
        if let idx = all.firstIndex(of: activeRatio) {
            activeRatio = all[(idx + 1) % all.count]
        } else {
            activeRatio = .ratio4_3
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

    /// Cycles self-timer between OFF (0s) → 3s → 10s.
    func cycleTimer() {
        switch timerDuration {
        case 0:  timerDuration = 3
        case 3:  timerDuration = 10
        default: timerDuration = 0
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Cycles date stamp between OFF → ORANGE → GREEN.
    func cycleDateStamp() {
        let all = DateStampMode.allCases
        if let idx = all.firstIndex(of: dateStampMode) {
            dateStampMode = all[(idx + 1) % all.count]
        } else {
            dateStampMode = .off
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
