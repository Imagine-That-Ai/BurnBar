import SwiftUI
import OpenBurnBarCore

/// Per-provider drain-target switcher.
///
/// Renders the accounts (switcher profiles) for a single provider and makes the
/// one currently burning quota — the "drain target" — unmistakable: full colour,
/// an ember pulse, a tinted glass surface. Every other account dims back so the
/// eye lands on the live one instantly. Tapping any account promotes it to the
/// drain target for this provider only; sibling providers are untouched.
///
/// Two variants share one visual language:
///   - `.compact` — a single provider row for the menu-bar popover (~290pt wide).
///   - `.full`    — stacked cards for the dashboard and settings.
struct DrainTargetSwitcher: View {
    enum Variant { case compact, full }

    let provider: AgentProvider
    /// All selectable accounts (CLI profiles) for `provider`, pre-sorted.
    let accounts: [SwitcherProfileRecord]
    /// The profile id currently draining quota for this provider, if any.
    let drainProfileID: String?
    var variant: Variant = .compact
    /// Optional short quota string per account (e.g. "62% left"). Returns nil to omit.
    var quotaText: (SwitcherProfileRecord) -> String? = { _ in nil }
    /// Invoked when the user picks a new drain target.
    let onSelect: (SwitcherProfileRecord) -> Void

    @State private var hoveredID: String?

    private var theme: ProviderTheme { ProviderTheme.theme(for: provider) }

