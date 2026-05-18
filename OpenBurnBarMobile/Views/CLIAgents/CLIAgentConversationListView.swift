import SwiftUI
import OpenBurnBarCore

// MARK: - CLI Agent Conversation List
//
// Replaces the "Connect your Mac" placeholder for the Codex, Claude
// Code, and OpenClaw tiles inside the iOS Assistants tab. Lists the
// mirrored sessions the macOS app has published into Firestore via
// `CLIAgentSessionMirror`. New chats are persisted immediately in
// `MobileChatHistoryStore`, while the paired Mac request queue is hidden
// behind the native chat surface.
//
// Empty-state copy is intentionally composer-first: Codex and Claude still
// execute on the trusted Mac, but iOS owns the chat thread and never blocks
// typing on setup or import.

struct CLIAgentConversationListView: View {
    let runtime: CLIAgentRuntime
    let onSelectExistingThreadInSplit: ((String) -> Void)?

    @State private var reader: CLIAgentChatReader = .shared
    @State private var historyStore: MobileChatHistoryStore = .shared
    @State private var selectedRoute: CLIAgentChatRoute?
    @State private var showConnectionSheet = false
    @State private var showModelPicker = false
    @State private var showImportSheet = false
    @State private var importSnapshot: AgentHarnessImportJobSnapshot?
    @State private var importObservation: CLIAgentMissionObservation?
    @State private var missionHost = MobileMissionConsoleHost()

