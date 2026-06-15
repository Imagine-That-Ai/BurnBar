import OpenBurnBarCore
import SwiftUI

// MARK: - Elder Wand Analysis Section
//
// The analysis panel: a provider-grouped, multi-select chip cloud. The user
// picks 1–8 models that answer the prompt in parallel. Selection state lives
// on the injected `@Bindable` configurator model; this view is a pure renderer
// over a pre-grouped model list (no inline `.filter`, no object creation in
// `body`).

struct ElderWandAnalysisSection: View {
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
                            ElderWandAnalysisGroupView(
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
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Analysis Panel")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("These models answer in parallel.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            Text("\(model.analysisCount) of \(ElderWandPreset.analysisPanelRange.upperBound)")
                .font(DesignSystem.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(
                    model.analysisCount == 0
                        ? DesignSystem.Colors.textMuted
                        : DesignSystem.Colors.ember
                )
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xxs)
                .background(
                    Capsule().fill(DesignSystem.Colors.ember.opacity(model.analysisCount == 0 ? 0 : 0.12))
                )
                .animation(DesignSystem.Animation.snappy, value: model.analysisCount)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Analysis panel, \(model.analysisCount) of \(ElderWandPreset.analysisPanelRange.upperBound) models selected")
    }

    private var emptyHint: some View {
        Text("No live models advertised yet. Refresh the chat gateway to populate the panel.")
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
            .liquidGlassSurface(in: .rect(cornerRadius: DesignSystem.Radius.md))
    }
}

// MARK: - Provider group

/// One provider's heading + its chip cloud. Extracted so the cloud's flow
/// layout and per-chip state stay isolated from the section header.
private struct ElderWandAnalysisGroupView: View {
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
                    ElderWandAnalysisChip(
                        option: option,
                        isSelected: model.selectedAnalysisIDs.contains(option.id),
                        canAdd: model.canAddMoreAnalysis,
                        iconSize: chipIconSize
                    ) {
                        model.toggleAnalysis(option.id)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.providerName) models")
    }
}

// MARK: - Chip

/// A single multi-select analysis chip. Tinted to the model's brand color when
/// selected; disabled (with a "panel full" hint) when the panel is at the
/// contract maximum and this chip is not already in it.
private struct ElderWandAnalysisChip: View {
    let option: ElderWandModelOption
    let isSelected: Bool
    let canAdd: Bool
    let iconSize: CGFloat
    let action: () -> Void

    private var modelColor: Color {
        DesignSystem.Colors.colorForModel(option.id)
    }

    private var isDisabled: Bool {
        !option.isRouteEligible || (!isSelected && !canAdd)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.xs + 2) {
                Circle()
                    .fill(modelColor)
                    .frame(width: iconSize, height: iconSize)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: iconSize * 0.7, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }

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
                tint: isSelected ? modelColor : nil,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        modelColor.opacity(isSelected ? 0.85 : 0),
                        lineWidth: 1.25
                    )
            }
            .opacity(isDisabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(DesignSystem.Animation.snappy, value: isSelected)
        .accessibilityLabel(option.title)
        .accessibilityValue(option.isRouteEligible ? "" : "no live route")
        .accessibilityHint(isSelected ? "Selected. Activate to remove from panel." : "Activate to add to panel.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
