import SwiftUI
import OpenBurnBarCore

// MARK: - Routing Visuals

/// Mobile tint binding for `ProviderRoutingStateText`. The text/icon labels
/// live in `OpenBurnBarCore` so iPhone, iPad, and Mac stay in lockstep; only
/// the platform-bound color binding lives here.
enum ProviderRoutingMobileVisual {
    static func label(_ state: ProviderRoutingQuotaState) -> String {
        ProviderRoutingStateText.label(state)
    }

    static func iconName(_ state: ProviderRoutingQuotaState) -> String {
        ProviderRoutingStateText.iconName(state)
    }

    static func tint(_ state: ProviderRoutingQuotaState) -> Color {
        switch state {
        case .healthy: return MobileTheme.Colors.success
        case .pressure: return MobileTheme.amber
        case .unknown: return MobileTheme.Colors.textMuted
        case .coolingDown, .rateLimited: return MobileTheme.Colors.warning
        case .exhausted, .authFailed: return MobileTheme.Colors.error
        case .disabled, .deleted: return MobileTheme.Colors.textMuted
        }
    }
}

// MARK: - Routing Cockpit (Mobile)

/// Routing lanes for one provider. Renders the active account, the next
/// fallback, and any blocked accounts. Uses native iOS/iPadOS styling and
/// never renders credential handles, secret refs, or bearer tokens.
struct ProviderRoutingCockpit: View {
    let provider: AgentProvider
    let state: ProviderRoutingStateSnapshot
    var compact: Bool = false

