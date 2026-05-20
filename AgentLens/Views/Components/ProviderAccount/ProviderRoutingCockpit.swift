import SwiftUI
import OpenBurnBarCore

// MARK: - Routing Visuals

/// Mac tint binding for `ProviderRoutingStateText`. The text/icon labels live
/// in `OpenBurnBarCore` so iPhone, iPad, and Mac stay in lockstep; only the
/// platform-bound color binding lives here.
enum ProviderRoutingVisual {
    static func label(_ state: ProviderRoutingQuotaState) -> String {
        ProviderRoutingStateText.label(state)
    }

    static func iconName(_ state: ProviderRoutingQuotaState) -> String {
        ProviderRoutingStateText.iconName(state)
    }

    static func tint(_ state: ProviderRoutingQuotaState) -> Color {
        switch state {
        case .healthy:
            return DesignSystem.Colors.success
        case .pressure:
            return DesignSystem.Colors.amber
        case .unknown:
            return DesignSystem.Colors.textMuted
        case .coolingDown, .rateLimited:
            return DesignSystem.Colors.warning
        case .exhausted, .authFailed:
            return DesignSystem.Colors.error
        case .disabled, .deleted:
            return DesignSystem.Colors.textMuted
        }
    }
}

// MARK: - Provider Routing Cockpit

/// Live "routing lanes" view for one provider. Renders the active account,
/// the next fallback, and any blocked accounts with calm control-panel
/// styling. Switch reasons are sanitized server-side; this view never renders
/// credential handles, secret refs, cookies, bearer strings, or API keys.
struct ProviderRoutingCockpit: View {
    let provider: AgentProvider
    let state: ProviderRoutingStateSnapshot
    var compact: Bool = false

    @State private var showsHistory = false

    private var blockedAccounts: [ProviderRoutingCandidate] {
        state.exhaustedOrCoolingDownAccounts
    }

