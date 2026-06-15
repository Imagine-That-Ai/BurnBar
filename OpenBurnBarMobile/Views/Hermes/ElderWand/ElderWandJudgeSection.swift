import SwiftUI
import OpenBurnBarCore

// MARK: - Elder Wand Judge Section (iOS)
//
// The single-select judge picker. The judge does not merge the panel answers —
// it COMPARES them into a structured verdict (consensus / contradictions /
// partial coverage / unique insights / blind spots). One model only, chosen
// from the same live roster as the panel, rendered as a single-select chip
// cloud (the chip-cloud sibling of `AuroraChipRail`'s single-select rail).

struct ElderWandJudgeSection: View {
    @Bindable var model: ElderWandConfiguratorModel
    let groups: [ElderWandProviderGroup]

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                header
                ForEach(groups) { group in
                    providerGroup(group)
                }
                footnote
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "scalemass")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.hermesAureate)
            Text("Judge")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer(minLength: 0)
            if model.judgeModelID.isEmpty {
                Text("Required")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(MobileTheme.amber)
            }
        }
    }

    @ViewBuilder
    private func providerGroup(_ group: ElderWandProviderGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.providerName)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .textCase(.uppercase)
                .tracking(0.5)
            ElderWandFlowLayout(spacing: 8) {
                ForEach(group.rows) { row in
                    chip(for: row)
                }
            }
        }
    }

    private func chip(for row: ElderWandModelRow) -> some View {
        ElderWandModelChip(
            displayName: row.displayName,
            modelID: row.id,
            isSelected: model.isJudge(row.id),
            isMultiSelect: false,
            isOrphaned: row.providerName == "Not advertised",
            action: {
                model.selectJudge(row.id)
                HapticBus.toggle()
            }
        )
    }

    private var footnote: some View {
        Text("The judge compares the panel's answers — where they agree, clash, and what they missed. It doesn't merge them.")
            .font(MobileTheme.Typography.tiny)
            .foregroundStyle(MobileTheme.Colors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
