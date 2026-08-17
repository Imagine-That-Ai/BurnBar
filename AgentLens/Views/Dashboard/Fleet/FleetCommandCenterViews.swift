import OpenBurnBarKernel
import SwiftUI

// MARK: - Needs you

struct FleetNeedsYouStrip: View {
    let items: [FleetViewModel.NeedsYouItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Needs you")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.warning)
                        Text(item.text)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(item.text)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.warning.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.warning.opacity(0.3), lineWidth: 1)
            )
        }
    }
}

// MARK: - CLI rail

struct FleetCLIRail: View {
    let viewModel: FleetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("CLIs")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            ForEach(BurnBarFleetAgentID.declaredRoster, id: \.self) { agentID in
                Button {
                    viewModel.selectCLI(agentID)
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Circle()
                            .fill(viewModel.providerColor(for: agentID))
                            .frame(width: 8, height: 8)
                        Text(viewModel.providerName(for: agentID))
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        railBadge(for: agentID)
                    }
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(
                                viewModel.selectedAgentID == agentID
                                    ? DesignSystem.Colors.ember.opacity(0.12)
                                    : DesignSystem.Colors.surfaceElevated.opacity(0.4)
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(railAccessibility(agentID))
            }
        }
        .frame(minWidth: 168, idealWidth: 188, maxWidth: 220, alignment: .topLeading)
    }

    @ViewBuilder
    private func railBadge(for agentID: BurnBarFleetAgentID) -> some View {
        if viewModel.snapshot == nil {
            Text("—")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .accessibilityLabel("Checking thread count")
        } else {
            let count = viewModel.runningThreadCount(for: agentID) ?? 0
            Text("\(count)")
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(count > 0 ? DesignSystem.Colors.success : DesignSystem.Colors.textSecondary)
        }
    }

    private func railAccessibility(_ agentID: BurnBarFleetAgentID) -> String {
        let name = viewModel.providerName(for: agentID)
        if viewModel.snapshot == nil {
            return "\(name), checking"
        }
        let count = viewModel.runningThreadCount(for: agentID) ?? 0
        return "\(name), \(count) running threads"
    }
}

// MARK: - Thread list

