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

enum CameraEngineMode: String, CaseIterable, Identifiable, Codable {
    case pixel8Bit = "8-BIT"
    case aesthetic = "DIGICAM"

    var id: String { rawValue }
    var displayLabel: String { rawValue }
}

enum GridMode: String, CaseIterable, Identifiable, Codable {
    case off = "OFF"
    case ruleOfThirds = "3×3"
    case goldenSpiral = "PHI"

    var id: String { rawValue }
    var displayLabel: String { rawValue }
}

enum DitherAlgorithm: String, CaseIterable, Identifiable, Codable {
    case bayer8 = "BAYER 8×8"
    case blueNoise = "BLUE NOISE"
    case atkinson = "ATKINSON '84"
    case floydSteinberg = "F-STEINBERG"

    var id: String { rawValue }
    var displayLabel: String { rawValue }

    var rawIndex: UInt32 {
        switch self {
        case .bayer8: return 0
        case .blueNoise: return 1
        case .atkinson: return 2
        case .floydSteinberg: return 3
        }
    }
}

@Observable
final class CameraViewModel {
    var engineMode: CameraEngineMode = {
        if let saved = UserDefaults.standard.string(forKey: "cameraEngineMode"),
           let mode = CameraEngineMode(rawValue: saved) {
            return mode
        }
        return .pixel8Bit
    }() {
        didSet {
            UserDefaults.standard.set(engineMode.rawValue, forKey: "cameraEngineMode")
        }
    }

    var aestheticProfiles: [AestheticProfile] = AestheticProfile.allBuiltIn

    var activeAestheticProfileIndex: Int = {
        if let savedId = UserDefaults.standard.string(forKey: "activeAestheticProfileId"),
           let idx = AestheticProfile.allBuiltIn.firstIndex(where: { $0.id == savedId }) {
            return idx
        }
        return 0
    }() {
        didSet {
            if activeAestheticProfileIndex >= 0 && activeAestheticProfileIndex < aestheticProfiles.count {
                UserDefaults.standard.set(aestheticProfiles[activeAestheticProfileIndex].id, forKey: "activeAestheticProfileId")
            }
        }
    }

    var activeAestheticProfile: AestheticProfile {
        guard !aestheticProfiles.isEmpty else { return AestheticProfile.canonG7X }
        let safeIdx = (activeAestheticProfileIndex % aestheticProfiles.count + aestheticProfiles.count) % aestheticProfiles.count
        return aestheticProfiles[safeIdx]
    }
    var activePaletteIndex: Int = {
        let list = Palette.loadPalettes()
        if let savedId = UserDefaults.standard.string(forKey: "activePaletteId"),
           let idx = list.firstIndex(where: { $0.id == savedId }) {
            return idx
        }
        if let savedIdx = UserDefaults.standard.object(forKey: "activePaletteIndex") as? Int,
           savedIdx >= 0, savedIdx < list.count {
            return savedIdx
        }
        if let midnightIdx = list.firstIndex(where: { $0.id == "7mdnight" || $0.name == "7MDNIGHT" }) {
            return midnightIdx
        }
        return 0
    }() {
        didSet {
            UserDefaults.standard.set(activePaletteIndex, forKey: "activePaletteIndex")
            if activePaletteIndex >= 0 && activePaletteIndex < palettes.count {
                UserDefaults.standard.set(palettes[activePaletteIndex].id, forKey: "activePaletteId")
            }
        }
    }

    var evBias: Float = 0.0          // clamped -2.0 … +2.0 in 0.5 steps

    var ditherIntensity: Float = {
        if let saved = UserDefaults.standard.object(forKey: "ditherIntensity") as? Float {
            return saved
        }
        return 0.50
    }() {
        didSet {
            UserDefaults.standard.set(ditherIntensity, forKey: "ditherIntensity")
        }
    }

    var ditherAlgorithm: DitherAlgorithm = {
        if let saved = UserDefaults.standard.string(forKey: "ditherAlgorithm"),
           let alg = DitherAlgorithm(rawValue: saved) {
            return alg
        }
        return .bayer8
    }() {
        didSet {
            UserDefaults.standard.set(ditherAlgorithm.rawValue, forKey: "ditherAlgorithm")
        }
    }

    var activeRatio: AspectRatio = {
        if let saved = UserDefaults.standard.string(forKey: "activeRatio"),
           let ratio = AspectRatio(rawValue: saved) {
            return ratio
        }
        return .ratio4_3
    }() {
        didSet {
            if !isFrontCamera {
                UserDefaults.standard.set(activeRatio.rawValue, forKey: "activeRatio")
            }
        }
    }

    var isFrontCamera: Bool = false
    var isFrontCameraLocked: Bool { isFrontCamera }
    private var rearCameraRatio: AspectRatio = .ratio4_3

    func toggleCamera() {
        setFrontCamera(!isFrontCamera)
    }

