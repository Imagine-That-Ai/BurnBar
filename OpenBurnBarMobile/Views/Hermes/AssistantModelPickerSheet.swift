import SwiftUI
import OpenBurnBarCore

// MARK: - Assistant Model Picker
//
// One sheet that handles model selection for every harness. Branches
// internally:
//   • Hermes / Pi → live model list off the service (`modelOptions`).
//     Tap to call the service's `selectModel(_:)` and (optionally) star
//     a favorite. Only exact relay-advertised model IDs are rendered.
//   • Codex / Claude / Droid / Forge / Antigravity → live catalogs pulled from the
//     paired Mac's installed CLI. Tap writes to `CLIAgentModelPreferences`.
//     The CLI binary on the user's Mac reads this preference at the start
//     of the next session.
//
// This is the surface that resolves the misrepresentation: every harness
// now exposes a real "what model is running under the hood" toggle.

struct AssistantModelPickerSheet: View {
    let runtime: AssistantRuntimeID
    @Bindable var hermesService: HermesService
    @Bindable var piService: PiService
    var onChange: ((AssistantModelOption) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var accountStore = AccountStore.shared
    @State private var refreshing = false
    @State private var cliPreference: String?
    @State private var cliCatalog: CLIRuntimeModelCatalogResponse?
    @State private var cliCatalogError: String?
    @State private var showProviderWizard: AgentProvider?

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
                if shouldShowRefreshButton {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await refreshModelList() }
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
                await refreshModelList()
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

    private var isCLIRuntime: Bool {
        switch runtime {
        case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent: return true
        case .hermes, .pi, .openClaw: return false
        }
    }

    private var shouldShowRefreshButton: Bool {
        isCLIRuntime || runtime == .hermes || runtime == .pi || runtime == .openClaw
    }

    // MARK: Current model card

    private var currentCard: some View {
        let snapshot = currentSnapshot()
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
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
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

    private func currentSnapshot() -> AssistantModelLens.ModelSnapshot {
        if isCLIRuntime,
           let preferred = cliPreference?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty,
           let option = cliCatalog?.options.first(where: {
               $0.modelID.caseInsensitiveCompare(preferred) == .orderedSame
           }) {
            return AssistantModelLens.ModelSnapshot(
                displayName: option.displayName,
                provider: hermesAgentProvider(for: option.providerID + " " + option.modelID),
                origin: .preference,
                activeModelID: option.modelID
            )
        }
        return AssistantModelLens(hermesService: hermesService, piService: piService)
            .snapshot(for: runtime)
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
        // Live runtimes render relay-advertised IDs only. CLI runtimes render
        // only the model/agent catalog discovered on the paired Mac.
        mergedGroups()
    }

    /// Build the visible model list and render grouped rows. Live runtimes show
    /// only models the selected relay advertises right now; CLI runtimes show
    /// only models/agents the underlying Mac CLI actually accepts.
    @ViewBuilder
    private func mergedGroups() -> some View {
        let rows = visibleRows()

        if rows.isEmpty {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                emptyModelState
            }
        } else {
            let grouped = Dictionary(grouping: rows, by: { $0.option.providerName })
            let sortedProviderNames = preservedProviderOrder(in: rows)

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                favoritesGroupIfAny()
                ForEach(sortedProviderNames, id: \.self) { providerName in
                    if let providerRows = grouped[providerName] {
                        providerGroup(providerName: providerName, rows: providerRows)
                    }
                }
                resetButton
            }
        }
    }

    /// Pull the live relay's advertised models for live relay runtimes.
    /// CLI-backed runtimes are fetched from the paired Mac through
    /// `fetchCLIRuntimeModelCatalog` instead.
    private func currentLiveRelayOptions() -> [HermesRuntimeModelOption] {
        switch runtime {
        case .hermes:           return hermesService.modelOptions
        case .pi:               return piService.modelOptions
        case .openClaw:         return OpenClawService.shared.modelOptions
        case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent: return []
        }
    }

    private func visibleRows() -> [AssistantModelMerger.Row] {
        if isCLIRuntime {
            guard let cliCatalog,
                  cliCatalog.runtime == runtime.rawValue else {
                return []
            }
            let cliOptions = cliCatalog.options
            return cliOptions.map { cliOption in
                AssistantModelMerger.Row(
                    option: AssistantModelOption(cliOption: cliOption),
                    reachability: .liveOnRelay
                )
            }
        }

        let liveRelay = currentLiveRelayOptions()
        let catalog = liveRelay.map(\.asAssistantModelOption)

        // Keep the merger on the live path so its self-loop guard still
        // filters placeholder runtime IDs such as `hermes-agent`.
        let relayDataLoaded = !liveRelay.isEmpty || !refreshing

        return AssistantModelMerger.merge(
            runtime: runtime,
            liveRelay: liveRelay,
            catalog: catalog,
            connectedProviderIDs: [],
            relayDataLoaded: relayDataLoaded
        )
    }

