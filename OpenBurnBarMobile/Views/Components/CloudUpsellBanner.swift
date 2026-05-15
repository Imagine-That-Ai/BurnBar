import SwiftUI
import OpenBurnBarCore

// MARK: - Cloud Upsell Banner
//
// Pro vocabulary — the whisper at the top of Pulse. Obsidian foil pill with
// a continuous mercury shimmer. Tap opens `CloudStoreView` as a sheet;
// dismiss stores a session flag so it doesn't reappear until the user
// revisits.
//
// Hidden entirely once the entitlement is active or the banner is dismissed.

struct CloudUpsellBanner: View {
    let priceText: String?
    let onTap: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            crestTile

            VStack(alignment: .leading, spacing: 2) {
                Text("OpenBurnBar Cloud")
                    .font(ProTheme.Typography.headlineSerif)
                    .foregroundStyle(ProTheme.Palette.mercury)
                    .lineLimit(1)
                Text(subtitle)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.68))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ProTheme.Palette.aureate)

            dismissButton
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, MobileTheme.Spacing.sm + 2)
        .background(bannerBackground)
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(ProTheme.Palette.aureateStroke, lineWidth: 0.9)
        )
        .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous))
        .shadow(color: ProTheme.Palette.aureate.opacity(0.22), radius: 14, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous))
        .onTapGesture {
            Haptics.light()
            onTap()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open OpenBurnBar Cloud") {
            Haptics.light()
            onTap()
        }
    }

    private var subtitle: String {
        if let priceText {
            return "Your agents, unbound — \(priceText)/mo"
        }
        return "Your agents, unbound"
    }

    private var crestTile: some View {
        ZStack {
            Circle().fill(ProTheme.Palette.obsidian)
            Circle().stroke(ProTheme.Palette.aureateStroke, lineWidth: 0.9)
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(ProTheme.Palette.aureate)
        }
        .frame(width: 30, height: 30)
    }

    private var dismissButton: some View {
        Button {
            Haptics.selection()
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(ProTheme.Palette.mercury.opacity(0.6))
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(ProTheme.Palette.obsidianElevated)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss banner")
    }

    @ViewBuilder
    private var bannerBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(ProTheme.Palette.obsidian)

            if !reduceMotion {
                MercuryShimmerOverlay()
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous))
                    .blendMode(.plusLighter)
                    .opacity(0.55)
                    .allowsHitTesting(false)
            }
        }
    }
}

#Preview {
    ZStack {
        UnifiedDesignSystem.Colors.background.ignoresSafeArea()
        VStack {
            CloudUpsellBanner(priceText: "$4.99", onTap: {}, onDismiss: {})
                .padding()
            Spacer()
        }
    }
}
