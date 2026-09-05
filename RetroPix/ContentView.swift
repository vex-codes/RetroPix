// ContentView.swift
// RetroPix — Primary layout: Metal feed behind an orientation-adaptive retro OSD + control deck.
//
// Layout modes:
//   Landscape: TopOSDBar (40pt) → Viewfinder → Horizontal BottomDeck (72pt)
//   Portrait:  TopOSDBar (40pt) → Viewfinder → Multi-row Brutalist Control Deck

import AVFoundation
import Photos
import SwiftUI

// MARK: — Root

struct ContentView: View {
    @State private var vm            = CameraViewModel()
    @State private var cameraManager = CameraManager()
    @State private var renderer: MetalRenderer?
    @State private var isCapturing   = false
    @State private var showSettings  = false

    var body: some View {
        GeometryReader { geo in
            let isPortrait = geo.size.height > geo.size.width
            let orientation: UInt32 = isPortrait ? 1 : (UIDevice.current.orientation == .landscapeRight ? 2 : 0)

            ZStack(alignment: .top) {
                // ── 1. Black base ─────────────────────────────────────────────
                Color.black.ignoresSafeArea()

                // ── 2. Metal viewfinder ───────────────────────────────────────
                if let renderer {
                    MetalView(renderer: renderer)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // ── 3. OSD rails ──────────────────────────────────────────────
                if isPortrait {
                    VStack(spacing: 0) {
                        TopOSDBar(vm: vm, onMenu: { showSettings = true })

                        CrosshairOverlay()

                        Spacer()

                        PortraitDeck(vm: vm, onShutter: triggerCapture)
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    VStack(spacing: 0) {
                        TopOSDBar(vm: vm, onMenu: { showSettings = true })

                        CrosshairOverlay()

                        Spacer()

                        BottomDeck(vm: vm, onShutter: triggerCapture)
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .onAppear {
                vm.isPortrait = isPortrait
                vm.orientation = orientation
                updateRendererConfig()
            }
            .onChange(of: geo.size) { _, newSize in
                let portrait = newSize.height > newSize.width
                let orient: UInt32 = portrait ? 1 : (UIDevice.current.orientation == .landscapeRight ? 2 : 0)
                vm.isPortrait = portrait
                vm.orientation = orient
                updateRendererConfig()
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: setupRenderer)
        .onDisappear { cameraManager.stopSession() }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
        ) { _ in cameraManager.stopSession() }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        ) { _ in cameraManager.startSession() }
        .onReceive(
            NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
        ) { _ in
            let isPortrait = vm.isPortrait
            let orient: UInt32 = isPortrait ? 1 : (UIDevice.current.orientation == .landscapeRight ? 2 : 0)
            if vm.orientation != orient {
                vm.orientation = orient
                updateRendererConfig()
            }
        }
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
        renderer?.updateConfig(width: w, height: h, cropUV: crop, orientation: vm.orientation)
        renderer?.updatePalette(vm.activePalette)
        renderer?.ditherSpread = vm.ditherIntensity
    }

    // MARK: — Capture

    func triggerCapture() {
        guard !isCapturing, let renderer else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            try? await CaptureService.capture(from: renderer)
        }
    }
}

// MARK: — Top OSD bar

private struct TopOSDBar: View {
    var vm: CameraViewModel
    let onMenu: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            OSDPill()

            Spacer()

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
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(RetroTheme.green.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(RetroTheme.green.opacity(0.45), lineWidth: 1)
                            )
                    )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RetroTheme.bg.opacity(0.92))
    }
}

// MARK: — Bottom control deck (Landscape)

private struct BottomDeck: View {
    var vm: CameraViewModel
    let onShutter: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                PaletteCycler(vm: vm)
                RandButton { vm.generateRandomPalette() }
            }
            .frame(maxWidth: .infinity)

            DeckDivider()

            EVStepper(vm: vm)
                .frame(maxWidth: .infinity)

            DeckDivider()

            DiamondToggle(vm: vm)
                .frame(maxWidth: .infinity)

            DeckDivider()

            // Shutter
            VStack(spacing: 4) {
                ShutterButton(action: onShutter)
                Text("SHUTTER")
                    .font(RetroTheme.mono(7))
                    .foregroundStyle(RetroTheme.dimText)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 72)
        .background(RetroTheme.bg.opacity(0.92))
    }
}

// MARK: — Portrait Deck (4 rows)

private struct PortraitDeck: View {
    var vm: CameraViewModel
    let onShutter: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Row 1: Telemetry
            HStack {
                let (w, h) = vm.outputSize
                Text("\(w)×\(h)  \(vm.activeRatio.displayLabel)")
                    .font(RetroTheme.mono(9))
                    .foregroundStyle(RetroTheme.amber)
                Spacer()
                Text(String(format: "EV %+.1f  DITHER %@", vm.evBias, vm.ditherLabel))
                    .font(RetroTheme.mono(8, weight: .regular))
                    .foregroundStyle(RetroTheme.dimText)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Divider().background(RetroTheme.border)

            // Row 2: Palette Cycler + RAND button
            HStack(spacing: 10) {
                PaletteCycler(vm: vm)
                RandButton { vm.generateRandomPalette() }
            }
            .padding(.horizontal, 14)

            // Row 3: Exposure + Dither
            HStack(spacing: 0) {
                EVStepper(vm: vm)
                    .frame(maxWidth: .infinity)

                DeckDivider()

                DiamondToggle(vm: vm)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 44)

            // Row 4: Large centered Shutter
            VStack(spacing: 4) {
                ShutterButton(action: onShutter)
                Text("SHUTTER")
                    .font(RetroTheme.mono(7))
                    .foregroundStyle(RetroTheme.dimText)
            }
            .padding(.bottom, 24)
        }
        .background(RetroTheme.bg.opacity(0.95))
    }
}

// MARK: — Palette cycler  [<] NAME [>]

private struct PaletteCycler: View {
    var vm: CameraViewModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ArrowBtn(symbol: "<") { vm.cyclePalette(forward: false) }

                Text(vm.activePalette.name)
                    .font(RetroTheme.mono(10))
                    .foregroundStyle(.white)
                    .frame(minWidth: 72, alignment: .center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                ArrowBtn(symbol: ">") { vm.cyclePalette(forward: true) }
            }
            ColorSwatchBar(palette: vm.activePalette, height: 6)
                .padding(.horizontal, 6)
        }
    }
}

// MARK: — EV stepper  [-] EV: 0.0 [+]

private struct EVStepper: View {
    var vm: CameraViewModel

    var body: some View {
        HStack(spacing: 8) {
            ArrowBtn(symbol: "−") { vm.stepEV(up: false) }

            VStack(spacing: 1) {
                Text(String(format: "%+.1f", vm.evBias))
                    .font(RetroTheme.mono(13))
                    .foregroundStyle(RetroTheme.amber)
                    .frame(minWidth: 38, alignment: .center)
                Text("EV")
                    .font(RetroTheme.mono(7, weight: .regular))
                    .foregroundStyle(RetroTheme.dimText)
            }

            ArrowBtn(symbol: "+") { vm.stepEV(up: true) }
        }
    }
}

// MARK: — Dither intensity toggle (tap to cycle)

private struct DiamondToggle: View {
    var vm: CameraViewModel

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
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
    }
}

// MARK: — Small left/right arrow button

private struct ArrowBtn: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(symbol)
                .font(RetroTheme.mono(14))
                .foregroundStyle(RetroTheme.green)
                .frame(width: 30, height: 44)
        }
        .buttonStyle(.plain)
    }
}
