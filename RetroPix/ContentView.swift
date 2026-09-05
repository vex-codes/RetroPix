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

    var body: some View {
        let rotation = orientationObserver.uiRotationAngle

        ZStack {
            // Base background
            Color.black.ignoresSafeArea()

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
                            MetalView(renderer: renderer)
                            CrosshairOverlay()
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
                PortraitDeck(vm: vm, rotation: rotation, onShutter: triggerCapture)
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
        .onAppear {
            vm.isPortrait = true
            vm.orientation = 1
            setupRenderer()
        }
        .onDisappear {
            cameraManager.stopSession()
            orientationObserver.stop()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
        ) { _ in cameraManager.stopSession() }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        ) { _ in cameraManager.startSession() }
        // ── Wire ViewModel → Metal + Camera ──────────────────────────────────
        .onChange(of: vm.activePaletteIndex) { _, _ in
            renderer?.updatePalette(vm.activePalette)
        }
        .onChange(of: vm.ditherIntensity) { _, new in
            renderer?.ditherSpread = new
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
                orientation: orientationObserver.orientation
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
            // Aspect ratio quick switchers
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
            }

            Spacer()

            // Menu button
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onMenu()
            } label: {
                Text("≡ MENU")
                    .font(RetroTheme.mono(10))
                    .foregroundStyle(RetroTheme.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(RetroTheme.green.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(RetroTheme.green.opacity(0.45), lineWidth: 1)
                            )
                    )
            }
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
    let rotation: Double
    let onShutter: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            // Row 1: Telemetry (rotates)
            HStack {
                let (w, h) = vm.outputSize
                Text("\(w)×\(h)  \(vm.activeRatio.displayLabel)")
                    .font(RetroTheme.mono(9))
                    .foregroundStyle(RetroTheme.amber)
                    .rotationEffect(.degrees(rotation))

                Spacer()

                let zoomStr = vm.zoomFactor > 1.05 ? String(format: "%.1f× ", vm.zoomFactor) : ""
                Text(String(format: "%@EV %+.1f  DITHER %@", zoomStr, vm.evBias, vm.ditherLabel))
                    .font(RetroTheme.mono(8, weight: .regular))
                    .foregroundStyle(RetroTheme.dimText)
                    .rotationEffect(.degrees(rotation))
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

            // Row 4: Shutter (text removed)
            ShutterButton(action: onShutter)
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
                    .foregroundStyle(.white)
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

// MARK: — Shutter Audio Service (in-memory mechanical click)

final class ShutterAudioService: @unchecked Sendable {
    static let shared = ShutterAudioService()
    private var player: AVAudioPlayer?

    private init() {
        let wav = createShutterWav()
        player = try? AVAudioPlayer(data: wav)
        player?.prepareToPlay()
    }

    func play() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if let player, player.isPlaying {
            player.currentTime = 0
            player.play()
        } else {
            player?.play()
        }
        AudioServicesPlaySystemSound(1108)
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
