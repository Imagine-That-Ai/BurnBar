import SwiftUI
import OpenBurnBarCore

/// Shared, observable cache of the per-runtime Mac model catalogs.
///
/// The rows used to be `@State` on `ChatEngineModelMenu` itself, which meant
/// only that view could ever render them. The Agent Deck's Sigil absorbs the
/// same rows as its model segment (`docs/CHAT_AGENT_SWITCHER_REDESIGN.md` §3.2),
/// so the catalog moved here: both surfaces read one cache, one discovery call
/// per runtime, and a menu opened from either place is already populated.
@MainActor
@Observable
final class CLIRuntimeModelCatalogCache {
    private(set) var rows: [AssistantRuntimeID: [CLIRuntimeModelOption]] = [:]
    private(set) var errors: [AssistantRuntimeID: String] = [:]
    @ObservationIgnored private var inFlight: Set<AssistantRuntimeID> = []

    func options(for runtime: AssistantRuntimeID) -> [CLIRuntimeModelOption]? {
        rows[runtime]
    }

    func error(for runtime: AssistantRuntimeID) -> String? {
        errors[runtime]
    }

    /// Loads a runtime's catalog once. `nil` runtimes (the gateway agents) and
    /// already-loaded / in-flight runtimes are no-ops, so callers can fire this
    /// from every surface without fanning out discovery processes.
    func refreshIfNeeded(runtime: AssistantRuntimeID?, settingsManager: SettingsManager) async {
        guard let runtime, rows[runtime] == nil, !inFlight.contains(runtime) else { return }
        inFlight.insert(runtime)
        defer { inFlight.remove(runtime) }
        do {
            let response = try await CLIRuntimeModelCatalogDiscovery(settingsManager: settingsManager)
                .modelCatalog(for: CLIRuntimeModelCatalogRequest(runtime: runtime.rawValue))
            rows[runtime] = response.options
            errors[runtime] = nil
        } catch {
            rows[runtime] = nil
            errors[runtime] = error.localizedDescription
        }
    }
}

/// The compact model picker used by `ChatPanelHeader`, `ChatMenuPopover`,
/// `ChatPanel` and `HermesPopoverChatView`.
///
/// Since the Liquid Plasma swap this is a thin adapter over
/// `PlasmaModelSelector`, so those four surfaces inherit the living orb and the
/// three-rung ladder without touching their layouts. The *rows* below stay:
/// `contextMenu` and the Sigil's long-press menu are AppKit menus, which only
/// render plain `Button(title)` rows, and `AgentSigilTests` / `CLIBridgeTests`
/// pin `cliMenuRows`.
struct ChatEngineModelMenu: View {
    @Bindable var controller: ChatSessionController

    /// The asset's pair: the mascot on the left, the model on the right.
    ///
    /// They sit together because they answer the two halves of the same
    /// question — *who* is answering and *what* is answering — and separating
    /// them would put the persona somewhere the user has to go looking for it.
    /// The persona orb comes first because it is the one with a face, and a
    /// face is what the eye lands on.
    var body: some View {
        HStack(spacing: 6) {
            PlasmaPersonaOrb(
                seat: activeSeat,
                roster: controller.personaRoster,
                isThinking: controller.isStreaming,
                onSelect: selectSeat,
                onCreate: { label, personaID in
                    guard let seat = controller.addPersonaSeat(label: label, personaID: personaID) else { return }
                    selectSeat(seat)
                },
                onDelete: { controller.removePersonaSeat(id: $0) }
            )
            PlasmaModelSelector(controller: controller, labelWidth: 120)
        }
    }

    private var activeSeat: PlasmaSeat? {
        guard let id = controller.personaSeatID(for: controller.chatBackend) else { return nil }
        return controller.personaRoster.first { $0.id == id }
    }

    private func selectSeat(_ seat: PlasmaSeat?) {
        controller.setPersonaSeatID(seat?.id, for: controller.chatBackend)
        Analytics.shared.track(.chatPersonaSelected, [
            "backend": .string(controller.chatBackend.rawValue),
            // The closed, app-authored persona id — never the seat's label,
            // which the user typed.
            "persona_id": .string(seat?.personaID ?? "none")
        ])
    }

