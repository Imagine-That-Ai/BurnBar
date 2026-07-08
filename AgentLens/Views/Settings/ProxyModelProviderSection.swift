import OpenBurnBarCore
import SwiftUI

struct ProxyModelProviderSection: View {
    let group: ProxyModelProviderGroup
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onToggleModelAdvertisement: ((ProxyAdvertisedModel, Bool) -> Void)?
    var onUpsertThinkingVariant: ((ProxyAdvertisedModel, BurnBarThinkingLevel) -> Void)?
    var onRemoveThinkingVariant: ((ProxyAdvertisedModel) -> Void)?
    var onUpsertModelAlias: ((ProxyAdvertisedModel, BurnBarModelAlias) async -> String?)?
    var onRemoveModelAlias: ((ProxyAdvertisedModel) -> Void)?
    var onSetDisplayName: ((ProxyAdvertisedModel, String) async -> String?)?
    var onClearDisplayName: ((ProxyAdvertisedModel) -> Void)?
    var onSetProviderAdvertisement: ((String, [String], Bool) -> Void)?

    private let collapsedLimit = 5

    private var anyAdvertised: Bool {
        group.models.contains { $0.advertisementEnabled }
    }

    private var providerAdvertiseHelp: String {
        anyAdvertised
            ? "Hide all \(group.providerName) models from /v1/models. You can switch individual models back on afterward."
            : "Advertise all \(group.providerName) models through /v1/models."
    }

    private var provider: AgentProvider? {
        AgentProvider.fromCatalogProviderID(group.providerID)
    }

    private var visibleModels: [ProxyAdvertisedModel] {
        isExpanded ? group.models : Array(group.models.prefix(collapsedLimit))
    }

    private var hiddenCount: Int {
        max(0, group.models.count - visibleModels.count)
    }

    private func existingVariantLevels(forBaseModelID baseModelID: String, providerID: String) -> Set<BurnBarThinkingLevel> {
        var levels: Set<BurnBarThinkingLevel> = []
        let trimmedBase = baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedProvider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedBase.isEmpty, !trimmedProvider.isEmpty else { return levels }
        for sibling in group.models where sibling.providerID.lowercased() == trimmedProvider {
            guard sibling.isThinkingLevelVariant,
                  let siblingBase = sibling.baseModelID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  siblingBase == trimmedBase,
                  let raw = sibling.thinkingLevel,
                  let level = BurnBarThinkingLevel(rawValue: raw) else { continue }
            levels.insert(level)
        }
        return levels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ProxyProviderLogoView(
                    catalogProviderID: group.providerID,
                    providerName: group.providerName,
                    size: 20
                )
                Text(group.providerName)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("\(group.models.count)")
                    .font(DesignSystem.Typography.monoTiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DesignSystem.Colors.background.opacity(0.55))
                    .clipShape(Capsule())
                Spacer()
                if let onSetProviderAdvertisement {
                    Toggle("", isOn: Binding(
                        get: { anyAdvertised },
                        set: { onSetProviderAdvertisement(group.providerID, group.models.map(\.modelID), $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(providerAdvertiseHelp)
                    .accessibilityLabel("Advertise all \(group.providerName) models")
                    .accessibilityValue(anyAdvertised ? "on" : "off")
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.xs)

            ForEach(visibleModels) { model in
                ProxyModelCatalogRow(
                    model: model,
                    onToggleAdvertisement: onToggleModelAdvertisement,
                    existingVariantLevels: existingVariantLevels(forBaseModelID: model.modelID, providerID: model.providerID),
                    onUpsertThinkingVariant: onUpsertThinkingVariant,
                    onRemoveThinkingVariant: onRemoveThinkingVariant,
                    onUpsertModelAlias: onUpsertModelAlias,
                    onRemoveModelAlias: onRemoveModelAlias,
                    onSetDisplayName: onSetDisplayName,
                    onClearDisplayName: onClearDisplayName
                )
            }

            if hiddenCount > 0 || isExpanded {
                Button(action: onToggleExpanded) {
                    Label(
                        isExpanded ? "Show fewer" : "Show \(hiddenCount) more",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.ember)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.top, 5)
                .padding(.bottom, DesignSystem.Spacing.sm)
            }
        }
    }
}
