// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

// MARK: - GemLogoView

/// The brand mark, rendered as clean oriental ink-drop art — the first thing a
/// new user sees on launch. The supplied `logo` sits in crisp negative space,
/// surrounded by a few deliberate dark ink droplets and a whisper of iridescent
/// oil-sheen that breathes slowly.
///
/// The component is platform-agnostic and lives in `OpenBurnBarCore` so both the
/// macOS menu-bar app and the iOS app render an identical hero. The caller
/// supplies the brand image via a `@ViewBuilder` so it resolves against the
/// *caller's* asset catalog (`Image("AppLogo")` from `Bundle.main`), not the
/// package bundle.
///
/// ```swift
/// GemLogoView(size: 132) {
///     Image("AppLogo").resizable().renderingMode(.original).scaledToFit()
/// }
/// ```
///
/// Accessibility:
/// - `accessibilityReduceMotion`: the iridescent sheen freezes at a flattering
///   fixed phase. The ink drops are still rendered.
/// - `accessibilityReduceTransparency`: removes every `plusLighter`/`screen`
///   blend, the blurred glow, and the iridescence, leaving only clean ink drops
///   and the logo.
/// - The mark is decorative here (`accessibilityHidden`); callers pair it with
///   a visible wordmark that carries the label.
struct GemLogoView<Logo: View>: View {
    private let size: CGFloat
    private let logo: Logo

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var start = Date()

    /// - Parameters:
    ///   - size: Edge-to-edge bounding box of the composition in points.
    ///     Default `132`.
    ///   - logo: The brand mark to display. Pass a `.resizable().scaledToFit()`
    ///     image so it adapts to the composition.
    init(size: CGFloat = 132, @ViewBuilder logo: () -> Logo) {
        self.size = size
        self.logo = logo()
    }

    var body: some View {
        Group {
            if reduceMotion {
                composition(phase: Phase.still)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    composition(phase: Phase(at: context.date.timeIntervalSince(start)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: Composition

    private func composition(phase: Phase) -> some View {
        ZStack {
            primaryDrop
            secondaryDrops

            if !reduceTransparency {
                oilSheen(phase: phase)
            }

            logoLayer(intensity: phase.breathe)
        }
        .compositingGroup()
    }

    // MARK: Layers

    /// The main ink drop — a soft dark teardrop sitting just behind the logo.
    private var primaryDrop: some View {
        InkDrop(width: size * 0.52, height: size * 0.68)
            .fill(
                RadialGradient(
                    colors: [
                        Color(hex: "1C1C22").opacity(0.95),
                        Color(hex: "121218").opacity(0.85),
                        Color(hex: "09090C").opacity(0.65),
                        .clear
                    ],
                    center: UnitPoint(x: 0.48, y: 0.55),
                    startRadius: 0,
                    endRadius: size * 0.35
                )
            )
            .frame(width: size * 0.52, height: size * 0.68)
            .offset(x: -size * 0.02, y: size * 0.16)
            .blur(radius: size * 0.02)
            .allowsHitTesting(false)
    }

    /// Two smaller satellite drops for asymmetric balance.
    private var secondaryDrops: some View {
        ZStack {
            InkDrop(width: size * 0.24, height: size * 0.32)
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: "18181E").opacity(0.90),
                            Color(hex: "0E0E12").opacity(0.70),
                            .clear
                        ],
                        center: UnitPoint(x: 0.45, y: 0.45),
                        startRadius: 0,
                        endRadius: size * 0.16
                    )
                )
                .frame(width: size * 0.24, height: size * 0.32)
                .offset(x: size * 0.22, y: -size * 0.12)
                .blur(radius: size * 0.015)

            InkDrop(width: size * 0.14, height: size * 0.18)
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: "141419").opacity(0.85),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.10
                    )
                )
                .frame(width: size * 0.14, height: size * 0.18)
                .offset(x: -size * 0.20, y: size * 0.28)
                .blur(radius: size * 0.01)
        }
        .allowsHitTesting(false)
    }

    /// A soft iridescent edge on the primary drop — like oil film on ink.
    /// Kept subtle so it reads as a material highlight, not a neon line.
    private func oilSheen(phase: Phase) -> some View {
        let sheenColors: [Color] = [
            Color(hex: "5C7BFF").opacity(0.5),
            Color(hex: "9B5CFF").opacity(0.4),
            Color(hex: "FF5A8A").opacity(0.3),
            Color(hex: "FF8A3D").opacity(0.3),
            Color(hex: "5C7BFF").opacity(0.5)
        ]

        return InkDrop(width: size * 0.52, height: size * 0.68)
            .stroke(
                RadialGradient(
                    colors: sheenColors,
                    center: UnitPoint(x: 0.45, y: 0.40),
                    startRadius: 0,
                    endRadius: size * 0.32
                ),
                style: StrokeStyle(lineWidth: size * 0.018, lineCap: .round)
            )
            .hueRotation(.degrees(phase.shift))
            .frame(width: size * 0.52, height: size * 0.68)
            .offset(x: -size * 0.02, y: size * 0.16)
            .blur(radius: size * 0.012)
            .blendMode(.plusLighter)
            .opacity(0.40 + 0.12 * phase.breathe)
            .allowsHitTesting(false)
    }

    /// The brand mark, crisp and centered.
    private func logoLayer(intensity: Double) -> some View {
        logo
            .frame(width: size * 0.36, height: size * 0.36)
            .shadow(color: .black.opacity(0.55), radius: size * 0.035, x: 0, y: size * 0.02)
            .shadow(
                color: Color(hex: "FF6A2A").opacity(reduceTransparency ? 0 : 0.14 + 0.08 * intensity),
                radius: size * 0.07
            )
    }
}