    /// The equivalent rows as an AppKit menu, for the surfaces that must be a
    /// native menu (`contextMenu`). Hermes additionally gets its `ROUTE`
    /// section.
    @ViewBuilder
    static func modelRows(controller: ChatSessionController) -> some View {
        ChatEngineModelRows(controller: controller)
    }

    static func cliRuntime(for backend: ChatBackendID) -> AssistantRuntimeID? {
        switch backend {
        case .codex: return .codex
        case .claude: return .claude
        case .droid: return .droid
        case .forge: return .forge
        case .antigravity: return .antigravity
        case .cursorAgent: return .cursorAgent
        case .omp: return .omp
        case .openClaude: return .openClaude
        case .junie: return .junie
        case .grok: return .grok
        case .kimi: return .grok
        case .hermes, .openclaw, .piAgent: return nil
        }
    }

    struct ModelMenuRow: Identifiable, Equatable {
        let id: String
        let title: String
        var disabled = false
    }

    static func cliMenuRows(
        options rows: [CLIRuntimeModelOption]?,
        error: String?,
        selected rawSelected: String,
        defaultTitle: String?
    ) -> [ModelMenuRow] {
        guard let rows, !rows.isEmpty else {
            if let error, !error.isEmpty {
                return [ModelMenuRow(id: "__catalog_error", title: "Mac catalog unavailable: \(error)", disabled: true)]
            }
            return [ModelMenuRow(id: "__catalog_loading", title: "Loading Mac catalog…", disabled: true)]
        }
        let mapped = rows.map { option in
            let modelID = option.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelSuffix = modelID.isEmpty ? "" : " (\(modelID))"
            return ModelMenuRow(
                id: modelID,
                title: "\(option.displayName)\(modelSuffix) · \(option.source.displayLabel)"
            )
        }
        let hasDefaultRow = rows.contains { $0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var result = mapped
        if !hasDefaultRow, let defaultTitle {
            result.insert(ModelMenuRow(id: "", title: defaultTitle), at: 0)
        }
        let selected = rawSelected.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty && !result.contains(where: { $0.id == selected }) {
            result.append(ModelMenuRow(
                id: selected,
                title: "\(selected) (not advertised by this Mac)",
                disabled: true
            ))
        }
        return result
    }
}

// MARK: - Rows

/// The menu content, hosted by both `ChatEngineModelMenu` and the Agent Sigil.
struct ChatEngineModelRows: View {
    @Bindable var controller: ChatSessionController

    @State private var quotaService = ProviderQuotaService.shared

    /// The shared Mac catalog, injected on the controller (see `AgentDeck.swift`).
    private var catalog: CLIRuntimeModelCatalogCache { controller.agentDeck.modelCatalog }

    typealias ModelMenuRow = ChatEngineModelMenu.ModelMenuRow

    var body: some View {
        let suffix = perRowQuotaSuffix
        Group {
            if controller.chatBackend == .hermes {
                HermesModelStrip.routeMenuRows(
                    controller: controller,
                    settingsManager: controller.settingsManager
                )
                Divider()
            }
            Section("Model") {
                ForEach(Array(menuOptions.enumerated()), id: \.offset) { _, row in
                    Button(row.title + (row.disabled ? "" : suffix)) {
                        controller.setChatModelSelection(row.id, for: controller.chatBackend)
                        Analytics.shared.track(.chatModelSelected, [
                            "backend": .string(controller.chatBackend.rawValue),
                            "model_id": .string(row.id)
                        ])
                    }
                    .disabled(row.disabled)
                }
            }
        }
        .task(id: controller.chatBackend) {
            await catalog.refreshIfNeeded(
                runtime: ChatEngineModelMenu.cliRuntime(for: controller.chatBackend),
                settingsManager: controller.settingsManager
            )
        }
    }

