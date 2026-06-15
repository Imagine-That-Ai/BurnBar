import OpenBurnBarCore
import SwiftUI

// MARK: - Elder Wand Judge Section
//
// The judge: a single-select chip rail. The judge model COMPARES the panel
// answers into a 5-field structured verdict (consensus / contradictions /
// partial coverage / unique insights / blind spots) — it never merges them.
// Selecting a model selects it as judge; tapping the selected model clears it.
// Pure renderer over the same pre-grouped model list as the analysis section.

struct ElderWandJudgeSection: View {
    @Bindable var model: ElderWandConfiguratorModel
    let groups: [ElderWandProviderGroup]

    @ScaledMetric(relativeTo: .body) private var chipIconSize: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header

            if groups.isEmpty {
                emptyHint
            } else {
                LiquidGlassGroup(spacing: DesignSystem.Spacing.sm) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                        ForEach(groups) { group in
                            ElderWandJudgeGroupView(
                                model: model,
                                group: group,
                                chipIconSize: chipIconSize
                            )
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Judge")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("Compares the panel answers into a structured verdict.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyHint: some View {
        Text("No live models advertised yet. Refresh the chat gateway to choose a judge.")
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
            .liquidGlassSurface(in: .rect(cornerRadius: DesignSystem.Radius.md))
    }
}

// MARK: - Provider group

private struct ElderWandJudgeGroupView: View {
    @Bindable var model: ElderWandConfiguratorModel
    let group: ElderWandProviderGroup
    let chipIconSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(group.providerName)
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            ElderWandFlowLayout(
                horizontalSpacing: DesignSystem.Spacing.sm,
                verticalSpacing: DesignSystem.Spacing.sm
            ) {
                ForEach(group.options) { option in
                    ElderWandJudgeChip(
                        option: option,
                        isSelected: model.judgeID == option.id,
                        iconSize: chipIconSize
                    ) {
                        model.selectJudge(option.id)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.providerName) judge candidates")
    }
}

// MARK: - Chip

private struct ElderWandJudgeChip: View {
    let option: ElderWandModelOption
    let isSelected: Bool
    let iconSize: CGFloat
    let action: () -> Void

    private var modelColor: Color {
        DesignSystem.Colors.colorForModel(option.id)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.xs + 2) {
                Image(systemName: isSelected ? "gavel.fill" : "circle.fill")
                    .font(.system(size: isSelected ? iconSize : iconSize * 0.55, weight: .semibold))
                    .foregroundStyle(isSelected ? DesignSystem.Colors.whimsy : modelColor)
                    .frame(width: iconSize, height: iconSize)

                Text(option.title)
                    .font(DesignSystem.Typography.caption)
                    .lineLimit(1)

                if !option.isRouteEligible {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: iconSize * 0.85))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .foregroundStyle(
                isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary
            )
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .liquidGlassInteractive(
                tint: isSelected ? DesignSystem.Colors.whimsy : nil,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        DesignSystem.Colors.whimsy.opacity(isSelected ? 0.85 : 0),
                        lineWidth: 1.25
                    )
            }
            .opacity(option.isRouteEligible ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!option.isRouteEligible)
        .animation(DesignSystem.Animation.snappy, value: isSelected)
        .accessibilityLabel(option.title)
        .accessibilityValue(option.isRouteEligible ? "" : "no live route")
        .accessibilityHint(isSelected ? "Selected as judge. Activate to clear." : "Activate to set as judge.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
