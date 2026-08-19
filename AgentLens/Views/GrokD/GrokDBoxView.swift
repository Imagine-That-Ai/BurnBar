import SwiftUI

/// Default-off Local D box pane: live `listAgents` roster, status pills, UUID composer.
struct GrokDBoxView: View {
    @State private var model = GrokDBoxModel()
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            Toggle("Enable Local D box", isOn: $model.enabled)
                .onChange(of: model.enabled) { _, _ in
                    Task { await model.refresh() }
                }
                .accessibilityIdentifier(OBBAccessibilityID.localDBoxEnable)
            Toggle("Auto-start local box", isOn: $model.autoStart)
                .disabled(!model.enabled)
                .onChange(of: model.autoStart) { _, _ in
                    Task { await model.refresh() }
                }
                .accessibilityIdentifier(OBBAccessibilityID.localDBoxAutoStart)

            if let warning = model.guiWarning {
                Text(warning)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            statusLine

            if model.enabled {
                roster
                composer
            } else {
                Text("Off until you enable it. Talks only to 127.0.0.1 — never D.app, never the Grok Build CLI.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1)
        )
        .settingsAnchor(SettingsAnchor.agentsLocalDBox)
        .accessibilityIdentifier(OBBAccessibilityID.localDBoxRoot)
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("127.0.0.1 · shim 1337 · host 1338 · inference 8787")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer(minLength: 8)
            if model.isRefreshing || model.isSending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(model.isSending ? "Sending" : "Refreshing")
            }
            Button("Refresh") {
                Task { await model.refresh() }
            }
            .disabled(!model.enabled || model.isRefreshing)
            .accessibilityIdentifier(OBBAccessibilityID.localDBoxRefresh)
        }
    }

    private var statusLine: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            Text(model.lastMessage.isEmpty ? " " : model.lastMessage)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(statusColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Local D box status")
        .accessibilityValue(model.lastMessage)
    }

    @ViewBuilder
    private var roster: some View {
        if model.agents.isEmpty {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("No live agents.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(emptyRosterHint)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier(OBBAccessibilityID.localDBoxEmpty)
        } else {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                ForEach(model.agents) { agent in
                    agentRow(agent)
                }
            }
        }
    }

    private func agentRow(_ agent: GrokDAgentRecord) -> some View {
        let selected = model.selectedAgentID == agent.id
        return Button {
            model.selectedAgentID = agent.id
        } label: {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name.isEmpty ? agent.id : agent.name)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(agent.id)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .textSelection(.enabled)
                    if let preview = agent.lastMessagePreview, !preview.isEmpty {
                        Text(preview)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Text(pillTitle(for: agent))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(pillForeground(for: agent))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(pillForeground(for: agent).opacity(0.14), in: Capsule())
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? DesignSystem.Colors.ember.opacity(0.12) : DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? DesignSystem.Colors.ember.opacity(0.45) : DesignSystem.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(agent.name.isEmpty ? agent.id : agent.name)
        .accessibilityValue("\(pillTitle(for: agent)). \(agent.id)")
        .accessibilityIdentifier(OBBAccessibilityID.localDBoxAgent(agent.id))
    }

    private var composer: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            TextField("Message the selected UUID", text: $model.promptText)
                .textFieldStyle(.roundedBorder)
                .disabled(!model.health.allowsSend || model.isSending)
                .focused($composerFocused)
                .onSubmit {
                    Task { await model.send() }
                }
                .accessibilityIdentifier(OBBAccessibilityID.localDBoxComposer)
            Button("Send") {
                Task { await model.send() }
            }
            .disabled(!model.canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier(OBBAccessibilityID.localDBoxSend)
        }
    }

    private var emptyRosterHint: String {
        if !model.health.allowsSend {
            return "Start the local box host, then refresh. Send stays disabled until 1337, 1338, and 8787 are up."
        }
        return "Create an agent in the local box, then refresh."
    }

    private var statusColor: Color {
        switch model.statusTone {
        case .success: return DesignSystem.Colors.success
        case .warning: return DesignSystem.Colors.warning
        case .error: return DesignSystem.Colors.error
        case .info: return DesignSystem.Colors.textSecondary
        }
    }

    private func pillTitle(for agent: GrokDAgentRecord) -> String {
        if agent.isRunning { return "Running" }
        if agent.isComposingMessage { return "Composing" }
        return "Idle"
    }

    private func pillForeground(for agent: GrokDAgentRecord) -> Color {
        if agent.isRunning { return DesignSystem.Colors.warning }
        if agent.isComposingMessage { return DesignSystem.Colors.amber }
        return DesignSystem.Colors.textMuted
    }
}
