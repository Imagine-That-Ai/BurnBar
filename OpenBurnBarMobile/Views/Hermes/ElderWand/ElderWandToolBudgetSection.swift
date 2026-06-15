import SwiftUI
import OpenBurnBarCore

// MARK: - Elder Wand Tool-Call Budget Section (iOS)
//
// The per-model tool-loop budget (OpenRouter Fusion `max_tool_calls`, range
// 1...16, default 8). Each panel model and the judge may take up to this many
// web_search / web_fetch steps. A plain Stepper keeps it honest and accessible;
// the value is clamped to the contract range on every change.

struct ElderWandToolBudgetSection: View {
    @Bindable var model: ElderWandConfiguratorModel

    private var range: ClosedRange<Int> { ElderWandPreset.maxToolCallsRange }

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                header
                Stepper(value: $model.maxToolCalls, in: range) {
                    HStack {
                        Text("Tool calls per model")
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Spacer(minLength: 0)
                        Text("\(model.maxToolCalls)")
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(MobileTheme.Colors.hermesAureate)
                            .contentTransition(.numericText())
                    }
                }
                .onChange(of: model.maxToolCalls) {
                    model.clampMaxToolCalls()
                    HapticBus.toggle()
                }
                Text("How many web search / fetch steps each panel model and the judge may take (\(range.lowerBound)–\(range.upperBound)).")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.hermesAureate)
            Text("Tool budget")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer(minLength: 0)
        }
    }
}
