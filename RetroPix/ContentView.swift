// ContentView.swift
// RetroPix — Minimal SwiftUI shell over the Metal viewfinder.
//
// Gestures:
//   • Double-tap          → shutter
//   • Volume Up/Down      → shutter (via AVAudioSession KVO)
//   • Long-press (0.5 s)  → reveal palette menu
//     Palette menu: Tap   → cycle selection  |  Long-press (1 s) → confirm + dismiss
//     Tap outside menu    → dismiss without change
//
// No UI chrome is shown during normal use — just the live pixel feed.

import AVFoundation
import MediaPlayer
import Photos
import SwiftUI

// MARK: — Root view

struct ContentView: View {
    // Created once; CameraManager holds the capture session.
    @State private var cameraManager = CameraManager()
    @State private var renderer: MetalRenderer?

    @State private var palette: Palette = Palette.all[0]
    @State private var showMenu = false
    @State private var isCapturing = false

    var body: some View {
        ZStack {
            // ── Pixel viewfinder ──────────────────────────────────────────────
            if let renderer {
                MetalView(renderer: renderer)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            // ── Volume button shutter (off-screen MPVolumeView) ───────────────
            if renderer != nil {
                VolumeMonitor { triggerCapture() }
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
            }

            // ── Gesture layer (double-tap + long-press) ───────────────────────
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { triggerCapture() }
                .onLongPressGesture(minimumDuration: 0.5) {
                    withAnimation(.easeInOut(duration: 0.12)) { showMenu = true }
                }

            // ── Palette overlay ───────────────────────────────────────────────
            if showMenu, let renderer {
                // Dim background closes menu on outside tap
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.12)) { showMenu = false }
                    }

                PaletteMenuView(current: palette) { selected in
                    palette = selected
                    renderer.updatePalette(selected)
                    withAnimation(.easeInOut(duration: 0.12)) { showMenu = false }
                } onDismiss: {
                    withAnimation(.easeInOut(duration: 0.12)) { showMenu = false }
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { setupRenderer() }
        .onDisappear { cameraManager.stopSession() }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
        ) { _ in cameraManager.stopSession() }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        ) { _ in cameraManager.startSession() }
        .task { await CaptureService.requestPhotoPermissionIfNeeded() }
    }

    // MARK: — Setup

    private func setupRenderer() {
        guard renderer == nil,
              let device = MTLCreateSystemDefaultDevice() else { return }
        cameraManager.setup(device: device)
        renderer = MetalRenderer(device: device, cameraManager: cameraManager)
    }

    // MARK: — Shutter

    func triggerCapture() {
        guard !isCapturing, let renderer else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            try? await CaptureService.capture(from: renderer)
        }
    }
}

// MARK: — Palette overlay menu

private struct PaletteMenuView: View {
    let current: Palette
    let onConfirm: (Palette) -> Void
    let onDismiss: () -> Void

    @State private var highlightedIndex: Int
    @State private var isConfirmHolding = false

    init(current: Palette, onConfirm: @escaping (Palette) -> Void, onDismiss: @escaping () -> Void) {
        self.current   = current
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        let idx = Palette.all.firstIndex(where: { $0.id == current.id }) ?? 0
        self._highlightedIndex = State(initialValue: idx)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("// PALETTE //")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
                .padding(.bottom, 10)

            // Palette rows
            ForEach(Array(Palette.all.enumerated()), id: \.offset) { idx, pal in
                HStack(spacing: 8) {
                    // Color swatches (first 4 colors)
                    HStack(spacing: 3) {
                        ForEach(Array(pal.colors.prefix(4).enumerated()), id: \.offset) { _, c in
                            Rectangle()
                                .fill(Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)))
                                .frame(width: 8, height: 8)
                        }
                    }
                    Text((highlightedIndex == idx ? "▶ " : "  ") + pal.name)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(highlightedIndex == idx ? Color.white : Color(white: 0.4))
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture { highlightedIndex = idx }
            }

            Rectangle()
                .fill(Color(white: 0.25))
                .frame(height: 1)
                .padding(.vertical, 10)

            // Hint bar
            HStack {
                Text("TAP=SELECT")
                Spacer()
                Text(isConfirmHolding ? "CONFIRMING..." : "HOLD=CONFIRM")
            }
            .font(.system(size: 9, weight: .regular, design: .monospaced))
            .foregroundStyle(Color(white: 0.35))
        }
        .padding(18)
        .background(
            ZStack {
                Rectangle().fill(Color.black.opacity(0.92))
                Rectangle().stroke(Color(white: 0.28), lineWidth: 1)
            }
        )
        .frame(minWidth: 220)
        // Long-press confirms; quick gesture on the menu itself cycles (separately handled above per row)
        .onLongPressGesture(minimumDuration: 1.0,
            pressing: { pressing in isConfirmHolding = pressing },
            perform: {
                isConfirmHolding = false
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onConfirm(Palette.all[highlightedIndex])
            })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(24)
    }
}

// MARK: — Volume button monitor

/// Adds an off-screen MPVolumeView to suppress the system volume HUD,
/// then KVO-observes AVAudioSession.outputVolume for any change (up or down).
private struct VolumeMonitor: UIViewRepresentable {
    let onPress: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPress: onPress) }

    func makeUIView(context: Context) -> MPVolumeView {
        context.coordinator.start()
        return MPVolumeView(frame: CGRect(x: -500, y: -500, width: 0, height: 0))
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}

    final class Coordinator: NSObject, @unchecked Sendable {
        private let onPress: () -> Void
        private var obs: NSKeyValueObservation?
        private var skipInitial = true

        init(onPress: @escaping () -> Void) { self.onPress = onPress }

        func start() {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.ambient, options: .mixWithOthers)
            try? session.setActive(true)
            obs = session.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                if self.skipInitial { self.skipInitial = false; return }
                DispatchQueue.main.async { self.onPress() }
            }
        }

        deinit { obs?.invalidate() }
    }
}
