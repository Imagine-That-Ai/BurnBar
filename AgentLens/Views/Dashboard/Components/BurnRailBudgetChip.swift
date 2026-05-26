import SwiftUI
import OpenBurnBarCore

/// Budget status chip for the BurnBar top rail. Shows the most restrictive active
/// rule's used/limit as a compact pill beside the existing delta chip.
///
/// Visible only when at least one budget rule is active and the user has spent
/// more than 50% of any rule's limit. Below 50% the chip stays hidden (too noisy
/// otherwise); at 80%+ it gains a warning tint; at 100%+ it turns error red.
struct BurnRailBudgetChip: View {
    let rules: [BudgetRule]
    let spendByRule: [String: Double]

    @State private var hover = false

    var body: some View {
        if let worst = mostRestrictiveRule {
            chip(for: worst)
        }
    }

    @ViewBuilder
    private func chip(for rule: BudgetRule) -> some View {
        let used = spendByRule[rule.id] ?? 0
        let pct = rule.amountUSD > 0 ? used / rule.amountUSD : 0

        if pct >= 0.5 {
            HStack(spacing: 4) {
                Image(systemName: pct >= 1.0 ? "xmark.octagon.fill" : pct >= 0.8 ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
                    .font(.system(size: 9, weight: .bold))
                Text("$\(String(format: "%.0f", used))/$\(String(format: "%.0f", rule.amountUSD))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(tintFor(pct))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColorFor(pct).opacity(hover ? 0.25 : 0.12))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tintFor(pct).opacity(0.3), lineWidth: 0.5)
                    )
            )
            .onHover { hover = $0 }
            .animation(DesignSystem.Animation.hover, value: hover)
            .help(toolTip(rule: rule, used: used, pct: pct))
            .accessibilityLabel(accessibilityLabel(rule: rule, used: used, pct: pct))
        }
    }

    // MARK: - Computed

    /// The rule closest to or over its limit. Returns nil when no rule is ≥ 50%.
    private var mostRestrictiveRule: BudgetRule? {
        rules
            .filter { $0.isEnabled && $0.amountUSD > 0 }
            .filter { rule in
                let used = spendByRule[rule.id] ?? 0
                return used / rule.amountUSD >= 0.5
            }
            .max(by: { a, b in
                let pctA = (spendByRule[a.id] ?? 0) / a.amountUSD
                let pctB = (spendByRule[b.id] ?? 0) / b.amountUSD
                return pctA < pctB
            })
    }

    private func tintFor(_ pct: Double) -> Color {
        if pct >= 1.0 { return DesignSystem.Colors.error }
        if pct >= 0.8 { return DesignSystem.Colors.warning }
        return DesignSystem.Colors.textSecondary
    }

    private func backgroundColorFor(_ pct: Double) -> Color {
        if pct >= 1.0 { return DesignSystem.Colors.error }
        if pct >= 0.8 { return DesignSystem.Colors.warning }
        return DesignSystem.Colors.textSecondary
    }

    private func toolTip(rule: BudgetRule, used: Double, pct: Double) -> String {
        if pct >= 1.0 {
            return "\(rule.displayLabel): BLOCKED — $\(String(format: "%.2f", used)) of $\(String(format: "%.2f", rule.amountUSD)) \(periodLabel(rule.period)). Click to open Budgets."
        }
        return "\(rule.displayLabel): $\(String(format: "%.2f", used)) of $\(String(format: "%.2f", rule.amountUSD)) \(periodLabel(rule.period)) (\(Int(pct * 100))%)"
    }

    private func accessibilityLabel(rule: BudgetRule, used: Double, pct: Double) -> String {
        let status = pct >= 1.0 ? "blocked" : "\(Int(pct * 100))% used"
        return "Budget \(rule.displayLabel): \(status), $\(String(format: "%.2f", used)) of $\(String(format: "%.2f", rule.amountUSD))"
    }

    private func periodLabel(_ period: BudgetPeriod) -> String {
        switch period {
        case .day: return "per day"
        case .week: return "per week"
        case .month: return "per month"
        case .allTime: return "all time"
        }
    }
}

#if DEBUG
#Preview("Budget chip — 80% warning") {
    BurnRailBudgetChip(
        rules: [
            BudgetRule(scope: .credential, providerID: "openrouter", label: "OpenRouter main", amountUSD: 50, period: .month, behavior: .warnThenBlock),
        ],
        spendByRule: ["openrouter-abc": 42]
    )
    .padding(20)
    .background(DesignSystem.Colors.background)
}

#Preview("Budget chip — 100% blocked") {
    let rule = BudgetRule(scope: .global, label: "All per-usage", amountUSD: 100, period: .month, behavior: .warnThenBlock)
    BurnRailBudgetChip(
        rules: [rule],
        spendByRule: [rule.id: 103.50]
    )
    .padding(20)
    .background(DesignSystem.Colors.background)
}
#endif
