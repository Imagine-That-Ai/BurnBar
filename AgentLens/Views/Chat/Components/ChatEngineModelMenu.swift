import SwiftUI

private enum ChatEngineModelCatalog {
    static let claudeCode: [String] = ["", "claude-sonnet-4-20250514", "claude-opus-4-20250514", "claude-opus-4-7", "claude-3-5-sonnet-20241022"]
    static let openClaw: [String] = ["", "gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1"]
}

struct ChatEngineModelMenu: View {
    @Bindable var controller: ChatSessionController

    private var menuOptions: [(id: String, title: String)] {
        switch controller.chatBackend {
        case .codex:
            return [("", "Default (gpt-5.5)")] + CLIBridge.codexChatModelIDs.map { ($0, $0) }
        case .claude:
            return ChatEngineModelCatalog.claudeCode.map { id in (id, id.isEmpty ? "Default (CLI profile)" : id) }
        case .hermes:
            var rows: [(String, String)] = [("", "Automatic")]
            let pinned = ["hermes", "gpt-5.5"]
            for p in pinned {
                if !rows.contains(where: { $0.0.caseInsensitiveCompare(p) == .orderedSame }) {
                    rows.append((p, p))
                }
            }
            if let g = controller.hermesModelName?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty {
                if !rows.contains(where: { $0.0.caseInsensitiveCompare(g) == .orderedSame }) {
                    rows.append((g, "Gateway: \(ChatSessionController.abbreviateChatModelName(g))"))
                }
            }
            return rows
        case .openclaw:
            return ChatEngineModelCatalog.openClaw.map { id in (id, id.isEmpty ? "Default (gpt-4o-mini)" : id) }
        }
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
