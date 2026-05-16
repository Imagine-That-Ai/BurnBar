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
    @State private var accountStore = AccountStore.shared
    @State private var refreshing = false
    @State private var cliPreference: String? = nil
    @State private var showProviderWizard: AgentProvider? = nil

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
                if runtime == .hermes || runtime == .pi || runtime == .openClaw {
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
                // Fire-and-forget remote refresh so the catalog stays in
                // lockstep with the website's authoritative `models.json`.
                // Bundled copy is shown immediately; this swaps it in
                // when the network call returns.
                AssistantModelCatalog.refreshRemote()
                // Kick the live relays too — the merger trusts these
                // first, so the user sees real data as soon as it lands.
                await refreshLive()
            }
        }
        .sheet(item: $showProviderWizard) { provider in
            NavigationStack {
                MobileProviderWizardView(
                    preselectedProvider: provider,
                    onConnected: { _ in
                        showProviderWizard = nil
                        Task { await accountStore.fetchConnections() }
                    },
                    onCancel: { showProviderWizard = nil }
                )
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
        // Three sources merged into one ordered, reachability-tagged list:
        //   1. Live relay (HermesService / PiService advertised models)
        //   2. User's connected provider accounts (AccountStore)
        //   3. Bundled / remote catalog (AssistantModelCatalog)
        // The merger drops the broken `hermes-agent` / `pi-agent` self-loop.
        mergedGroups()
    }

    /// Build the merger input and render grouped rows. Live rows win on
    /// conflict; catalog rows backed by a connected account get tagged
    /// `.connectedOnIOS`; everything else is `.unreachable` (dimmed + CTA).
    private func mergedGroups() -> some View {
        let liveRelay = currentLiveRelayOptions()
        let catalog = AssistantModelCatalog.options(for: runtime)
        let connected = accountStore.connectedProviderIDs

        let rows = AssistantModelMerger.merge(
            runtime: runtime,
            liveRelay: liveRelay,
            catalog: catalog,
            connectedProviderIDs: connected
        )

        let grouped = Dictionary(grouping: rows, by: { $0.option.providerName })
        let sortedProviderNames = preservedProviderOrder(in: rows)

        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            favoritesGroupIfAny()
            ForEach(sortedProviderNames, id: \.self) { providerName in
                if let providerRows = grouped[providerName] {
                    providerGroup(providerName: providerName, rows: providerRows)
                }
            }
            resetButton
        }
    }

    /// Pull the live relay's advertised models for the active runtime.
    /// OpenClaw reads from its own dedicated service. Codex/Claude have
    /// no mobile-native discovery yet — those return `[]` and the merger
    /// fills exclusively from the catalog + connected accounts.
    private func currentLiveRelayOptions() -> [HermesRuntimeModelOption] {
        switch runtime {
        case .hermes:           return hermesService.modelOptions
        case .pi:               return piService.modelOptions
        case .openClaw:         return OpenClawService.shared.modelOptions
        case .codex, .claude:   return []
        }
    }

    /// Preserve the merger's stable ordering (catalog ordering, then any
    /// live-only providers appended at the end) rather than alphabetising.
    private func preservedProviderOrder(in rows: [AssistantModelMerger.Row]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for row in rows where !seen.contains(row.option.providerName) {
            seen.insert(row.option.providerName)
            ordered.append(row.option.providerName)
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
        case .openClaw:
            if !OpenClawService.shared.favoriteModelOptions.isEmpty {
                liveFavoritesGroup(favorites: OpenClawService.shared.favoriteModelOptions, service: .openClaw)
            }
        case .codex, .claude:
            EmptyView()
        }
    }

    private func liveFavoritesGroup(favorites: [HermesRuntimeModelOption],
                                    service: AssistantRuntimeID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Favorites", systemName: "star.fill", tint: MobileTheme.amber)
            ForEach(favorites) { option in
                modelRow(option: option.asAssistantModelOption,
                         reachability: .liveOnRelay,
                         isFavoriteToggleable: true,
                         isFavorite: true)
            }
        }
    }

    private func providerGroup(providerName: String, rows: [AssistantModelMerger.Row]) -> some View {
        let provider = hermesAgentProvider(for: rows.first?.option.providerID ?? providerName)
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
                Text("\(rows.count)")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            ForEach(rows) { row in
                modelRow(
                    option: row.option,
                    reachability: row.reachability,
                    isFavoriteToggleable: (runtime == .hermes
                                           || runtime == .pi
                                           || runtime == .openClaw)
                        && row.reachability == .liveOnRelay,
                    isFavorite: isFavorited(row.option)
                )
            }
        }
    }

    private func isFavorited(_ option: AssistantModelOption) -> Bool {
        switch runtime {
        case .hermes:   return hermesService.isFavoriteModel(option.asHermesRuntimeModelOption)
        case .pi:       return piService.isFavoriteModel(option.asHermesRuntimeModelOption)
        case .openClaw: return OpenClawService.shared.isFavoriteModel(option.asHermesRuntimeModelOption)
        case .codex, .claude: return false
        }
    }

    private func currentModelID() -> String? {
        switch runtime {
        case .hermes:   return hermesService.selectedModelID
        case .pi:       return piService.selectedModelID
        case .openClaw: return OpenClawService.shared.selectedModelID
        case .codex, .claude:
            return cliPreference ?? CLIAgentModelPreferences.preferredModelID(for: runtime)
        }
    }

    private func modelRow(option: AssistantModelOption,
                          reachability: AssistantModelMerger.Row.Reachability = .liveOnRelay,
                          isFavoriteToggleable: Bool,
                          isFavorite: Bool) -> some View {
        let isSelected = currentModelID() == option.modelID && reachability != .unreachable
        let isUnreachable = reachability == .unreachable
        let rowOpacity: Double = isUnreachable ? 0.55 : 1.0

        return HStack(spacing: 10) {
            Button {
                if isUnreachable {
                    showProviderWizard = inferAgentProvider(for: option)
                } else {
                    applySelection(option)
                }
            } label: {
                HStack(spacing: MobileTheme.Spacing.md) {
                    UnifiedProviderLogoView(
                        provider: hermesAgentProvider(for: option.providerID + " " + option.modelID),
                        size: 32
                    )
                    .opacity(rowOpacity)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(option.displayName)
                                .font(MobileTheme.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                                .lineLimit(1)
                            reachabilityBadge(reachability)
                        }
                        Text(option.modelID)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .lineLimit(1)
                    }
                    .opacity(rowOpacity)
                    Spacer()
                    trailingAccessory(option: option,
                                      reachability: reachability,
                                      isSelected: isSelected)
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
            .accessibilityLabel(accessibilityLabel(for: option, reachability: reachability))

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

    // MARK: Reachability affordances

    @ViewBuilder
    private func reachabilityBadge(_ reachability: AssistantModelMerger.Row.Reachability) -> some View {
        switch reachability {
        case .liveOnRelay:
            EmptyView()
        case .connectedOnIOS:
            tagPill(text: "Account", tint: MobileTheme.hermesAureate)
        case .unreachable:
            tagPill(text: "Connect", tint: MobileTheme.amber)
        }
    }

    @ViewBuilder
    private func trailingAccessory(
        option: AssistantModelOption,
        reachability: AssistantModelMerger.Row.Reachability,
        isSelected: Bool
    ) -> some View {
        switch reachability {
        case .unreachable:
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(MobileTheme.amber)
        case .liveOnRelay, .connectedOnIOS:
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(MobileTheme.success)
            }
        }
    }

    private func tagPill(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(tint.opacity(0.15))
            )
            .overlay(
                Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5)
            )
    }

    private func accessibilityLabel(
        for option: AssistantModelOption,
        reachability: AssistantModelMerger.Row.Reachability
    ) -> String {
        switch reachability {
        case .liveOnRelay:    return "\(option.displayName), available on relay"
        case .connectedOnIOS: return "\(option.displayName), account connected"
        case .unreachable:    return "\(option.displayName), tap to connect provider"
        }
    }

    /// Best-effort map from a model's provider ID to the `AgentProvider`
    /// the wizard knows how to onboard. Falls back to `.openAI` only when
    /// no match exists — the wizard will still let the user pick.
    private func inferAgentProvider(for option: AssistantModelOption) -> AgentProvider {
        let token = ProviderID(rawValue: option.providerID).rawValue
        if let provider = AgentProvider.mobileAccountConnectableProviders
            .first(where: { $0.providerID.rawValue == token })
        {
            return provider
        }
        return hermesAgentProvider(for: option.providerID + " " + option.modelID)
    }

    private func applySelection(_ option: AssistantModelOption) {
        switch runtime {
        case .hermes:
            hermesService.selectModel(option.asHermesRuntimeModelOption)
        case .pi:
            piService.selectModel(option.asHermesRuntimeModelOption)
        case .openClaw:
            OpenClawService.shared.selectModel(option.asHermesRuntimeModelOption)
        case .codex, .claude:
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
        case .openClaw:
            OpenClawService.shared.toggleFavoriteModel(option.asHermesRuntimeModelOption)
        case .codex, .claude:
            break
        }
        HapticBus.toggle()
    }

    @ViewBuilder
    private var resetButton: some View {
        let hasPreference: Bool = {
            switch runtime {
            case .hermes:   return hermesService.selectedModelID != nil
            case .pi:       return piService.selectedModelID != nil
            case .openClaw: return OpenClawService.shared.selectedModelID != nil
            case .codex, .claude: return cliPreference != nil
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
        case .hermes, .pi, .openClaw: return "Clear selection (let the relay pick)"
        case .codex, .claude:         return "Clear preference (let the Mac CLI choose)"
        }
    }

    private func clearPreference() {
        switch runtime {
        case .hermes:
            hermesService.clearSelectedModel()
        case .pi:
            piService.clearSelectedModel()
        case .openClaw:
            OpenClawService.shared.clearSelectedModel()
        case .codex, .claude:
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
        case .hermes:           await hermesService.refreshRuntime()
        case .pi:               await piService.refreshRuntime()
        case .openClaw:         await OpenClawService.shared.refreshRuntime()
        case .codex, .claude:   break
        }
    }
}
