import SwiftUI
import OpenBurnBarCore

// MARK: - Foil CTA Button
//
// Pro vocabulary — the primary call to action, and the single most important
// button on any Pro surface. It wears the membership two-coat system: a
// pressed-gold ember bar in light mode (warm, saturated, unmissable against
// the parchment certificate) and an obsidian black-card with a living mercury
// sheen in dark mode. All colors are adaptive `ProTheme.Membership` tokens, so
// one view tree reads luxuriously in both appearances. High-contrast ink, a
// beveled minted-gold rim, a specular top sheen, and a haptic on tap. Used on
// the CloudStoreView poster, locked-feature veils, and any inline Pro upsell.

struct FoilCTAButton: View {
    let title: String
    var subtitle: String? = nil
    var icon: String = "sparkle"
    var isLoading: Bool = false
    var fillWidth: Bool = true
    let action: () -> Void

    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            Haptics.medium()
            action()
        } label: {
            HStack(spacing: MobileTheme.Spacing.md) {
                leadingIcon
                titleStack
                if fillWidth { Spacer(minLength: 0) }
                if !isLoading {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(ProTheme.Membership.ctaInk)
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .padding(.vertical, MobileTheme.Spacing.md)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .background(backgroundLayers)
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .stroke(ProTheme.Membership.ctaEdge, lineWidth: 1.2)
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .shadow(color: ProTheme.Membership.ctaGlow.opacity(0.38), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isPressed { isPressed = true } }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                        isPressed = false
                    }
                }
        )
        .disabled(isLoading)
        .accessibilityLabel(subtitle.map { "\(title). \($0)" } ?? title)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if isLoading {
            MiningPickLoader(.inline, tint: ProTheme.Membership.ctaInk)
        } else {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(ProTheme.Membership.ctaInk)
        }
    }

    @ViewBuilder
    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(ProTheme.Typography.headlineSerif)
                .foregroundStyle(ProTheme.Membership.ctaInk)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Membership.ctaInkSoft)
            }
        }
    }

    @ViewBuilder
    private var backgroundLayers: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(ProTheme.Membership.ctaFill)

            // Pressed-metal highlight along the top edge — reads in both coats.
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(ProTheme.Membership.ctaSheen)
                .allowsHitTesting(false)

            // Living platinum shimmer is reserved for the obsidian dark coat;
            // on the warm gold bar the static sheen above carries the highlight.
            if colorScheme == .dark && !reduceMotion {
                MercuryShimmerOverlay()
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous))
                    .blendMode(.plusLighter)
                    .opacity(isPressed ? 0.85 : 0.55)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Preview

#Preview("Foil CTA Button") {
    ZStack {
        ProTheme.Palette.obsidian.ignoresSafeArea()
        VStack(spacing: 16) {
            FoilCTAButton(title: "Become a Member", subtitle: "$7.99 / month") {}
            FoilCTAButton(title: "Continue on iPhone", icon: "iphone") {}
            FoilCTAButton(title: "Processing", isLoading: true) {}
        }
        .padding(24)
    }
}
