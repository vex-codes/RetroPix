// CustomPaletteEditorView.swift
// RetroPix — Brutalist custom palette authoring sheet.

import SwiftUI

struct CustomPaletteEditorView: View {
    var vm: CameraViewModel
    var paletteToEdit: Palette? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var paletteName: String
    @State private var colors: [Color]

    init(vm: CameraViewModel, paletteToEdit: Palette? = nil) {
        self.vm = vm
        self.paletteToEdit = paletteToEdit
        let initialName = paletteToEdit?.name ?? "CUSTOM_\(Int.random(in: 10...99))"
        let initialColors = paletteToEdit?.colors.map {
            Color(red: Double($0.r), green: Double($0.g), blue: Double($0.b))
        } ?? [
            Color(hex: 0x111115),
            Color(hex: 0x3d3550),
            Color(hex: 0x785684),
            Color(hex: 0xd896a0),
            Color(hex: 0xf5eed8),
        ]
        _paletteName = State(initialValue: initialName)
        _colors = State(initialValue: initialColors)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RetroTheme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {

                        // Header
                        HStack {
                            Text(paletteToEdit != nil ? "EDIT \(paletteToEdit!.name)" : "PALETTE STUDIO")
                                .font(RetroTheme.mono(18, weight: .black))
                                .foregroundStyle(RetroTheme.amber)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer()
                        }
                        .padding(.top, 16)

                        // Name input
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PALETTE NAME")
                                .font(RetroTheme.mono(10))
                                .foregroundStyle(RetroTheme.dimText)
                            TextField("NAME", text: $paletteName)
                                .font(RetroTheme.mono(14))
                                .foregroundStyle(RetroTheme.green)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(RetroTheme.panel)
                                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(RetroTheme.border, lineWidth: 1))
                                )
                        }

                        // Colors list
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("COLORS (\(colors.count)/8)")
                                    .font(RetroTheme.mono(10))
                                    .foregroundStyle(RetroTheme.dimText)
                                Spacer()
                                Button("SORT LUMINANCE") {
                                    sortLuminance()
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                                .font(RetroTheme.mono(9))
                                .foregroundStyle(RetroTheme.amber)
                            }

                            ForEach(0..<colors.count, id: \.self) { idx in
                                HStack(spacing: 12) {
                                    Text(String(format: "#%02d", idx + 1))
                                        .font(RetroTheme.mono(11))
                                        .foregroundStyle(RetroTheme.dimText)
                                        .frame(width: 28)

                                    ColorPicker("", selection: $colors[idx], supportsOpacity: false)
                                        .labelsHidden()

                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(colors[idx])
                                        .frame(height: 24)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(RetroTheme.border, lineWidth: 1)
                                        )

                                    if colors.count > 4 {
                                        Button {
                                            colors.remove(at: idx)
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        } label: {
                                            Text("[X]")
                                                .font(RetroTheme.mono(10))
                                                .foregroundStyle(RetroTheme.red)
                                                .frame(width: 32, height: 32)
                                        }
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(RetroTheme.panel)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            }

                            if colors.count < 8 {
                                Button {
                                    colors.append(Color(hex: 0x888888))
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    HStack {
                                        Text("+ ADD COLOR")
                                            .font(RetroTheme.mono(10))
                                            .foregroundStyle(RetroTheme.green)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(RetroTheme.green.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Save action
                        Button(action: savePalette) {
                            Text("SAVE & ACTIVATE")
                                .font(RetroTheme.mono(12, weight: .bold))
                                .foregroundStyle(RetroTheme.bg)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(RetroTheme.green)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(20)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("[ CLOSE ]") { dismiss() }
                        .font(RetroTheme.mono(11))
                        .foregroundStyle(RetroTheme.red)
                }
            }
        }
        .preferredColorScheme(vm.isDarkMode ? .dark : .light)
        .onAppear {
            if let pal = paletteToEdit {
                paletteName = pal.name
                colors = pal.colors.map {
                    Color(red: Double($0.r), green: Double($0.g), blue: Double($0.b))
                }
            }
        }
    }

    private func sortLuminance() {
        let retro = colors.map { retroColor(from: $0) }
        let sorted = retro.sorted { $0.luminance < $1.luminance }
        let newColors = sorted.map { Color(red: Double($0.r), green: Double($0.g), blue: Double($0.b)) }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            colors = newColors
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func savePalette() {
        sortLuminance()
        let retro = colors.map { retroColor(from: $0) }
        let name = paletteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? (paletteToEdit?.name ?? "CUSTOM") : name

        if let existing = paletteToEdit {
            let updated = Palette(id: existing.id, name: finalName, colors: retro)
            vm.updatePalette(updated)
        } else {
            let palette = Palette(id: "usr_\(UUID().uuidString.prefix(8))", name: finalName, colors: retro)
            vm.addCustomPalette(palette)
        }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        dismiss()
    }

    private func retroColor(from color: Color) -> RetroColor {
        let resolved = color.resolve(in: EnvironmentValues())
        return RetroColor(r: resolved.red, g: resolved.green, b: resolved.blue)
    }
}
