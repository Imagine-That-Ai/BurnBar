import SwiftUI
import OpenBurnBarCore

/// Budget status chip for the Pulse top rail. Shows the most restrictive active
/// rule's used/limit as a compact pill.
///
/// Threshold behavior:
/// - **Hidden** when all rules are below 50% usage (too noisy otherwise)
/// - **Neutral** at 50–79% (secondary text tint)
/// - **Warning** at 80–99% (amber tint with triangle icon)
/// - **Error** at ≥ 100% (error red with octagon icon)
///
/// iOS port of `BurnRailBudgetChip`:
/// - Renamed to `BudgetStatusChip` per iOS naming conventions
/// - Replaces `DesignSystem.*` tokens with `MobileTheme.*` equivalents
/// - Removes hover state and `.onHover` modifier (no hover on iOS)
/// - Replaces `.help()` tooltip with `.accessibilityLabel()` only
struct BudgetStatusChip: View {
    let rules: [BudgetRule]
    let spendByRule: [String: Double]

    var body: some View {
        if let worst = mostRestrictiveRule {
            chip(for: worst)
        }
    }

    // MARK: - Chip

    @ViewBuilder
    private func chip(for rule: BudgetRule) -> some View {
        let used = spendByRule[rule.id] ?? 0
        let pct = rule.amountUSD > 0 ? used / rule.amountUSD : 0

        if pct >= 0.5 {
            HStack(spacing: 4) {
                Image(systemName: iconName(for: pct))
                    .font(.system(size: 9, weight: .bold))
                Text("$\(String(format: "%.0f", used))/$\(String(format: "%.0f", rule.amountUSD))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(tintFor(pct))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColorFor(pct).opacity(0.12))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(tintFor(pct).opacity(0.3), lineWidth: 0.5)
                    )
            )
            .accessibilityLabel(accessibilityLabel(rule: rule, used: used, pct: pct))
        }
    }

    // MARK: - Most restrictive rule

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

    // MARK: - Theming helpers

    private func iconName(for pct: Double) -> String {
        if pct >= 1.0 { return "xmark.octagon.fill" }
        if pct >= 0.8 { return "exclamationmark.triangle.fill" }
        return "gauge.with.dots.needle.33percent"
    }

    private func tintFor(_ pct: Double) -> Color {
        if pct >= 1.0 { return MobileTheme.error }
        if pct >= 0.8 { return MobileTheme.warning }
        return MobileTheme.textSecondary
    }

    private func backgroundColorFor(_ pct: Double) -> Color {
        if pct >= 1.0 { return MobileTheme.error }
        if pct >= 0.8 { return MobileTheme.warning }
        return MobileTheme.textSecondary
    }

    private func accessibilityLabel(rule: BudgetRule, used: Double, pct: Double) -> String {
        let status = pct >= 1.0 ? "blocked" : "\(Int(pct * 100))% used"
        return "Budget \(rule.displayLabel): \(status), $\(String(format: "%.2f", used)) of $\(String(format: "%.2f", rule.amountUSD))"
    }
}

// MARK: - Previews

#Preview("Budget chip — 80% warning") {
    let rule = BudgetRule(
        scope: .credential,
        providerID: "openrouter",
        label: "OpenRouter main",
        amountUSD: 50,
        period: .month,
        behavior: .warnThenBlock
    )
    BudgetStatusChip(
        rules: [rule],
        spendByRule: [rule.id: 42]
    )
    .padding(20)
    .background(MobileTheme.background)
}

#Preview("Budget chip — 100% blocked") {
    let rule = BudgetRule(
        scope: .global,
        label: "All per-usage",
        amountUSD: 100,
        period: .month,
        behavior: .warnThenBlock
    )
    BudgetStatusChip(
        rules: [rule],
        spendByRule: [rule.id: 103.50]
    )
    .padding(20)
    .background(MobileTheme.background)
}