    private var drainAccount: SwitcherProfileRecord? {
        guard let drainProfileID else { return nil }
        return accounts.first { $0.id == drainProfileID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header
            if accounts.isEmpty {
                emptyState
            } else {
                switch variant {
                case .compact: compactChips
                case .full: fullRows
                }
            }
        }
        .animation(DesignSystem.Animation.snappy, value: drainProfileID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ProviderQuotaIdentityOrb(provider: provider, isActive: drainProfileID != nil)

            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)

                if let drainAccount {
                    HStack(spacing: 5) {
                        DrainPulseDot(isLive: true)
                            .frame(width: 12, height: 12)
                        Text("Draining \(drainAccount.displayName)")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.ember)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text(accounts.isEmpty ? "No accounts connected" : "No drain target — pick one")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Compact (popover) — chips

    private var compactChips: some View {
        // A wrapping row keeps short labels intact without horizontal scrolling,
        // matching the popover's one-thing-per-line rhythm.
        FlowLayout(horizontalSpacing: DesignSystem.Spacing.xs, verticalSpacing: DesignSystem.Spacing.xs) {
            ForEach(accounts) { account in
                chip(account)
            }
        }
    }

    private func chip(_ account: SwitcherProfileRecord) -> some View {
        let isDrain = account.id == drainProfileID
        let isHovering = hoveredID == account.id
        return Button {
            guard !isDrain else { return }
            onSelect(account)
        } label: {
            HStack(spacing: 5) {
                if isDrain {
                    DrainPulseDot(isLive: true).frame(width: 12, height: 12)
                } else {
                    Circle()
                        .fill(theme.primaryColor.opacity(0.5))
                        .frame(width: 5, height: 5)
                }
                Text(account.displayName)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(isDrain ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let quota = quotaText(account) {
                    Text(quota)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(isDrain ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 5)
            .background(chipBackground(isDrain: isDrain))
            .overlay(chipBorder(isDrain: isDrain))
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isDrain ? 1 : (isHovering ? 0.85 : 0.55))
        .scaleEffect(isHovering && !isDrain ? 1.04 : 1)
        .animation(DesignSystem.Animation.gentle, value: isHovering)
        .onHover { hovering in hoveredID = hovering ? account.id : (hoveredID == account.id ? nil : hoveredID) }
        .help(isDrain ? "Currently draining \(account.displayName)" : "Switch drain target to \(account.displayName)")
        .accessibilityLabel(account.displayName)
        .accessibilityValue(isDrain ? "Draining" : "Idle")
        .accessibilityAddTraits(isDrain ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Full (dashboard / settings) — rows

    private var fullRows: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(accounts) { account in
                row(account)
            }
        }
    }

    private func row(_ account: SwitcherProfileRecord) -> some View {
        let isDrain = account.id == drainProfileID
        let isHovering = hoveredID == account.id
        return Button {
            guard !isDrain else { return }
            onSelect(account)
        } label: {
            GlassCard(interactive: !isDrain) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    if isDrain {
                        DrainPulseDot(isLive: true).frame(width: 18, height: 18)
                    } else {
                        Circle()
                            .strokeBorder(theme.primaryColor.opacity(0.4), lineWidth: 1.5)
                            .frame(width: 12, height: 12)
                            .padding(3)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.displayName)
                            .font(DesignSystem.Typography.body)
                            .fontWeight(isDrain ? .semibold : .regular)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail = account.cliMetadata?.accountDescription, !detail.isEmpty {
                            Text(detail)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: DesignSystem.Spacing.xs)

                    if let quota = quotaText(account) {
                        Text(quota)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .monospacedDigit()
                    }

                    if isDrain {
                        Text("DRAINING")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.ember)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(DesignSystem.Colors.ember.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
            }
        }
        .buttonStyle(.plain)
        .background(rowBackground(isDrain: isDrain))
        .overlay(rowBorder(isDrain: isDrain))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .opacity(isDrain ? 1 : (isHovering ? 0.9 : 0.6))
        .scaleEffect(isHovering && !isDrain ? 1.01 : 1)
        .animation(DesignSystem.Animation.gentle, value: isHovering)
        .onHover { hovering in hoveredID = hovering ? account.id : (hoveredID == account.id ? nil : hoveredID) }
        .accessibilityLabel(account.displayName)
        .accessibilityValue(isDrain ? "Draining" : "Idle")
        .accessibilityAddTraits(isDrain ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Empty

    private var emptyState: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text("No \(provider.displayName) accounts yet")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Backgrounds / borders

    private func chipBackground(isDrain: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(isDrain
                ? AnyShapeStyle(LinearGradient(
                    colors: [DesignSystem.Colors.ember.opacity(0.18), DesignSystem.Colors.amber.opacity(0.12)],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                : AnyShapeStyle(DesignSystem.Colors.surfaceElevated))
    }

    private func chipBorder(isDrain: Bool) -> some View {
        Capsule(style: .continuous)
            .strokeBorder(
                isDrain ? DesignSystem.Colors.ember.opacity(0.45) : DesignSystem.Colors.border.opacity(0.4),
                lineWidth: isDrain ? 1 : 0.5
            )
    }

    private func rowBackground(isDrain: Bool) -> some View {
        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
            .fill(isDrain ? DesignSystem.Colors.ember.opacity(0.10) : Color.clear)
    }

    private func rowBorder(isDrain: Bool) -> some View {
        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
            .strokeBorder(
                isDrain ? DesignSystem.Colors.ember.opacity(0.40) : Color.clear,
                lineWidth: isDrain ? 1 : 0
            )
    }

    // MARK: - Accessibility

    private var accessibilitySummary: String {
        let drain = drainAccount?.displayName ?? "none"
        let others = accounts.filter { $0.id != drainProfileID }.map(\.displayName)
        let otherText = others.isEmpty ? "" : ". Other accounts: \(others.joined(separator: ", "))"
        return "\(provider.displayName) drain target: \(drain)\(otherText)"
    }
}

// MARK: - Drain pulse dot

/// Self-contained ember pulse used to mark the live drain target. Mirrors the
/// look of the burn-rail pulse without coupling to its private definition.
private struct DrainPulseDot: View {
    let isLive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(DesignSystem.Colors.ember.opacity(0.35))
                .frame(width: 18, height: 18)
                .opacity(isLive ? 0.28 : 0)
            Circle()
                .fill(isLive ? DesignSystem.Colors.ember : DesignSystem.Colors.textMuted)
                .frame(width: 7, height: 7)
                .shadow(color: DesignSystem.Colors.ember.opacity(isLive ? 0.65 : 0), radius: 4, y: 0)
        }
        .frame(width: 18, height: 18)
    }
}

extension DrainTargetSwitcher {
    /// Groups CLI switcher profiles by their provider for drain-target display:
    /// providers sorted by name, accounts within each sorted by `sortKey`.
    /// Browser profiles (no `cliType`) are excluded. Centralised so the popover
    /// and dashboard render identical groupings from one tested code path.
    static func grouped(
        _ profiles: [SwitcherProfileRecord]
    ) -> [(provider: AgentProvider, accounts: [SwitcherProfileRecord])] {
        let cliProfiles = profiles.filter { $0.cliType != nil }
        let byProvider: [AgentProvider: [SwitcherProfileRecord]] = Dictionary(
            grouping: cliProfiles
        ) { profile in
            profile.cliType?.agentProvider ?? .claudeCode
        }
        return byProvider
            .map { (provider: $0.key, accounts: $0.value.sorted { $0.sortKey < $1.sortKey }) }
            .sorted { $0.provider.displayName < $1.provider.displayName }
    }
}
