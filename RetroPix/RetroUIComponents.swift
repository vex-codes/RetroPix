// RetroUIComponents.swift
// RetroPix — Design tokens and reusable retro UI primitives.
// 90s industrial dark-mode aesthetic: charcoal, phosphor green, vermillion, amber.

import SwiftUI

// MARK: — Color utility

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255.0, green: CGFloat((hex >> 8) & 0xFF) / 255.0, blue: CGFloat(hex & 0xFF) / 255.0, alpha: 1.0)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

// MARK: — Design tokens

enum RetroTheme {
    static let bg      = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x0A0A0C) : UIColor(hex: 0xEAEAE6) })
    static let panel   = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x121214) : UIColor(hex: 0xDFDFDA) })
    static let border  = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x2A2A2E) : UIColor(hex: 0xBCBCB4) })
    static let green   = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x00FF66) : UIColor(hex: 0x008833) })
    static let red     = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xFF4438) : UIColor(hex: 0xD92218) })
    static let amber   = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xFFA830) : UIColor(hex: 0xB85C00) })
    static let dimText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x55575F) : UIColor(hex: 0x767880) })
    static let text    = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(hex: 0x141416) })

    static func mono(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: — Tactile shutter button  ◉

struct ShutterButton: View {
    let action: () -> Void
    @GestureState private var pressed = false
    private let haptic = UIImpactFeedbackGenerator(style: .rigid)

    var body: some View {
        ZStack {
            // Outer glow ring
            Circle()
                .stroke(RetroTheme.red.opacity(0.25), lineWidth: 6)
                .frame(width: 56, height: 56)
            // Mid ring
            Circle()
                .fill(RetroTheme.panel)
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
                .onChanged { _ in haptic.prepare() }
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
    let pad: CGFloat    = 2
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

// MARK: — Flash / Torch Button (Left of Shutter)

struct FlashButton: View {
    let isFlashOn: Bool
    var isEnabled: Bool = true
    var rotation: Double = 0.0
    let action: () -> Void

    var body: some View {
        Button(action: {
            if isEnabled { action() }
        }) {
            ZStack {
                Circle()
                    .fill(RetroTheme.panel)
                    .overlay(
                        Circle().stroke(
                            isFlashOn ? RetroTheme.amber : RetroTheme.border,
                            lineWidth: isFlashOn ? 1.5 : 1.0
                        )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: isFlashOn ? "bolt.fill" : (isEnabled ? "bolt.slash" : "bolt.slash.fill"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(
                        !isEnabled ? RetroTheme.dimText.opacity(0.4) :
                        (isFlashOn ? RetroTheme.amber : RetroTheme.dimText)
                    )
                    .rotationEffect(.degrees(rotation))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(isFlashOn ? "Flash On" : "Flash Off")
    }
}

// MARK: — Camera Flip Button (Right of Shutter)

struct CameraFlipButton: View {
    let isFront: Bool
    var rotation: Double = 0.0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(RetroTheme.panel)
                    .overlay(
                        Circle().stroke(
                            isFront ? RetroTheme.green : RetroTheme.border,
                            lineWidth: isFront ? 1.5 : 1.0
                        )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "camera.rotate.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isFront ? RetroTheme.green : RetroTheme.dimText)
                    .rotationEffect(.degrees(rotation))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFront ? "Front Camera Active" : "Back Camera Active")
    }
}

// MARK: — Self-Timer Quick Button

struct TimerButton: View {
    let duration: Int // 0, 3, 10
    var rotation: Double = 0.0
    let action: () -> Void

    private var label: String {
        duration == 0 ? "⏱" : "⏱\(duration)s"
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(RetroTheme.mono(9))
                .foregroundStyle(duration > 0 ? RetroTheme.bg : RetroTheme.dimText)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(duration > 0 ? RetroTheme.amber : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(
                                    duration > 0 ? RetroTheme.amber : RetroTheme.border,
                                    lineWidth: 1
                                )
                        )
                )
                .rotationEffect(.degrees(rotation))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Timer \(duration) seconds")
    }
}

// MARK: — Composition Grid Quick Button (# / # 3×3 / # PHI)

struct GridButton: View {
    let mode: GridMode
    var rotation: Double = 0.0
    let action: () -> Void

    private var label: String {
        switch mode {
        case .off:          return "GRID"
        case .ruleOfThirds: return "# 3×3"
        case .goldenSpiral: return "🌀 PHI"
        }
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(RetroTheme.mono(9))
                .foregroundStyle(mode != .off ? RetroTheme.bg : RetroTheme.dimText)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(mode != .off ? RetroTheme.amber : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(
                                    mode != .off ? RetroTheme.amber : RetroTheme.border,
                                    lineWidth: 1
                                )
                        )
                )
                .rotationEffect(.degrees(rotation))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Composition Grid \(mode.rawValue)")
    }
}

// MARK: — Engine Mode Button (8-BIT vs DIGICAM)

struct EngineModeButton: View {
    let mode: CameraEngineMode
    var rotation: Double = 0.0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(mode.rawValue)
                .font(RetroTheme.mono(9, weight: .black))
                .foregroundStyle(mode == .pixel8Bit ? RetroTheme.green : RetroTheme.red)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill((mode == .pixel8Bit ? RetroTheme.green : RetroTheme.red).opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke((mode == .pixel8Bit ? RetroTheme.green : RetroTheme.red).opacity(0.6), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .rotationEffect(.degrees(rotation))
        .accessibilityLabel("Engine Mode: \(mode.rawValue)")
    }
}