struct FleetThreadList: View {
    let viewModel: FleetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Threads")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                TextField("Filter repo, id, status", text: bindFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignSystem.Typography.tiny)
                    .frame(maxWidth: 220)
            }

            if viewModel.threadsForSelectedCLI.isEmpty {
                Text(viewModel.emptyCLIReason(for: viewModel.selectedAgentID))
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, DesignSystem.Spacing.md)
            } else {
                VStack(spacing: DesignSystem.Spacing.xs) {
                    ForEach(viewModel.threadsForSelectedCLI, id: \.id) { thread in
                        threadRow(thread)
                    }
                }
            }
        }
        .onKeyPress(.downArrow) {
            viewModel.moveThreadSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            viewModel.moveThreadSelection(by: -1)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "j")) {
            viewModel.moveThreadSelection(by: 1)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "k")) {
            viewModel.moveThreadSelection(by: -1)
            return .handled
        }
    }

    private var bindFilter: Binding<String> {
        Binding(
            get: { viewModel.threadFilter },
            set: { viewModel.threadFilter = $0 }
        )
    }

    private func threadRow(_ thread: BurnBarFleetThread) -> some View {
        let selected = viewModel.selectedThread?.id == thread.id
        return Button {
            viewModel.selectThread(thread)
        } label: {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(FleetStatusPresentation.color(for: thread.status))
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.id)
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                    Text(secondaryLine(thread))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(FleetStatusPresentation.label(for: thread.status))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            .padding(DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(selected ? DesignSystem.Colors.ember.opacity(0.12) : DesignSystem.Colors.surfaceElevated.opacity(0.35))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(thread.id), \(FleetStatusPresentation.label(for: thread.status)), \(thread.projectName ?? "no repo")"
        )
    }

    private func secondaryLine(_ thread: BurnBarFleetThread) -> String {
        var parts: [String] = []
        parts.append(FleetConfidencePresentation.shortLabel(for: thread.confidence))
        if let repo = thread.projectName, !repo.isEmpty { parts.append(repo) }
        if let activity = thread.lastActivityAt {
            parts.append(FleetFormatting.formatRelativeTime(activity))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Inspector + Command Well

struct FleetCommandWell: View {
    let viewModel: FleetViewModel
    let onOpenOrchestratorChat: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            inspector
            compose
            queue
            if let note = viewModel.lastHandoffNote {
                Text(note)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(note)
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Inspector")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            if let thread = viewModel.selectedThread {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    labeled("CLI", viewModel.providerName(for: thread.agentID))
                    labeled("Thread", thread.id)
                    labeled("Status", FleetStatusPresentation.label(for: thread.status))
                    labeled("Confidence", FleetConfidencePresentation.label(for: thread.confidence))
                    labeled("Repo", thread.projectName ?? "—")
                    labeled("Model", thread.model ?? "—")
                    labeled("PID", thread.process.map { String($0.pid) } ?? "—")
                    if let note = thread.note {
                        Text(note)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
                HStack {
                    Button("Designate this thread") {
                        Task { await viewModel.designateSelectedThread() }
                    }
                    .disabled(viewModel.isSettingDesignation)
                    Button("Copy thread id") {
                        copy(thread.id)
                    }
                    if let pid = thread.process?.pid {
                        Button("Copy PID") { copy(String(pid)) }
                    }
                    if let path = thread.projectName, FileManager.default.fileExists(atPath: path) {
                        Button("Reveal in Finder") {
                            #if canImport(AppKit)
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            #endif
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text(viewModel.emptyCLIReason(for: viewModel.selectedAgentID))
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Button("Designate this CLI") {
                    Task { await viewModel.designateSelectedThread() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isSettingDesignation)
            }
        }
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Command Well")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Picker("Kind", selection: bindKind) {
                Text("Ask status").tag(BurnBarFleetDirectiveKind.askStatus)
                Text("Summarize").tag(BurnBarFleetDirectiveKind.summarize)
                Text("Focus repo").tag(BurnBarFleetDirectiveKind.focusRepo)
                Text("Custom").tag(BurnBarFleetDirectiveKind.custom)
            }
            .labelsHidden()
            TextEditor(text: bindPayload)
                .font(DesignSystem.Typography.body)
                .frame(minHeight: 72, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 1)
                )
            HStack {
                Button("Queue") {
                    Task { _ = await viewModel.queueDirective(state: .proposed) }
                }
                Button("Approve & hand off") {
                    Task { await viewModel.approveAndHandOff() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                if let onOpenOrchestratorChat {
                    Button("Open chat", action: onOpenOrchestratorChat)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.service.isRecordingDirective)
            Text("Hand off writes the BurnBar inbox for this thread. A new-turn CLI is optional and is never a live TUI inject.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Queue")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            if viewModel.queue.isEmpty {
                Text("No recent directives.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            } else {
                ForEach(viewModel.queue, id: \.id) { directive in
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(queueTitle(directive))
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                            Text(directive.payload)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            if case .proposed = directive.state {
                                Button("Approve") {
                                    Task { await viewModel.approveAndHandOff(directive) }
                                }
                                Button("Dismiss") {
                                    Task { await viewModel.dismissDirective(directive) }
                                }
                            }
                            if case .submitted = directive.state {
                                Button("New turn") {
                                    Task { await viewModel.startNewTurn(directive) }
                                }
                            }
                            if case .failed = directive.state {
                                Button("Retry") {
                                    Task { await viewModel.approveAndHandOff(directive) }
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var bindKind: Binding<BurnBarFleetDirectiveKind> {
        Binding(get: { viewModel.composeKind }, set: { viewModel.composeKind = $0 })
    }

    private var bindPayload: Binding<String> {
        Binding(get: { viewModel.composePayload }, set: { viewModel.composePayload = $0 })
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
        }
    }

    private func queueTitle(_ directive: BurnBarFleetDirective) -> String {
        let agent = directive.targetAgent?.wireValue ?? "fleet"
        let thread = directive.sessionRef ?? "inbox"
        return "\(stateLabel(directive.state)) · \(agent) / \(thread)"
    }

    private func stateLabel(_ state: BurnBarFleetDirectiveState) -> String {
        switch state {
        case .proposed: return "Proposed"
        case .approved: return "Approved"
        case .submitted: return "Submitted"
        case .dismissed: return "Dismissed"
        case .delivered: return "Delivered"
        case .failed: return "Failed"
        case .unsupported: return "Unsupported"
        }
    }

    private func copy(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

#if canImport(AppKit)
import AppKit
#endif
