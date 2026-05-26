import SwiftUI
import OpenBurnBarCore

/// First-class error card rendered in chat when a per-usage credential hits its
/// spending limit. Shows the rule name, used/limit, period, reset time, and three
/// action buttons: raise the limit by $25, allow this session (temporary override),
/// and open Budget Settings.
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
                .foregroundStyle(DesignSystem.Colors.error)

            VStack(alignment: .leading, spacing: 8) {
                header
                details
                actionButtons
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(DesignSystem.Colors.error.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Budget limit reached")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text(error.rule.displayLabel)
                .font(.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("$\(String(format: "%.2f", error.used))")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.error)
                Text("of")
                    .font(.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text("$\(String(format: "%.2f", error.limit))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(periodLabel)
                    .font(.caption2)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            if let resetAt = error.resetAt {
                Text("Resets \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }

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
            Label(raised ? "Raised" : "+$25", systemImage: raised ? "checkmark" : "arrow.up.circle")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(raised ? DesignSystem.Colors.success.opacity(0.15) : DesignSystem.Colors.coral.opacity(0.15))
                )
                .foregroundStyle(raised ? DesignSystem.Colors.success : DesignSystem.Colors.coral)
        }
        .buttonStyle(.plain)
        .disabled(raised)
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
                        .fill(DesignSystem.Colors.purple.opacity(0.12))
                )
                .foregroundStyle(DesignSystem.Colors.purple)
        }
        .buttonStyle(.plain)
    }

    private var settingsButton: some View {
        Button { onOpenSettings() } label: {
            Image(systemName: "gearshape")
                .font(.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .help("Open Budget Settings")
    }

    private var periodLabel: String {
        switch error.rule.period {
        case .day: return "per day"
        case .week: return "per week"
        case .month: return "per month"
        case .allTime: return "all time"
        }
    }
}

#if DEBUG
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
    .background(DesignSystem.Colors.background)
}
#endif
