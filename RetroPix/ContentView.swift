// ContentView.swift
// RetroPix — Primary layout: Portrait-anchored retro OSD with Apple Camera-style icon rotation.

import AudioToolbox
import AVFoundation
import Photos
import SwiftUI

// MARK: — Root

struct ContentView: View {
    @State private var vm                  = CameraViewModel()
    @State private var cameraManager       = CameraManager()
    @State private var renderer: MetalRenderer?
    @State private var isCapturing         = false
    @State private var showSettings        = false
    @State private var shutterFlash        = 0.0
    @State private var orientationObserver = DeviceOrientationObserver()
    @State private var countdownRemaining: Int? = nil
    @State private var countdownTask: Task<Void, Never>? = nil
    @State private var isSwitchingCamera: Bool = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let rotation = orientationObserver.uiRotationAngle

        ZStack {
            // Base background
            RetroTheme.bg.ignoresSafeArea()

            // Main vertical layout: Top Bar → Viewfinder Frame → Control Deck
            VStack(spacing: 0) {
                TopOSDBar(vm: vm, onMenu: { showSettings = true })

                // Viewfinder container: strict aspect ratio fit, pinch to zoom
                let (w, h) = vm.outputSize
                let aspect = CGFloat(w) / CGFloat(h)

                ZStack {
                    Color.black

                    if let renderer {
                        ZStack {
                            MetalView(renderer: renderer, isPaused: showSettings || scenePhase != .active)
                            CrosshairOverlay()

                            if vm.gridMode != .off {
                                ViewfinderGridOverlay(mode: vm.gridMode)
                            }

                            if vm.dateStampMode != .off {
                                ViewfinderQuartzDateStamp(
                                    mode: vm.dateStampMode,
                                    orientation: orientationObserver.orientation,
                                    rotation: rotation
                                )
                            }

                            if let count = countdownRemaining {
                                CountdownOSDOverlay(remaining: count)
                            }

                            // Smooth blackout transition during camera switch to eliminate single-frame warp/flip glitches
                            Color.black
                                .opacity(isSwitchingCamera ? 1.0 : 0.0)
                                .animation(.easeInOut(duration: 0.12), value: isSwitchingCamera)
                        }
                        .aspectRatio(aspect, contentMode: .fit)
                        .clipped()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    handleCameraSwitch()
                }
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            vm.updateZoom(magnification: value)
                        }
                        .onEnded { _ in
                            vm.commitZoom()
                        }
                )

                // Bottom control deck
                PortraitDeck(
                    vm: vm,
                    cameraManager: cameraManager,
                    isCountingDown: countdownRemaining != nil,
                    rotation: rotation,
                    onShutter: handleShutterTap,
                    onFlipCamera: handleCameraSwitch
                )
            }
            .ignoresSafeArea(edges: .bottom)