    private var menuOptions: [ModelMenuRow] {
        switch controller.chatBackend {
        case .codex:
            return liveCLIRows(for: .codex, defaultTitle: "Default (Codex profile)")
        case .claude:
            return liveCLIRows(for: .claude, defaultTitle: "Default (Claude Code profile)")
        case .hermes:
            return liveGatewayRows(for: .hermes, automaticTitle: "Automatic")
        case .openclaw:
            return liveGatewayRows(for: .openclaw, automaticTitle: "Automatic")
        case .piAgent:
            return liveGatewayRows(for: .piAgent, automaticTitle: "Automatic")
        case .droid:
            return liveCLIRows(for: .droid, defaultTitle: nil)
        case .forge:
            return liveCLIRows(for: .forge, defaultTitle: nil)
        case .antigravity:
            return liveCLIRows(for: .antigravity, defaultTitle: nil)
        case .cursorAgent:
            return liveCLIRows(for: .cursorAgent, defaultTitle: "Default (Cursor Agent profile)")
        case .omp:
            return liveCLIRows(for: .omp, defaultTitle: "Default (OMP profile)")
        case .openClaude:
            return liveCLIRows(for: .openClaude, defaultTitle: "Default (OpenClaude profile)")
        case .junie:
            return liveCLIRows(for: .junie, defaultTitle: "Default (Junie profile)")
        case .grok:
            return liveCLIRows(for: .grok, defaultTitle: "Default (Grok profile)")
        case .kimi:
            return liveCLIRows(for: .grok, defaultTitle: "Default (Kimi profile)")
        }
    }

    private func liveCLIRows(
        for runtime: AssistantRuntimeID,
        defaultTitle: String?
    ) -> [ModelMenuRow] {
        ChatEngineModelMenu.cliMenuRows(
            options: catalog.options(for: runtime),
            error: catalog.error(for: runtime),
            selected: controller.chatModelSelection(for: controller.chatBackend),
            defaultTitle: defaultTitle
        )
    }

    private func liveGatewayRows(
        for backend: ChatBackendID,
        automaticTitle: String
    ) -> [ModelMenuRow] {
        let models = controller.chatModelCatalog(for: backend)
        var rows: [ModelMenuRow] = []
        let defaultModel = models.first { $0.routeEligible }?.id
        if let defaultModel, !defaultModel.isEmpty {
            rows.append(ModelMenuRow(id: "", title: "\(automaticTitle) (\(ChatSessionController.abbreviateChatModelName(defaultModel)))"))
        } else {
            rows.append(ModelMenuRow(id: "", title: "Select live model"))
        }
        for model in models {
            let suffix = model.routeEligible ? "" : " (unavailable)"
            rows.append(ModelMenuRow(id: model.id, title: model.menuTitle + suffix, disabled: !model.routeEligible))
        }
        let selected = controller.chatModelSelection(for: backend).trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty && !rows.contains(where: { $0.id == selected }) {
            rows.append(ModelMenuRow(id: selected, title: "\(selected) (not advertised)", disabled: true))
        }
        return rows
    }

    /// Same provider drains the same quota for every row in single-provider
    /// CLI agents (Codex, Claude Code, Droid, Antigravity). We append " · NN%"
    /// once to make the pressure visible per row without inventing a richer
    /// macOS Menu item (Menu only renders plain `Button(title)` text).
    /// Hermes, OpenClaw, Pi route across many providers so we skip them;
    /// Forge has no quota signal.
    private var perRowQuotaSuffix: String {
        let backend = controller.chatBackend
        switch backend {
        // `.kimi` has no agentProvider, so the guard below yields "" for it naturally.
        case .codex, .claude, .droid, .antigravity, .cursorAgent, .openClaude, .omp, .junie,
             .grok, .kimi:
            guard let provider = backend.agentProvider,
                  let resolution = ProviderQuotaChip.resolve(
                    provider: provider,
                    style: .full,
                    displayName: backend.displayName,
                    service: quotaService,
                    cumulative: controller.settingsManager.cumulativeAcrossAccounts
                  )
            else { return "" }
            return " · \(resolution.text) left"
        case .hermes, .openclaw, .piAgent, .forge:
            return ""
        }
    }
}
