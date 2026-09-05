// CameraSettingsView.swift
// RetroPix — Dedicated 90s-industrial configuration sheet.
// Palette configuration with full swatch cards + continuous dither slider.

import SwiftUI

struct CameraSettingsView: View {
    var vm: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                RetroTheme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {

                        // ── Header ───────────────────────────────────────────
                        HStack {
                            Text("CAMERA SETTINGS")
                                .font(RetroTheme.mono(18, weight: .black))
                                .foregroundStyle(RetroTheme.red)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 14)

                        Divider().background(RetroTheme.border)

                        // ── Palette Configuration ─────────────────────────────
                        SectionHeader(title: "PALETTE CONFIGURATION", sub: "Tap to activate palette")

                        VStack(spacing: 10) {
                            ForEach(Array(Palette.all.enumerated()), id: \.offset) { idx, palette in
                                PaletteCard(
                                    palette: palette,
                                    isActive: vm.activePaletteIndex == idx
                                ) {
                                    vm.activePaletteIndex = idx
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)

                        Divider().background(RetroTheme.border).padding(.vertical, 16)

                        // ── Dither & Grain Engine ─────────────────────────────
                        SectionHeader(title: "DITHER & GRAIN ENGINE", sub: "Bayer 8×8 ordered dither")

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("SPREAD")
                                    .font(RetroTheme.mono(10))
                                    .foregroundStyle(RetroTheme.dimText)
                                Spacer()
                                Text("\(Int(vm.ditherIntensity * 100))%")
                                    .font(RetroTheme.mono(13))
                                    .foregroundStyle(RetroTheme.amber)
                                    .frame(minWidth: 44, alignment: .trailing)
                            }

                            Slider(
                                value: Binding(
                                    get: { Double(vm.ditherIntensity) },
                                    set: { vm.ditherIntensity = Float($0) }
                                ),
                                in: 0...1
                            )
                            .tint(RetroTheme.green)

                            // Quick preset buttons
                            HStack(spacing: 8) {
                                ForEach(["OFF", "50%", "75%", "100%"], id: \.self) { label in
                                    let val: Float = label == "OFF" ? 0 : label == "50%" ? 0.5 : label == "75%" ? 0.75 : 1.0
                                    Button(label) {
                                        vm.ditherIntensity = val
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    }
                                    .font(RetroTheme.mono(9))
                                    .foregroundStyle(vm.ditherLabel == label ? RetroTheme.bg : RetroTheme.green)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(vm.ditherLabel == label ? RetroTheme.green : Color.clear)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 3)
                                                    .stroke(RetroTheme.green.opacity(0.5), lineWidth: 1)
                                            )
                                    )
                                }
                                Spacer()
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("[ EXIT ]") { dismiss() }
                        .font(RetroTheme.mono(11))
                        .foregroundStyle(RetroTheme.red)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: — Section header

private struct SectionHeader: View {
    let title: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(RetroTheme.mono(11))
                .foregroundStyle(RetroTheme.amber)
            Text(sub)
                .font(RetroTheme.mono(9, weight: .regular))
                .foregroundStyle(RetroTheme.dimText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: — Palette card with swatch bar

private struct PaletteCard: View {
    let palette: Palette
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(palette.name)
                        .font(RetroTheme.mono(12))
                        .foregroundStyle(isActive ? RetroTheme.red : Color.white)
                    Spacer()
                    if isActive {
                        Text("▶ ACTIVE")
                            .font(RetroTheme.mono(9))
                            .foregroundStyle(RetroTheme.red)
                    }
                    Text("\(palette.count) CLR")
                        .font(RetroTheme.mono(9, weight: .regular))
                        .foregroundStyle(RetroTheme.dimText)
                }
                ColorSwatchBar(palette: palette, height: 22)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(RetroTheme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isActive ? RetroTheme.red : RetroTheme.border, lineWidth: isActive ? 1.5 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