    init(
        runtime: CLIAgentRuntime,
        onSelectExistingThreadInSplit: ((String) -> Void)? = nil
    ) {
        self.runtime = runtime
        self.onSelectExistingThreadInSplit = onSelectExistingThreadInSplit
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()

            VStack(spacing: 0) {
                brandHeader
                if mobileThreads.isEmpty && visibleMirroredSessions.isEmpty && visibleMissionTiles.isEmpty {
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
        .sheet(isPresented: $showImportSheet) {
            CLIAgentImportSheet(
                focusedRuntime: runtime,
                snapshot: importSnapshot,
                onStart: { harnesses in
                    await startImport(harnesses: harnesses)
                }
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showImportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(accent)
                }
                .accessibilityLabel("Import agent history from Mac")
            }
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
        .fullScreenCover(item: $selectedRoute) { route in
            NavigationStack {
                CLIAgentChatThreadView(
                    runtime: runtime,
                    route: route
                )
                    .navigationTitle(route.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { selectedRoute = nil }
                        }
                    }
            }
        }
        .task {
            historyStore.bootstrap()
            missionHost.start()
            await reader.refresh()
        }
        .onDisappear {
            missionHost.stop()
            importObservation?.cancel()
        }
        .refreshable {
            await reader.refresh()
            await missionHost.refresh()
        }
    }

    private var visibleSessions: [CLIAgentSessionRecord] {
        reader.sessions(for: runtime)
    }

    private var mobileThreads: [MobileChatThread] {
        historyStore.threads(for: runtime.assistantRuntime)
    }

    private var visibleMirroredSessions: [CLIAgentSessionRecord] {
        let mobileIDs = Set(mobileThreads.map(\.id))
        return visibleSessions.filter { !mobileIDs.contains($0.id) }
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
                ForEach(visibleMissionTiles) { tile in
                    activeMissionRow(tile)
                }
                if let lastError = reader.lastError {
                    errorBanner(lastError)
                }
                ForEach(mobileThreads) { thread in
                    Button {
                        if let onSelectExistingThreadInSplit {
                            onSelectExistingThreadInSplit("cli_mirror:\(thread.id)")
                            return
                        }
                        selectedRoute = .mobile(thread)
                    } label: {
                        mobileThreadRow(thread)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(visibleMirroredSessions) { session in
                    Button {
                        if let onSelectExistingThreadInSplit {
                            onSelectExistingThreadInSplit("cli:\(session.id)")
                            return
                        }
                        selectedRoute = session.sourceKind == .archivedLog ? .archived(session) : .existing(session)
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
    private func mobileThreadRow(_ thread: MobileChatThread) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(thread.title)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("mobile")
                    .font(MobileTheme.Typography.tiny.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent.opacity(0.18)))
                    .foregroundStyle(accent)
            }
            if !thread.preview.isEmpty {
                Text(thread.preview)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
            }
            MobileAttachmentSummaryStrip(attachments: thread.recentAttachmentPreviews)
            HStack(spacing: 8) {
                if let model = thread.modelName, !model.isEmpty {
                    Label(model, systemImage: "cpu")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Label("\(thread.messageCount) msgs", systemImage: "bubble.left.and.bubble.right")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Spacer()
                Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(accent.opacity(0.42), lineWidth: 0.8)
        )
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
            ForEach(visibleMissionTiles) { tile in
                activeMissionRow(tile)
                    .frame(maxWidth: 360)
            }
            Button {
                selectedRoute = .new(runtime: runtime)
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
            selectedRoute = .new(runtime: runtime)
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
            return "Start a Codex chat here. Replies run through your paired Mac while this device keeps the thread."
        case .claude:
            return "Start a Claude Code chat here. The trusted Mac executes it, but the conversation stays native on mobile."
        case .openClaw:
            return "Start an OpenClaw chat here. The Mac streams replies back into this mobile thread."
        }
    }

    private var accent: Color {
        switch runtime {
        case .codex:    return Color(hex: "1ABC9C")
        case .claude:   return Color(hex: "D58A4F")
        case .openClaw: return Color(hex: "6E56CF")
        }
    }

    private func startImport(harnesses: [String]) async {
        do {
            let jobID = try await AgentHarnessImportJobDispatcher.shared.create(selectedHarnesses: harnesses)
            importSnapshot = AgentHarnessImportJobSnapshot(
                documentID: jobID,
                data: [
                    "id": jobID,
                    "status": "pending",
                    "progressMessage": "Waiting for a trusted Mac.",
                    "scannedCount": 0,
                    "importedCount": 0,
                    "mirroredSessionCount": 0,
                    "uploadedSessionLogCount": 0
                ]
            )
            importObservation?.cancel()
            importObservation = try AgentHarnessImportJobDispatcher.shared.observe(
                jobID: jobID,
                onUpdate: { snapshot in
                    importSnapshot = snapshot
                    if snapshot.isTerminal {
                        Task {
                            await reader.refresh()
                        }
                    }
                },
                onError: { message in
                    importSnapshot = AgentHarnessImportJobSnapshot(
                        documentID: jobID,
                        data: [
                            "id": jobID,
                            "status": "failed",
                            "progressMessage": "Import watcher failed.",
                            "errorMessage": message,
                            "scannedCount": 0,
                            "importedCount": 0,
                            "mirroredSessionCount": 0,
                            "uploadedSessionLogCount": 0
                        ]
                    )
                }
            )
        } catch {
            importSnapshot = AgentHarnessImportJobSnapshot(
                documentID: "local-error",
                data: [
                    "status": "failed",
                    "progressMessage": "Could not start import.",
                    "errorMessage": error.localizedDescription,
                    "scannedCount": 0,
                    "importedCount": 0,
                    "mirroredSessionCount": 0,
                    "uploadedSessionLogCount": 0
                ]
            )
        }
    }

}

enum CLIAgentChatRoute: Identifiable {
    case new(runtime: CLIAgentRuntime)
    case mobile(MobileChatThread)
    case existing(CLIAgentSessionRecord)
    case archived(CLIAgentSessionRecord)

    var id: String {
        switch self {
        case let .new(runtime): return "new-\(runtime.rawValue)"
        case let .mobile(thread): return "mobile-\(thread.id)"
        case let .existing(session): return "existing-\(session.id)"
        case let .archived(session): return "archived-\(session.id)"
        }
    }

    var title: String {
        switch self {
        case let .new(runtime): return "New \(runtime.displayName) Chat"
        case let .mobile(thread): return thread.title
        case let .existing(session), let .archived(session): return session.title
        }
    }

    var isNew: Bool {
        if case .new = self { return true }
        return false
    }
}

@MainActor
@Observable
final class CLIAgentMobileChatService {
    private(set) var threadID: String
    private(set) var streamingMessageID: String?
    private(set) var isSending = false
    private(set) var errorMessage: String?

    private let runtime: CLIAgentRuntime
    private let historyStore: MobileChatHistoryStore
    private let relayChatTransport: CLIAgentRelayChatTransporting
    private let parentSessionID: String?
    private let resumeAction: String
    private var observation: CLIAgentMissionObservation?

    init(
        runtime: CLIAgentRuntime,
        route: CLIAgentChatRoute,
        historyStore: MobileChatHistoryStore,
        relayChatTransport: CLIAgentRelayChatTransporting = CLIAgentRelayChatTransport.shared
    ) {
        self.runtime = runtime
        self.historyStore = historyStore
        self.relayChatTransport = relayChatTransport
        switch route {
        case .new:
            self.threadID = "mobile-\(runtime.rawValue)-\(UUID().uuidString)"
            self.parentSessionID = nil
            self.resumeAction = "new"
        case let .mobile(thread):
            self.threadID = thread.id
            self.parentSessionID = nil
            self.resumeAction = "continue"
        case let .existing(session):
            self.threadID = session.id
            self.parentSessionID = session.id
            self.resumeAction = "continue"
            seedThread(from: session, id: session.id)
        case let .archived(session):
            self.threadID = "mobile-\(runtime.rawValue)-\(UUID().uuidString)"
            self.parentSessionID = session.id
            self.resumeAction = session.resumeHandle?.canResume == true ? "resume" : "forward"
            seedThread(from: session, id: threadID)
        }
    }

    func startNewThread() {
        observation?.cancel()
        observation = nil
        threadID = "mobile-\(runtime.rawValue)-\(UUID().uuidString)"
        streamingMessageID = nil
        isSending = false
        errorMessage = nil
    }

    func send(message: String) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        errorMessage = nil
        observation?.cancel()

        let now = Date()
        let userMessage = MobileChatMessage(
            role: "user",
            text: trimmed,
            timestamp: now
        )
        let assistantPlaceholder = MobileChatMessage(
            role: "assistant",
            text: "",
            timestamp: now.addingTimeInterval(0.001)
        )
        streamingMessageID = assistantPlaceholder.id
        upsertThreadAppending(userMessage: userMessage, assistantPlaceholder: assistantPlaceholder)

        do {
            try await relayChatTransport.stream(
                runtime: runtime,
                threadID: threadID,
                prompt: trimmed,
                title: currentThreadTitle(),
                parentSessionID: parentSessionID,
                resumeAction: resumeAction,
                onEvent: { [weak self] event in
                    self?.apply(event, placeholderID: assistantPlaceholder.id)
                }
            )
            if isSending {
                isSending = false
                streamingMessageID = nil
            }
        } catch {
            guard shouldFallBackToMission(afterRelayError: error) else {
                finalizePlaceholder(
                    assistantPlaceholder.id,
                    text: "Could not reach \(runtime.displayName) on your Mac: \(error.localizedDescription)",
                    isError: true,
                    modelName: nil,
                    toolCalls: []
                )
                errorMessage = error.localizedDescription
                isSending = false
                return
            }
            await dispatchMissionFallback(
                prompt: trimmed,
                placeholderID: assistantPlaceholder.id,
                relayError: error
            )
        }
    }

    private func dispatchMissionFallback(prompt: String, placeholderID: String, relayError: Error) async {
        do {
            let requestID = try await CLIAgentMissionDispatcher.shared.dispatch(
                title: currentThreadTitle(),
                prompt: prompt,
                missionKind: "chat",
                requestedRuntime: runtime.rawValue,
                depth: "standard",
                approvalMode: "existing_policy",
                commandsAllowed: false,
                fileEditsAllowed: false,
                clientThreadID: threadID,
                parentSessionID: parentSessionID,
                resumeAction: resumeAction
            )
            observation = try CLIAgentMissionDispatcher.shared.observe(
                requestID: requestID,
                onUpdate: { [weak self] snapshot in
                    self?.apply(snapshot, placeholderID: placeholderID)
                },
                onError: { [weak self] message in
                    guard let self else { return }
                    self.finalizePlaceholder(
                        placeholderID,
                        text: "Could not watch \(self.runtime.displayName) response: \(message)",
                        isError: true,
                        modelName: nil,
                        toolCalls: []
                    )
                    self.errorMessage = message
                    self.isSending = false
                    self.streamingMessageID = nil
                    self.observation?.cancel()
                    self.observation = nil
                }
            )
        } catch {
            finalizePlaceholder(
                placeholderID,
                text: "Could not reach \(runtime.displayName) on your Mac: \(error.localizedDescription)",
                isError: true,
                modelName: nil,
                toolCalls: []
            )
            errorMessage = relayError.localizedDescription
            isSending = false
        }
    }

    private func shouldFallBackToMission(afterRelayError error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("already responding")
            || lower.contains("unsupported runtime")
            || lower.contains("cannot send an empty") {
            return false
        }
        return true
    }

    func isStreamingMessage(_ id: String) -> Bool {
        isSending && streamingMessageID == id
    }

    private func seedThread(from session: CLIAgentSessionRecord, id: String) {
        guard historyStore.thread(id: id) == nil else { return }
        let messages = session.messages.map { message in
            MobileChatMessage(
                id: message.id,
                role: message.role.rawValue,
                text: message.text,
                timestamp: message.timestamp,
                modelName: session.modelName,
                isError: message.isError,
                toolCalls: message.toolUses.map(Self.mobileToolCall(from:))
            )
        }
        let thread = MobileChatThread(
            id: id,
            runtime: runtime.assistantRuntime.rawValue,
            title: session.title,
            preview: session.preview,
            modelName: session.modelName,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            messages: messages
        )
        historyStore.upsert(thread)
    }

    private func upsertThreadAppending(userMessage: MobileChatMessage, assistantPlaceholder: MobileChatMessage) {
        var thread = historyStore.thread(id: threadID) ?? MobileChatThread(
            id: threadID,
            runtime: runtime.assistantRuntime.rawValue,
            title: "New \(runtime.displayName) chat",
            preview: "",
            modelName: nil,
            createdAt: Date(),
            updatedAt: Date(),
            messages: []
        )
        thread.messages.append(userMessage)
        thread.messages.append(assistantPlaceholder)
        thread.title = Self.derivedTitle(from: thread.messages, fallback: "New \(runtime.displayName) chat")
        thread.preview = Self.derivedPreview(from: thread.messages)
        historyStore.upsert(thread)
    }

    private func currentThreadTitle() -> String {
        historyStore.thread(id: threadID)?.title ?? "New \(runtime.displayName) chat"
    }

    private func apply(_ snapshot: CLIAgentMissionSnapshot, placeholderID: String) {
        let text = CLIAgentMobileChatSnapshotReducer.visibleAssistantText(for: snapshot)
        let toolCalls = CLIAgentMobileChatSnapshotReducer.toolCalls(for: snapshot)
        if let text {
            finalizePlaceholder(
                placeholderID,
                text: text,
                isError: CLIAgentMobileChatSnapshotReducer.isError(snapshot),
                modelName: snapshot.selectedModelID ?? snapshot.requestedModelID ?? snapshot.runtimeLabel,
                toolCalls: toolCalls,
                keepStreaming: !snapshot.isTerminal
            )
        } else if !toolCalls.isEmpty {
            finalizePlaceholder(
                placeholderID,
                text: "",
                isError: false,
                modelName: snapshot.selectedModelID ?? snapshot.requestedModelID ?? snapshot.runtimeLabel,
                toolCalls: toolCalls,
                keepStreaming: !snapshot.isTerminal
            )
        }

        if snapshot.isTerminal {
            if text == nil {
                finalizePlaceholder(
                    placeholderID,
                    text: "\(snapshot.runtimeLabel) finished without a visible reply.",
                    isError: CLIAgentMobileChatSnapshotReducer.isError(snapshot),
                    modelName: snapshot.selectedModelID ?? snapshot.requestedModelID ?? snapshot.runtimeLabel,
                    toolCalls: []
                )
            }
            isSending = false
            streamingMessageID = nil
            observation?.cancel()
            observation = nil
        }
    }

    private func apply(_ event: CLIAgentRelayChatEvent, placeholderID: String) {
        let relayText = event.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let errorText = event.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let visibleText = relayText ?? errorText.map { "Error: \($0)" } ?? ""
        finalizePlaceholder(
            placeholderID,
            text: visibleText,
            isError: event.isError,
            modelName: event.modelID,
            toolCalls: Self.mobileToolCalls(from: event.transcriptPieces),
            keepStreaming: !event.isTerminal
        )
        if event.isTerminal {
            isSending = false
            streamingMessageID = nil
            observation?.cancel()
            observation = nil
        }
    }

    private func finalizePlaceholder(
        _ placeholderID: String,
        text: String,
        isError: Bool,
        modelName: String?,
        toolCalls: [MobileChatToolCall],
        keepStreaming: Bool = false
    ) {
        guard var thread = historyStore.thread(id: threadID),
              let idx = thread.messages.firstIndex(where: { $0.id == placeholderID })
        else { return }
        var message = thread.messages[idx]
        message.text = text
        message.isError = isError
        message.modelName = modelName
        message.toolCalls = toolCalls
        thread.messages[idx] = message
        thread.modelName = modelName ?? thread.modelName
        thread.preview = Self.derivedPreview(from: thread.messages)
        historyStore.upsert(thread)
        if !keepStreaming {
            streamingMessageID = nil
        }
    }

    private static func mobileToolCall(from tool: CLIAgentToolUse) -> MobileChatToolCall {
        MobileChatToolCall(
            id: tool.id,
            name: tool.name,
            status: tool.status,
            detail: tool.detail
        )
    }

    private static func mobileToolCalls(from pieces: [CLIAgentRelayTranscriptPiece]) -> [MobileChatToolCall] {
        pieces.compactMap { piece in
            switch piece.kind {
            case .text:
                return nil
            case .toolUse:
                return MobileChatToolCall(
                    id: piece.id,
                    name: piece.value,
                    status: "running",
                    detail: piece.detail
                )
            case .toolResult:
                return MobileChatToolCall(
                    id: piece.id,
                    name: piece.value,
                    status: "done",
                    detail: piece.detail
                )
            }
        }
    }

    private static func derivedTitle(from messages: [MobileChatMessage], fallback: String) -> String {
        if let first = messages.first(where: { $0.role == "user" })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !first.isEmpty {
            return String(first.prefix(64))
        }
        return fallback
    }

    private static func derivedPreview(from messages: [MobileChatMessage]) -> String {
        if let latest = messages.reversed().first(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            return String(latest.prefix(140))
        }
        return ""
    }
}

enum CLIAgentMobileChatSnapshotReducer {
    static func visibleAssistantText(for snapshot: CLIAgentMissionSnapshot) -> String? {
        let status = snapshot.status.lowercased()
        if snapshot.isTerminal {
            if let error = snapshot.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return "Error: \(error)"
            }
            if let assistant = latestAssistantText(from: snapshot) {
                return assistant
            }
            if let result = snapshot.resultPreview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return result
            }
            if status == "completed" {
                return "\(snapshot.runtimeLabel) finished without a visible reply."
            }
            return snapshot.displayLiveSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        if let assistant = latestAssistantText(from: snapshot) {
            return assistant
        }
        guard snapshot.hasBeenClaimedByMac else { return nil }
        return snapshot.displayLiveSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func isError(_ snapshot: CLIAgentMissionSnapshot) -> Bool {
        ["failed", "canceled", "cancelled", "unauthorized", "agent_launch_failed"].contains(snapshot.status.lowercased())
            || snapshot.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func toolCalls(for snapshot: CLIAgentMissionSnapshot) -> [MobileChatToolCall] {
        snapshot.events.compactMap { event in
            guard event.kind == "tool_call"
                    || event.kind == "tool_result"
                    || event.phase == "tool_use"
                    || event.phase == "tool_result"
            else { return nil }
            let name = event.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? event.phase.replacingOccurrences(of: "_", with: " ").capitalized
            let status = (event.kind == "tool_result" || event.phase == "tool_result") ? "done" : "running"
            let detail = event.fullMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? event.message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return MobileChatToolCall(
                id: "mission-\(snapshot.id)-\(event.sequence)",
                name: name,
                status: status,
                detail: detail
            )
        }
    }

    private static func latestAssistantText(from snapshot: CLIAgentMissionSnapshot) -> String? {
        snapshot.events.reversed().first { event in
            event.kind == "llm_response"
                || event.kind == "final_answer"
                || event.phase == "assistant_response"
                || event.phase == "completed"
        }.flatMap { event in
            event.fullMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? event.message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }
}

struct CLIAgentChatThreadView: View {
    let runtime: CLIAgentRuntime
    let route: CLIAgentChatRoute

    @State private var historyStore: MobileChatHistoryStore = .shared
    @State private var chatService: CLIAgentMobileChatService
    @State private var draft: String = ""
    @State private var showConnectionSheet = false
    @State private var showModelPicker = false
    @FocusState private var inputFocused: Bool

    init(runtime: CLIAgentRuntime, route: CLIAgentChatRoute) {
        self.runtime = runtime
        self.route = route
        _chatService = State(initialValue: CLIAgentMobileChatService(runtime: runtime, route: route, historyStore: .shared))
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()
            VStack(spacing: 0) {
                messageList
                Divider().background(MobileTheme.Colors.border.opacity(0.35))
                composer
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showModelPicker = true
                    } label: {
                        Label("Switch model", systemImage: "cpu")
                    }
                    Button {
                        showConnectionSheet = true
                    } label: {
                        Label("Connections", systemImage: "network")
                    }
                    Button {
                        chatService.startNewThread()
                        draft = ""
                        inputFocused = true
                    } label: {
                        Label("New chat", systemImage: "plus.bubble")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(accent)
                }
            }
        }
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
        .task {
            historyStore.bootstrap()
            guard route.isNew else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            inputFocused = true
        }
    }

    private var activeThread: MobileChatThread? {
        historyStore.thread(id: chatService.threadID)
    }

    private var messages: [MobileChatMessage] {
        activeThread?.messages ?? []
    }

    private var lastMessageSignature: String {
        guard let last = messages.last else { return "empty" }
        return "\(last.id)-\(last.text.count)-\(last.toolCalls.count)"
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                    if messages.isEmpty {
                        emptyNativeState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 84)
                    } else {
                        ForEach(messages) { message in
                            chatBubble(message)
                                .id(message.id)
                        }
                    }
                    if let error = chatService.errorMessage, messages.isEmpty {
                        errorBanner(error)
                    }
                }
                .padding(MobileTheme.Spacing.lg)
            }
            .onChange(of: lastMessageSignature) { _, _ in
                guard let lastID = messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private var emptyNativeState: some View {
        VStack(spacing: 16) {
            UnifiedProviderLogoView(provider: runtime.assistantRuntime.agentProvider, size: 78)
            Text(runtime.displayName)
                .font(MobileTheme.Typography.title)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            HStack(spacing: 8) {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 12, weight: .semibold))
                Text("Paired Mac")
                    .font(MobileTheme.Typography.caption.weight(.semibold))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(accent.opacity(0.14)))
        }
    }

