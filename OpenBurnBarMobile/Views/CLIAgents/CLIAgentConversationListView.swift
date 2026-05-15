import SwiftUI
import OpenBurnBarCore

// MARK: - CLI Agent Conversation List
//
// Replaces the "Connect your Mac" placeholder for the Codex, Claude
// Code, and OpenClaw tiles inside the iOS Assistants tab. Lists the
// mirrored sessions the macOS app has published into Firestore via
// `CLIAgentSessionMirror`. New chats are persisted through the paired
// Mac request queue and then show back up here as real `cli_sessions`.
//
// Empty-state copy is intentional: if the user is signed in but hasn't
// chatted with this runtime on their Mac yet, we explain what will sync
// and still expose a real persisted chat composer.

struct CLIAgentConversationListView: View {
    let runtime: CLIAgentRuntime
    @State private var reader: CLIAgentChatReader = .shared
    @State private var selectedSession: CLIAgentSessionRecord?
    @State private var showConnectionSheet = false
    @State private var showModelPicker = false
    @State private var showNewChatSheet = false
    @State private var missionHost = MobileMissionConsoleHost()
    @State private var queuedChatMessage: String?

    var body: some View {
        ZStack {
            AuroraBackdrop()

            VStack(spacing: 0) {
                brandHeader
                if visibleSessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    newThreadFAB
                        .padding(.trailing, MobileTheme.Spacing.lg)
                        .padding(.bottom, 108)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showConnectionSheet) {
            AssistantConnectionSheet(
                hermesService: HermesService.shared,
                piService: PiService.shared,
                focusedRuntime: runtime.assistantRuntime
            )
        }
        .sheet(isPresented: $showModelPicker) {
            AssistantModelPickerSheet(
                runtime: runtime.assistantRuntime,
                hermesService: HermesService.shared,
                piService: PiService.shared
            )
        }
        .sheet(isPresented: $showNewChatSheet) {
            CLIAgentNewChatSheet(
                runtime: runtime,
                missionHost: missionHost
            ) { requestID in
                queuedChatMessage = "\(runtime.displayName) chat queued on your account. It will appear here when your Mac starts streaming. \(shortRequestID(requestID))"
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reader.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Refresh \(runtime.displayName) sessions")
                .disabled(reader.isLoading)
            }
        }
        .sheet(item: $selectedSession) { session in
            NavigationStack {
                CLIAgentTranscriptView(session: session)
                    .navigationTitle(session.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { selectedSession = nil }
                        }
                    }
            }
        }
        .task {
            missionHost.start()
            await reader.refresh()
        }
        .onDisappear {
            missionHost.stop()
        }
        .refreshable {
            await reader.refresh()
            await missionHost.refresh()
        }
    }

    private var visibleSessions: [CLIAgentSessionRecord] {
        reader.sessions(for: runtime)
    }

    private var visibleMissionTiles: [MissionConsoleActiveTile] {
        missionHost.snapshot.activeTiles.filter { tile in
            guard let runtimeID = tile.runtimeID?.lowercased() else { return false }
            return runtimeID == runtime.rawValue.lowercased()
        }
    }

    // MARK: - Brand Header

    private var brandHeader: some View {
        let lens = AssistantModelLens(hermesService: HermesService.shared, piService: PiService.shared)
        let resolver = AssistantStatusResolver(hermesService: HermesService.shared, piService: PiService.shared)
        return AssistantBrandHeader(
            runtime: runtime.assistantRuntime,
            runtimeStatus: resolver.status(for: runtime.assistantRuntime),
            modelSnapshot: lens.snapshot(for: runtime.assistantRuntime),
            endpointLabel: resolver.endpointLabel(for: runtime.assistantRuntime),
            onTapModel: { showModelPicker = true },
            onTapStatus: { showConnectionSheet = true }
        )
    }

