import SwiftUI
import OpenBurnBarCore

/// Penultimate wizard step. Shows the freshly-connected accounts as a list of
/// chips and offers a "Refresh now" action to confirm data is flowing.
///
/// All connections are surfaced (not just the wizard ones) so reinstalling
/// users see their existing accounts plus the new ones.
struct OnboardingReviewStep: View {
    let connectedAccounts: [ProviderAccountDoc]
    let onRefreshAll: () async -> Void
    let onContinue: () -> Void

    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                Text("All set")
                    .font(MobileTheme.Typography.display)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(connectedAccounts.isEmpty
                     ? "You can connect a provider any time from the Account tab."
                     : "Pull a fresh snapshot now, or finish and let OpenBurnBar do it on its own.")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !connectedAccounts.isEmpty {
                ScrollView {
                    VStack(spacing: MobileTheme.Spacing.sm) {
                        ForEach(connectedAccounts) { account in
                            ConnectedAccountChip(account: account)
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                }
                .frame(maxHeight: 320)

                Button {
                    Task {
                        Haptics.medium()
                        isRefreshing = true
                        await onRefreshAll()
                        isRefreshing = false
                        Haptics.success()
                    }
                } label: {
                    HStack(spacing: MobileTheme.Spacing.sm) {
                        if isRefreshing {
                            MiningPickLoader(.inline)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isRefreshing ? "Refreshing all accounts…" : "Refresh now")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, MobileTheme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                            .stroke(MobileTheme.Colors.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
            } else {
                emptyStateCard
            }

            Spacer(minLength: 0)
        }
    }

    private var emptyStateCard: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text("No providers connected yet")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text("That's totally fine. You can add accounts whenever you're ready from the Account tab.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, MobileTheme.Spacing.lg)
        }
        .frame(maxWidth: .infinity)
        .padding(MobileTheme.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.7))
        )
    }
}

private struct ConnectedAccountChip: View {
    let account: ProviderAccountDoc

    private var providerEnum: AgentProvider? {
        AgentProvider.fromProviderID(account.providerID)
    }

    var body: some View {
        HStack(alignment: .center, spacing: MobileTheme.Spacing.md) {
            if let providerEnum {
                ProviderAvatar(provider: providerEnum, mode: .aurora, size: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(providerEnum?.displayName ?? account.providerID.rawValue)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(account.label)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(MobileTheme.Colors.success)
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .stroke(MobileTheme.Colors.success.opacity(0.3), lineWidth: 0.75)
        )
    }
}

#Preview {
    OnboardingReviewStep(
        connectedAccounts: [],
        onRefreshAll: { },
        onContinue: { }
    )
    .padding()
    .background(EmberSurfaceBackground().ignoresSafeArea())
}