    private var emptyModelState: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: MobileTheme.Radius.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(MobileTheme.amber)
                    Text("No models advertised")
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                }
                Text(emptyModelStateMessage)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isCLIRuntime {
                    Button {
                        Task { await refreshModelList() }
                    } label: {
                        Label(refreshing ? "Refreshing" : "Refresh Mac catalog", systemImage: "arrow.clockwise")
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                    }
                    .disabled(refreshing)
                }
            }
        }
    }

    private var emptyModelStateMessage: String {
        if refreshing {
            return "Reading \(runtime.displayName)'s model catalog from the paired Mac."
        }
        if let cliCatalogError, isCLIRuntime {
            return classifiedCatalogError(cliCatalogError, runtime: runtime)
        }
        if let openClawError = OpenClawService.shared.runtimeErrorText, runtime == .openClaw {
            return classifiedCatalogError(openClawError, runtime: runtime)
        }
        if let piError = piService.runtimeErrorText, runtime == .pi {
            return classifiedCatalogError(piError, runtime: runtime)
        }
        if let hermesError = hermesService.runtimeErrorText, runtime == .hermes {
            return classifiedCatalogError(hermesError, runtime: runtime)
        }
        if isCLIRuntime {
            return "\(runtime.displayName) has not returned a live Mac catalog yet. Keep OpenBurnBar open on your Mac with Remote Relay enabled, then refresh."
        }
        return "\(runtime.displayName) has not reported a usable model list yet. Refresh the Mac relay, then reopen this picker."
    }

    /// Classify raw catalog errors into actionable user-facing messages.
    /// Firestore PERMISSION_DENIED, App Check rejections, and relay-specific
    /// errors each get a distinct recovery hint so the user knows what to do.
    private func classifiedCatalogError(_ rawError: String, runtime: AssistantRuntimeID) -> String {
        switch CloudErrorClassification.classify(message: rawError) {
        case .permissionDenied:
            return "Sign out and sign back in with the same account you use on your Mac, then reopen this picker."
        case .appCheckBlocked:
            return "App Check rejected this device. Reinstall from the official channel or register a debug token, then try again."
        case .notAuthenticated:
            return "Sign in to discover \(runtime.displayName) models from your paired Mac."
        case .networkUnavailable:
            return "You appear to be offline. Check your network connection, then try again."
        case .other(let message):
            return message
        case .decodingFailed, .firebaseUnavailable, .firestoreUnavailable,
             .accountMismatch, .rateLimited:
            return rawError
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
        case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent:
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
                providerGroupLogo(provider: provider, rows: rows)
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

    @ViewBuilder
    private func providerGroupLogo(provider: AgentProvider, rows: [AssistantModelMerger.Row]) -> some View {
        if rows.contains(where: { $0.option.cliSource?.showsOpenBurnBarProxyBadge == true }) {
            openBurnBarLogo(size: 22)
        } else {
            UnifiedProviderLogoView(provider: provider, size: 22)
        }
    }

    private func isFavorited(_ option: AssistantModelOption) -> Bool {
        switch runtime {
        case .hermes:   return hermesService.isFavoriteModel(option.asHermesRuntimeModelOption)
        case .pi:       return piService.isFavoriteModel(option.asHermesRuntimeModelOption)
        case .openClaw: return OpenClawService.shared.isFavoriteModel(option.asHermesRuntimeModelOption)
        case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent: return false
        }
    }

    private func currentModelID() -> String? {
        switch runtime {
        case .hermes:   return hermesService.selectedModelID
        case .pi:       return piService.selectedModelID
        case .openClaw: return OpenClawService.shared.selectedModelID
        case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent:
            return cliPreference ?? CLIAgentModelPreferences.preferredModelID(for: runtime)
        }
    }

    private func modelRow(option: AssistantModelOption,
                          reachability: AssistantModelMerger.Row.Reachability = .liveOnRelay,
                          isFavoriteToggleable: Bool,
                          isFavorite: Bool) -> some View {
        let currentID = currentModelID()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let optionID = option.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSelected = reachability == .liveOnRelay
            && (optionID.isEmpty
                ? (currentID?.isEmpty ?? true)
                : currentID.map {
                    AssistantModelIDCanonicalizer.lookupKey($0) == AssistantModelIDCanonicalizer.lookupKey(optionID)
                } == true)
        let isUnreachable = reachability == .unreachable
        let rowOpacity: Double = isUnreachable ? 0.55 : 1.0

        return HStack(spacing: 10) {
            Button {
                switch reachability {
                case .liveOnRelay:
                    applySelection(option)
                case .connectedOnIOS:
                    break
                case .pendingRelayData:
                    break
                case .unreachable:
                    showProviderWizard = inferAgentProvider(for: option)
                }
            } label: {
                HStack(spacing: MobileTheme.Spacing.md) {
                    modelProviderLogo(option: option, opacity: rowOpacity)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(option.displayName)
                                .font(MobileTheme.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.82)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                            sourceBadge(option)
                            reachabilityBadge(reachability)
                        }
                        if !optionID.isEmpty {
                            Text(optionID)
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                                .lineLimit(1)
                        }
                        if let detail = sourceDetail(for: option) {
                            Text(detail)
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(sourceTint(for: option).opacity(0.92))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
    private func modelProviderLogo(option: AssistantModelOption, opacity: Double) -> some View {
        ZStack(alignment: .bottomTrailing) {
            UnifiedProviderLogoView(
                provider: hermesAgentProvider(for: option.providerID + " " + option.modelID),
                size: 32
            )
            if option.cliSource?.showsOpenBurnBarProxyBadge == true {
                openBurnBarLogo(size: 14)
                    .offset(x: 3, y: 3)
                    .accessibilityHidden(true)
            }
        }
        .opacity(opacity)
    }

    @ViewBuilder
    private func openBurnBarLogo(size: CGFloat) -> some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .padding(size * 0.12)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(MobileTheme.Colors.surfaceElevated.opacity(0.98))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .stroke(Color.white.opacity(0.55), lineWidth: 0.7)
                    )
            )
    }

    @ViewBuilder
    private func reachabilityBadge(_ reachability: AssistantModelMerger.Row.Reachability) -> some View {
        switch reachability {
        case .liveOnRelay:
            EmptyView()
        case .connectedOnIOS:
            tagPill(text: "Relay only", tint: MobileTheme.Colors.textMuted)
        case .pendingRelayData:
            tagPill(text: "Loading…", tint: MobileTheme.Colors.textMuted)
        case .unreachable:
            tagPill(text: "Connect", tint: MobileTheme.amber)
        }
    }

    @ViewBuilder
    private func sourceBadge(_ option: AssistantModelOption) -> some View {
        if let source = option.cliSource {
            tagPill(text: source.displayLabel, tint: sourceTint(for: option))
        }
    }

    private func sourceDetail(for option: AssistantModelOption) -> String? {
        option.cliSource?.detailLabel
    }

    private func sourceTint(for option: AssistantModelOption) -> Color {
        switch option.cliSource {
        case .droidStandardQuota, .droidCoreQuota:
            return MobileTheme.amber
        case .openBurnBarProxy:
            return MobileTheme.success
        case .droidCustomModel,
             .forgeAgent,
             .antigravityProfile,
             .antigravityModelCatalog,
             .claudeModelCatalog,
             .cursorAgentProfile,
             .codexModelCatalog,
             .grokModelCatalog,
             .ollamaLocalCatalog,
             .ollamaCloudCatalog,
             .cliProfile:
            return MobileTheme.Colors.textSecondary
        case nil:
            return MobileTheme.Colors.textMuted
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
        case .liveOnRelay:
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(MobileTheme.success)
            }
        case .connectedOnIOS:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MobileTheme.Colors.textMuted)
        case .pendingRelayData:
            ProgressView()
                .scaleEffect(0.7)
        }
    }

    private func tagPill(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
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
        case .liveOnRelay:
            let sourcePhrase = option.cliSource.map { ", \($0.detailLabel)" } ?? ""
            if isCLIRuntime {
                return "\(option.displayName), available in \(runtime.displayName) on your Mac\(sourcePhrase)"
            }
            return "\(option.displayName), available on relay"
        case .connectedOnIOS:     return "\(option.displayName), account connected but relay does not advertise this model"
        case .pendingRelayData:   return "\(option.displayName), waiting for relay data"
        case .unreachable:        return "\(option.displayName), tap to connect provider"
        }
    }

    /// Best-effort map from a model's provider ID to the `AgentProvider`
    /// the wizard knows how to onboard. Falls back to `.openAI` only when
    /// no match exists — the wizard will still let the user pick.
    private func inferAgentProvider(for option: AssistantModelOption) -> AgentProvider {
        let token = ProviderID(rawValue: option.providerID).rawValue
        if let provider = AgentProvider.mobileAccountConnectableProviders
            .first(where: { $0.providerID.rawValue == token }) {
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
        case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent:
            let modelID = option.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            CLIAgentModelPreferences.setPreferredModelID(modelID.isEmpty ? nil : modelID, for: runtime)
            cliPreference = modelID.isEmpty ? nil : modelID
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
        case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent:
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
            case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent: return cliPreference != nil
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
        case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent: return "Clear preference (let the Mac CLI choose)"
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
        case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent:
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
        case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent: break
        }
    }

    private func refreshModelList() async {
        if isCLIRuntime {
            await refreshCLICatalog()
        } else {
            await refreshLive()
        }
    }

    private func refreshCLICatalog() async {
        guard !refreshing else { return }
        refreshing = true
        cliCatalogError = nil
        defer { refreshing = false }
        do {
            cliCatalog = try await hermesService.fetchCLIRuntimeModelCatalog(runtime: runtime)
        } catch {
            cliCatalog = nil
            cliCatalogError = error.localizedDescription
        }
    }
}
