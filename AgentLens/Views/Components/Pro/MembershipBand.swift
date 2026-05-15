import SwiftUI

// MARK: - Membership Band (macOS)
//
// Horizontal foil strip — embedded inside free-user surfaces (dashboard
// quota panel, onboarding finale) for a tasteful Pro reveal. Mirrors iOS.

struct MembershipBand: View {
    enum Variant {
        case upsell
        case active
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
                Button(action: action, label: { bandRow })
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
        HStack(spacing: 12) {
            leadingDisc
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ProTheme.Palette.mercury)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(ProTheme.Palette.mercury.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailingAffordance
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ProTheme.Palette.aureate)
        }
        .frame(width: 26, height: 26)
    }

    @ViewBuilder
    private var trailingAffordance: some View {
        if variant == .upsell {
            HStack(spacing: 4) {
                Text(ctaLabel)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(ProTheme.Palette.aureate)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ProTheme.Palette.aureate)
            }
        } else {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ProTheme.Palette.aureate)
        }
    }

    @ViewBuilder
    private var backgroundLayers: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous)
                .fill(ProTheme.Palette.obsidian)
            if !reduceMotion {
                RoundedRectangle(cornerRadius: ProTheme.Layout.bandRadius, style: .continuous)
                    .fill(Color.clear)
                    .mercuryShimmer(active: true)
                    .opacity(variant == .upsell ? 0.55 : 0.30)
                    .allowsHitTesting(false)
            }
        }
    }
}

#Preview("Membership Band (macOS)") {
    ZStack {
        DesignSystem.Colors.background.ignoresSafeArea()
        VStack(spacing: 14) {
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
    .frame(width: 520, height: 220)
}
