import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Live Glyph
//
// Same robot silhouette as the nav-bar Hermes icon (`HermesGlyphShape` made of
// `HermesHeadShape` + `HermesEarcupsShape` + `HermesAntennaHeartShape`), but
// packaged for inline reuse — chat badges, status pills, list rows.
//
// `isLive == true` lights the eyes and antenna heart with the same ember
// gradient + halo bloom + smile-line eyes used in the selected nav icon. When
// `isLive == false` it renders the calm mercury silhouette used elsewhere.

struct HermesLiveGlyph: View {
    /// Pixel size of the glyph's bounding box.
    var size: CGFloat
    /// When true the eyes & antenna glow and a slow pulse animates.
    var isLive: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse: CGFloat = 0

    var body: some View {
        ZStack {
            // Antenna stalk
            HermesAntennaShape()
                .stroke(antennaStyle,
                        style: StrokeStyle(lineWidth: max(1, size * 0.06), lineCap: .round))

            // Heart antenna tip — halo + filled heart
            ZStack {
                if isLive {
                    HermesAntennaHeartShape(pulse: pulse)
                        .fill(MobileTheme.ember.opacity(0.55))
                        .blur(radius: size * 0.06)
                        .scaleEffect(1.4 + pulse * 0.3)
                }
                HermesAntennaHeartShape(pulse: isLive ? pulse : 0)
                    .fill(heartFill)
            }

            // Earcups (drawn under helmet so the helmet stroke rims them)
            HermesEarcupsShape()
                .fill(earcupsFill)
                .overlay(
                    HermesEarcupsShape()
                        .stroke(antennaStyle,
                                style: StrokeStyle(lineWidth: max(0.6, size * 0.045),
                                                   lineCap: .round))
                )

            // Helmet body — sheen fill + outline
            HermesHeadShape()
                .fill(headFill)
                .overlay(
                    HermesHeadShape()
                        .stroke(antennaStyle,
                                style: StrokeStyle(lineWidth: max(0.8, size * 0.06),
                                                   lineCap: .round, lineJoin: .round))
                )

            // Cheek blush — bright when live, faint when calm
            HermesCheeksShape()
                .fill(
                    isLive
                        ? AnyShapeStyle(MobileTheme.ember.opacity(0.55))
                        : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.22))
                )
                .blur(radius: isLive ? size * 0.018 : 0)

            // Eye halo bloom — only when live
            if isLive {
                HermesEyesShape(glow: pulse)
                    .fill(MobileTheme.ember.opacity(0.50))
                    .blur(radius: size * 0.08)
                    .scaleEffect(1.5)
            }

            // Eye pupils — coral radial gradient when live, mercury when calm.
            HermesEyesShape(glow: isLive ? pulse : 0)
                .fill(eyeFill)

            // Eye smile arcs — only when live
            if isLive {
                HermesEyeSmileShape()
                    .stroke(MobileTheme.ember.opacity(0.85),
                            style: StrokeStyle(lineWidth: max(0.6, size * 0.035),
                                               lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .onAppear { startPulse() }
        .onChange(of: isLive) { _, _ in startPulse() }
        .accessibilityHidden(true)
    }

    // MARK: - Animation

    private func startPulse() {
        guard isLive, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.18)) { pulse = 0 }
            return
        }
        // Loop a soft 1.4s pulse — drives heart scale + eye glow.
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulse = 1.0
        }
    }

    // MARK: - Style Sources

    private var antennaStyle: AnyShapeStyle {
        isLive
            ? AnyShapeStyle(AuroraDesign.Gradients.mercuryFoil)
            : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.85))
    }

    private var heartFill: AnyShapeStyle {
        isLive
            ? AnyShapeStyle(
                LinearGradient(
                    colors: [MobileTheme.ember, MobileTheme.amber],
                    startPoint: .top,
                    endPoint: .bottom))
            : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.78))
    }

    private var earcupsFill: AnyShapeStyle {
        isLive
            ? AnyShapeStyle(
                LinearGradient(
                    colors: [
                        MobileTheme.Colors.surfaceElevated,
                        MobileTheme.Colors.surface
                    ],
                    startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(MobileTheme.Colors.textMuted.opacity(0.18))
    }

    private var headFill: AnyShapeStyle {
        isLive
            ? AnyShapeStyle(
                LinearGradient(
                    colors: [
                        MobileTheme.Colors.surfaceElevated.opacity(0.95),
                        MobileTheme.Colors.surface.opacity(0.70)
                    ],
                    startPoint: .top,
                    endPoint: .bottom))
            : AnyShapeStyle(MobileTheme.Colors.surfaceElevated.opacity(0.20))
    }

    private var eyeFill: AnyShapeStyle {
        isLive
            ? AnyShapeStyle(
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.95),
                        MobileTheme.ember,
                        MobileTheme.ember.opacity(0.85)
                    ],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: size * 0.13))
            : AnyShapeStyle(AuroraDesign.Gradients.mercuryFoil)
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 16) {
        HermesLiveGlyph(size: 24, isLive: false)
        HermesLiveGlyph(size: 24, isLive: true)
        HermesLiveGlyph(size: 48, isLive: true)
    }
    .padding()
    .background(MobileTheme.Colors.background)
}
