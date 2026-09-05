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
            if shutterFlash > 0 {
                Color.white
                    .opacity(shutterFlash)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
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

        // Play standard shutter click sound
        AudioServicesPlaySystemSound(1108)

        // Flash screen white
        shutterFlash = 0.95
        withAnimation(.easeOut(duration: 0.18)) {
            shutterFlash = 0.0
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
            // Row 1: Telemetry
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

            // Row 2: Palette Cycler
            PaletteCycler(vm: vm, rotation: rotation)
                .padding(.horizontal, 14)

            // Row 3: Exposure + Dither
            HStack(spacing: 0) {
                EVStepper(vm: vm, rotation: rotation)
                    .frame(maxWidth: .infinity)

                DeckDivider()

                DiamondToggle(vm: vm, rotation: rotation)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 44)

            // Row 4: Large centered Shutter
            VStack(spacing: 4) {
                ShutterButton(action: onShutter)
                Text("SHUTTER")
                    .font(RetroTheme.mono(7))
                    .foregroundStyle(RetroTheme.dimText)
                    .rotationEffect(.degrees(rotation))
            }
            .padding(.bottom, 24)
        }
        .background(RetroTheme.bg.opacity(0.95))
    }
}

// MARK: — Palette cycler  [<] NAME [>]

private struct PaletteCycler: View {
    var vm: CameraViewModel
    let rotation: Double

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ArrowBtn(symbol: "<", rotation: rotation) {
                    vm.cyclePalette(forward: false)
                }

                Text(vm.activePalette.name)
                    .font(RetroTheme.mono(11))
                    .foregroundStyle(.white)
                    .frame(minWidth: 90, alignment: .center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .rotationEffect(.degrees(rotation))

                ArrowBtn(symbol: ">", rotation: rotation) {
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
    let rotation: Double
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