    @ViewBuilder
    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: MobileTheme.Spacing.sm) {
                if let queuedChatMessage {
                    successBanner(queuedChatMessage)
                }
                ForEach(visibleMissionTiles) { tile in
                    activeMissionRow(tile)
                }
                if let lastError = reader.lastError {
                    errorBanner(lastError)
                }
                ForEach(visibleSessions) { session in
                    Button {
                        selectedSession = session
                    } label: {
                        sessionRow(session)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(MobileTheme.Spacing.md)
            .padding(.bottom, 96)
        }
    }

    @ViewBuilder
    private func activeMissionRow(_ tile: MissionConsoleActiveTile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(
                    tile.phase.displayLabel,
                    systemImage: tile.phase.isProblem ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right"
                )
                .font(MobileTheme.Typography.tiny.weight(.bold))
                .foregroundStyle(tile.phase.isProblem ? MobileTheme.Colors.error : accent)
                .textCase(.uppercase)
                Spacer()
                Text("chat")
                    .font(MobileTheme.Typography.tiny.weight(.semibold))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            Text(tile.title)
                .font(MobileTheme.Typography.body.weight(.semibold))
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .lineLimit(2)
            if let detail = tile.phaseDetail ?? tile.lastEventSnippet {
                Text(detail)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.90))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(accent.opacity(0.55), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func sessionRow(_ session: CLIAgentSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(session.title)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                if !session.isCompleted {
                    Text("live")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(accent.opacity(0.18))
                        )
                        .foregroundStyle(accent)
                }
            }
            if !session.preview.isEmpty {
                Text(session.preview)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let model = session.modelName, !model.isEmpty {
                    Label(model, systemImage: "cpu")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                if let workspace = session.workspaceLabel, !workspace.isEmpty {
                    Label(workspace, systemImage: "folder")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(accent.opacity(0.3), lineWidth: 0.7)
        )
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(MobileTheme.Typography.caption)
            .foregroundStyle(MobileTheme.Colors.error)
            .padding(.horizontal, MobileTheme.Spacing.md)
            .padding(.vertical, MobileTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .fill(MobileTheme.Colors.error.opacity(0.12))
            )
    }

    @ViewBuilder
    private func successBanner(_ message: String) -> some View {
        Text(message)
            .font(MobileTheme.Typography.caption)
            .foregroundStyle(accent)
            .padding(.horizontal, MobileTheme.Spacing.md)
            .padding(.vertical, MobileTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .fill(accent.opacity(0.13))
            )
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: MobileTheme.Spacing.lg) {
            Spacer()
            ZStack {
                Circle()
                    .fill(accent.opacity(0.20))
                    .frame(width: 84, height: 84)
                Image(systemName: "command")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
            }
            VStack(spacing: 6) {
                Text("No \(runtime.displayName) sessions yet")
                    .font(MobileTheme.Typography.title)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(emptyCopy)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if let queuedChatMessage {
                successBanner(queuedChatMessage)
                    .frame(maxWidth: 360)
            }
            ForEach(visibleMissionTiles) { tile in
                activeMissionRow(tile)
                    .frame(maxWidth: 360)
            }
            Button {
                showNewChatSheet = true
            } label: {
                Label("New \(runtime.displayName) chat", systemImage: "plus")
                    .font(MobileTheme.Typography.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(accent.opacity(0.22)))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            Button {
                Task { await reader.refresh() }
            } label: {
                Label(reader.isLoading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                    .font(MobileTheme.Typography.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(accent.opacity(0.18)))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            .disabled(reader.isLoading)
            Spacer()
            Spacer()
        }
        .padding(MobileTheme.Spacing.lg)
    }

    private var newThreadFAB: some View {
        Button {
            HapticBus.sheetOpen()
            showNewChatSheet = true
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.62)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                    .shadow(color: accent.opacity(0.35), radius: 12, y: 6)
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start new \(runtime.displayName) chat")
    }

    private var emptyCopy: String {
        switch runtime {
        case .codex:
            return "Start a Codex chat here, or chat on your Mac and the transcript will sync back automatically."
        case .claude:
            return "Start a Claude Code chat here, or chat on your Mac and this list will mirror the conversation."
        case .openClaw:
            return "Start an OpenClaw chat here, or chat on your Mac and the transcript appears as it streams."
        }
    }

    private var accent: Color {
        switch runtime {
        case .codex:    return Color(hex: "1ABC9C")
        case .claude:   return Color(hex: "D58A4F")
        case .openClaw: return Color(hex: "6E56CF")
        }
    }

    private func shortRequestID(_ id: String) -> String {
        "#\(id.prefix(8))"
    }
}

private struct CLIAgentNewChatSheet: View {
    @Environment(\.dismiss) private var dismiss

    let runtime: CLIAgentRuntime
    let missionHost: MobileMissionConsoleHost
    let onQueued: (String) -> Void

    @State private var title: String
    @State private var message: String = ""
    @State private var targetProject: String = ""
    @State private var dispatching: Bool = false
    @State private var inlineError: String?

    init(
        runtime: CLIAgentRuntime,
        missionHost: MobileMissionConsoleHost,
        onQueued: @escaping (String) -> Void
    ) {
        self.runtime = runtime
        self.missionHost = missionHost
        self.onQueued = onQueued
        _title = State(initialValue: "New \(runtime.displayName) chat")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(runtime.displayName)) {
                    TextField("Title", text: $title)
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $message)
                            .frame(minHeight: 140)
                        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Message \(runtime.displayName)")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                        }
                    }
                }

                Section(header: Text("Project")) {
                    TextField("Optional path or project", text: $targetProject)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !missionHost.snapshot.recentProjects.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(missionHost.snapshot.recentProjects, id: \.self) { project in
                                    Button(project) {
                                        targetProject = project
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }

                if let inlineError {
                    Section {
                        Text(inlineError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if dispatching {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Start") {
                            Task { await dispatch() }
                        }
                        .disabled(!canDispatch)
                    }
                }
            }
        }
        .onAppear {
            missionHost.start()
        }
    }

    private var canDispatch: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func dispatch() async {
        dispatching = true
        inlineError = nil
        do {
            let requestID = try await CLIAgentMissionDispatcher.shared.dispatch(
                title: title.trimmedOrFallback("New \(runtime.displayName) chat"),
                prompt: message,
                missionKind: "chat",
                requestedRuntime: runtime.rawValue,
                targetProject: targetProject.trimmedNilIfEmpty,
                depth: "standard",
                approvalMode: "existing_policy",
                commandsAllowed: false,
                fileEditsAllowed: false
            )
            await missionHost.refresh()
            dispatching = false
            onQueued(requestID)
            dismiss()
        } catch {
            dispatching = false
            inlineError = error.localizedDescription
        }
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func trimmedOrFallback(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

#Preview {
    NavigationStack {
        CLIAgentConversationListView(runtime: .codex)
    }
}
