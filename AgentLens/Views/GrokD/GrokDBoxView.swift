import SwiftUI

/// Default-off Local D box pane: live `listAgents` roster, status pills, UUID composer.
struct GrokDBoxView: View {
    @State private var model = GrokDBoxModel()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text(model.title)
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Toggle("Enable Local D box", isOn: $model.enabled)
                .onChange(of: model.enabled) { _, _ in
                    Task { await model.refresh() }
                }
            Toggle("Auto-start local box", isOn: $model.autoStart)
                .disabled(!model.enabled)

            if let warning = model.guiWarning {
                Text(warning)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Text(model.lastMessage)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            if model.enabled {
                roster
                composer
            }
        }
        .settingsAnchor(SettingsAnchor.agentsLocalDBox)
        .task { await model.refresh() }
    }

    @ViewBuilder
    private var roster: some View {
        if model.agents.isEmpty {
            Text("No live agents.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        } else {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                ForEach(model.agents) { agent in
                    Button {
                        model.selectedAgentID = agent.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name.isEmpty ? agent.id : agent.name)
                                    .font(DesignSystem.Typography.body)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                Text(agent.id)
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Text(pill(for: agent))
                                .font(DesignSystem.Typography.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(DesignSystem.Colors.surfaceElevated, in: Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                    .opacity(model.selectedAgentID == agent.id ? 1 : 0.75)
                }
            }
        }
    }

    private var composer: some View {
        HStack {
            TextField("Message the selected UUID", text: $model.promptText)
                .textFieldStyle(.roundedBorder)
                .disabled(!model.health.allowsSend)
            Button("Send") {
                Task { await model.send() }
            }
            .disabled(!model.canSend)
        }
    }

    private func pill(for agent: GrokDAgentRecord) -> String {
        if agent.isRunning { return "Running" }
        if agent.isComposingMessage { return "Composing" }
        return "Idle"
    }
}
