import SwiftUI
import OpenBurnBarCore

struct ChatEngineModelMenu: View {
    @Bindable var controller: ChatSessionController
    @State private var quotaService = ProviderQuotaService.shared
    @State private var cliRows: [AssistantRuntimeID: [CLIRuntimeModelOption]] = [:]
    @State private var cliErrors: [AssistantRuntimeID: String] = [:]

    struct ModelMenuRow: Identifiable, Equatable {
        let id: String
        let title: String
        var disabled = false
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
        }
    }

    private func liveCLIRows(
        for runtime: AssistantRuntimeID,
        defaultTitle: String?
    ) -> [ModelMenuRow] {
        Self.cliMenuRows(
            options: cliRows[runtime],
            error: cliErrors[runtime],
            selected: controller.chatModelSelection(for: controller.chatBackend),
            defaultTitle: defaultTitle
        )
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

    private func liveGatewayRows(
        for backend: ChatBackendID,
        automaticTitle: String
    ) -> [ModelMenuRow] {
        let models = controller.liveAdvertisedModels(for: backend)
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
    /// CLI backends (Codex, Claude Code, Droid, Antigravity). We append " · NN%" once
    /// to make the pressure visible per row without inventing a richer
    /// macOS Menu item (Menu only renders plain `Button(title)` text).
    /// Hermes, OpenClaw, Pi route across many providers so we skip them;
    /// Forge has no quota signal.
    private var perRowQuotaSuffix: String {
        let backend = controller.chatBackend
        switch backend {
        case .codex, .claude, .droid, .antigravity, .cursorAgent:
            guard let provider = backend.agentProvider,
                  let resolution = ProviderQuotaChip.resolve(
                    provider: provider,
                    style: .full,
                    displayName: backend.displayName,
                    service: quotaService
                  )
            else { return "" }
            return " · \(resolution.text) left"
        case .hermes, .openclaw, .piAgent, .forge:
            return ""
        }
    }

    var body: some View {
        let suffix = perRowQuotaSuffix
        Menu {
            ForEach(Array(menuOptions.enumerated()), id: \.offset) { _, row in
                Button(row.title + (row.disabled ? "" : suffix)) {
                    controller.setChatModelSelection(row.id, for: controller.chatBackend)
                }
                .disabled(row.disabled)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.system(size: 11, weight: .medium))
                Text(controller.chatModelMenuTitle())
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
            }
            .foregroundStyle(controller.chatBackend == .hermes ? DesignSystem.Colors.hermesAureate : DesignSystem.Colors.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .help("Model for \(controller.chatBackend.displayName) chat. Each engine remembers its own choice.")
        .animation(DesignSystem.Animation.snappy, value: controller.chatBackend)
        .animation(DesignSystem.Animation.snappy, value: controller.chatModelSelection(for: controller.chatBackend))
        .animation(DesignSystem.Animation.snappy, value: controller.hermesModelName)
        .task(id: controller.chatBackend) {
            await refreshCLIRowsIfNeeded()
        }
    }

    @MainActor
    private func refreshCLIRowsIfNeeded() async {
        guard let runtime = cliRuntime(for: controller.chatBackend),
              cliRows[runtime] == nil else {
            return
        }
        do {
            let response = try await CLIRuntimeModelCatalogDiscovery()
                .modelCatalog(for: CLIRuntimeModelCatalogRequest(runtime: runtime.rawValue))
            cliRows[runtime] = response.options
            cliErrors[runtime] = nil
        } catch {
            cliRows[runtime] = nil
            cliErrors[runtime] = error.localizedDescription
        }
    }

    private func cliRuntime(for backend: ChatBackendID) -> AssistantRuntimeID? {
        switch backend {
        case .codex: return .codex
        case .claude: return .claude
        case .droid: return .droid
        case .forge: return .forge
        case .antigravity: return .antigravity
        case .cursorAgent: return .cursorAgent
        case .hermes, .openclaw, .piAgent: return nil
        }
    }
}