    private var blockedAccounts: [ProviderRoutingCandidate] {
        state.exhaustedOrCoolingDownAccounts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            headerRow
            providerChangePopup
            lanesRow
            switchReasonRow
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .stroke(MobileTheme.Colors.border.opacity(0.5), lineWidth: 0.5)
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: latestProviderChangeEvent?.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isHeader)
    }

    private var headerRow: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.primary(for: provider))

            Text("Router")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)

            Spacer()

            routerStatusPill
        }
    }

    @ViewBuilder
    private var routerStatusPill: some View {
        if state.activeAccount != nil && blockedAccounts.isEmpty {
            routingPill("Automatic", tint: MobileTheme.Colors.success, icon: "bolt.fill")
        } else if state.activeAccount != nil {
            routingPill("Holding line", tint: MobileTheme.amber, icon: "shield.lefthalf.filled")
        } else {
            routingPill("Needs attention", tint: MobileTheme.Colors.warning, icon: "exclamationmark.triangle.fill")
        }
    }

    // MARK: - Provider Change Popup

    @ViewBuilder
    private var providerChangePopup: some View {
        if let event = latestProviderChangeEvent {
            let source = event.providerChangeSourceLabel ?? "Previous provider"
            let destination = event.providerChangeDestinationLabel ?? "New provider"
            let model = event.providerChangeModelLabel ?? "requested model"
            let reason = sanitizedReason(event.failoverReason ?? event.reason)
            let sourceTint = providerChangeTint(for: event.originalProviderID, fallback: MobileTheme.blaze)
            let destinationTint = providerChangeTint(
                for: event.failoverDestinationProviderID,
                fallback: MobileTheme.Colors.primary(for: provider)
            )

            HStack(alignment: .center, spacing: MobileTheme.Spacing.sm) {
                providerLogoHandoff(event)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(event.exactModelInvariantPassed ? "Provider changed" : "Provider change blocked")
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        routingPill(
                            event.exactModelInvariantPassed ? "Same model" : "Check model",
                            tint: event.exactModelInvariantPassed ? MobileTheme.Colors.success : MobileTheme.Colors.warning,
                            icon: event.exactModelInvariantPassed ? "equal.circle.fill" : "exclamationmark.triangle.fill"
                        )
                    }

                    HStack(spacing: 6) {
                        Text(source)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(destinationTint)
                        Text(destination)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                    Text(
                        event.exactModelInvariantPassed
                            ? "\(model) stayed exact\(reason.map { " because \($0)" } ?? ".")"
                            : "Exact model proof was missing\(reason.map { " because \($0)" } ?? ".")"
                    )
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(MobileTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                sourceTint.opacity(0.14),
                                MobileTheme.Colors.surfaceElevated.opacity(0.82),
                                destinationTint.opacity(0.13)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [sourceTint.opacity(0.42), destinationTint.opacity(0.42)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                event.exactModelInvariantPassed
                    ? "Provider changed from \(source) to \(destination). \(model) stayed exact."
                    : "Provider change from \(source) to \(destination) did not pass exact model proof."
            )
        }
    }

    @ViewBuilder
    private func providerLogoHandoff(_ event: ProviderRoutingDecisionEvent) -> some View {
        let sourceTint = providerChangeTint(for: event.originalProviderID, fallback: MobileTheme.blaze)
        let destinationTint = providerChangeTint(
            for: event.failoverDestinationProviderID,
            fallback: MobileTheme.Colors.primary(for: provider)
        )
        HStack(spacing: 0) {
            providerLogoTile(providerID: event.originalProviderID, fallbackSymbol: "cpu", tint: sourceTint)
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [sourceTint, destinationTint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 18, height: 18)
            .padding(.horizontal, -3)
            .zIndex(1)
            providerLogoTile(providerID: event.failoverDestinationProviderID, fallbackSymbol: "terminal", tint: destinationTint)
        }
        .shadow(color: destinationTint.opacity(0.25), radius: 8, y: 3)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func providerLogoTile(providerID: ProviderID?, fallbackSymbol: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(tint.opacity(0.32), lineWidth: 0.7)
                )
            if let providerID,
               let provider = AgentProvider.fromProviderID(providerID) {
                ProviderAvatar(provider: provider, mode: .plain, size: 24)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 34, height: 34)
    }

    private func providerChangeTint(for providerID: ProviderID?, fallback: Color) -> Color {
        guard let providerID,
              let provider = AgentProvider.fromProviderID(providerID) else {
            return fallback
        }
        return MobileTheme.Colors.primary(for: provider)
    }

    @ViewBuilder
    private var lanesRow: some View {
        if compact {
            // Compact phone/iPad rows must stay narrow and never truncate the
            // account label. Stacking vertically keeps each lane on a single
            // legible line and matches the rhythm of the surrounding cards.
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                compactLaneRow(
                    title: "Active",
                    icon: "arrowtriangle.right.circle.fill",
                    candidate: state.activeAccount,
                    emptyText: "No eligible account",
                    accentTint: MobileTheme.Colors.success
                )
                compactLaneRow(
                    title: "Next",
                    icon: "arrow.triangle.branch",
                    candidate: state.nextFallback,
                    emptyText: "No fallback",
                    accentTint: MobileTheme.Colors.primary(for: provider)
                )
                compactBlockedRow
            }
        } else {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
                laneCard(
                    title: "Active",
                    icon: "arrowtriangle.right.circle.fill",
                    candidate: state.activeAccount,
                    emptyText: "No eligible account",
                    accentTint: MobileTheme.Colors.success
                )

                laneCard(
                    title: "Next",
                    icon: "arrow.triangle.branch",
                    candidate: state.nextFallback,
                    emptyText: "No fallback",
                    accentTint: MobileTheme.Colors.primary(for: provider)
                )

                blockedLaneCard
            }
        }
    }

    private func compactLaneRow(
        title: String,
        icon: String,
        candidate: ProviderRoutingCandidate?,
        emptyText: String,
        accentTint: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accentTint)
            // `fixedSize` so titles like "Active" / "Next" / "Blocked" don't
            // clip at large Dynamic Type sizes; the spacer below absorbs the
            // remaining width.
            Text(title)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .fixedSize(horizontal: true, vertical: false)

            if let candidate {
                Circle()
                    .fill(ProviderRoutingMobileVisual.tint(candidate.quotaState))
                    .frame(width: 6, height: 6)
                Text(candidate.accountLabel)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(ProviderRoutingMobileVisual.label(candidate.quotaState))
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
            } else {
                Text(emptyText)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var compactBlockedRow: some View {
        if blockedAccounts.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.success)
                Text("Blocked")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .fixedSize(horizontal: true, vertical: false)
                Text("None")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MobileTheme.Colors.warning)
                    Text("Blocked")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                ForEach(Array(blockedAccounts.prefix(2)), id: \.id) { account in
                    HStack(spacing: 6) {
                        Spacer().frame(width: 16)
                        Circle()
                            .fill(ProviderRoutingMobileVisual.tint(account.quotaState))
                            .frame(width: 6, height: 6)
                        Text(account.accountLabel)
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(ProviderRoutingMobileVisual.label(account.quotaState))
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                if blockedAccounts.count > 2 {
                    Text("+\(blockedAccounts.count - 2) more")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .padding(.leading, 22)
                }
            }
        }
    }

    private func laneCard(
        title: String,
        icon: String,
        candidate: ProviderRoutingCandidate?,
        emptyText: String,
        accentTint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentTint)
                Text(title)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }

            if let candidate {
                Text(candidate.accountLabel)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    Circle()
                        .fill(ProviderRoutingMobileVisual.tint(candidate.quotaState))
                        .frame(width: 6, height: 6)
                    Text(ProviderRoutingMobileVisual.label(candidate.quotaState))
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(1)
                    Image(systemName: ProviderAccountStorageVisual.iconName(candidate.storageScope))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ProviderAccountStorageVisual.tint(candidate.storageScope))
                }
            } else {
                Text(emptyText)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, MobileTheme.Spacing.xs)
    }

    private var blockedLaneCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: blockedAccounts.isEmpty ? "checkmark.shield.fill" : "pause.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(blockedAccounts.isEmpty ? MobileTheme.Colors.success : MobileTheme.Colors.warning)
                Text("Blocked")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }

            if blockedAccounts.isEmpty {
                Text("None")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
            } else {
                ForEach(Array(blockedAccounts.prefix(2).enumerated()), id: \.element.id) { _, account in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(ProviderRoutingMobileVisual.tint(account.quotaState))
                            .frame(width: 6, height: 6)
                        Text(account.accountLabel)
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if blockedAccounts.count > 2 {
                    Text("+\(blockedAccounts.count - 2) more")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, MobileTheme.Spacing.xs)
    }

    @ViewBuilder
    private var switchReasonRow: some View {
        if let reason = sanitizedReason(state.lastSwitchReason) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.xs) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Text(reason)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private func routingPill(_ text: String, tint: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.medium)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }

    private var latestProviderChangeEvent: ProviderRoutingDecisionEvent? {
        state.recentEvents.last(where: { $0.isProviderChangeFailover }) ?? Self.debugForcedProviderChangeEvent
    }

    #if DEBUG
    private static let debugForcedProviderChangeEvent = ProviderRoutingDecisionEvent(
        id: UUID(uuidString: "7F570BF2-9A2B-4C52-9CB1-2AB1E8D7B55D")!,
        occurredAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
        modelID: "gpt-5.4",
        routerMode: .sameModelFailover,
        selected: ProviderRoutingCandidate(
            providerID: .codex,
            accountID: "codex-debug-preview",
            accountLabel: "Codex backup",
            credentialHandle: "debug-preview",
            storageScope: .deviceKeychain,
            modelCompatibility: .compatible,
            canonicalModelID: "gpt-5.4",
            quotaState: .healthy,
            cooldownUntil: nil,
            priority: 0,
            routingEnabled: true,
            lastUsedAt: nil,
            lastFailureCode: nil,
            localCredentialAvailable: true
        ),
        nextFallback: nil,
        originalProviderID: .openAI,
        originalAccountID: "openai-debug-primary",
        originalAccountLabel: "OpenAI primary",
        attemptedModelID: "gpt-5.4",
        attemptedCanonicalModelID: "gpt-5.4",
        failoverDestination: ProviderRoutingCandidate(
            providerID: .codex,
            accountID: "codex-debug-preview",
            accountLabel: "Codex backup",
            credentialHandle: "debug-preview",
            storageScope: .deviceKeychain,
            modelCompatibility: .compatible,
            canonicalModelID: "gpt-5.4",
            quotaState: .healthy,
            cooldownUntil: nil,
            priority: 0,
            routingEnabled: true,
            lastUsedAt: nil,
            lastFailureCode: nil,
            localCredentialAvailable: true
        ),
        failoverReason: "OpenAI primary is exhausted; Codex backup serves the exact same canonical model.",
        exactModelInvariantPassed: true,
        reason: "OpenAI primary is exhausted; Codex backup serves the exact same canonical model.",
        explanation: "Debug preview of exact model failover.",
        skipped: []
    )
    #else
    private static let debugForcedProviderChangeEvent: ProviderRoutingDecisionEvent? = nil
    #endif

    /// Defense-in-depth: routing reasons are sanitized server-side, but the
    /// UI never renders them without a final sweep so a stray credential
    /// string can't slip through.
    private func sanitizedReason(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let sanitized = ProviderRoutingPolicy.sanitizedAuditText(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    private var accessibilitySummary: String {
        let active = state.activeAccount?.accountLabel ?? "none"
        let fallback = state.nextFallback?.accountLabel ?? "none"
        let blocked = blockedAccounts.isEmpty
            ? "none"
            : blockedAccounts.map { "\($0.accountLabel) is \(ProviderRoutingMobileVisual.label($0.quotaState).lowercased())" }
                .joined(separator: ", ")
        let reason = sanitizedReason(state.lastSwitchReason).map { ". \($0)" } ?? ""
        return "Provider router for \(provider.displayName). Active account \(active). Next fallback \(fallback). Blocked accounts: \(blocked)\(reason)"
    }
}
