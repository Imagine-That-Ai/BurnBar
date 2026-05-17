import SwiftUI

private enum ChatEngineModelCatalog {
    static let claudeCode: [String] = ["", "claude-sonnet-4-20250514", "claude-opus-4-20250514", "claude-opus-4-7", "claude-3-5-sonnet-20241022"]
}

struct ChatEngineModelMenu: View {
    @Bindable var controller: ChatSessionController

    private var menuOptions: [(id: String, title: String)] {
        switch controller.chatBackend {
        case .codex:
            return [("", "Default (Codex profile)")] + CLIBridge.codexChatModelIDs.map { ($0, $0) }
        case .claude:
            return ChatEngineModelCatalog.claudeCode.map { id in (id, id.isEmpty ? "Default (CLI profile)" : id) }
        case .hermes:
            return liveGatewayRows(for: .hermes, automaticTitle: "Automatic")
        case .openclaw:
            return liveGatewayRows(for: .openclaw, automaticTitle: "Automatic")
        case .piAgent:
            return liveGatewayRows(for: .piAgent, automaticTitle: "Automatic")
        }
    }

    private func liveGatewayRows(
        for backend: ChatBackendID,
        automaticTitle: String
    ) -> [(id: String, title: String)] {
        let models = controller.liveAdvertisedModels(for: backend)
        var rows: [(String, String)] = []
        let defaultModel = models.first { $0.routeEligible }?.id
        if let defaultModel, !defaultModel.isEmpty {
            rows.append(("", "\(automaticTitle) (\(ChatSessionController.abbreviateChatModelName(defaultModel)))"))
        } else {
            rows.append(("", "Select live model"))
        }
        for model in models {
            let suffix = model.routeEligible ? "" : " (unavailable)"
            rows.append((model.id, model.menuTitle + suffix))
        }
        let selected = controller.chatModelSelection(for: backend).trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty && !rows.contains(where: { $0.0 == selected }) {
            rows.append((selected, "\(selected) (not advertised)"))
        }
        return rows
    }

    var body: some View {
        Menu {
            ForEach(Array(menuOptions.enumerated()), id: \.offset) { _, row in
                Button(row.title) {
                    controller.setChatModelSelection(row.id, for: controller.chatBackend)
                }
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
    }
}