    @ViewBuilder
    private func chatBubble(_ message: MobileChatMessage) -> some View {
        let isUser = message.role == "user"
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 48) }
            if !isUser {
                UnifiedProviderLogoView(provider: runtime.assistantRuntime.agentProvider, size: 24)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                bubbleBody(message, isUser: isUser)
                if !message.toolCalls.isEmpty {
                    toolCallStrip(message.toolCalls)
                }
                if !isUser, let model = message.modelName, !model.isEmpty {
                    Text(model)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
            if !isUser { Spacer(minLength: 48) }
        }
    }

    private func bubbleBody(_ message: MobileChatMessage, isUser: Bool) -> some View {
        Group {
            if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               chatService.isStreamingMessage(message.id) {
                thinkingDots
                    .padding(.horizontal, MobileTheme.Spacing.md)
                    .padding(.vertical, MobileTheme.Spacing.sm)
            } else {
                Text(message.text.isEmpty ? " " : message.text)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(message.isError ? MobileTheme.Colors.error : MobileTheme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, MobileTheme.Spacing.md)
                    .padding(.vertical, MobileTheme.Spacing.sm)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(isUser ? accent.opacity(0.22) : MobileTheme.Colors.surfaceElevated.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(isUser ? accent.opacity(0.28) : MobileTheme.Colors.border.opacity(0.35), lineWidth: 0.7)
        )
    }

    private var thinkingDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { idx in
                Circle()
                    .fill(accent.opacity(0.35 + Double(idx) * 0.18))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityLabel("\(runtime.displayName) is responding")
    }

    private func toolCallStrip(_ toolCalls: [MobileChatToolCall]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(toolCalls) { tool in
                    Label(tool.name, systemImage: tool.status == "done" ? "checkmark.circle" : "wrench.and.screwdriver")
                        .font(MobileTheme.Typography.tiny.weight(.semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(accent.opacity(0.13)))
                }
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(MobileTheme.Typography.caption)
            .foregroundStyle(MobileTheme.Colors.error)
            .padding(MobileTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous).fill(MobileTheme.Colors.error.opacity(0.12)))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(runtime.displayName)", text: $draft, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...5)
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous).fill(MobileTheme.Colors.surfaceElevated))
                .onSubmit { send() }
            Button {
                send()
            } label: {
                Image(systemName: chatService.isSending ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(canSend ? accent : MobileTheme.Colors.textMuted)
            }
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
        .padding(MobileTheme.Spacing.md)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatService.isSending
    }

    private func send() {
        let current = draft
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        HapticBus.send()
        draft = ""
        inputFocused = true
        Task {
            await chatService.send(message: current)
        }
    }

    private var accent: Color {
        switch runtime {
        case .codex: return Color(hex: "1ABC9C")
        case .claude: return Color(hex: "D58A4F")
        case .openClaw: return Color(hex: "6E56CF")
        }
    }
}

