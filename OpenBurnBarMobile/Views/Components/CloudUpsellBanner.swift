import SwiftUI
import OpenBurnBarCore

// MARK: - Cloud Upsell Banner
//
// Compact glass strip rendered at the top of `PulseView` when the user
// doesn't have an active OpenBurnBar Cloud subscription. Tap opens the
// dedicated `CloudStoreView` as a sheet; the dismiss button stores a
// session-scoped flag so it doesn't reappear until the user revisits.
//
// Hidden entirely once the entitlement is active or the banner has been
// dismissed for the session.

struct CloudUpsellBanner: View {
    let priceText: String?
    let onTap: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            glyphTile

            VStack(alignment: .leading, spacing: 2) {
                Text("Quota and Hermes, anywhere")
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.textMuted)

            dismissButton
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .background(bannerBackground)
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.primaryGradient.opacity(0.65), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous))
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
            return "Try OpenBurnBar Cloud — \(priceText)/mo"
        }
        return "Try OpenBurnBar Cloud"
    }

    private var glyphTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MobileTheme.primaryGradient)
                .frame(width: 36, height: 36)
                .shadow(color: UnifiedDesignSystem.Colors.ember.opacity(0.45), radius: 8, y: 4)
            Image(systemName: "cloud.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var dismissButton: some View {
        Button {
            Haptics.selection()
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss banner")
    }

    @ViewBuilder
    private var bannerBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            UnifiedDesignSystem.Colors.ember.opacity(0.10),
                            UnifiedDesignSystem.Colors.amber.opacity(0.06),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
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
