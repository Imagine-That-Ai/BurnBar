import SwiftUI
import OpenBurnBarCore

// remediation(hermes-decomposition): relocated verbatim from HermesTabView.swift
// to shrink that god-file. `HermesModelPickerSheet` and its row
// (`HermesModelPickerRow`) are a self-contained pair — they read only from the
// `HermesService` they're handed plus module-/Core-level helpers
// (`hermesAgentProvider`, the `HermesRuntimeModelOption.agentProvider`
// extension, `ChatTilePreferences`, design tokens). Both were already internal
// `struct`s, so no access change was needed. Behavior is unchanged.

// MARK: - Hermes Model Picker

struct HermesModelPickerSheet: View {
    @Bindable var service: HermesService
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ChatTilePreferencesStorage.userDefaultsKey) private var tilePreferencesJSON: String = ""

    /// Visible Hermes sub-providers per user preference. Empty set means
    /// "no filter" — every advertised model passes through.
    private var visibleSubProviders: Set<HermesSubProvider> {
        let prefs = ChatTilePreferences.from(jsonString: tilePreferencesJSON)
        return prefs.enabledHermesSubProviders
    }

    /// Live `HermesRuntimeModelOption` list filtered by the user's enabled
    /// sub-providers. When the relay hasn't advertised any models we render
    /// the static six-row fallback below.
    private var filteredModelOptions: [HermesRuntimeModelOption] {
        let raw = service.modelOptions
        guard !visibleSubProviders.isEmpty else { return raw }
        return raw.filter { option in
            // Drop the option only when its provider tag maps to a sub-provider
            // that the user has explicitly hidden. Unknown provider tags pass
            // through so we never silently drop advertised models.
            if let sub = HermesSubProvider.fromProviderToken(option.providerID) {
                return visibleSubProviders.contains(sub)
            }
            if let sub = HermesSubProvider.fromProviderToken(option.providerName) {
                return visibleSubProviders.contains(sub)
            }
            return true
        }
    }

    private var groupedModels: [(provider: String, options: [HermesRuntimeModelOption])] {
        Dictionary(grouping: filteredModelOptions, by: \.providerName)
            .map { (provider: $0.key, options: $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { $0.provider < $1.provider }
    }

    private var favoriteModels: [HermesRuntimeModelOption] {
        let visible = Set(filteredModelOptions.map(\.id))
        return service.favoriteModelOptions.filter { visible.contains($0.id) }
    }

    /// Sub-providers shown as static fallback rows when the relay hasn't
    /// advertised concrete models yet. Always honors the user's visibility set.
    private var staticFallbackSubProviders: [HermesSubProvider] {
        let prefs = ChatTilePreferences.from(jsonString: tilePreferencesJSON)
        return prefs.orderedVisibleHermesSubProviders
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(density: .subtle)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        currentModelCard
                        if filteredModelOptions.isEmpty {
                            staticFallbackGroup
                            emptyModelsCard
                        } else {
                            if !favoriteModels.isEmpty {
                                favoriteGroup
                            }
                            ForEach(groupedModels, id: \.provider) { group in
                                providerGroup(group)
                            }
                        }
                    }
                    .padding(AuroraDesign.Layout.cardInset)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Switch Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await service.refreshRuntime() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh Hermes models")
                }
            }
            .task { await service.refreshRuntime() }
        }
    }

    private var currentModelCard: some View {
        let option = service.selectedModelOption
        let provider = option?.agentProvider ?? hermesAgentProvider(for: service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "hermes")
        let title = option?.displayName ?? service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "Automatic"
        let subtitle = option?.providerName ?? provider.displayName
        return AuroraGlassCard(variant: .hermes, cornerRadius: 18) {
            HStack(spacing: 12) {
                UnifiedProviderLogoView(provider: provider, size: 42, useFallbackColor: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(MobileTheme.success)
            }
        }
    }

    private var emptyModelsCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MobileTheme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No live models yet")
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("Pick a sub-provider above to route Hermes through it. The relay will fill in concrete model names once it reports them.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Static six-row fallback rendered when the relay hasn't advertised any
    /// concrete models. Tapping a row selects the sub-provider's default
    /// model hint so Hermes routes through that sub-provider until the relay
    /// reports something more specific.
    private var staticFallbackGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MobileTheme.hermesAureate)
                Text("Hermes sub-providers")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer()
                Text("\(staticFallbackSubProviders.count)")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            ForEach(staticFallbackSubProviders) { sub in
                let option = HermesRuntimeModelOption(
                    providerID: sub.providerToken,
                    providerName: sub.displayName,
                    modelID: sub.defaultModelHint,
                    displayName: sub.displayName
                )
                HermesModelPickerRow(
                    option: option,
                    isSelected: service.selectedModelID == option.modelID,
                    isFavorite: service.isFavoriteModel(option)
                ) {
                    service.selectModel(option)
                    HapticBus.primaryAction()
                    dismiss()
                } onToggleFavorite: {
                    service.toggleFavoriteModel(option)
                    HapticBus.toggle()
                }
            }
        }
    }

    private func providerGroup(_ group: (provider: String, options: [HermesRuntimeModelOption])) -> some View {
        let provider = hermesAgentProvider(for: group.options.first?.providerID ?? group.provider)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                UnifiedProviderLogoView(provider: provider, size: 24, useFallbackColor: true)
                Text(group.provider)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer()
                Text("\(group.options.count)")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            ForEach(group.options) { option in
                HermesModelPickerRow(
                    option: option,
                    isSelected: service.selectedModelID == option.modelID,
                    isFavorite: service.isFavoriteModel(option)
                ) {
                    service.selectModel(option)
                    HapticBus.primaryAction()
                    dismiss()
                } onToggleFavorite: {
                    service.toggleFavoriteModel(option)
                    HapticBus.toggle()
                }
            }
        }
    }

    private var favoriteGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MobileTheme.amber)
                Text("Favorites")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer()
                Text("\(favoriteModels.count)")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            ForEach(favoriteModels) { option in
                HermesModelPickerRow(
                    option: option,
                    isSelected: service.selectedModelID == option.modelID,
                    isFavorite: true
                ) {
                    service.selectModel(option)
                    HapticBus.primaryAction()
                    dismiss()
                } onToggleFavorite: {
                    service.toggleFavoriteModel(option)
                    HapticBus.toggle()
                }
            }
        }
    }
}