private struct CLIAgentImportSheet: View {
    let focusedRuntime: CLIAgentRuntime
    let snapshot: AgentHarnessImportJobSnapshot?
    let onStart: ([String]) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selections: Set<String>
    @State private var isStarting = false

    init(
        focusedRuntime: CLIAgentRuntime,
        snapshot: AgentHarnessImportJobSnapshot?,
        onStart: @escaping ([String]) async -> Void
    ) {
        self.focusedRuntime = focusedRuntime
        self.snapshot = snapshot
        self.onStart = onStart
        _selections = State(initialValue: Set(Self.defaultHarnesses(focusedRuntime: focusedRuntime).map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Self.availableHarnesses, id: \.id) { harness in
                        Toggle(isOn: binding(for: harness.id)) {
                            Label(harness.name, systemImage: harness.symbol)
                        }
                    }
                }
                Section {
                    if let snapshot {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(snapshot.progressMessage)
                                .font(MobileTheme.Typography.body.weight(.semibold))
                            HStack {
                                metric("Scanned", snapshot.scannedCount)
                                metric("Imported", snapshot.importedCount)
                                metric("Mirrored", snapshot.mirroredSessionCount)
                            }
                            if let error = snapshot.errorMessage {
                                Text(error)
                                    .font(MobileTheme.Typography.caption)
                                    .foregroundStyle(MobileTheme.Colors.error)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("Import Codex, Claude Code, OpenClaw, Hermes, and other local Mac agent sessions into mobile search.")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                }
            }
            .navigationTitle("Import Agent History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isStarting ? "Starting..." : "Start") {
                        Task {
                            isStarting = true
                            await onStart(Array(selections))
                            isStarting = false
                        }
                    }
                    .disabled(isStarting || selections.isEmpty)
                }
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selections.contains(id) },
            set: { enabled in
                if enabled {
                    selections.insert(id)
                } else {
                    selections.remove(id)
                }
            }
        )
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(MobileTheme.Typography.body.weight(.bold))
            Text(label)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func defaultHarnesses(focusedRuntime: CLIAgentRuntime) -> [Harness] {
        let defaults = ["codex", "claude", "openclaw", "hermes", "opencode"]
        let focused = focusedRuntime.rawValue
        return availableHarnesses.filter { defaults.contains($0.id) || $0.id == focused }
    }

    private static let availableHarnesses: [Harness] = [
        Harness(id: "codex", name: "Codex", symbol: "terminal"),
        Harness(id: "claude", name: "Claude Code", symbol: "curlybraces"),
        Harness(id: "openclaw", name: "OpenClaw", symbol: "bolt"),
        Harness(id: "hermes", name: "Hermes", symbol: "bubble.left.and.bubble.right"),
        Harness(id: "opencode", name: "OpenCode", symbol: "chevron.left.forwardslash.chevron.right"),
        Harness(id: "factory", name: "Factory", symbol: "hammer"),
        Harness(id: "cursor", name: "Cursor", symbol: "cursorarrow"),
        Harness(id: "aider", name: "Aider", symbol: "wand.and.stars"),
        Harness(id: "cline", name: "Cline", symbol: "doc.text"),
        Harness(id: "kilocode", name: "Kilo Code", symbol: "k.circle"),
        Harness(id: "roocode", name: "Roo Code", symbol: "r.circle"),
        Harness(id: "forge", name: "Forge", symbol: "flame"),
        Harness(id: "gemini", name: "Gemini CLI", symbol: "sparkles"),
        Harness(id: "goose", name: "Goose", symbol: "bird"),
        Harness(id: "windsurf", name: "Windsurf", symbol: "wind"),
        Harness(id: "warp", name: "Warp", symbol: "rectangle.3.group"),
        Harness(id: "kimi", name: "Kimi", symbol: "moon"),
        Harness(id: "ollama", name: "Ollama", symbol: "cpu")
    ]

    private struct Harness: Equatable {
        let id: String
        let name: String
        let symbol: String
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

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
