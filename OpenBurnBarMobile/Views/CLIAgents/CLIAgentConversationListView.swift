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
    @State private var selectedRoute: CLIAgentChatRoute?
    @State private var showConnectionSheet = false
    @State private var showModelPicker = false
    @State private var showImportSheet = false
    @State private var importSnapshot: AgentHarnessImportJobSnapshot?
    @State private var importObservation: CLIAgentMissionObservation?
    @State private var missionHost = MobileMissionConsoleHost()

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
        .sheet(item: $selectedRoute) { route in
            NavigationStack {
                CLIAgentChatThreadView(
                    runtime: runtime,
                    route: route,
                    missionHost: missionHost
                )
                    .navigationTitle(route.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { selectedRoute = nil }
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
                ForEach(visibleSessions) { session in
                    Button {
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

private enum CLIAgentChatRoute: Identifiable {
    case new(runtime: CLIAgentRuntime)
    case existing(CLIAgentSessionRecord)
    case archived(CLIAgentSessionRecord)

    var id: String {
        switch self {
        case let .new(runtime): return "new-\(runtime.rawValue)"
        case let .existing(session): return "existing-\(session.id)"
        case let .archived(session): return "archived-\(session.id)"
        }
    }

    var title: String {
        switch self {
        case let .new(runtime): return "New \(runtime.displayName) Chat"
        case let .existing(session), let .archived(session): return session.title
        }
    }
}

@MainActor
@Observable
private final class CLIAgentChatService {
    private(set) var optimisticMessages: [CLIAgentMessage] = []
    private(set) var queuedRequestID: String?
    private(set) var isSending = false
    private(set) var errorMessage: String?

    let clientThreadID: String
    private let runtime: CLIAgentRuntime
    private let parentSessionID: String?
    private let resumeAction: String

    init(runtime: CLIAgentRuntime, route: CLIAgentChatRoute) {
        self.runtime = runtime
        switch route {
        case .new:
            self.clientThreadID = "mobile-\(UUID().uuidString)"
            self.parentSessionID = nil
            self.resumeAction = "new"
        case let .existing(session):
            self.clientThreadID = session.id
            self.parentSessionID = session.id
            self.resumeAction = "forward"
        case let .archived(session):
            self.clientThreadID = "mobile-\(UUID().uuidString)"
            self.parentSessionID = session.id
            self.resumeAction = session.resumeHandle?.canResume == true ? "resume" : "forward"
        }
    }

    func send(message: String, title: String, targetProject: String?) async -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return nil }
        isSending = true
        errorMessage = nil
        let optimistic = CLIAgentMessage(
            id: "local-\(UUID().uuidString)",
            role: .user,
            text: trimmed,
            timestamp: Date()
        )
        optimisticMessages.append(optimistic)
        do {
            let requestID = try await CLIAgentMissionDispatcher.shared.dispatch(
                title: title,
                prompt: trimmed,
                missionKind: "chat",
                requestedRuntime: runtime.rawValue,
                targetProject: targetProject,
                depth: "standard",
                approvalMode: "existing_policy",
                commandsAllowed: false,
                fileEditsAllowed: false,
                clientThreadID: clientThreadID,
                parentSessionID: parentSessionID,
                resumeAction: resumeAction
            )
            queuedRequestID = requestID
            isSending = false
            return requestID
        } catch {
            optimisticMessages.removeAll { $0.id == optimistic.id }
            errorMessage = error.localizedDescription
            isSending = false
            return nil
        }
    }
}

private struct CLIAgentChatThreadView: View {
    let runtime: CLIAgentRuntime
    let route: CLIAgentChatRoute
    let missionHost: MobileMissionConsoleHost

    @State private var reader: CLIAgentChatReader = .shared
    @State private var chatService: CLIAgentChatService
    @State private var message: String = ""
    @State private var targetProject: String = ""

    init(runtime: CLIAgentRuntime, route: CLIAgentChatRoute, missionHost: MobileMissionConsoleHost) {
        self.runtime = runtime
        self.route = route
        self.missionHost = missionHost
        _chatService = State(initialValue: CLIAgentChatService(runtime: runtime, route: route))
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                        metadataBanner
                        if messages.isEmpty, case .archived = route {
                            archivedLogBanner
                        }
                        ForEach(messages) { bubble(for: $0) }
                        if let queued = chatService.queuedRequestID {
                            queuedBanner(queued)
                        }
                        if let error = chatService.errorMessage {
                            errorBanner(error)
                        }
                    }
                    .padding(MobileTheme.Spacing.lg)
                }

                composer
            }
        }
        .task {
            missionHost.start()
            await reader.refresh()
            await missionHost.refresh()
        }
    }

    private var baseSession: CLIAgentSessionRecord? {
        switch route {
        case .new: return nil
        case let .existing(session), let .archived(session):
            return reader.session(id: session.id) ?? session
        }
    }

    private var messages: [CLIAgentMessage] {
        (baseSession?.messages ?? []) + chatService.optimisticMessages
    }

    private var threadTitle: String {
        baseSession?.title ?? "New \(runtime.displayName) chat"
    }

    @ViewBuilder
    private var metadataBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(runtime.displayName)
                .font(MobileTheme.Typography.tiny.weight(.semibold))
                .foregroundStyle(accent)
            if let session = baseSession {
                Text(session.preview.isEmpty ? "Continue this thread through your signed-in Mac." : session.preview)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
            } else {
                Text("Type immediately. Project and model choices stay in options so setup never blocks the blank composer.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
        }
        .padding(MobileTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous).fill(accent.opacity(0.10)))
    }

    @ViewBuilder
    private var archivedLogBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Archived provider session", systemImage: "lock.doc")
                .font(MobileTheme.Typography.body.weight(.semibold))
                .foregroundStyle(accent)
            if let handle = baseSession?.resumeHandle {
                HStack {
                    if handle.canResume {
                        Label("Resume", systemImage: "arrow.uturn.forward")
                    }
                    if handle.canFork {
                        Label("Fork", systemImage: "arrow.triangle.branch")
                    }
                    if handle.canForward {
                        Label("Forward", systemImage: "paperplane")
                    }
                }
                .font(MobileTheme.Typography.tiny.weight(.semibold))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
        }
        .padding(MobileTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous).fill(MobileTheme.Colors.surface.opacity(0.78)))
    }

    @ViewBuilder
    private func bubble(for message: CLIAgentMessage) -> some View {
        let isUser = message.role == .user
        HStack {
            if isUser { Spacer(minLength: 32) }
            Text(message.text.isEmpty ? "..." : message.text)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(message.isError ? MobileTheme.Colors.error : MobileTheme.Colors.textPrimary)
                .padding(.horizontal, MobileTheme.Spacing.md)
                .padding(.vertical, MobileTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .fill(isUser ? accent.opacity(0.20) : MobileTheme.Colors.surfaceElevated)
                )
            if !isUser { Spacer(minLength: 32) }
        }
    }

    @ViewBuilder
    private func queuedBanner(_ requestID: String) -> some View {
        Label("Queued on your Mac account #\(requestID.prefix(8))", systemImage: "checkmark.circle.fill")
            .font(MobileTheme.Typography.caption.weight(.semibold))
            .foregroundStyle(accent)
            .padding(MobileTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous).fill(accent.opacity(0.12)))
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

    @ViewBuilder
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !missionHost.snapshot.recentProjects.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(missionHost.snapshot.recentProjects, id: \.self) { project in
                            Button(project) { targetProject = project }
                                .font(MobileTheme.Typography.tiny.weight(.semibold))
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(runtime.displayName)", text: $message, axis: .vertical)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous).fill(MobileTheme.Colors.surfaceElevated))
                Button {
                    Task { await dispatch() }
                } label: {
                    Image(systemName: chatService.isSending ? "hourglass" : "arrow.up.circle.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(canDispatch ? accent : MobileTheme.Colors.textMuted)
                }
                .disabled(!canDispatch || chatService.isSending)
            }
        }
        .padding(MobileTheme.Spacing.md)
        .background(.ultraThinMaterial)
    }

    private func dispatch() async {
        let current = message
        let requestID = await chatService.send(
            message: current,
            title: threadTitle,
            targetProject: targetProject.trimmedNilIfEmpty
        )
        if requestID != nil {
            message = ""
            await missionHost.refresh()
            await reader.refresh()
        }
    }

    private var canDispatch: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