struct HermesModelPickerRow: View {
    let option: HermesRuntimeModelOption
    let isSelected: Bool
    let isFavorite: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    UnifiedProviderLogoView(provider: option.agentProvider, size: 30, useFallbackColor: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(FriendlyModelName.format(option.displayName))
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Text(option.modelID)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .lineLimit(1)
                        if let detail = option.liveCatalogDetailText {
                            Text(detail)
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(option.isRouteEligible ? MobileTheme.Colors.textSecondary : MobileTheme.error)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if !option.isRouteEligible {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(MobileTheme.error)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(MobileTheme.success)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use \(option.displayName)")
            .accessibilityValue(isSelected ? "Selected" : option.providerName)
            .disabled(!option.isRouteEligible)
            .opacity(option.isRouteEligible ? 1 : 0.62)

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isFavorite ? MobileTheme.amber : MobileTheme.Colors.textMuted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(MobileTheme.Colors.surfaceElevated.opacity(0.75)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Remove \(option.displayName) from favorites" : "Add \(option.displayName) to favorites")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? MobileTheme.hermesAureate.opacity(0.16) : MobileTheme.Colors.surfaceElevated.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? MobileTheme.hermesAureate.opacity(0.6) : MobileTheme.Colors.border.opacity(0.45), lineWidth: isSelected ? 1 : 0.5)
        )
    }
}
