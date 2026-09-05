// ContentView.swift
// RetroPix — Primary layout: Metal feed behind a retro OSD + control deck.
//
// Structure (landscape):
//   TopOSDBar  (40pt) — status pill, telemetry, menu button
//   ZStack     (flex) — MetalView fullscreen + crosshair overlay
//   BottomDeck (72pt) — palette cycler | EV stepper | dither toggle | shutter

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
        ZStack(alignment: .top) {
            // ── 1. Black base (visible while camera initialises) ──────────────
            Color.black.ignoresSafeArea()

            // ── 2. Metal viewfinder ───────────────────────────────────────────
            if let renderer {
                MetalView(renderer: renderer)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // ── 3. OSD rails ─────────────────────────────────────────────────
            VStack(spacing: 0) {
                TopOSDBar(vm: vm, onMenu: { showSettings = true })

                // Crosshair corners sit over the middle of the screen
                CrosshairOverlay()

                Spacer()

                BottomDeck(vm: vm, onShutter: triggerCapture)
            }
            .ignoresSafeArea(edges: .bottom)
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
        .sheet(isPresented: $showSettings) {
            CameraSettingsView(vm: vm)
        }
        .task { await CaptureService.requestPhotoPermissionIfNeeded() }
    }

    // MARK: — Setup

    private func setupRenderer() {
        guard renderer == nil,
              let device = MTLCreateSystemDefaultDevice() else { return }
        cameraManager.setup(device: device)
        renderer = MetalRenderer(device: device, cameraManager: cameraManager)
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
        HStack(spacing: 14) {
            OSDPill()

            Spacer()

            // Centre telemetry
            VStack(spacing: 1) {
                Text("256×128  2:1  60FPS")
                    .font(RetroTheme.mono(9))
                    .foregroundStyle(RetroTheme.amber)
                Text(String(format: "EV %+.1f  DITHER \(vm.ditherLabel)", vm.evBias))
                    .font(RetroTheme.mono(8, weight: .regular))
                    .foregroundStyle(RetroTheme.dimText)
            }

            Spacer()

            // Menu button
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onMenu()
            } label: {
                Text("≡  MENU")
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
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RetroTheme.bg.opacity(0.92))
    }
}

// MARK: — Bottom control deck

private struct BottomDeck: View {
    var vm: CameraViewModel
    let onShutter: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            PaletteCycler(vm: vm)
                .frame(maxWidth: .infinity)

            DeckDivider()

            EVStepper(vm: vm)
                .frame(maxWidth: .infinity)

            DeckDivider()

            DiamondToggle(vm: vm)
                .frame(maxWidth: .infinity)

            DeckDivider()

            // Shutter — rightmost for right-thumb grip
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

// MARK: — Palette cycler  [<] NAME [>]

private struct PaletteCycler: View {
    var vm: CameraViewModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
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
                .padding(.horizontal, 14)
        }
        .padding(.horizontal, 8)
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
                .frame(width: 30, height: 44)  // 44pt touch target
        }
        .buttonStyle(.plain)
    }
}