    private var hasMeaningfulHistory: Bool {
        // The disclosure earns its space when there's something the
        // switch-reason row above can't show: a second decision, a skipped
        // candidate breakdown, or a different earlier reason. A single event
        // whose reason already appears in `lastSwitchReason` is redundant.
        let nonEmptyEvents = state.recentEvents.filter { event in
            !event.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !event.skipped.isEmpty
        }
        if nonEmptyEvents.count > 1 { return true }
        if let only = nonEmptyEvents.first, !only.skipped.isEmpty { return true }
        if let only = nonEmptyEvents.first,
           let displayed = sanitizedReason(state.lastSwitchReason),
           sanitizedReason(only.reason) != displayed {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            headerRow
            selectedRouteRow
            lanesRow
            switchReasonRow
            benchmarkFreshnessRow
            historyDisclosure
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.36))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.primary(for: provider))

            Text("Router")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            routingPill(
                state.routerMode.usesExactSameModelInvariant ? "Exact model" : "Provider family",
                tint: state.routerMode.usesExactSameModelInvariant ? DesignSystem.Colors.blaze : DesignSystem.Colors.primary(for: provider),
                icon: state.routerMode.usesExactSameModelInvariant ? "equal.circle" : "rectangle.2.swap",
                help: state.routerMode.usesExactSameModelInvariant
                    ? "Fallback may cross providers only when the next route proves the exact same canonical model."
                    : "Fallback is limited to accounts in the selected provider family."
            )

            Spacer(minLength: DesignSystem.Spacing.sm)

            routerStatusPill
        }
    }

    @ViewBuilder
    private var selectedRouteRow: some View {
        if state.selectedModelID != nil || state.selectedProviderID != nil || state.selectedAccountID != nil {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "scope")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(selectedRouteSummary)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var routerStatusPill: some View {
        if state.activeAccount != nil && blockedAccounts.isEmpty {
            routingPill(
                "Automatic",
                tint: DesignSystem.Colors.success,
                icon: "bolt.fill",
                help: "Router is selecting the healthiest account automatically."
            )
        } else if state.activeAccount != nil {
            routingPill(
                "Holding line",
                tint: DesignSystem.Colors.amber,
                icon: "shield.lefthalf.filled",
                help: "An account is routing traffic, but at least one peer is blocked or cooling down."
            )
        } else {
            routingPill(
                "Needs attention",
                tint: DesignSystem.Colors.warning,
                icon: "exclamationmark.triangle.fill",
                help: "No account is eligible to handle traffic right now. Review the blocked accounts below."
            )
        }
    }

    // MARK: - Lanes

    @ViewBuilder
    private var lanesRow: some View {
        if compact {
            // Popover mode: 290pt of usable width is too tight to read three
            // truncated lane cards side by side. Stacking vertically keeps the
            // labels intact and matches the popover's existing one-thing-
            // per-row rhythm.
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                compactLaneRow(
                    title: "Active",
                    icon: "arrowtriangle.right.circle.fill",
                    candidate: state.activeAccount,
                    emptyText: "No eligible account",
                    accentTint: DesignSystem.Colors.success
                )
                compactLaneRow(
                    title: "Next",
                    icon: "arrow.triangle.branch",
                    candidate: state.nextFallback,
                    emptyText: "No fallback",
                    accentTint: DesignSystem.Colors.primary(for: provider)
                )
                compactBlockedRow
            }
        } else {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                laneCard(
                    title: "Active",
                    icon: "arrowtriangle.right.circle.fill",
                    candidate: state.activeAccount,
                    emptyText: "No eligible account",
                    accentTint: DesignSystem.Colors.success
                )

                laneCard(
                    title: "Next",
                    icon: "arrow.triangle.branch",
                    candidate: state.nextFallback,
                    emptyText: "No fallback",
                    accentTint: DesignSystem.Colors.primary(for: provider)
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accentTint)
            Text(title)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: true, vertical: false)

            if let candidate {
                quotaStateDot(candidate.quotaState)
                Text(candidate.accountLabel)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(ProviderRoutingVisual.label(candidate.quotaState))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            } else {
                Text(emptyText)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.success)
                Text("Blocked")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: true, vertical: false)
                Text("None")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.warning)
                    Text("Blocked")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                ForEach(Array(blockedAccounts.prefix(2)), id: \.id) { account in
                    HStack(spacing: 6) {
                        Spacer().frame(width: 16)
                        quotaStateDot(account.quotaState)
                        Text(account.accountLabel)
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(ProviderRoutingVisual.label(account.quotaState))
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                if blockedAccounts.count > 2 {
                    Text("+\(blockedAccounts.count - 2) more")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accentTint)
                Text(title)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            if let candidate {
                Text(candidate.accountLabel)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    quotaStateDot(candidate.quotaState)
                    Text(ProviderRoutingVisual.label(candidate.quotaState))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                    Image(systemName: ProviderAccountStorage.iconName(candidate.storageScope))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ProviderAccountStorage.tint(candidate.storageScope))
                        .help(ProviderAccountStorage.description(candidate.storageScope))
                }

                if let cooldown = candidate.cooldownUntil, cooldown > Date() {
                    Text("Resumes \(cooldown.formatted(.relative(presentation: .named)))")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .lineLimit(1)
                }
            } else {
                Text(emptyText)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    private var blockedLaneCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: blockedAccounts.isEmpty ? "checkmark.shield.fill" : "pause.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(blockedAccounts.isEmpty ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
                Text("Blocked")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            if blockedAccounts.isEmpty {
                Text("None")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            } else {
                ForEach(Array(blockedAccounts.prefix(2).enumerated()), id: \.element.id) { _, account in
                    HStack(spacing: 5) {
                        quotaStateDot(account.quotaState)
                        Text(account.accountLabel)
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(blockedAccountHelp(account))
                }

                if blockedAccounts.count > 2 {
                    Text("+\(blockedAccounts.count - 2) more")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    // MARK: - Switch Reason

    @ViewBuilder
    private var switchReasonRow: some View {
        if let reason = sanitizedReason(state.latestExplanation ?? state.lastSwitchReason) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(reason)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var benchmarkFreshnessRow: some View {
        if state.routerMode == .intelligentModelRouter, let status = state.benchmarkStatus {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(benchmarkSummary(status))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - History Disclosure

    @ViewBuilder
    private var historyDisclosure: some View {
        if !compact, hasMeaningfulHistory {
            DisclosureGroup(isExpanded: $showsHistory) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(displayedEvents) { event in
                        routingEventRow(event)
                    }
                }
                .padding(.top, DesignSystem.Spacing.xs)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Text(showsHistory ? "Hide router history" : "Show router history")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
            .accessibilityHint(Text("Shows recent routing decisions for this provider."))
        }
    }

    private var displayedEvents: [ProviderRoutingDecisionEvent] {
        Array(state.recentEvents.suffix(8).reversed())
    }

    private func routingEventRow(_ event: ProviderRoutingDecisionEvent) -> some View {
        let timestamp = event.occurredAt.formatted(.relative(presentation: .named))
        let active = event.selectedAccountLabel ?? "No active account"
        let reason = sanitizedReason(event.reason) ?? "Routing decision"

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: event.selectedAccountID != nil ? "arrowtriangle.right.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(event.selectedAccountID != nil ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
                Text(active)
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(timestamp)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Text(reason)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.30), lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    private func quotaStateDot(_ state: ProviderRoutingQuotaState) -> some View {
        Circle()
            .fill(ProviderRoutingVisual.tint(state))
            .frame(width: 6, height: 6)
    }

    private func routingPill(_ text: String, tint: Color, icon: String, help: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.medium)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
        .help(help ?? "")
    }

    private func blockedAccountHelp(_ candidate: ProviderRoutingCandidate) -> String {
        var parts = [ProviderRoutingVisual.label(candidate.quotaState)]
        if let cooldown = candidate.cooldownUntil, cooldown > Date() {
            parts.append("Resumes \(cooldown.formatted(.relative(presentation: .named)))")
        }
        parts.append(ProviderAccountStorage.description(candidate.storageScope))
        return parts.joined(separator: " · ")
    }

    private var selectedRouteSummary: String {
        var parts: [String] = []
        if let providerID = state.selectedProviderID {
            parts.append("provider \(providerID.rawValue)")
        }
        if let accountID = state.selectedAccountID {
            parts.append("account \(accountID)")
        }
        if let modelID = state.selectedModelID {
            parts.append("model \(modelID)")
        }
        return "Selected route: " + (parts.isEmpty ? "automatic" : parts.joined(separator: " · "))
    }

    private func benchmarkSummary(_ status: ProviderModelBenchmarkStatus) -> String {
        let source = status.source.rawValue.replacingOccurrences(of: "_", with: " ")
        let fetched = status.fetchedAt.map { " · \($0.formatted(.relative(presentation: .named)))" } ?? ""
        return "Benchmark freshness: \(status.freshness.rawValue) from \(source)\(fetched). \(status.message)"
    }

    /// Defense-in-depth: routing reasons are sanitized server-side, but the UI
    /// never renders them without a final sweep so a stray credential string
    /// can't slip through into the rendered text.
    private func sanitizedReason(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let sanitized = ProviderRoutingPolicy.sanitizedAuditText(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    // MARK: - Accessibility

    private var accessibilitySummary: String {
        let active = state.activeAccount?.accountLabel ?? "none"
        let fallback = state.nextFallback?.accountLabel ?? "none"
        let blocked = blockedAccounts.isEmpty
            ? "none"
            : blockedAccounts.map { "\($0.accountLabel) is \(ProviderRoutingVisual.label($0.quotaState).lowercased())" }
                .joined(separator: ", ")
        let reason = sanitizedReason(state.latestExplanation ?? state.lastSwitchReason).map { ". \($0)" } ?? ""
        return "Provider router for \(provider.displayName). Mode \(state.routerMode.rawValue). Active account \(active). Next fallback \(fallback). Blocked accounts: \(blocked)\(reason)"
    }
}
