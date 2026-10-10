// CameraSettingsView.swift
// RetroPix — Dedicated 90s-industrial configuration sheet.
// Palette management (rename/delete/create/generate), aspect ratio picker, and continuous dither engine.

import SwiftUI

struct PaletteEditorTarget: Identifiable {
    let id: String
    let palette: Palette?
}

struct CameraSettingsView: View {
    var vm: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editorTarget: PaletteEditorTarget? = nil

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

                        // ── Computational Engine ──────────────────────────────
                        SectionHeader(title: "COMPUTATIONAL ENGINE", sub: "Select active GPU processing engine")

                        HStack(spacing: 8) {
                            ForEach(CameraEngineMode.allCases) { mode in
                                Button {
                                    vm.engineMode = mode
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                } label: {
                                    VStack(spacing: 3) {
                                        Text(mode == .pixel8Bit ? "8-BIT PIXEL" : "DIGICAM / FILM")
                                            .font(RetroTheme.mono(11, weight: .bold))
                                            .foregroundStyle(vm.engineMode == mode ? RetroTheme.bg : (mode == .pixel8Bit ? RetroTheme.green : RetroTheme.red))
                                        Text(mode == .pixel8Bit ? "BAYER DITHER" : "AESTHETIC COMPUTE")
                                            .font(RetroTheme.mono(7, weight: .regular))
                                            .foregroundStyle(vm.engineMode == mode ? RetroTheme.bg.opacity(0.8) : RetroTheme.dimText)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(vm.engineMode == mode ? (mode == .pixel8Bit ? RetroTheme.green : RetroTheme.red) : Color.clear)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 3)
                                                    .stroke(mode == .pixel8Bit ? RetroTheme.green.opacity(0.6) : RetroTheme.red.opacity(0.6), lineWidth: 1)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)

                        Divider().background(RetroTheme.border).padding(.vertical, 14)

                        // ── Appearance ────────────────────────────────────────
                        SectionHeader(title: "APPEARANCE", sub: "Toggle light or dark interface")

                        Toggle(isOn: Binding(
                            get: { vm.isDarkMode },
                            set: {
                                vm.isDarkMode = $0
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        )) {
                            Text(vm.isDarkMode ? "DARK MODE" : "LIGHT MODE")
                                .font(RetroTheme.mono(11))
                                .foregroundStyle(vm.isDarkMode ? RetroTheme.green : RetroTheme.amber)
                        }
                        .tint(RetroTheme.green)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)

                        Divider().background(RetroTheme.border).padding(.vertical, 14)

                        // ── Photo Effects & Timer ─────────────────────────────
                        SectionHeader(title: "PHOTO EFFECTS & TIMER", sub: "90s quartz date stamp, frame borders, and self-timer")

                        // Date/Time Stamp mode picker
                        VStack(alignment: .leading, spacing: 6) {
                            Text("90S DATE/TIME STAMP")
                                .font(RetroTheme.mono(10))
                                .foregroundStyle(RetroTheme.dimText)

                            HStack(spacing: 8) {
                                ForEach(DateStampMode.allCases) { mode in
                                    Button {
                                        vm.dateStampMode = mode
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    } label: {
                                        Text(mode.displayLabel)
                                            .font(RetroTheme.mono(10))
                                            .foregroundStyle(vm.dateStampMode == mode ? RetroTheme.bg : (mode == .orange ? RetroTheme.amber : (mode == .green ? RetroTheme.green : RetroTheme.dimText)))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(vm.dateStampMode == mode ? (mode == .orange ? RetroTheme.amber : (mode == .green ? RetroTheme.green : RetroTheme.dimText)) : Color.clear)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 3)
                                                            .stroke(mode == .orange ? RetroTheme.amber.opacity(0.6) : (mode == .green ? RetroTheme.green.opacity(0.6) : RetroTheme.border), lineWidth: 1)
                                                    )
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)

                        // Frame Borders Toggle
                        Toggle(isOn: Binding(
                            get: { vm.frameBorderEnabled },
                            set: {
                                vm.frameBorderEnabled = $0
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("FRAME BORDERS")
                                    .font(RetroTheme.mono(11))
                                    .foregroundStyle(vm.frameBorderEnabled ? RetroTheme.green : RetroTheme.text)
                                Text("Vintage photo paper margin & corner ticks")
                                    .font(RetroTheme.mono(8, weight: .regular))
                                    .foregroundStyle(RetroTheme.dimText)
                            }
                        }
                        .tint(RetroTheme.green)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)

                        // Self-Timer Selector
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SELF-TIMER")
                                .font(RetroTheme.mono(10))
                                .foregroundStyle(RetroTheme.dimText)

                            HStack(spacing: 8) {
                                ForEach([0, 3, 10], id: \.self) { sec in
                                    Button {
                                        vm.timerDuration = sec
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    } label: {
                                        Text(sec == 0 ? "OFF" : "\(sec) SEC")
                                            .font(RetroTheme.mono(10))
                                            .foregroundStyle(vm.timerDuration == sec ? RetroTheme.bg : RetroTheme.amber)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(vm.timerDuration == sec ? RetroTheme.amber : Color.clear)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 3)
                                                            .stroke(RetroTheme.amber.opacity(0.5), lineWidth: 1)
                                                    )
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)

                        Divider().background(RetroTheme.border).padding(.vertical, 14)

                        if vm.engineMode == .pixel8Bit {
                            // ── Dithering Engine ──────────────────────────────────
                            SectionHeader(title: "DITHERING ENGINE", sub: "Select algorithm and spatial dispersion")

                            VStack(alignment: .leading, spacing: 10) {
                                Text("ALGORITHM")
                                    .font(RetroTheme.mono(10))
                                    .foregroundStyle(RetroTheme.dimText)

                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                    ForEach(DitherAlgorithm.allCases) { alg in
                                        Button {
                                            vm.ditherAlgorithm = alg
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        } label: {
                                            Text(alg.displayLabel)
                                                .font(RetroTheme.mono(10))
                                                .foregroundStyle(vm.ditherAlgorithm == alg ? RetroTheme.bg : RetroTheme.green)
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 8)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .fill(vm.ditherAlgorithm == alg ? RetroTheme.green : Color.clear)
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 3)
                                                                .stroke(RetroTheme.green.opacity(0.5), lineWidth: 1)
                                                        )
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                // Dither Amount Slider
                                HStack {
                                    Text("DITHER")
                                        .font(RetroTheme.mono(10))
                                        .foregroundStyle(RetroTheme.dimText)
                                    Spacer()
                                    Text(vm.ditherLabel)
                                        .font(RetroTheme.mono(10))
                                        .foregroundStyle(RetroTheme.amber)
                                }
                                .padding(.top, 4)

                                Slider(
                                    value: Binding(
                                        get: { Double(vm.ditherIntensity) },
                                        set: { vm.ditherIntensity = Float($0) }
                                    ),
                                    in: 0.0...1.0
                                )
                                .tint(RetroTheme.amber)
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 6)

                            Divider().background(RetroTheme.border).padding(.vertical, 14)

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
                                    editorTarget = PaletteEditorTarget(id: "new_\(UUID().uuidString)", palette: nil)
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
                            SectionHeader(title: "PALETTE MANAGEMENT", sub: "Tap to activate. Edit or delete below.")

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
                                        onEdit: {
                                            editorTarget = PaletteEditorTarget(id: palette.id, palette: palette)
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                            .padding(.bottom, 32)
                        } else {
                            // ── Aesthetic Profiles ───────────────────────────────
                            SectionHeader(title: "CAMERA & FILM PROFILES", sub: "Calibrated CCD sensors, 3×3 color science matrices, halation & film stocks")

                            VStack(spacing: 10) {
                                ForEach(Array(vm.aestheticProfiles.enumerated()), id: \.element.id) { idx, profile in
                                    AestheticProfileCard(
                                        profile: profile,
                                        isActive: vm.activeAestheticProfileIndex == idx,
                                        onTap: {
                                            vm.activeAestheticProfileIndex = idx
                                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 32)
                        }
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
            .sheet(item: $editorTarget) { target in
                CustomPaletteEditorView(vm: vm, paletteToEdit: target.palette)
                    .id(target.id)
            }
        }
        .preferredColorScheme(vm.isDarkMode ? .dark : .light)
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
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: Name, Active indicator, Rename and Delete buttons
            HStack {
                Button(action: onTap) {
                    HStack(spacing: 6) {
                        Text(palette.name)
                            .font(RetroTheme.mono(12))
                            .foregroundStyle(isActive ? RetroTheme.red : RetroTheme.text)

                        if isActive {
                            Text("▶ ACTIVE")
                                .font(RetroTheme.mono(9))
                                .foregroundStyle(RetroTheme.red)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                // Edit button
                Button(action: onEdit) {
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

// MARK: — Aesthetic Profile card

private struct AestheticProfileCard: View {
    let profile: AestheticProfile
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // Header: Name, Active indicator, Era & Code
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(profile.name)
                                .font(RetroTheme.mono(12))
                                .foregroundStyle(isActive ? RetroTheme.red : RetroTheme.text)

                            if isActive {
                                Text("▶ ACTIVE")
                                    .font(RetroTheme.mono(9))
                                    .foregroundStyle(RetroTheme.red)
                            }
                        }

                        Text(profile.subtitle)
                            .font(RetroTheme.mono(8, weight: .regular))
                            .foregroundStyle(RetroTheme.dimText)
                            .lineLimit(1)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(profile.eraYear)
                            .font(RetroTheme.mono(9, weight: .bold))
                            .foregroundStyle(RetroTheme.amber)
                        Text(profile.code)
                            .font(RetroTheme.mono(8, weight: .regular))
                            .foregroundStyle(RetroTheme.dimText)
                    }
                }

                // Characteristics badges
                HStack(spacing: 6) {
                    Text(profile.category.rawValue)
                        .font(RetroTheme.mono(8, weight: .bold))
                        .foregroundStyle(RetroTheme.amber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 2)
                                .fill(RetroTheme.amber.opacity(0.12))
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(RetroTheme.amber.opacity(0.4), lineWidth: 0.5))
                        )

                    Text(String(format: "GRAIN %d%%", Int(round(profile.grainAmount * 100))))
                        .font(RetroTheme.mono(7, weight: .regular))
                        .foregroundStyle(RetroTheme.dimText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(RetroTheme.border, lineWidth: 0.5)
                        )

                    Text(String(format: "HALATION %d%%", Int(round(profile.halationStrength * 100))))
                        .font(RetroTheme.mono(7, weight: .regular))
                        .foregroundStyle(RetroTheme.dimText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(RetroTheme.border, lineWidth: 0.5)
                        )

                    Text(String(format: "VIGNETTE %d%%", Int(round(profile.vignette * 100))))
                        .font(RetroTheme.mono(7, weight: .regular))
                        .foregroundStyle(RetroTheme.dimText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(RetroTheme.border, lineWidth: 0.5)
                        )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
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
