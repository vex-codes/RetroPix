// CameraSettingsView.swift
// RetroPix — Dedicated 90s-industrial configuration sheet.
// Palette management (rename/delete/create/generate), aspect ratio picker, and continuous dither engine.

import SwiftUI

struct CameraSettingsView: View {
    var vm: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPaletteEditor = false

    @State private var showRenameAlert = false
    @State private var paletteToRename: Palette?
    @State private var renameText = ""

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

                        // ── Aspect Ratio Picker ──────────────────────────────
                        SectionHeader(title: "FRAME ASPECT RATIO", sub: "Select sensor crop & internal grid")

                        HStack(spacing: 10) {
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
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)

                        Divider().background(RetroTheme.border).padding(.vertical, 16)

                        // ── Palette Creation & Generation ─────────────────────
                        SectionHeader(title: "PALETTE CREATOR & GENERATOR", sub: "Synthesize harmonic or custom palettes")

                        HStack(spacing: 10) {
                            Button {
                                vm.generateRandomPalette()
                            } label: {
                                Text("[ + HARMONIC RANDOM ]")
                                    .font(RetroTheme.mono(10))
                                    .foregroundStyle(RetroTheme.amber)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(RetroTheme.amber.opacity(0.08))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 3)
                                                    .stroke(RetroTheme.amber.opacity(0.4), lineWidth: 1)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)

                            Button {
                                showPaletteEditor = true
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                Text("[ + CUSTOM STUDIO ]")
                                    .font(RetroTheme.mono(10))
                                    .foregroundStyle(RetroTheme.green)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(RetroTheme.green.opacity(0.08))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 3)
                                                    .stroke(RetroTheme.green.opacity(0.4), lineWidth: 1)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)

                        Divider().background(RetroTheme.border).padding(.vertical, 14)

                        // ── Palette Configuration & Management ────────────────
                        SectionHeader(title: "PALETTE MANAGEMENT", sub: "Tap to activate. Rename or delete below.")

                        VStack(spacing: 10) {
                            ForEach(Array(vm.palettes.enumerated()), id: \.element.id) { idx, palette in
                                PaletteCard(
                                    palette: palette,
                                    isActive: vm.activePaletteIndex == idx,
                                    canDelete: vm.palettes.count > 1,
                                    onTap: {
                                        vm.activePaletteIndex = idx
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    },
                                    onRename: {
                                        paletteToRename = palette
                                        renameText = palette.name
                                        showRenameAlert = true
                                    },
                                    onDelete: {
                                        vm.deletePalette(id: palette.id)
                                    }
                                )
                            }

                            // Restore defaults button
                            Button {
                                vm.resetPalettesToDefault()
                            } label: {
                                Text("[ RESTORE DEFAULT PALETTES ]")
                                    .font(RetroTheme.mono(10))
                                    .foregroundStyle(RetroTheme.dimText)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(RetroTheme.border, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 6)
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
            .sheet(isPresented: $showPaletteEditor) {
                CustomPaletteEditorView(vm: vm)
            }
            .alert("RENAME PALETTE", isPresented: $showRenameAlert) {
                TextField("NEW NAME", text: $renameText)
                Button("CANCEL", role: .cancel) {}
                Button("SAVE") {
                    if let pal = paletteToRename {
                        vm.renamePalette(id: pal.id, newName: renameText)
                    }
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

// MARK: — Palette card with swatch bar + actions

private struct PaletteCard: View {
    let palette: Palette
    let isActive: Bool
    let canDelete: Bool
    let onTap: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: Name, Active indicator, Rename and Delete buttons
            HStack {
                Button(action: onTap) {
                    HStack(spacing: 6) {
                        Text(palette.name)
                            .font(RetroTheme.mono(12))
                            .foregroundStyle(isActive ? RetroTheme.red : Color.white)

                        if isActive {
                            Text("▶ ACTIVE")
                                .font(RetroTheme.mono(9))
                                .foregroundStyle(RetroTheme.red)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                // Rename button
                Button(action: onRename) {
                    Text("[EDIT]")
                        .font(RetroTheme.mono(9))
                        .foregroundStyle(RetroTheme.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(RetroTheme.green.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                // Delete button
                if canDelete {
                    Button(action: onDelete) {
                        Text("[DEL]")
                            .font(RetroTheme.mono(9))
                            .foregroundStyle(RetroTheme.red)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(RetroTheme.red.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Text("\(palette.count) CLR")
                    .font(RetroTheme.mono(9, weight: .regular))
                    .foregroundStyle(RetroTheme.dimText)
            }

            // Swatch bar
            Button(action: onTap) {
                ColorSwatchBar(palette: palette, height: 22)
            }
            .buttonStyle(.plain)
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
}