            // Shutter white flash overlay
            Color.white
                .opacity(shutterFlash)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(vm.isDarkMode ? .dark : .light)
        .onAppear {
            vm.isPortrait = true
            vm.orientation = 1
            orientationObserver.start()
            setupRenderer()
            DispatchQueue.global(qos: .utility).async {
                _ = ShutterAudioService.shared
            }
            DispatchQueue.main.async {
                UIImpactFeedbackGenerator(style: .light).prepare()
            }
        }
        .onDisappear {
            cameraManager.stopSession()
            orientationObserver.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if !showSettings {
                    renderer?.isSuspended = false
                    cameraManager.startSession()
                    orientationObserver.start()
                }
            case .inactive, .background:
                renderer?.isSuspended = true
                cameraManager.stopSession()
                orientationObserver.stop()
            @unknown default:
                break
            }
        }
        .onChange(of: showSettings) { _, open in
            if open {
                cameraManager.stopSession()
                orientationObserver.stop()
            } else if scenePhase == .active {
                renderer?.updatePalette(vm.activePalette)
                cameraManager.startSession()
                orientationObserver.start()
            }
        }
        // ── Wire ViewModel → Metal + Camera ──────────────────────────────────
        .onChange(of: vm.engineMode) { _, newMode in
            renderer?.engineMode = newMode
            updateRendererConfig()
        }
        .onChange(of: vm.activeAestheticProfile) { _, newProfile in
            renderer?.activeAestheticProfile = newProfile
        }
        .onChange(of: vm.activeAestheticProfileIndex) { _, _ in
            renderer?.activeAestheticProfile = vm.activeAestheticProfile
        }
        .onChange(of: vm.activePalette) { _, newPalette in
            renderer?.updatePalette(newPalette)
        }
        .onChange(of: vm.activePaletteIndex) { _, _ in
            renderer?.updatePalette(vm.activePalette)
        }
        .onChange(of: vm.ditherIntensity) { _, new in
            renderer?.ditherSpread = new
        }
        .onChange(of: vm.ditherAlgorithm) { _, newAlg in
            renderer?.ditherAlgorithm = newAlg.rawIndex
        }
        .onChange(of: vm.evBias) { _, new in
            cameraManager.setExposureBias(new)
        }
        .onChange(of: vm.activeRatio) { _, _ in
            updateRendererConfig()
        }
        .onChange(of: vm.zoomFactor) { _, newZoom in
            cameraManager.setZoom(newZoom)
        }
        .sheet(isPresented: $showSettings) {
            CameraSettingsView(vm: vm)
        }
        .task { await CaptureService.requestPhotoPermissionIfNeeded() }
    }

    // MARK: — Setup & Config

    private func setupRenderer() {
        guard renderer == nil,
              let device = MTLCreateSystemDefaultDevice() else { return }
        cameraManager.setup(device: device)
        renderer = MetalRenderer(device: device, cameraManager: cameraManager)
        vm.hasTorch = !vm.isFrontCamera && cameraManager.hasTorch
        updateRendererConfig()
    }

    private func handleCameraSwitch() {
        guard !isSwitchingCamera else { return }
        isSwitchingCamera = true
        vm.toggleCamera()
        cameraManager.isFrontCamera = vm.isFrontCamera
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        cameraManager.switchCamera(toFront: vm.isFrontCamera) { actualFront in
            vm.hasTorch = actualFront ? false : cameraManager.hasTorch
            if actualFront {
                vm.isFlashOn = false
            }
            if actualFront != vm.isFrontCamera {
                vm.setFrontCamera(actualFront)
            }
            cameraManager.isFrontCamera = actualFront
            updateRendererConfig()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.easeInOut(duration: 0.12)) {
                    isSwitchingCamera = false
                }
            }
        }
    }

    private func updateRendererConfig() {
        let (w, h) = vm.outputSize
        let crop = vm.activeRatio.cropUV(isFrontCamera: vm.isFrontCamera)
        renderer?.engineMode = vm.engineMode
        renderer?.activeAestheticProfile = vm.activeAestheticProfile
        renderer?.updateConfig(width: w, height: h, cropUV: crop, orientation: 1, isFrontCamera: vm.isFrontCamera)
        renderer?.updatePalette(vm.activePalette)
        renderer?.ditherSpread = vm.ditherIntensity
        renderer?.ditherAlgorithm = vm.ditherAlgorithm.rawIndex
    }

    // MARK: — Shutter & Timer Handling

    private func handleShutterTap() {
        if countdownRemaining != nil {
            cancelCountdown()
            return
        }

        if vm.timerDuration > 0 {
            startCountdown(seconds: vm.timerDuration)
        } else {
            triggerCapture()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func startCountdown(seconds: Int) {
        countdownRemaining = seconds
        countdownTask = Task { @MainActor in
            var remaining = seconds
            while remaining > 0 {
                let isUrgent = remaining <= 3
                ShutterAudioService.shared.playBeep(urgent: isUrgent)
                countdownRemaining = remaining

                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }

                if Task.isCancelled { return }
                remaining -= 1
            }

            countdownRemaining = nil
            ShutterAudioService.shared.playBeep(urgent: true)
            try? await Task.sleep(nanoseconds: 100_000_000)
            triggerCapture()
        }
    }

    // MARK: — Capture

    func triggerCapture() {
        guard !isCapturing, let renderer else { return }
        isCapturing = true

        // Play authentic mechanical shutter click
        ShutterAudioService.shared.play()

        // Screen white flash: high opacity immediately, fade out smoothly on next tick
        shutterFlash = 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.22)) {
                shutterFlash = 0.0
            }
        }

        Task {
            defer { isCapturing = false }
            try? await CaptureService.capture(
                from: renderer,
                orientation: orientationObserver.orientation,
                dateStampMode: vm.dateStampMode,
                frameBorderEnabled: vm.frameBorderEnabled
            )
        }
    }
}

// MARK: — Top OSD bar

private struct TopOSDBar: View {
    var vm: CameraViewModel
    let onMenu: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Engine mode switcher + Aspect ratio quick switchers + self-timer
            HStack(spacing: 6) {
                EngineModeButton(mode: vm.engineMode) {
                    vm.cycleEngineMode()
                }

                Rectangle()
                    .fill(RetroTheme.border)
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 1)