// MARK: - Animation phase

/// Time-derived animation state. Slow, organic motion so the sheen never feels
/// mechanical.
private struct Phase {
    var shift: Double // degrees — hue rotation of the iridescent edge
    var breathe: Double // 0…1 — gentle intensity pulse

    /// A flattering frozen pose for Reduce Motion.
    static let still = Phase(shift: 0, breathe: 0.6)

    init(shift: Double, breathe: Double) {
        self.shift = shift
        self.breathe = breathe
    }

    init(at t: TimeInterval) {
        shift = t * 8 // ~45s per full hue cycle
        breathe = 0.5 + 0.5 * sin(t * 0.40) // ~16s breath
    }
}

// MARK: - Ink drop shape

/// A clean teardrop / ink drop with a soft, tapered tail.
private struct InkDrop: Shape {
    let width: CGFloat
    let height: CGFloat

    func path(in rect: CGRect) -> Path {
        let centerX = rect.midX
        let topY = rect.minY + rect.height * 0.05
        let bottomY = rect.maxY - rect.height * 0.02
        let shoulderY = rect.minY + rect.height * 0.45
        let shoulderWidth = rect.width * 0.46

        var path = Path()
        path.move(to: CGPoint(x: centerX, y: topY))
        path.addCurve(
            to: CGPoint(x: centerX - shoulderWidth, y: shoulderY),
            control1: CGPoint(x: centerX - rect.width * 0.12, y: topY + rect.height * 0.14),
            control2: CGPoint(x: centerX - shoulderWidth * 0.8, y: shoulderY - rect.height * 0.18)
        )
        path.addCurve(
            to: CGPoint(x: centerX, y: bottomY),
            control1: CGPoint(x: centerX - rect.width * 0.52, y: shoulderY + rect.height * 0.28),
            control2: CGPoint(x: centerX - rect.width * 0.32, y: bottomY - rect.height * 0.08)
        )
        path.addCurve(
            to: CGPoint(x: centerX + shoulderWidth, y: shoulderY),
            control1: CGPoint(x: centerX + rect.width * 0.32, y: bottomY - rect.height * 0.08),
            control2: CGPoint(x: centerX + rect.width * 0.52, y: shoulderY + rect.height * 0.28)
        )
        path.addCurve(
            to: CGPoint(x: centerX, y: topY),
            control1: CGPoint(x: centerX + shoulderWidth * 0.8, y: shoulderY - rect.height * 0.18),
            control2: CGPoint(x: centerX + rect.width * 0.12, y: topY + rect.height * 0.14)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Gem · dark") {
    GemLogoView(size: 160) {
        Image(systemName: "flame.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(
                LinearGradient(
                    colors: [Color(hex: "FED430"), Color(hex: "F25205"), Color(hex: "E31B24")],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
    .padding(60)
    .background(Color(hex: "0A0A0C"))
    .preferredColorScheme(.dark)
}

#Preview("Gem · light") {
    GemLogoView(size: 120) {
        Image(systemName: "flame.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color(hex: "F25205"))
    }
    .padding(60)
    .background(Color(hex: "F2F2F4"))
}
#endif
