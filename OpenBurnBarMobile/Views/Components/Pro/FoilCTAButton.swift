import SwiftUI
import OpenBurnBarCore

// MARK: - Foil CTA Button
//
// Pro vocabulary — the call to action. Obsidian fill with foil edge,
// continuous mercury shimmer behind the surface, mercury-aureate iconography,
// and a haptic on tap. Used on the CloudStoreView poster, locked-feature
// veils, and any inline Pro upsell that needs a primary action.

struct FoilCTAButton: View {
    let title: String
    var subtitle: String? = nil
    var icon: String = "sparkle"
    var isLoading: Bool = false
    var fillWidth: Bool = true
    let action: () -> Void

    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        .foregroundStyle(ProTheme.Palette.aureate)
                }
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .padding(.vertical, MobileTheme.Spacing.md)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .background(backgroundLayers)
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .stroke(ProTheme.Palette.aureateStroke, lineWidth: 1.0)
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .shadow(color: ProTheme.Palette.aureate.opacity(0.22), radius: 18, y: 8)
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
            MiningPickLoader(.inline, tint: ProTheme.Palette.mercury)
        } else {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(ProTheme.Palette.aureate)
        }
    }

    @ViewBuilder
    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(ProTheme.Typography.headlineSerif)
                .foregroundStyle(ProTheme.Palette.mercury)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.68))
            }
        }
    }

    @ViewBuilder
    private var backgroundLayers: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(ProTheme.Palette.obsidianElevated)

            if !reduceMotion {
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
            FoilCTAButton(title: "Become a Member", subtitle: "$4.99 / month") {}
            FoilCTAButton(title: "Continue on iPhone", icon: "iphone") {}
            FoilCTAButton(title: "Processing", isLoading: true) {}
        }
        .padding(24)
    }
}
