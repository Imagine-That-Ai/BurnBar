import SwiftUI
import OpenBurnBarCore

// MARK: - Membership Card Chrome
//
// The adaptive luxury surface for the redesigned Cloud destination. Dark
// mode renders an Obsidian Black-Card with a mercury/platinum foil edge;
// light mode renders a warm cream letterpress certificate with a brushed
// gold-leaf edge. Both fire the existing one-shot specular sweep and a
// continuous mercury shimmer (gated on reduce-motion).
//
// Composes `ProTheme.Membership` tokens + the shared `MercuryShimmerOverlay`
// so the destination stays in the Pro vocabulary without introducing any
// per-callsite color math.

struct MembershipCardModifier: ViewModifier {
    var cornerRadius: CGFloat = ProTheme.Layout.cardRadius
    var elevated: Bool = false
    var enableShimmer: Bool = true
    var strokeWidth: CGFloat = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var specularPhase: CGFloat = -1.4
    @State private var didFireSpecular = false

    func body(content: Content) -> some View {
        content
            .background(backgroundLayers)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(ProTheme.Membership.foilEdge, lineWidth: strokeWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: ProTheme.Membership.foilLeaf.opacity(0.18), radius: 22, y: 10)
            .shadow(color: Color.black.opacity(0.16), radius: 12, y: 6)
            .onAppear(perform: fireSpecularIfNeeded)
    }

    @ViewBuilder
    private var backgroundLayers: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(elevated ? ProTheme.Membership.surfaceElevated : ProTheme.Membership.surface)

            // Corner-anchored foil glow adds depth without lifting the card
            // off the page.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [ProTheme.Membership.foilLeaf.opacity(0.12), Color.clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 320
                    )
                )
                .blendMode(.plusLighter)

            // Light-mode letterpress: a faint inner top shadow that reads as
            // debossed stock. Near-clear in dark so obsidian stays flat.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(ProTheme.Membership.letterpress.opacity(0.05), lineWidth: 2)
                .blur(radius: 2)
                .offset(y: 1)

            if enableShimmer && !reduceMotion {
                MercuryShimmerOverlay()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .blendMode(.plusLighter)
                    .opacity(0.40)
                    .allowsHitTesting(false)
            }

            if !reduceMotion {
                MembershipSpecularSweep(phase: specularPhase)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
        }
    }

    private func fireSpecularIfNeeded() {
        guard !reduceMotion, !didFireSpecular else { return }
        didFireSpecular = true
        specularPhase = -1.4
        withAnimation(ProTheme.Motion.specular.delay(0.15)) {
            specularPhase = 1.4
        }
    }
}

extension View {
    /// Wraps content in the adaptive membership card chrome (obsidian foil in
    /// dark, gold-leaf letterpress in light).
    func membershipCard(
        cornerRadius: CGFloat = ProTheme.Layout.cardRadius,
        elevated: Bool = false,
        enableShimmer: Bool = true,
        strokeWidth: CGFloat = 1.0
    ) -> some View {
        modifier(MembershipCardModifier(
            cornerRadius: cornerRadius,
            elevated: elevated,
            enableShimmer: enableShimmer,
            strokeWidth: strokeWidth
        ))
    }
}

// MARK: - Specular Sweep

private struct MembershipSpecularSweep: View {
    let phase: CGFloat

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    Color.clear,
                    ProTheme.Membership.foilHighlight.opacity(0.22),
                    Color.white.opacity(0.24),
                    ProTheme.Membership.foilHighlight.opacity(0.22),
                    Color.clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.55, height: geo.size.height * 1.6)
            .rotationEffect(.degrees(18))
            .offset(x: phase * geo.size.width, y: -geo.size.height * 0.3)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Membership Backdrop
//
// The full-screen adaptive backdrop behind the Cloud destination. Obsidian
// with an ember vignette in dark; warm parchment with a soft gold radial in
// light. Replaces the flat `Color(.systemGroupedBackground)`.

struct MembershipBackdrop: View {
    var body: some View {
        ZStack {
            ProTheme.Membership.backdrop
            Rectangle().fill(ProTheme.Membership.backdropGlow)
            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [
                            UnifiedDesignSystem.Colors.ember.opacity(0.07),
                            Color.clear
                        ],
                        center: .bottomTrailing,
                        startRadius: 0,
                        endRadius: 460
                    )
                )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Foil Seal
//
// A small engraved capsule used for "SAVE 17%", "MOST POWERFUL", and trial
// ribbons. Foil-leaf stroke, adaptive fill.

struct MembershipSeal: View {
    let text: String
    var systemImage: String?
    var prominent: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .heavy))
            }
            Text(text)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(1.4)
        }
        // Dark ink in BOTH modes: the prominent fill is bright foil (gold in
        // light, platinum in dark) — cream-on-gold fails WCAG AA in light mode.
        .foregroundStyle(prominent ? ProTheme.Membership.letterpress : ProTheme.Membership.foilLeaf)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(prominent ? AnyShapeStyle(ProTheme.Membership.foilEdge) : AnyShapeStyle(ProTheme.Membership.surfaceElevated))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(ProTheme.Membership.foilLeaf.opacity(prominent ? 0 : 0.55), lineWidth: 0.8)
        )
        // Periodic glint across the seal — minted foil, not a flat sticker.
        // Self-gates on reduce-motion.
        .overlay(
            HoloSheenSweep(
                tint: prominent ? Color.white : ProTheme.Membership.foilHighlight,
                period: 6.2,
                bandOpacity: prominent ? 0.45 : 0.35
            )
            .clipShape(Capsule(style: .continuous))
        )
        .shadow(color: ProTheme.Membership.foilLeaf.opacity(prominent ? 0.35 : 0), radius: 8, y: 3)
        // Spoken label uses sentence case — the caps are visual styling, not
        // something VoiceOver should shout.
        .accessibilityLabel(Text(text.localizedCapitalized))
    }
}
