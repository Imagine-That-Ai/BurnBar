import SwiftUI
import OpenBurnBarCore

// MARK: - Membership Band
//
// Pro vocabulary — horizontal foil strip variant of MercuryFoilCard.
// Lives inside free-user surfaces (forecast cards, quota detail, provider
// wizard) for a tasteful Pro reveal that doesn't dominate the layout. Tap
// opens the destination — typically `CloudStoreView`.
//
// Also used post-purchase as a reassurance band (variant `.active`) so the
// surface doesn't go visually empty for members.

struct MembershipBand: View {
    enum Variant {
        case upsell          // Free user — invites the tap.
        case active          // Member — quiet confirmation, no tap.
    }

    let title: String
    let detail: String
    var variant: Variant = .upsell
    var icon: String = "sparkle"
    var ctaLabel: String = "OPEN CLOUD"
    var action: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if variant == .upsell, let action {
                Button(action: {
                    Haptics.light()
                    action()
                }, label: { bandRow })
                .buttonStyle(.plain)
            } else {
                bandRow
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if variant == .upsell {
            return "\(title). \(detail). \(ctaLabel)."
        }
        return "\(title). \(detail)."
    }

    private var bandRow: some View {
        HStack(spacing: MobileTheme.Spacing.md) {
            leadingDisc
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(ProTheme.Palette.mercury)
                Text(detail)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailingAffordance
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, MobileTheme.Spacing.sm + 2)
        .background(backgroundLayers)
        .overlay(
            RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous)
                .stroke(ProTheme.Palette.aureateStroke, lineWidth: 0.9)
        )
        .clipShape(RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous))
        .shadow(color: ProTheme.Palette.aureate.opacity(variant == .upsell ? 0.20 : 0.10), radius: 12, y: 4)
    }

    private var leadingDisc: some View {
        ZStack {
            Circle().fill(ProTheme.Palette.obsidian)
            Circle().stroke(ProTheme.Palette.aureateStroke, lineWidth: 0.9)
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ProTheme.Palette.aureate)
        }
        .frame(width: 30, height: 30)
    }

    @ViewBuilder
    private var trailingAffordance: some View {
        if variant == .upsell {
            HStack(spacing: 4) {
                Text(ctaLabel)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(ProTheme.Palette.aureate)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ProTheme.Palette.aureate)
            }
        } else {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ProTheme.Palette.aureate)
        }
    }

    @ViewBuilder
    private var backgroundLayers: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous)
                .fill(ProTheme.Palette.obsidian)

            if !reduceMotion {
                MercuryShimmerOverlay()
                    .clipShape(RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous))
                    .blendMode(.plusLighter)
                    .opacity(variant == .upsell ? 0.55 : 0.30)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Preview

#Preview("Membership Band") {
    ZStack {
        MobileTheme.Colors.background.ignoresSafeArea()
        VStack(spacing: 16) {
            MembershipBand(
                title: "Lift the lid",
                detail: "Refresh Codex quota anywhere with OpenBurnBar Cloud.",
                variant: .upsell
            ) {}
            MembershipBand(
                title: "Cloud Member",
                detail: "Hosted refresh, conversation backup, full session sync.",
                variant: .active,
                icon: "checkmark.seal.fill"
            )
        }
        .padding(20)
    }
}
