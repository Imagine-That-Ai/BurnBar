import SwiftUI
import OpenBurnBarCore

// MARK: - Assistant Model Picker
//
// One sheet that handles model selection for every harness. Branches
// internally:
//   • Hermes / Pi → live model list off the service (`modelOptions`).
//     Tap to call the service's `selectModel(_:)` and (optionally) star
//     a favorite.
//   • Codex / Claude / OpenClaw → static catalog from
//     `AssistantModelCatalog`. Tap writes to
//     `CLIAgentModelPreferences`. The CLI binary on the user's Mac
//     reads this preference at the start of the next session.
//
// This is the surface that resolves the misrepresentation: every harness
// now exposes a real "what model is running under the hood" toggle.

struct AssistantModelPickerSheet: View {
    let runtime: AssistantRuntimeID
    @Bindable var hermesService: HermesService
    @Bindable var piService: PiService
    var onChange: ((AssistantModelOption) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var refreshing = false
    @State private var cliPreference: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(density: .subtle)
                ScrollView {
                    VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                        currentCard
                        contextCopy
                        modelGroups
                    }
                    .padding(MobileTheme.Spacing.lg)
                    .padding(.bottom, MobileTheme.Spacing.xxl)
                }
            }
            .navigationTitle("\(runtime.displayName) model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
                if runtime == .hermes || runtime == .pi {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await refreshLive() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(refreshing)
                        .accessibilityLabel("Refresh \(runtime.displayName) models")
                    }
                }
            }
            .task {
                cliPreference = CLIAgentModelPreferences.preferredModelID(for: runtime)
            }
        }
    }

    // MARK: Current model card

    private var currentCard: some View {
        let snapshot = AssistantModelLens(hermesService: hermesService, piService: piService)
            .snapshot(for: runtime)
        return AuroraGlassCard(variant: .hermes, cornerRadius: MobileTheme.Radius.lg) {
            HStack(spacing: MobileTheme.Spacing.md) {
                HarnessModelBadge(
                    harness: runtime.agentProvider,
                    model: snapshot.provider,
                    size: 50
                )
                .frame(width: 64, height: 64, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.displayName)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(originDescription(snapshot.origin))
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: snapshot.origin == .fallback ? "questionmark.circle" : "checkmark.seal.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(snapshot.origin == .fallback ? MobileTheme.amber : MobileTheme.success)
            }
        }
    }

    private func originDescription(_ origin: AssistantModelLens.ModelSnapshot.Origin) -> String {
        switch origin {
        case .live:        return "Live from \(runtime.displayName) relay"
        case .preference:  return "Your preference — applied on next session"
        case .lastSession: return "Last session ran this model"
        case .fallback:    return "No preference set — pick one below"
        }
    }

    @ViewBuilder
    private var contextCopy: some View {
        if AssistantModelCatalog.appliesNextSession(runtime) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MobileTheme.amber)
                Text("Picking a model here saves your preference. Your Mac CLI picks it up at the start of the next chat — existing sessions keep their original model.")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(MobileTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                    .fill(MobileTheme.amber.opacity(0.10))
            )
        }
    }

    // MARK: Groups

    @ViewBuilder
    private var modelGroups: some View {
        // Every harness routes to the same broad universe of frontier
        // models, so the picker always offers the full catalog. For
        // Hermes/Pi we additionally honor the live relay's favorite list
        // and call `selectModel(_:)` on the service so the change applies
        // instantly. For the CLI harnesses (Codex / Claude / OpenClaw) we
        // persist via `CLIAgentModelPreferences` because their Mac binary
        // reads the preference at the next session boundary.
        catalogGroups()
    }

    private func catalogGroups() -> some View {
        let options = AssistantModelCatalog.options(for: runtime)
        let grouped = Dictionary(grouping: options, by: { $0.providerName })
        let sortedProviderNames = preservedProviderOrder(in: options)

        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            favoritesGroupIfAny()
            ForEach(sortedProviderNames, id: \.self) { providerName in
                if let providerOptions = grouped[providerName] {
                    providerGroup(providerName: providerName, options: providerOptions)
                }
            }
            resetButton
        }
    }

    /// Preserve the catalog's intentional ordering (newest provider first,
    /// most capable model first) rather than alphabetising.
    private func preservedProviderOrder(in options: [AssistantModelOption]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for option in options where !seen.contains(option.providerName) {
            seen.insert(option.providerName)
            ordered.append(option.providerName)
        }
        return ordered
    }

    @ViewBuilder
    private func favoritesGroupIfAny() -> some View {
        switch runtime {
        case .hermes:
            if !hermesService.favoriteModelOptions.isEmpty {
                liveFavoritesGroup(favorites: hermesService.favoriteModelOptions, service: .hermes)
            }
        case .pi:
            if !piService.favoriteModelOptions.isEmpty {
                liveFavoritesGroup(favorites: piService.favoriteModelOptions, service: .pi)
            }
        case .codex, .claude, .openClaw:
            EmptyView()
        }
    }

    private func liveFavoritesGroup(favorites: [HermesRuntimeModelOption],
                                    service: AssistantRuntimeID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Favorites", systemName: "star.fill", tint: MobileTheme.amber)
            ForEach(favorites) { option in
                modelRow(option: option.asAssistantModelOption,
                         isFavoriteToggleable: true,
                         isFavorite: true)
            }
        }
    }

    private func providerGroup(providerName: String, options: [AssistantModelOption]) -> some View {
        let provider = hermesAgentProvider(for: options.first?.providerID ?? providerName)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                UnifiedProviderLogoView(provider: provider, size: 22)
                Text(providerName)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Text("\(options.count)")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            ForEach(options) { option in
                modelRow(option: option,
                         isFavoriteToggleable: runtime == .hermes || runtime == .pi,
                         isFavorite: isFavorited(option))
            }
        }
    }

    private func isFavorited(_ option: AssistantModelOption) -> Bool {
        switch runtime {
        case .hermes: return hermesService.isFavoriteModel(option.asHermesRuntimeModelOption)
        case .pi:     return piService.isFavoriteModel(option.asHermesRuntimeModelOption)
        case .codex, .claude, .openClaw: return false
        }
    }

    private func currentModelID() -> String? {
        switch runtime {
        case .hermes: return hermesService.selectedModelID
        case .pi:     return piService.selectedModelID
        case .codex, .claude, .openClaw:
            return cliPreference ?? CLIAgentModelPreferences.preferredModelID(for: runtime)
        }
    }

    private func modelRow(option: AssistantModelOption,
                          isFavoriteToggleable: Bool,
                          isFavorite: Bool) -> some View {
        let isSelected = currentModelID() == option.modelID
        return HStack(spacing: 10) {
            Button {
                applySelection(option)
            } label: {
                HStack(spacing: MobileTheme.Spacing.md) {
                    UnifiedProviderLogoView(
                        provider: hermesAgentProvider(for: option.providerID + " " + option.modelID),
                        size: 32
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.displayName)
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Text(option.modelID)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(MobileTheme.success)
                    }
                }
                .padding(MobileTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                        .fill(MobileTheme.Colors.surface.opacity(0.55))
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                                .stroke(isSelected
                                        ? MobileTheme.success.opacity(0.6)
                                        : MobileTheme.Colors.border.opacity(0.45),
                                        lineWidth: isSelected ? 1.1 : 0.5)
                        )
                )
            }
            .buttonStyle(.plain)

            if isFavoriteToggleable {
                Button {
                    toggleFavorite(option)
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isFavorite ? MobileTheme.amber : MobileTheme.Colors.textMuted)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.7))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorite ? "Remove \(option.displayName) from favorites" : "Add \(option.displayName) to favorites")
            }
        }
    }

    private func applySelection(_ option: AssistantModelOption) {
        switch runtime {
        case .hermes:
            hermesService.selectModel(option.asHermesRuntimeModelOption)
        case .pi:
            piService.selectModel(option.asHermesRuntimeModelOption)
        case .codex, .claude, .openClaw:
            CLIAgentModelPreferences.setPreferredModelID(option.modelID, for: runtime)
            cliPreference = option.modelID
        }
        HapticBus.primaryAction()
        onChange?(option)
        dismiss()
    }

    private func toggleFavorite(_ option: AssistantModelOption) {
        switch runtime {
        case .hermes:
            hermesService.toggleFavoriteModel(option.asHermesRuntimeModelOption)
        case .pi:
            piService.toggleFavoriteModel(option.asHermesRuntimeModelOption)
        case .codex, .claude, .openClaw:
            break
        }
        HapticBus.toggle()
    }

    @ViewBuilder
    private var resetButton: some View {
        let hasPreference: Bool = {
            switch runtime {
            case .hermes: return hermesService.selectedModelID != nil
            case .pi:     return piService.selectedModelID != nil
            case .codex, .claude, .openClaw: return cliPreference != nil
            }
        }()
        if hasPreference {
            Button {
                clearPreference()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 13, weight: .semibold))
                    Text(resetLabel)
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(MobileTheme.Colors.surfaceElevated.opacity(0.55))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var resetLabel: String {
        switch runtime {
        case .hermes, .pi: return "Clear selection (let the relay pick)"
        case .codex, .claude, .openClaw: return "Clear preference (let the Mac CLI choose)"
        }
    }

    private func clearPreference() {
        switch runtime {
        case .hermes:
            hermesService.selectedModelID = nil
        case .pi:
            piService.selectedModelID = nil
        case .codex, .claude, .openClaw:
            CLIAgentModelPreferences.setPreferredModelID(nil, for: runtime)
            cliPreference = nil
        }
        HapticBus.toggle()
    }

    // MARK: Helpers

    private func sectionLabel(_ title: String, systemName: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
    }

    private func refreshLive() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        switch runtime {
        case .hermes: await hermesService.refreshRuntime()
        case .pi:     await piService.refreshRuntime()
        case .codex, .claude, .openClaw: break
        }
    }
}
