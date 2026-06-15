import SwiftUI
import OpenBurnBarCore

// MARK: - Elder Wand Analysis Section (iOS)
//
// The analysis-panel multi-select. A provider-grouped chip cloud over the live
// model roster; the user taps to add/remove panel members up to the OpenRouter
// Fusion ceiling of eight. Mirrors `AssistantModelPickerSheet`'s provider
// grouping and `MercuryBadgePicker`'s chip-cloud interaction, composed from the
// shared `ElderWandFlowLayout` + `ElderWandModelChip`.

struct ElderWandAnalysisSection: View {
    @Bindable var model: ElderWandConfiguratorModel
    let groups: [ElderWandProviderGroup]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedCount: Int { model.selectedAnalysisModelIDs.count }
    private var ceiling: Int { ElderWandPreset.analysisPanelRange.upperBound }

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
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.hermesAureate)
            Text("Analysis panel")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer(minLength: 0)
            Text("\(selectedCount) / \(ceiling)")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(selectedCount >= ceiling ? MobileTheme.amber : MobileTheme.Colors.textMuted)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : MobileTheme.Animation.snappy, value: selectedCount)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Analysis panel, \(selectedCount) of \(ceiling) models selected")
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
        let isSelected = model.isAnalysisSelected(row.id)
        // Lock out adding new members once the panel is full; already-selected
        // chips stay tappable so the user can always deselect.
        let isAtCeiling = model.isPanelFull && !isSelected
        return ElderWandModelChip(
            displayName: row.displayName,
            modelID: row.id,
            isSelected: isSelected,
            isMultiSelect: true,
            isOrphaned: row.providerName == "Not advertised",
            action: {
                let changed = model.toggleAnalysis(row.id)
                if changed {
                    HapticBus.toggle()
                } else {
                    // Hit the contract ceiling — soft warning, no modal.
                    HapticBus.threshold()
                }
            }
        )
        .opacity(isAtCeiling ? 0.5 : 1.0)
    }

    @ViewBuilder
    private var footnote: some View {
        Text(model.isPanelFull
             ? "Panel full — the Elder Wand caps at \(ceiling) analysis models. Remove one to swap."
             : "Tap to add a model to the panel. They all answer your prompt in parallel.")
            .font(MobileTheme.Typography.tiny)
            .foregroundStyle(MobileTheme.Colors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