    func setFrontCamera(_ front: Bool) {
        guard isFrontCamera != front else { return }
        isFrontCamera = front
        if front {
            rearCameraRatio = activeRatio
            activeRatio = .ratio4_3
            hasTorch = false
        } else {
            activeRatio = rearCameraRatio
            hasTorch = true
        }
    }

    func lockToFrontCamera() {
        setFrontCamera(true)
    }

    func unlockFromFrontCamera() {
        setFrontCamera(false)
    }

    var isPortrait: Bool = false
    var orientation: UInt32 = 0      // 0: landscape right, 1: portrait, 2: landscape left

    // Pinch-to-zoom state
    var zoomFactor: CGFloat = 1.0
    var baseZoomFactor: CGFloat = 1.0

    var palettes: [Palette] = Palette.loadPalettes()

    var isDarkMode: Bool = UserDefaults.standard.object(forKey: "isDarkMode") as? Bool ?? false {
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

    var frameBorderEnabled: Bool = UserDefaults.standard.object(forKey: "frameBorderEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(frameBorderEnabled, forKey: "frameBorderEnabled")
        }
    }

    var timerDuration: Int = UserDefaults.standard.object(forKey: "timerDuration") as? Int ?? 0 {
        didSet {
            UserDefaults.standard.set(timerDuration, forKey: "timerDuration")
        }
    }

    var gridMode: GridMode = {
        if let saved = UserDefaults.standard.string(forKey: "gridMode"),
           let mode = GridMode(rawValue: saved) {
            return mode
        }
        return .off
    }() {
        didSet {
            UserDefaults.standard.set(gridMode.rawValue, forKey: "gridMode")
        }
    }

    var hasTorch: Bool = true
    var isFrontFlashOn: Bool = false
    var isBackFlashOn: Bool = false

    /// Flash is available via physical torch on rear camera or Retina Screen Flash on front camera
    var isFlashAvailable: Bool {
        isFrontCamera ? true : hasTorch
    }

    var isFlashOn: Bool {
        get { isFrontCamera ? isFrontFlashOn : isBackFlashOn }
        set {
            if isFrontCamera {
                isFrontFlashOn = newValue
            } else {
                isBackFlashOn = newValue
            }
        }
    }

    var activePalette: Palette {
        guard !palettes.isEmpty else { return Palette.def }
        let safeIdx = (activePaletteIndex % palettes.count + palettes.count) % palettes.count
        return palettes[safeIdx]
    }

    /// Internal rendering resolution for active ratio, orientation, and engine mode
    var outputSize: (w: Int, h: Int) {
        switch engineMode {
        case .pixel8Bit:
            return activeRatio.outputSize
        case .aesthetic:
            return activeRatio.aestheticOutputSize
        }
    }

    /// Real-time human-readable label matching exact percentage or OFF.
    var ditherLabel: String {
        let percent = Int(round(ditherIntensity * 100))
        if percent <= 0 {
            return "OFF"
        } else {
            return "\(percent)%"
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
        let pal = HarmonicPaletteGenerator.generate(existingPalettes: palettes, count: Int.random(in: 6...8))
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
        if let midnightIdx = palettes.firstIndex(where: { $0.id == "7mdnight" || $0.name == "7MDNIGHT" }) {
            activePaletteIndex = midnightIdx
        } else {
            activePaletteIndex = 0
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }


    // MARK: — Camera Controls

    func stepEV(up: Bool) {
        evBias = max(-2.0, min(2.0, evBias + (up ? 0.5 : -0.5)))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func cycleRatio() {
        guard !isFrontCameraLocked else {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            return
        }
        let all = AspectRatio.allCases
        if let idx = all.firstIndex(of: activeRatio) {
            activeRatio = all[(idx + 1) % all.count]
        } else {
            activeRatio = .ratio4_3
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Cycles dither through OFF (0%) → 50% → 75% → 100% snap points.
    func cycleDither() {
        let steps: [Float] = [0.0, 0.5, 0.75, 1.0]
        if let next = steps.first(where: { $0 > ditherIntensity + 0.02 }) {
            ditherIntensity = next
        } else {
            ditherIntensity = 0.0
        }
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

    /// Cycles composition grid between OFF → 3×3 (Rule of Thirds) → PHI (Golden Spiral).
    func cycleGrid() {
        switch gridMode {
        case .off:          gridMode = .ruleOfThirds
        case .ruleOfThirds: gridMode = .goldenSpiral
        case .goldenSpiral: gridMode = .off
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

    /// Toggles between 8-BIT (Pixel) and DIGICAM (Aesthetic) computational engines.
    func cycleEngineMode() {
        engineMode = (engineMode == .pixel8Bit) ? .aesthetic : .pixel8Bit
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Cycles active aesthetic camera profile / film simulation.
    func cycleAestheticProfile(forward: Bool) {
        let count = aestheticProfiles.count
        guard count > 0 else { return }
        activeAestheticProfileIndex = (activeAestheticProfileIndex + (forward ? 1 : count - 1)) % count
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