                if vm.isFrontCameraLocked {
                    RatioButton(
                        label: AspectRatio.ratio4_3.displayLabel,
                        isActive: true
                    ) {
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    }
                } else {
                    ForEach(AspectRatio.allCases) { ratio in
                        RatioButton(
                            label: ratio.displayLabel,
                            isActive: vm.activeRatio == ratio
                        ) {
                            vm.activeRatio = ratio
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                }

                // Self-Timer Quick Button
                TimerButton(duration: vm.timerDuration) {
                    vm.cycleTimer()
                }

                // Composition Grid Quick Button (3×3 / PHI)
                GridButton(mode: vm.gridMode) {
                    vm.cycleGrid()
                }
            }

            Spacer()

            // Menu button (three lines)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onMenu()
            } label: {
                VStack(spacing: 3) {
                    Rectangle().fill(RetroTheme.green).frame(width: 14, height: 1.5)
                    Rectangle().fill(RetroTheme.green).frame(width: 14, height: 1.5)
                    Rectangle().fill(RetroTheme.green).frame(width: 14, height: 1.5)
                }
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(RetroTheme.green.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(RetroTheme.green.opacity(0.45), lineWidth: 1)
                        )
                )
            }
            .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RetroTheme.bg.opacity(0.95))
    }
}

// MARK: — Bottom control deck

private struct PortraitDeck: View {
    var vm: CameraViewModel
    var cameraManager: CameraManager
    let isCountingDown: Bool
    let rotation: Double
    let onShutter: () -> Void
    let onFlipCamera: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            // Row 1: Telemetry (stays horizontal)
            HStack {
                let (w, h) = vm.outputSize
                let modeCode = vm.engineMode == .pixel8Bit ? "" : " [\(vm.activeAestheticProfile.code)]"
                Text("\(w)×\(h)  \(vm.activeRatio.displayLabel)\(modeCode)")
                    .font(RetroTheme.mono(9))
                    .foregroundStyle(vm.engineMode == .pixel8Bit ? RetroTheme.amber : RetroTheme.red)

                Spacer()

                let zoomStr = vm.zoomFactor > 1.05 ? String(format: "%.1f× ", vm.zoomFactor) : ""
                if vm.engineMode == .pixel8Bit {
                    Text(String(format: "%@EV %+.1f  DITHER %@", zoomStr, vm.evBias, vm.ditherLabel))
                        .font(RetroTheme.mono(8, weight: .regular))
                        .foregroundStyle(RetroTheme.dimText)
                } else {
                    Text(String(format: "%@EV %+.1f  %@ '%@", zoomStr, vm.evBias, vm.activeAestheticProfile.category.rawValue, vm.activeAestheticProfile.eraYear))
                        .font(RetroTheme.mono(8, weight: .regular))
                        .foregroundStyle(RetroTheme.dimText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Divider().background(RetroTheme.border)

            // Row 2: Cycler (Palette in 8-bit, Aesthetic profile in digicam)
            if vm.engineMode == .pixel8Bit {
                PaletteCycler(vm: vm)
                    .padding(.horizontal, 14)
            } else {
                AestheticProfileCycler(vm: vm)
                    .padding(.horizontal, 14)
            }

            // Row 3: Exposure + Dither/Profile (rotates)
            HStack(spacing: 0) {
                EVStepper(vm: vm, rotation: rotation)
                    .frame(maxWidth: .infinity)

                DeckDivider()

                if vm.engineMode == .pixel8Bit {
                    DiamondToggle(vm: vm, rotation: rotation)
                        .frame(maxWidth: .infinity)
                } else {
                    DateStampToggle(vm: vm, rotation: rotation)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 44)

            // Row 4: Flash (Left) | Shutter (Center)
            HStack(spacing: 0) {
                // Flash Toggle (Left)
                FlashButton(
                    isFlashOn: vm.isFlashOn,
                    isEnabled: vm.hasTorch,
                    rotation: rotation
                ) {
                    guard vm.hasTorch else { return }
                    let state = cameraManager.toggleTorch()
                    vm.isFlashOn = state
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                .frame(width: 64, alignment: .center)

                Spacer()

                // Shutter Button (Center)
                ZStack {
                    ShutterButton(action: onShutter)

                    if isCountingDown {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(RetroTheme.red)
                            .frame(width: 14, height: 14)
                            .allowsHitTesting(false)
                    }
                }

                Spacer()

                // Flip Camera (Right) — matching 64pt width, alignment & padding as FlashButton
                CameraFlipButton(
                    isFront: vm.isFrontCamera,
                    rotation: rotation
                ) {
                    onFlipCamera()
                }
                .frame(width: 64, alignment: .center)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 24)
        }
        .background(RetroTheme.bg.opacity(0.95))
    }
}

// MARK: — Palette cycler  [<] NAME [>] (stays horizontal)

private struct PaletteCycler: View {
    var vm: CameraViewModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ArrowBtn(symbol: "<") {
                    vm.cyclePalette(forward: false)
                }

                Text(vm.activePalette.name)
                    .font(RetroTheme.mono(11))
                    .foregroundStyle(RetroTheme.text)
                    .frame(minWidth: 90, alignment: .center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                ArrowBtn(symbol: ">") {
                    vm.cyclePalette(forward: true)
                }
            }
            ColorSwatchBar(palette: vm.activePalette, height: 6)
                .padding(.horizontal, 6)
        }
    }
}

// MARK: — Aesthetic profile cycler [<] CANON G7 X [>] (stays horizontal)

private struct AestheticProfileCycler: View {
    var vm: CameraViewModel

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                ArrowBtn(symbol: "<") {
                    vm.cycleAestheticProfile(forward: false)
                }

