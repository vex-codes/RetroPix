// RetroUIComponents.swift
// RetroPix — Design tokens and reusable retro UI primitives.
// 90s industrial dark-mode aesthetic: charcoal, phosphor green, vermillion, amber.

import SwiftUI

// MARK: — Color utility

extension Color {
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double(hex         & 0xFF) / 255
        )
    }
}

// MARK: — Design tokens

enum RetroTheme {
    static let bg      = Color(hex: 0x0A0A0C)
    static let panel   = Color(hex: 0x121214)
    static let border  = Color(hex: 0x2A2A2E)
    static let green   = Color(hex: 0x00FF66)
    static let red     = Color(hex: 0xFF4438)
    static let amber   = Color(hex: 0xFFA830)
    static let dimText = Color(hex: 0x55575F)

    static func mono(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: — Tactile shutter button  ◉

struct ShutterButton: View {
    let action: () -> Void
    @GestureState private var pressed = false

    var body: some View {
        ZStack {
            // Outer glow ring
            Circle()
                .stroke(RetroTheme.red.opacity(0.25), lineWidth: 6)
                .frame(width: 56, height: 56)
            // Mid ring
            Circle()
                .fill(Color(hex: 0x1C1214))
                .overlay(Circle().stroke(RetroTheme.red, lineWidth: 1.5))
                .frame(width: 46, height: 46)
            // Inner dot
            Circle()
                .fill(RetroTheme.red)
                .frame(width: 22, height: 22)
                .opacity(pressed ? 0.6 : 1.0)
        }
        .scaleEffect(pressed ? 0.88 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.5), value: pressed)
        .contentShape(Circle().size(CGSize(width: 64, height: 64)))
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressed) { _, state, _ in state = true }
                .onEnded { _ in action() }
        )
        .accessibilityLabel("Shutter")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: — Horizontal color swatch bar for palette cards

struct ColorSwatchBar: View {
    let palette: Palette
    var height: CGFloat = 20

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(palette.colors.enumerated()), id: \.offset) { _, c in
                Rectangle()
                    .fill(Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

// MARK: — Viewfinder corner crosshairs (Canvas, zero hit-testing)

struct CrosshairOverlay: View {
    let arm: CGFloat    = 18
    let thick: CGFloat  = 1.5
    let pad: CGFloat    = 14
    let color: Color    = RetroTheme.green.opacity(0.55)

    var body: some View {
        Canvas { ctx, size in
            let corners: [(x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat)] = [
                (pad,             pad,              1,  1),
                (size.width - pad, pad,            -1,  1),
                (pad,             size.height - pad, 1, -1),
                (size.width - pad, size.height - pad, -1, -1),
            ]
            for c in corners {
                var h = Path()
                h.move(to: CGPoint(x: c.x, y: c.y))
                h.addLine(to: CGPoint(x: c.x + arm * c.dx, y: c.y))
                ctx.stroke(h, with: .color(color), lineWidth: thick)

                var v = Path()
                v.move(to: CGPoint(x: c.x, y: c.y))
                v.addLine(to: CGPoint(x: c.x, y: c.y + arm * c.dy))
                ctx.stroke(v, with: .color(color), lineWidth: thick)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: — Subtle vertical deck divider

struct DeckDivider: View {
    var body: some View {
        Rectangle()
            .fill(RetroTheme.border)
            .frame(width: 1)
            .padding(.vertical, 10)
    }
}

// MARK: — Ratio Button

struct RatioButton: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(RetroTheme.mono(9))
                .foregroundStyle(isActive ? RetroTheme.bg : RetroTheme.amber)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isActive ? RetroTheme.amber : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(RetroTheme.amber.opacity(0.5), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: — Procedural Palette Randomizer Button

struct RandButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("RAND")
                .font(RetroTheme.mono(9))
                .foregroundStyle(RetroTheme.amber)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(RetroTheme.amber.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(RetroTheme.amber.opacity(0.4), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

