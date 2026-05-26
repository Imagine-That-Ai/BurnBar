import SwiftUI
import OpenBurnBarCore

/// First-class error card rendered in chat when a per-usage credential hits its
/// spending limit. Shows the rule name, used/limit, period, reset time, and three
/// action buttons: raise the limit by $25, allow this session (temporary override),
/// and open Budget Settings.
///
/// iOS port of the macOS `BudgetBlockedCard`:
/// - Replaces `DesignSystem.Colors.*` with `MobileTheme.*` tokens
/// - Removes hover state (no hover on iOS)
/// - Replaces `.help()` tooltips with `.accessibilityHint()`
/// - Uses `clipShape(.rect(cornerRadius:))` instead of `cornerRadius()`
struct BudgetBlockedCard: View {
    let error: BudgetBlockedError
    let onRaiseLimit: (BudgetRule, Double) -> Void
    let onAllowSession: (BudgetRule) -> Void
    let onOpenSettings: () -> Void

    @State private var raised = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "xmark.octagon.fill")
                .font(.title2)
                .foregroundStyle(MobileTheme.error)

            VStack(alignment: .leading, spacing: 8) {
                header
                details
                actionButtons
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(MobileTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                        .stroke(MobileTheme.error.opacity(0.35), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Budget limit reached for \(error.rule.displayLabel)")
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Budget limit reached")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(MobileTheme.textPrimary)
            Text(error.rule.displayLabel)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.textSecondary)
        }
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("$\(String(format: "%.2f", error.used))")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(MobileTheme.error)
                Text("of")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.textMuted)
                Text("$\(String(format: "%.2f", error.limit))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(MobileTheme.textPrimary)
                Text(periodLabel)
                    .font(.caption2)
                    .foregroundStyle(MobileTheme.textMuted)
            }
            if let resetAt = error.resetAt {
                Text("Resets \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(MobileTheme.textMuted)
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 8) {
            raiseButton
            allowSessionButton
            settingsButton
        }
        .padding(.top, 4)
    }

    private var raiseButton: some View {
        Button {
            onRaiseLimit(error.rule, 25)
            raised = true
        } label: {
            Label(
                raised ? "Raised" : "+$25",
                systemImage: raised ? "checkmark" : "arrow.up.circle"
            )
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(raised
                          ? MobileTheme.success.opacity(0.15)
                          : MobileTheme.ember.opacity(0.15))
            )
            .foregroundStyle(raised ? MobileTheme.success : MobileTheme.ember)
        }
        .buttonStyle(.plain)
        .disabled(raised)
        .accessibilityLabel(raised ? "Limit already raised" : "Raise limit by 25 dollars")
        .accessibilityHint("Increases the budget rule limit by $25")
    }

    private var allowSessionButton: some View {
        Button {
            onAllowSession(error.rule)
        } label: {
            Label("Allow session", systemImage: "arrow.uturn.right.circle")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(MobileTheme.whimsy.opacity(0.12))
                )
                .foregroundStyle(MobileTheme.whimsy)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Allow this session to continue")
        .accessibilityHint("Temporarily bypasses the budget limit for the current session")
    }

    private var settingsButton: some View {
        Button {
            onOpenSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Budget Settings")
        .accessibilityHint("Navigate to the budget settings screen")
    }

    // MARK: - Helpers

    private var periodLabel: String {
        switch error.rule.period {
        case .day: return "per day"
        case .week: return "per week"
        case .month: return "per month"
        case .allTime: return "all time"
        }
    }
}

// MARK: - Preview

#Preview("Budget blocked card") {
    BudgetBlockedCard(
        error: BudgetBlockedError(
            rule: BudgetRule(
                scope: .credential,
                providerID: "openrouter",
                accountID: "abc123",
                label: "OpenRouter main",
                amountUSD: 50,
                period: .month,
                behavior: .warnThenBlock
            ),
            used: 52.37,
            limit: 50,
            fallback: nil,
            resetAt: Calendar.current.date(byAdding: .day, value: 4, to: Date())
        ),
        onRaiseLimit: { _, _ in },
        onAllowSession: { _ in },
        onOpenSettings: {}
    )
    .padding(20)
    .background(MobileTheme.background)
}
