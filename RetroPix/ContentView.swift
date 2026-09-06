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

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let rotation = orientationObserver.uiRotationAngle

        ZStack {
            // Base background
            RetroTheme.bg.ignoresSafeArea()

            // Main vertical layout: Top Bar → Viewfinder Frame → Control Deck
            VStack(spacing: 0) {
                TopOSDBar(vm: vm, rotation: rotation, onMenu: { showSettings = true })

                // Viewfinder container: strict aspect ratio fit, pinch to zoom
                let (w, h) = vm.outputSize
                let aspect = CGFloat(w) / CGFloat(h)

                ZStack {
                    Color.black

                    if let renderer {
                        ZStack {
                            MetalView(renderer: renderer, isPaused: showSettings || scenePhase != .active)
                            CrosshairOverlay()

                            if let count = countdownRemaining {
                                CountdownOSDOverlay(remaining: count, rotation: rotation)
                            }
                        }
                        .aspectRatio(aspect, contentMode: .fit)
                        .clipped()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
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
                    onShutter: handleShutterTap
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
        updateRendererConfig()
    }

    private func updateRendererConfig() {
        let (w, h) = vm.outputSize
        let crop = vm.activeRatio.cropUV
        renderer?.updateConfig(width: w, height: h, cropUV: crop, orientation: 1)
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
    let rotation: Double
    let onMenu: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Aspect ratio quick switchers + self-timer
            HStack(spacing: 6) {
                ForEach(AspectRatio.allCases) { ratio in
                    RatioButton(
                        label: ratio.displayLabel,
                        isActive: vm.activeRatio == ratio
                    ) {
                        vm.activeRatio = ratio
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .rotationEffect(.degrees(rotation))
                }

                // Self-Timer Quick Button
                TimerButton(duration: vm.timerDuration, rotation: rotation) {
                    vm.cycleTimer()
                }
            }

            Spacer()

            // Menu button (three lines, square 28×28 so it never clips on rotation)
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
            .rotationEffect(.degrees(rotation))
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

    var body: some View {
        VStack(spacing: 10) {
            // Row 1: Telemetry (stays horizontal)
            HStack {
                let (w, h) = vm.outputSize
                Text("\(w)×\(h)  \(vm.activeRatio.displayLabel)")
                    .font(RetroTheme.mono(9))
                    .foregroundStyle(RetroTheme.amber)

                Spacer()

                let zoomStr = vm.zoomFactor > 1.05 ? String(format: "%.1f× ", vm.zoomFactor) : ""
                Text(String(format: "%@EV %+.1f  DITHER %@", zoomStr, vm.evBias, vm.ditherLabel))
                    .font(RetroTheme.mono(8, weight: .regular))
                    .foregroundStyle(RetroTheme.dimText)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Divider().background(RetroTheme.border)

            // Row 2: Palette Cycler (stays horizontal, does NOT rotate)
            PaletteCycler(vm: vm)
                .padding(.horizontal, 14)

            // Row 3: Exposure + Dither (rotates)
            HStack(spacing: 0) {
                EVStepper(vm: vm, rotation: rotation)
                    .frame(maxWidth: .infinity)

                DeckDivider()

                DiamondToggle(vm: vm, rotation: rotation)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 44)

            // Row 4: Flash (Left) | Shutter (Center)
            HStack(spacing: 0) {
                // Flash Toggle (Left)
                FlashButton(
                    isFlashOn: vm.isFlashOn,
                    isEnabled: cameraManager.hasTorch,
                    rotation: rotation
                ) {
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

                // Balanced spacer
                Color.clear
                    .frame(width: 64, height: 44)
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
    let rotation: Double
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
                .rotationEffect(.degrees(rotation))
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
