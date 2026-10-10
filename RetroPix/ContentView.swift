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
        GeometryReader { geo in
            let isLandscape = orientationObserver.isLandscape
            let isLandscapeLeft = orientationObserver.orientation == .landscapeLeft

            ZStack {
                // Base background
                RetroTheme.bg.ignoresSafeArea()

                if isLandscape {
                    LandscapeDigicamView(
                        vm: vm,
                        cameraManager: cameraManager,
                        renderer: renderer,
                        orientation: orientationObserver.orientation,
                        isCountingDown: countdownRemaining != nil,
                        isSwitchingCamera: isSwitchingCamera,
                        countdownRemaining: countdownRemaining,
                        onShutter: handleShutterTap,
                        onFlipCamera: handleCameraSwitch,
                        onMenu: { showSettings = true }
                    )
                    .frame(width: geo.size.height, height: geo.size.width)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .rotationEffect(.degrees(isLandscapeLeft ? 90 : -90))
                } else {
                    PortraitDigicamView(
                        vm: vm,
                        cameraManager: cameraManager,
                        renderer: renderer,
                        isCountingDown: countdownRemaining != nil,
                        isSwitchingCamera: isSwitchingCamera,
                        countdownRemaining: countdownRemaining,
                        onShutter: handleShutterTap,
                        onFlipCamera: handleCameraSwitch,
                        onMenu: { showSettings = true }
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                // Shutter white flash overlay
                Color.white
                    .opacity(shutterFlash)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(vm.isDarkMode ? .dark : .light)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: orientationObserver.isLandscape)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: orientationObserver.orientation)
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

// MARK: — Portrait Layout
private struct PortraitDigicamView: View {
    var vm: CameraViewModel
    var cameraManager: CameraManager
    var renderer: MetalRenderer?
    let isCountingDown: Bool
    let isSwitchingCamera: Bool
    let countdownRemaining: Int?
    let onShutter: () -> Void
    let onFlipCamera: () -> Void
    let onMenu: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TopOSDBar(vm: vm, onMenu: onMenu)

            // Viewfinder container: strict aspect ratio fit, pinch to zoom
            let (w, h) = vm.outputSize
            let aspect = CGFloat(w) / CGFloat(h)

            ZStack {
                Color.black

                if let renderer {
                    ZStack {
                        MetalView(renderer: renderer, isPaused: false)
                        CrosshairOverlay()

                        if vm.dateStampMode != .off {
                            ViewfinderQuartzDateStamp(mode: vm.dateStampMode, rotation: 0.0)
                        }

                        if let count = countdownRemaining {
                            CountdownOSDOverlay(remaining: count, rotation: 0.0)
                        }

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
                onFlipCamera()
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

            PortraitDeck(
                vm: vm,
                cameraManager: cameraManager,
                isCountingDown: isCountingDown,
                onShutter: onShutter,
                onFlipCamera: onFlipCamera
            )
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

// MARK: — Landscape Adaptive Digicam Layout
private struct LandscapeDigicamView: View {
    var vm: CameraViewModel
    var cameraManager: CameraManager
    var renderer: MetalRenderer?
    let orientation: DeviceOrientation
    let isCountingDown: Bool
    let isSwitchingCamera: Bool
    let countdownRemaining: Int?
    let onShutter: () -> Void
    let onFlipCamera: () -> Void
    let onMenu: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Left: Widescreen Viewfinder Frame
            let (w, h) = vm.outputSize
            let aspect = CGFloat(h) / CGFloat(w) // In landscape, aspect ratio is inverted (e.g. 240/180 = 4:3)

            ZStack {
                Color.black

                if let renderer {
                    GeometryReader { vgeo in
                        let frameW = vgeo.size.width
                        let frameH = vgeo.size.height

                        ZStack {
                            MetalView(renderer: renderer, isPaused: false)
                                .frame(width: frameH, height: frameW)
                                .position(x: frameW / 2, y: frameH / 2)
                                .rotationEffect(.degrees(orientation == .landscapeLeft ? 90 : -90))

                            CrosshairOverlay()

                            if vm.dateStampMode != .off {
                                ViewfinderQuartzDateStamp(mode: vm.dateStampMode, rotation: 0.0)
                            }

                            if let count = countdownRemaining {
                                CountdownOSDOverlay(remaining: count, rotation: 0.0)
                            }

                            Color.black
                                .opacity(isSwitchingCamera ? 1.0 : 0.0)
                                .animation(.easeInOut(duration: 0.12), value: isSwitchingCamera)
                        }
                    }
                    .aspectRatio(aspect, contentMode: .fit)
                    .clipped()
                }

                // Top OSD Telemetry Banner
                VStack {
                    HStack {
                        let modeCode = vm.engineMode == .pixel8Bit ? "" : " [\(vm.activeAestheticProfile.code)]"
                        let zoomStr = vm.zoomFactor > 1.05 ? String(format: "%.1f× ", vm.zoomFactor) : ""
                        Text("\(h)×\(w)  \(vm.activeRatio.displayLabel)\(modeCode)  \(zoomStr)EV \(String(format: "%+.1f", vm.evBias))")
                            .font(RetroTheme.mono(9))
                            .foregroundStyle(vm.engineMode == .pixel8Bit ? RetroTheme.amber : RetroTheme.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 3))

                        Spacer()
                    }
                    .padding(10)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onFlipCamera()
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

            // Right: Authentic Point-and-Shoot Camera Grip Deck
            LandscapeGripDeck(
                vm: vm,
                cameraManager: cameraManager,
                isCountingDown: isCountingDown,
                onShutter: onShutter,
                onFlipCamera: onFlipCamera,
                onMenu: onMenu
            )
            .frame(width: 154)
        }
        .background(RetroTheme.bg)
    }
}

// MARK: — Right-Hand Camera Grip Deck
private struct LandscapeGripDeck: View {
    var vm: CameraViewModel
    var cameraManager: CameraManager
    let isCountingDown: Bool
    let onShutter: () -> Void
    let onFlipCamera: () -> Void
    let onMenu: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Row 1: Engine Mode & Menu
            HStack(spacing: 6) {
                EngineModeButton(mode: vm.engineMode) {
                    vm.cycleEngineMode()
                }

                Spacer()

                Button(action: onMenu) {
                    VStack(spacing: 2.5) {
                        Rectangle().fill(RetroTheme.green).frame(width: 12, height: 1.5)
                        Rectangle().fill(RetroTheme.green).frame(width: 12, height: 1.5)
                        Rectangle().fill(RetroTheme.green).frame(width: 12, height: 1.5)
                    }
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(RetroTheme.green.opacity(0.07))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(RetroTheme.green.opacity(0.45), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
            .padding(.horizontal, 10)

            // Row 2: Aspect Ratios & Quick Timer
            HStack(spacing: 4) {
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

                Spacer()

                TimerButton(duration: vm.timerDuration) {
                    vm.cycleTimer()
                }
            }
            .padding(.horizontal, 10)

            Divider().background(RetroTheme.border)

            Spacer()

            // Row 3: Big Shutter Button
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

            // Row 4: Flash (Left) | Flip (Right)
            HStack(spacing: 12) {
                FlashButton(
                    isFlashOn: vm.isFlashOn,
                    isEnabled: vm.hasTorch
                ) {
                    guard vm.hasTorch else { return }
                    let state = cameraManager.toggleTorch()
                    vm.isFlashOn = state
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }

                CameraFlipButton(isFront: vm.isFrontCamera) {
                    onFlipCamera()
                }
            }
            .padding(.horizontal, 10)

            Divider().background(RetroTheme.border)

            // Row 5: Cycler
            if vm.engineMode == .pixel8Bit {
                PaletteCycler(vm: vm)
                    .padding(.horizontal, 8)
            } else {
                AestheticProfileCycler(vm: vm)
                    .padding(.horizontal, 8)
            }

            // Row 6: EV & Date/Dither
            HStack(spacing: 6) {
                EVStepper(vm: vm)
                    .frame(maxWidth: .infinity)

                DeckDivider()

                if vm.engineMode == .pixel8Bit {
                    DiamondToggle(vm: vm)
                        .frame(maxWidth: .infinity)
                } else {
                    DateStampToggle(vm: vm)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 38)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(RetroTheme.panel)
        .overlay(
            Rectangle()
                .fill(RetroTheme.border)
                .frame(width: 1),
            alignment: .leading
        )
    }
}

// MARK: — Top OSD bar

private struct TopOSDBar: View {
    var vm: CameraViewModel
    var rotation: Double = 0.0
    let onMenu: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Engine mode switcher + Aspect ratio quick switchers + self-timer
            HStack(spacing: 6) {
                EngineModeButton(mode: vm.engineMode, rotation: rotation) {
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
                TimerButton(duration: vm.timerDuration, rotation: rotation) {
                    vm.cycleTimer()
                }
            }

            Spacer()

            // Menu button (three lines, square 28×28)
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
    var rotation: Double = 0.0
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

            // Row 3: Exposure + Dither/Profile
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
    var rotation: Double = 0.0

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
    var rotation: Double = 0.0

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
    var rotation: Double = 0.0

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
    var rotation: Double = 0.0
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

// MARK: — Authentic 7-Segment Viewfinder Quartz Date Overlay

private struct ViewfinderQuartzDateStamp: View {
    let mode: DateStampMode
    var rotation: Double = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
            let stampText = formatDate(timeline.date)
            let stampH: CGFloat = 12.0
            let stampW = QuartzDateStampRenderer.calculateWidth(text: stampText, digitHeight: stampH)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    QuartzDateStampCanvas(
                        text: stampText,
                        color: (mode == .orange)
                            ? UIColor(red: 1.0, green: 0.48, blue: 0.02, alpha: 0.98)
                            : UIColor(red: 0.10, green: 0.98, blue: 0.38, alpha: 0.98)
                    )
                    .frame(width: stampW, height: stampH)
                    .rotationEffect(.degrees(rotation))
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                }
            }
            .allowsHitTesting(false)
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

