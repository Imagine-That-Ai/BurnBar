import SwiftUI

// MARK: - The living fluid aurora kernel
//
// A small circular surface that renders the same idea as the WebGL
// `fluidAuroraKernel` — slow luminous ribbons advected through a palette ramp —
// as native SwiftUI content. The consent sheet gets one of these instead of a
// flat `Circle()` behind a `brain.head.profile` glyph: the permission moment
// reads as the app's own weather.
//
// The split follows `BurnBarKernelField`: every number the frame carries is
// produced by pure, `Sendable`, view-free math (`FluidAuroraMotion` →
// `FluidAuroraFrame`), pinned by tests without mounting a window. The view is a
// thin shell that owns a clock and three accessibility switches.
//
// Cost: O(ribbons) views per frame, ~a dozen floats, no display list, nothing to
// invalidate. One `PlasmaClock` per surface at 30fps — these are slow 2.9–37s
// organic drifts with no fast edges, where extra frames are invisible and extra
// power is not.

/// A circular living aurora: BurnBar brand accents over a mint-lavender cool
/// span, breathing as layered fluid ribbons.
struct FluidAuroraKernelView: View {
    var size: CGFloat = 96
    /// Hold the aurora still for reasons the view cannot see — a sheet behind a
    /// non-front window, a preview being rasterised. Reduce Motion is handled
    /// internally and resolves to the authored still pose.
    var isRunning: Bool = true
    /// When set, the kernel exposes itself to accessibility under this label
    /// (the emblem replaces an SF Symbol, so it owes assistive tech the same
    /// meaning the glyph carried). When nil the kernel is decorative chrome.
    var accessibilityLabel: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private var animates: Bool { isRunning && !reduceMotion }

    var body: some View {
        let palette = FluidAuroraKernelPalette.palette(
            colorScheme: colorScheme,
            reduceTransparency: reduceTransparency
        )

        return PlasmaClock(isRunning: animates) { tick in
            let frame = tick.isAnimating
                ? FluidAuroraMotion.frame(at: tick.date.timeIntervalSinceReferenceDate, renderedSize: size)
                : FluidAuroraMotion.still

            ZStack {
                ground(palette: palette)
                ribbons(palette: palette, frame: frame)
                core(palette: palette, frame: frame)
                rim(palette: palette, frame: frame)
            }
            .frame(width: size, height: size)
        }
        .modifier(FluidAuroraAccessibility(label: accessibilityLabel))
    }

    // MARK: Layers

    /// The deep pool the ribbons glow over. Dark mode keeps a deep ink well
    /// (the theme's own `background` token); light mode sinks toward the sheet's
    /// own elevated surface so the aurora reads as printed ink on cream rather
    /// than a dark hole in the paper.
    private func ground(palette: FluidAuroraKernelPalette) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        colorScheme == .dark
                            ? DesignSystem.Colors.background
                            : DesignSystem.Colors.surfaceElevated,
                        colorScheme == .dark
                            ? DesignSystem.Colors.surface
                            : DesignSystem.Colors.surface
                    ],
                    center: UnitPoint(x: 0.5, y: 0.45),
                    startRadius: 0,
                    endRadius: size * 0.62
                )
            )
            .opacity(palette.groundVisibility)
    }

    /// The three fluid ribbons. Each is an ellipse blurred into a vapour band,
    /// swayed, stretched and faded by its own track, composited additively so
    /// they bloom where they cross — the cheap native cousin of the WebGL
    /// kernel's luminous accumulation.
    private func ribbons(palette: FluidAuroraKernelPalette, frame: FluidAuroraFrame) -> some View {
        ZStack {
            ForEach(0..<FluidAuroraMotion.ribbonCount, id: \.self) { index in
                let ribbonColor = palette.stops[min(
                    index + 1,
                    palette.stops.count - 1
                )].color

                Ellipse()
                    .fill(ribbonColor)
                    .frame(
                        width: size * (0.78 + 0.16 * Double(index)),
                        height: size * (0.30 + 0.06 * Double(index))
                    )
                    .blur(radius: size * 0.11)
                    .scaleEffect(x: frame.stretch[index], y: 1)
                    .offset(x: frame.sway[index], y: frame.lift[index])
                    .rotationEffect(.degrees(ribbonTilt[index]))
                    .opacity(Double(frame.alpha[index]) * palette.emission)
                    .blendMode(.plusLighter)
            }
        }
    }

    /// Cool high, warm low — the ramp's own order expressed as tilt, so the
    /// kernel's geometry agrees with its palette about which end is which.
    private var ribbonTilt: [Double] { [-8, 3, 12] }

    /// The specular core — the kernel's "alive" tell. A soft white highlight
    /// riding the mint band, breathing faster than the ribbons.
    private func core(palette: FluidAuroraKernelPalette, frame: FluidAuroraFrame) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.55), .clear],
                        center: UnitPoint(x: 0.42, y: 0.38),
                        startRadius: 0,
                        endRadius: size * 0.30
                    )
                )
                .scaleEffect(frame.coreScale)
                .opacity(Double(frame.coreBrightness) * palette.coreLift * 1.6)
                .blendMode(.plusLighter)

            Circle()
                .fill(palette.stops[1].color.opacity(0.35))
                .frame(width: size * 0.42, height: size * 0.42)
                .blur(radius: size * 0.08)
                .scaleEffect(frame.coreScale)
                .opacity(Double(frame.coreBrightness))
                .blendMode(.plusLighter)
        }
    }

    /// The rim: a hairline carrying the palette's own ends, with the halo's slow
    /// bloom in its shadow. This is what stops the aurora reading as a sticker
    /// and makes it read as a contained instrument.
    private func rim(palette: FluidAuroraKernelPalette, frame: FluidAuroraFrame) -> some View {
        Circle()
            .strokeBorder(
                LinearGradient(
                    colors: [
                        palette.stops.first?.color.opacity(0.55) ?? .clear,
                        palette.stops.last?.color.opacity(0.55) ?? .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .shadow(
                color: (palette.stops.first?.color ?? .clear).opacity(0.45),
                radius: size * 0.16 * Double(frame.halo),
                y: 0
            )
    }
}

// MARK: - Accessibility

/// Applies the kernel's accessibility contract: labelled when the surface owes
/// assistive tech a meaning, hidden when it is decorative chrome.
private struct FluidAuroraAccessibility: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityElement(children: .ignore).accessibilityLabel(label)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

#Preview("Aurora kernel, dark") {
    VStack(spacing: 32) {
        FluidAuroraKernelView(size: 96, accessibilityLabel: "Memory")
        FluidAuroraKernelView(size: 48, accessibilityLabel: "Memory")
        FluidAuroraKernelView(size: 64, isRunning: false)
    }
    .padding(40)
    .background(DesignSystem.Colors.background)
    .environment(\.colorScheme, .dark)
}

#Preview("Aurora kernel, light") {
    VStack(spacing: 32) {
        FluidAuroraKernelView(size: 96, accessibilityLabel: "Memory")
        FluidAuroraKernelView(size: 48, accessibilityLabel: "Memory")
    }
    .padding(40)
    .background(DesignSystem.Colors.background)
    .environment(\.colorScheme, .light)
}