                VStack(spacing: 1) {
                    Text(vm.activeAestheticProfile.name)
                        .font(RetroTheme.mono(11))
                        .foregroundStyle(RetroTheme.red)
                        .frame(minWidth: 150, alignment: .center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text("\(vm.activeAestheticProfile.subtitle.uppercased()) • \(vm.activeAestheticProfile.eraYear)")
                        .font(RetroTheme.mono(7, weight: .regular))
                        .foregroundStyle(RetroTheme.dimText)
                        .lineLimit(1)
                }

                ArrowBtn(symbol: ">") {
                    vm.cycleAestheticProfile(forward: true)
                }
            }

            // Category & Code Pill Bar
            HStack(spacing: 6) {
                Text(vm.activeAestheticProfile.category.rawValue)
                    .font(RetroTheme.mono(7, weight: .bold))
                    .foregroundStyle(RetroTheme.amber)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(RetroTheme.amber.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(RetroTheme.amber.opacity(0.4), lineWidth: 0.5))
                    )

                Text(vm.activeAestheticProfile.code)
                    .font(RetroTheme.mono(7, weight: .bold))
                    .foregroundStyle(RetroTheme.dimText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(RetroTheme.border, lineWidth: 0.5)
                    )

                Text(String(format: "GRAIN %d%%", Int(round(vm.activeAestheticProfile.grainAmount * 100))))
                    .font(RetroTheme.mono(7, weight: .regular))
                    .foregroundStyle(RetroTheme.dimText)
            }
        }
    }
}

// MARK: — EV stepper  [-] EV: 0.0 [+]

private struct EVStepper: View {
    var vm: CameraViewModel
    let rotation: Double

    var body: some View {
        HStack(spacing: 8) {
            ArrowBtn(symbol: "−", rotation: rotation) {
                vm.stepEV(up: false)
            }

            VStack(spacing: 1) {
                Text(String(format: "%+.1f", vm.evBias))
                    .font(RetroTheme.mono(13))
                    .foregroundStyle(RetroTheme.amber)
                    .frame(minWidth: 38, alignment: .center)
                Text("EV")
                    .font(RetroTheme.mono(7, weight: .regular))
                    .foregroundStyle(RetroTheme.dimText)
            }
            .rotationEffect(.degrees(rotation))

            ArrowBtn(symbol: "+", rotation: rotation) {
                vm.stepEV(up: true)
            }
        }
    }
}

// MARK: — Dither intensity toggle (tap to cycle)

private struct DiamondToggle: View {
    var vm: CameraViewModel
    let rotation: Double

    var body: some View {
        Button(action: vm.cycleDither) {
            VStack(spacing: 3) {
                Text(vm.ditherLabel)
                    .font(RetroTheme.mono(14))
                    .foregroundStyle(vm.ditherIntensity == 0 ? RetroTheme.dimText : RetroTheme.green)
                Text("DITHER")
                    .font(RetroTheme.mono(7, weight: .regular))
                    .foregroundStyle(RetroTheme.dimText)
            }
            .rotationEffect(.degrees(rotation))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
    }
}

// MARK: — 90s Quartz Date Stamp Toggle (tap to cycle: OFF → ORG → GRN)

private struct DateStampToggle: View {
    var vm: CameraViewModel
    let rotation: Double

