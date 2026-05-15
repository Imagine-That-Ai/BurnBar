import SwiftUI
import OpenBurnBarCore

// MARK: - Cloud Whisper Strip (macOS popover)
//
// Aurora-language footer strip rendered above the popover action bar.
//
// Free state: warm glass strip with the "OpenBurnBar Cloud" upsell.
// Member state: vivid ember/amber gradient chip with the user's selected
// `CloudBadge` and "Cloud Member · renews …" status line — the same
// language the iOS You-tab row and macOS Cloud settings pane use.
//
// Tapping either parks a deep-link tab in UserDefaults so callers route
// the Settings window straight to `SettingsTab.cloud`.

struct CloudWhisperStrip: View {
    let onOpen: () -> Void

    @StateObject private var entitlement = MacCloudEntitlementStore.shared

    var body: some View {
        Button(action: onOpen) {
            if entitlement.isActive {
                memberChip
            } else {
                upsellRow
            }
        }
        .buttonStyle(.plain)
        .popoverTooltip(entitlement.isActive
                        ? "Open Cloud in Settings"
                        : "Open Cloud upsell in Settings")
        .accessibilityLabel(entitlement.isActive
                            ? "Cloud Member. \(entitlement.humanStatus). Opens Settings."
                            : "OpenBurnBar Cloud. Your agents, unbound. Opens Settings.")
        .onAppear { entitlement.start() }
    }

    // MARK: - Member chip
    //
    // Real "I have this" signal: animated ember/amber gradient, foil
    // hairline, CloudBadge on the left, "Cloud Member" in primary gradient,
    // status subtitle. Distinct enough that it never reads as an ad.

    @ViewBuilder
    private var memberChip: some View {
        HStack(spacing: 12) {
            CloudBadge(size: .custom(28))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("PRO")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [DesignSystem.Colors.ember, DesignSystem.Colors.amber],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        )
                    Text("Cloud Member")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                }
                Text(entitlement.humanStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(DesignSystem.Colors.amber)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(stripBackdrop)
        .overlay(
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.hermesAureate.opacity(0.85),
                            DesignSystem.Colors.amber.opacity(0.55),
                            DesignSystem.Colors.ember.opacity(0.55),
                            DesignSystem.Colors.hermesAureate.opacity(0.85)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
        )
    }

    // MARK: - Upsell row (free)

    @ViewBuilder
    private var upsellRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(
                    LinearGradient(
                        colors: [DesignSystem.Colors.ember.opacity(0.30), DesignSystem.Colors.amber.opacity(0.20)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.amber)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("OpenBurnBar Cloud")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
                Text("Your agents, unbound — hosted refresh, backup, relay.")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.ember)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(stripBackdrop)
    }

    // MARK: - Backdrop (shared)

    @ViewBuilder
    private var stripBackdrop: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(
                LinearGradient(
                    colors: entitlement.isActive
                        ? [
                            DesignSystem.Colors.ember.opacity(0.30),
                            DesignSystem.Colors.amber.opacity(0.24),
                            DesignSystem.Colors.blaze.opacity(0.20),
                            DesignSystem.Colors.whimsy.opacity(0.14)
                        ]
                        : [
                            DesignSystem.Colors.ember.opacity(0.08),
                            DesignSystem.Colors.amber.opacity(0.06),
                            .clear
                        ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }
}