    var body: some View {
        Button(action: vm.cycleDateStamp) {
            VStack(spacing: 3) {
                Text(label)
                    .font(RetroTheme.mono(13))
                    .foregroundStyle(tintColor)
                Text("DATE")
                    .font(RetroTheme.mono(7, weight: .regular))
                    .foregroundStyle(RetroTheme.dimText)
            }
            .rotationEffect(.degrees(rotation))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
    }

    private var label: String {
        switch vm.dateStampMode {
        case .off: return "OFF"
        case .orange: return "'98 ORG"
        case .green: return "'98 GRN"
        }
    }

    private var tintColor: Color {
        switch vm.dateStampMode {
        case .off: return RetroTheme.dimText
        case .orange: return RetroTheme.amber
        case .green: return RetroTheme.green
        }
    }
}

// MARK: — Small left/right arrow button

private struct ArrowBtn: View {
    let symbol: String
    var rotation: Double = 0.0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(symbol)
                .font(RetroTheme.mono(14))
                .foregroundStyle(RetroTheme.green)
                .frame(width: 32, height: 44)
                .rotationEffect(.degrees(rotation))
        }
        .buttonStyle(.plain)
    }
}

// MARK: — Blinking Countdown OSD Overlay

private struct CountdownOSDOverlay: View {
    let remaining: Int
    @State private var isBlinking = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)

            // Large blinking phosphor numeral
            Text("\(remaining)")
                .font(RetroTheme.mono(96, weight: .heavy))
                .foregroundStyle(remaining <= 3 ? RetroTheme.amber : RetroTheme.green)
                .scaleEffect(isBlinking ? 1.08 : 0.95)
                .shadow(color: (remaining <= 3 ? RetroTheme.amber : RetroTheme.green).opacity(0.8), radius: 14)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                isBlinking = true
            }
        }
    }
}

// MARK: — Shutter Audio Service (in-memory mechanical click + retro timer beeps)

final class ShutterAudioService: @unchecked Sendable {
    static let shared = ShutterAudioService()
    private var shutterPlayer: AVAudioPlayer?
    private var normalBeepPlayer: AVAudioPlayer?
    private var urgentBeepPlayer: AVAudioPlayer?

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let wav = createShutterWav()
        shutterPlayer = try? AVAudioPlayer(data: wav)
        shutterPlayer?.prepareToPlay()

        let normalWav = createToneWav(freq: 1200.0, duration: 0.05)
        normalBeepPlayer = try? AVAudioPlayer(data: normalWav)
        normalBeepPlayer?.prepareToPlay()

        let urgentWav = createToneWav(freq: 2400.0, duration: 0.045)
        urgentBeepPlayer = try? AVAudioPlayer(data: urgentWav)
        urgentBeepPlayer?.prepareToPlay()
    }

    func play() {
        if let shutterPlayer {
            shutterPlayer.currentTime = 0
            shutterPlayer.play()
        }
        AudioServicesPlaySystemSound(1108)
    }

    func playBeep(urgent: Bool = false) {
        let p = urgent ? urgentBeepPlayer : normalBeepPlayer
        if let p {
            p.currentTime = 0
            p.play()
        }
        UIImpactFeedbackGenerator(style: urgent ? .rigid : .light).impactOccurred()
    }

    private func createToneWav(freq: Double, duration: Double) -> Data {
        let sampleRate: Int32 = 44100
        let numSamples = Int(Double(sampleRate) * duration)
        var samples = [Int16](repeating: 0, count: numSamples)

        for i in 0..<numSamples {
            let t = Double(i) / Double(sampleRate)
            let attack = min(1.0, t / 0.005)
            let decay = min(1.0, (duration - t) / 0.005)
            let envelope = attack * decay
            let s = sin(2.0 * .pi * freq * t) * envelope * 0.75
            samples[i] = Int16(s * 32767.0)
        }

        var data = Data()
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        let fileSize = Int32(36 + numSamples * 2)
        withUnsafeBytes(of: fileSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [UInt8]("WAVEfmt ".utf8))
        let subchunk1Size: Int32 = 16
        withUnsafeBytes(of: subchunk1Size.littleEndian) { data.append(contentsOf: $0) }
        let audioFormat: Int16 = 1
        withUnsafeBytes(of: audioFormat.littleEndian) { data.append(contentsOf: $0) }
        let numChannels: Int16 = 1
        withUnsafeBytes(of: numChannels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { data.append(contentsOf: $0) }
        let byteRate = sampleRate * 2
        withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
        let blockAlign: Int16 = 2
        withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
        let bitsPerSample: Int16 = 16
        withUnsafeBytes(of: bitsPerSample.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [UInt8]("data".utf8))
        let dataSize = Int32(numSamples * 2)
        withUnsafeBytes(of: dataSize.littleEndian) { data.append(contentsOf: $0) }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private func createShutterWav() -> Data {
        let sampleRate: Int32 = 44100
        let duration: Double = 0.085
        let numSamples = Int(Double(sampleRate) * duration)
        var samples = [Int16](repeating: 0, count: numSamples)

        for i in 0..<numSamples {
            let t = Double(i) / Double(sampleRate)
            var s: Double = 0
            if t < 0.02 {
                let decay = exp(-t * 350.0)
                let freq = 1400.0 - t * 30000.0
                let noise = Double.random(in: -0.3...0.3)
                s += (sin(2.0 * .pi * freq * t) + noise) * decay * 0.95
            }
            if t >= 0.032 && t < 0.075 {
                let dt = t - 0.032
                let decay = exp(-dt * 250.0)
                let freq = 900.0 - dt * 15000.0
                let noise = Double.random(in: -0.2...0.2)
                s += (sin(2.0 * .pi * freq * dt) + noise) * decay * 0.9
            }
            s = max(-1.0, min(1.0, s))
            samples[i] = Int16(s * 32767.0)
        }

        var data = Data()
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        let fileSize = Int32(36 + numSamples * 2)
        withUnsafeBytes(of: fileSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [UInt8]("WAVEfmt ".utf8))
        let subchunk1Size: Int32 = 16
        withUnsafeBytes(of: subchunk1Size.littleEndian) { data.append(contentsOf: $0) }
        let audioFormat: Int16 = 1
        withUnsafeBytes(of: audioFormat.littleEndian) { data.append(contentsOf: $0) }
        let numChannels: Int16 = 1
        withUnsafeBytes(of: numChannels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { data.append(contentsOf: $0) }
        let byteRate = sampleRate * 2
        withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
        let blockAlign: Int16 = 2
        withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
        let bitsPerSample: Int16 = 16
        withUnsafeBytes(of: bitsPerSample.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [UInt8]("data".utf8))
        let dataSize = Int32(numSamples * 2)
        withUnsafeBytes(of: dataSize.littleEndian) { data.append(contentsOf: $0) }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

// MARK: — Authentic 7-Segment Viewfinder Quartz Date Overlay

private struct ViewfinderQuartzDateStamp: View {
    let mode: DateStampMode
    let orientation: DeviceOrientation
    let rotation: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
            let stampText = formatDate(timeline.date)
            let stampH: CGFloat = 12.0
            let stampW = QuartzDateStampRenderer.calculateWidth(text: stampText, digitHeight: stampH)

            let isQuarterTurn = (orientation == .landscapeLeft || orientation == .landscapeRight)
            let boxW = isQuarterTurn ? stampH : stampW
            let boxH = isQuarterTurn ? stampW : stampH

            ZStack(alignment: stampAlignment) {
                Color.clear

                QuartzDateStampCanvas(
                    text: stampText,
                    color: (mode == .orange)
                        ? UIColor(red: 1.0, green: 0.48, blue: 0.02, alpha: 0.98)
                        : UIColor(red: 0.10, green: 0.98, blue: 0.38, alpha: 0.98)
                )
                .frame(width: stampW, height: stampH)
                .rotationEffect(.degrees(rotation))
                .frame(width: boxW, height: boxH)
                .padding(stampPaddingEdges, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: orientation)
            .allowsHitTesting(false)
        }
    }

    private var stampAlignment: Alignment {
        switch orientation {
        case .portrait: return .bottomTrailing
        case .landscapeLeft: return .bottomLeading
        case .landscapeRight: return .topTrailing
        case .portraitUpsideDown: return .topLeading
        }
    }

    private var stampPaddingEdges: Edge.Set {
        switch orientation {
        case .portrait: return [.bottom, .trailing]
        case .landscapeLeft: return [.bottom, .leading]
        case .landscapeRight: return [.top, .trailing]
        case .portraitUpsideDown: return [.top, .leading]
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "''yy MM dd  HH:mm"
        return formatter.string(from: date)
    }
}

private struct QuartzDateStampCanvas: UIViewRepresentable {
    let text: String
    let color: UIColor

    func makeUIView(context: Context) -> QuartzDateStampUIView {
        let v = QuartzDateStampUIView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.text = text
        v.color = color
        return v
    }

    func updateUIView(_ uiView: QuartzDateStampUIView, context: Context) {
        if uiView.text != text || uiView.color != color {
            uiView.text = text
            uiView.color = color
            uiView.setNeedsDisplay()
        }
    }
}

private final class QuartzDateStampUIView: UIView {
    var text: String = ""
    var color: UIColor = .orange

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !text.isEmpty else { return }
        let h = rect.height
        QuartzDateStampRenderer.draw(
            text: text,
            in: ctx,
            origin: CGPoint(x: 0, y: 0),
            digitHeight: h,
            color: color,
            withGhosting: true
        )
    }
}

// MARK: — Viewfinder Composition Grid (Rule of Thirds & Golden Fibonacci Spiral)

private struct ViewfinderGridOverlay: View {
    let mode: GridMode

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            guard w > 10, h > 10 else { return }

            switch mode {
            case .off:
                break

            case .ruleOfThirds:
                drawRuleOfThirds(in: ctx, size: size)

            case .goldenSpiral:
                drawGoldenSpiral(in: ctx, size: size)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawRuleOfThirds(in ctx: GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        let x1 = w / 3.0
        let x2 = w * 2.0 / 3.0
        let y1 = h / 3.0
        let y2 = h * 2.0 / 3.0

        // 1. Grid dividing lines with subtle shadow for visibility against light & dark scenes
        var gridLines = Path()
        gridLines.move(to: CGPoint(x: x1, y: 0)); gridLines.addLine(to: CGPoint(x: x1, y: h))
        gridLines.move(to: CGPoint(x: x2, y: 0)); gridLines.addLine(to: CGPoint(x: x2, y: h))
        gridLines.move(to: CGPoint(x: 0, y: y1)); gridLines.addLine(to: CGPoint(x: w, y: y1))
        gridLines.move(to: CGPoint(x: 0, y: y2)); gridLines.addLine(to: CGPoint(x: w, y: y2))

        var shadowLines = Path()
        shadowLines.move(to: CGPoint(x: x1, y: 0.5)); shadowLines.addLine(to: CGPoint(x: x1, y: h))
        shadowLines.move(to: CGPoint(x: x2, y: 0.5)); shadowLines.addLine(to: CGPoint(x: x2, y: h))
        shadowLines.move(to: CGPoint(x: 0, y: y1 + 0.5)); shadowLines.addLine(to: CGPoint(x: w, y: y1 + 0.5))
        shadowLines.move(to: CGPoint(x: 0, y: y2 + 0.5)); shadowLines.addLine(to: CGPoint(x: w, y: y2 + 0.5))

        ctx.stroke(shadowLines, with: .color(Color.black.opacity(0.40)), lineWidth: 1.0)
        ctx.stroke(gridLines, with: .color(Color.white.opacity(0.60)), lineWidth: 0.75)

        // 2. Power point crosshairs at the 4 Rule of Thirds intersections
        let tick: CGFloat = 6.0
        var ticks = Path()
        for px in [x1, x2] {
            for py in [y1, y2] {
                ticks.move(to: CGPoint(x: px - tick, y: py)); ticks.addLine(to: CGPoint(x: px + tick, y: py))
                ticks.move(to: CGPoint(x: px, y: py - tick)); ticks.addLine(to: CGPoint(x: px, y: py + tick))
            }
        }
        ctx.stroke(ticks, with: .color(Color.black.opacity(0.40)), lineWidth: 1.5)
        ctx.stroke(ticks, with: .color(Color.white.opacity(0.85)), lineWidth: 1.0)

        // 3. Center leveling crosshair
        let cx = w / 2.0
        let cy = h / 2.0
        let centerArm: CGFloat = 7.0
        var centerCross = Path()
        centerCross.move(to: CGPoint(x: cx - centerArm, y: cy)); centerCross.addLine(to: CGPoint(x: cx + centerArm, y: cy))
        centerCross.move(to: CGPoint(x: cx, y: cy - centerArm)); centerCross.addLine(to: CGPoint(x: cx, y: cy + centerArm))
        ctx.stroke(centerCross, with: .color(Color.black.opacity(0.40)), lineWidth: 1.5)
        ctx.stroke(centerCross, with: .color(Color.white.opacity(0.70)), lineWidth: 1.0)
    }

    private func drawGoldenSpiral(in ctx: GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        let phi: CGFloat = (1.0 + sqrt(5.0)) / 2.0
        let isLandscape = w > h

        // Recursive golden rectangle subdivision in portrait [0, 0, 1, phi]
        // or rotated for landscape [0, 0, phi, 1]
        var rx0: CGFloat = 0.0
        var ry0: CGFloat = 0.0
        var rx1: CGFloat = 1.0
        var ry1: CGFloat = phi

        var boxesPath = Path()
        var spiralPath = Path()

        var firstPoint = true
        var lastScreenPt = CGPoint.zero

        for k in 0..<8 {
            let r = 1.0 / pow(phi, CGFloat(k))
            let cut = k % 4
            let sqX0: CGFloat
            let sqY0: CGFloat
            let sqX1: CGFloat
            let sqY1: CGFloat
            let centerX: CGFloat
            let centerY: CGFloat

            switch cut {
            case 0: // top
                sqX0 = rx0; sqY0 = ry0; sqX1 = rx0 + r; sqY1 = ry0 + r
                centerX = rx0; centerY = ry0 + r
                ry0 += r
            case 1: // right
                sqX0 = rx1 - r; sqY0 = ry0; sqX1 = rx1; sqY1 = ry0 + r
                centerX = rx1 - r; centerY = ry0
                rx1 -= r
            case 2: // bottom
                sqX0 = rx1 - r; sqY0 = ry1 - r; sqX1 = rx1; sqY1 = ry1
                centerX = rx1; centerY = ry1 - r
                ry1 -= r
            default: // left
                sqX0 = rx0; sqY0 = ry1 - r; sqX1 = rx0 + r; sqY1 = ry1
                centerX = rx0 + r; centerY = ry1
                rx0 += r
            }

            // Screen box: mirrored horizontally so spiral curls naturally into lower-right golden section
            let boxRect: CGRect
            if isLandscape {
                boxRect = CGRect(
                    x: (1.0 - sqY1 / phi) * w,
                    y: sqX0 * h,
                    width: ((sqY1 - sqY0) / phi) * w,
                    height: (sqX1 - sqX0) * h
                )
            } else {
                boxRect = CGRect(
                    x: (1.0 - sqX1) * w,
                    y: (sqY0 / phi) * h,
                    width: (sqX1 - sqX0) * w,
                    height: ((sqY1 - sqY0) / phi) * h
                )
            }
            boxesPath.addRect(boxRect)

            // Sample quarter-circle arc with C^1 continuous tangent connection
            let startDeg = Double((k - 1) * 90)
            let endDeg = Double(k * 90)
            let segments = 24

            for s in 0...segments {
                let frac = Double(s) / Double(segments)
                let angleRad = (startDeg + (endDeg - startDeg) * frac) * .pi / 180.0
                let px = centerX + r * CGFloat(cos(angleRad))
                let py = centerY + r * CGFloat(sin(angleRad))

                let screenPt: CGPoint
                if isLandscape {
                    screenPt = CGPoint(x: (1.0 - py / phi) * w, y: px * h)
                } else {
                    screenPt = CGPoint(x: (1.0 - px) * w, y: (py / phi) * h)
                }

                if firstPoint {
                    spiralPath.move(to: screenPt)
                    firstPoint = false
                } else {
                    spiralPath.addLine(to: screenPt)
                }
                lastScreenPt = screenPt
            }
        }

        // 1. Harmonic subdivision boxes
        ctx.stroke(boxesPath, with: .color(Color.black.opacity(0.35)), lineWidth: 1.0)
        ctx.stroke(boxesPath, with: .color(Color.white.opacity(0.28)), lineWidth: 0.6)

        // 2. Smooth continuous Golden Spiral curve
        ctx.stroke(spiralPath, with: .color(Color.black.opacity(0.45)), lineWidth: 2.2)
        ctx.stroke(spiralPath, with: .color(RetroTheme.amber.opacity(0.90)), lineWidth: 1.4)

        // 3. Golden Eye focal marker (+)
        let eyeArm: CGFloat = 5.0
        var eyeCross = Path()
        eyeCross.move(to: CGPoint(x: lastScreenPt.x - eyeArm, y: lastScreenPt.y))
        eyeCross.addLine(to: CGPoint(x: lastScreenPt.x + eyeArm, y: lastScreenPt.y))
        eyeCross.move(to: CGPoint(x: lastScreenPt.x, y: lastScreenPt.y - eyeArm))
        eyeCross.addLine(to: CGPoint(x: lastScreenPt.x, y: lastScreenPt.y + eyeArm))
        ctx.stroke(eyeCross, with: .color(Color.black.opacity(0.40)), lineWidth: 1.5)
        ctx.stroke(eyeCross, with: .color(RetroTheme.amber), lineWidth: 1.0)
    }
}

