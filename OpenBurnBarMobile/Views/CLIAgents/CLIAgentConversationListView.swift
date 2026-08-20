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
//
// Persistence/networking lives in `CLIAgentMobileChatService` and
// `AgentHarnessImportStore` (Services); these views render state and send
// intents only (audit wave 4, item 15).

struct CLIAgentConversationListView: View {
    let runtime: CLIAgentRuntime
    let onSelectExistingThreadInSplit: ((String) -> Void)?

    @State private var reader: CLIAgentChatReader = .shared
    @State private var historyStore: MobileChatHistoryStore = .shared
    @State private var selectedRoute: CLIAgentChatRoute?
    @State private var showConnectionSheet = false
    @State private var showModelPicker = false
    @State private var showImportSheet = false
    @State private var importStore = AgentHarnessImportStore()
    @State private var missionHost = MobileMissionConsoleHost()
    @State private var resumeSheetSession: CLIAgentSessionRecord?

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
                snapshot: importStore.snapshot,
                onStart: { harnesses in
                    await importStore.start(harnesses: harnesses)
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
        .sheet(item: $resumeSheetSession) { session in
            CLIAgentResumeSheet(session: session)
        }
        .task {
            historyStore.bootstrap()
            missionHost.start()
            await reader.refresh()
        }
        .onDisappear {
            missionHost.stop()
            importStore.cancelObservation()
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
                    HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
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

                        sessionActionMenu(session)
                    }
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
                // Previews persisted before the markdown-flattening fix may
                // still carry raw markers — strip at display too.
                Text(HermesAtomParser.plainText(thread.preview))
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
                // Mac-mirrored previews arrive via Firestore as raw
                // assistant text — flatten markdown at display.
                Text(HermesAtomParser.plainText(session.preview))
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func sessionActionMenu(_ session: CLIAgentSessionRecord) -> some View {
        Button {
            HapticBus.sheetOpen()
            resumeSheetSession = session
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .fill(accent.opacity(0.16))
                    .frame(width: 48)
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Restart \(session.title) on Mac")
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
                fabPlate
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start new \(runtime.displayName) chat")
    }

    /// FAB plate. On iOS 26 the accent gradient becomes a translucent wash
    /// riding ON interactive Liquid Glass — no opaque fill underneath, so the
    /// glass samples the Aurora backdrop and the scrolling list behind it;
    /// the accent survives as the glass tint plus the wash. iOS 17–25 keeps
    /// the original opaque gradient byte-identical.
    @ViewBuilder
    private var fabPlate: some View {
        if #available(iOS 26, *) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.48), accent.opacity(0.26)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)
                .liquidGlassEffect(.regular.tint(accent).interactive(), in: .circle)
                .shadow(color: accent.opacity(0.35), radius: 12, y: 6)
        } else {
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
        }
    }

    private var emptyCopy: String {
        switch runtime {
        case .codex:
            return "Start a Codex chat here. Replies run through your paired Mac while this device keeps the thread."
        case .claude:
            return "Start a Claude Code chat here. The trusted Mac executes it, but the conversation stays native on mobile."
        case .openClaw:
            return "Start an OpenClaw chat here. The Mac streams replies back into this mobile thread."
        case .droid:
            return "Start a Droid chat here. The Mac streams replies back into this mobile thread."
        case .forge:
            return "Start a Forge chat here. The Mac streams replies back into this mobile thread."
        case .antigravity:
            return "Start an Antigravity chat here. The Mac streams replies back into this mobile thread."
        case .grok:
            return "Start a Grok Build chat here. The Mac streams replies back into this mobile thread."
        case .cursorAgent:
            return "Start a Cursor Agent chat here. The Mac streams replies back into this mobile thread."
        case .junie:
            return "Start a Junie chat here. The Mac streams replies back into this mobile thread."
        case .openClaude:
            return "Start an OpenClaude chat here. The Mac streams replies back into this mobile thread."
        case .omp:
            return "Start an OMP chat here. The Mac streams replies back into this mobile thread."
        case .fx:
            return "Start an fx chat here. The Mac streams replies back into this mobile thread."
        }
    }

    private var accent: Color {
        switch runtime {
        case .codex:    return Color(hex: "1ABC9C")
        case .claude:   return Color(hex: "D58A4F")
        case .openClaw: return Color(hex: "6E56CF")
        case .openClaude: return Color(hex: "D97757")
        case .omp: return Color(hex: "EC4899")
        case .droid:    return Color(hex: "8B5CF6")
        case .forge:    return Color(hex: "F97316")
        case .antigravity: return Color(hex: "6C63FF")
        case .grok: return Color(hex: "111111")
        case .cursorAgent: return Color(hex: "00E5FF")
        case .junie:    return Color(hex: "48E054")
        case .fx:       return Color(hex: "A1A1AA")
        }
    }

}

struct CLIAgentChatThreadView: View {
    let runtime: CLIAgentRuntime
    let route: CLIAgentChatRoute

    @State private var historyStore: MobileChatHistoryStore = .shared
    @State private var chatService: CLIAgentMobileChatService
    @State private var draft: String = ""
    @State private var presentationMode: CLIAgentChatPresentationMode
    @State private var showConnectionSheet = false
    @State private var showModelPicker = false
    @State private var showPermissionSheet = false
    @State private var showThinkingStylePicker = false
    @FocusState private var inputFocused: Bool

    init(runtime: CLIAgentRuntime, route: CLIAgentChatRoute) {
        self.runtime = runtime
        self.route = route
        _chatService = State(initialValue: CLIAgentMobileChatService(runtime: runtime, route: route, historyStore: .shared))
        _presentationMode = State(initialValue: CLIAgentPresentationModePreferences.mode(for: runtime))
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()
            VStack(spacing: 0) {
                primaryContent
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
                        showThinkingStylePicker = true
                    } label: {
                        Label("Thinking Style", systemImage: "circle.dotted")
                    }
                    Button {
                        showPermissionSheet = true
                    } label: {
                        Label("Agent permissions", systemImage: "hand.raised")
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
        .sheet(isPresented: $showPermissionSheet) {
            AgentPermissionGrantSheet(
                runtimeID: runtime.assistantRuntime,
                threadID: chatService.threadID
            )
        }
        .sheet(isPresented: $showThinkingStylePicker) {
            HermesThinkingStylePickerSheet(provider: runtime.agentProvider)
        }
        .task {
            historyStore.bootstrap()
            guard route.isNew else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            inputFocused = true
        }
        .onAppear {
            AgentReplyNotificationService.shared.setActiveChat(
                runtime: runtime.rawValue,
                threadID: chatService.threadID,
                surface: "cli_agent_chat"
            )
        }
        .onChange(of: chatService.threadID) { _, threadID in
            AgentReplyNotificationService.shared.setActiveChat(
                runtime: runtime.rawValue,
                threadID: threadID,
                surface: "cli_agent_chat"
            )
        }
        .onDisappear {
            AgentReplyNotificationService.shared.setActiveChat(runtime: nil, threadID: nil, surface: nil)
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

    /// In `.macInteractiveCLI` mode the chat list is replaced by the focused
    /// single-window terminal: the Mac launches this runtime's CLI in a visible
    /// Terminal and pins the mirror to just that window. Other modes keep the
    /// native chat transcript.
    @ViewBuilder
    private var primaryContent: some View {
        if presentationMode == .macInteractiveCLI {
            InlineAgentMirrorView(
                singleton: AgentWatchOverlaySingleton.shared,
                hermesService: HermesService.shared,
                runtime: runtime.rawValue
            )
            .padding(MobileTheme.Spacing.md)
        } else {
            messageList
        }
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
                thinkingIndicator
            } else {
                // Assistant turns arrive as markdown — render inline
                // emphasis instead of raw `**` markers. User and error
                // turns stay verbatim.
                Text(
                    isUser || message.isError || message.text.isEmpty
                        ? AttributedString(message.text.isEmpty ? " " : message.text)
                        : HermesInlineMarkdown.attributedString(message.text)
                )
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

    /// The shared thinking spinner (user-chosen style/color/size). The
    /// `provider` color choice resolves to this runtime's brand color.
    private var thinkingIndicator: some View {
        HermesThinkingSpinner(provider: runtime.agentProvider)
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

    /// Composer chrome. On iOS 26 the bar rides on pure Liquid Glass that
    /// samples the Aurora backdrop (no material underneath — a fill would
    /// block the refraction), extended under the home indicator exactly like
    /// the edge-bleeding material it replaces. iOS 17–25 keeps the original
    /// `.ultraThinMaterial` line byte-identical; the shared adapter is not
    /// used here because a shape-scoped fallback background would lose the
    /// default safe-area bleed of the plain material.
    @ViewBuilder
    private var composer: some View {
        if #available(iOS 26, *) {
            composerBody
                .background {
                    Color.clear
                        .liquidGlassEffect(.regular, in: .rect)
                        .ignoresSafeArea(.container, edges: .bottom)
                }
        } else {
            composerBody
                .background(.ultraThinMaterial)
        }
    }

    private var composerBody: some View {
        VStack(spacing: 8) {
            Picker("Session interface", selection: $presentationMode) {
                ForEach(CLIAgentChatPresentationMode.allCases) { mode in
                    Label(mode.shortLabel, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(chatService.isSending)
            .onChange(of: presentationMode) { _, newValue in
                CLIAgentPresentationModePreferences.set(newValue, for: runtime)
            }

            if presentationMode != .macInteractiveCLI {
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
            }
        }
        .padding(MobileTheme.Spacing.md)
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
            await chatService.send(message: current, presentationMode: presentationMode)
        }
    }

    private var accent: Color {
        switch runtime {
        case .codex: return Color(hex: "1ABC9C")
        case .claude: return Color(hex: "D58A4F")
        case .openClaw: return Color(hex: "6E56CF")
        case .openClaude: return Color(hex: "D97757")
        case .omp: return Color(hex: "EC4899")
        case .droid: return Color(hex: "8B5CF6")
        case .forge: return Color(hex: "F97316")
        case .antigravity: return Color(hex: "6C63FF")
        case .grok: return Color(hex: "111111")
        case .cursorAgent: return Color(hex: "00E5FF")
        case .junie: return Color(hex: "48E054")
        case .fx:    return Color(hex: "A1A1AA")
        }
    }
}

private extension CLIAgentChatPresentationMode {
    var shortLabel: String {
        switch self {
        case .nativeChat: return "Chat"
        case .macVisibleCLI: return "Mac CLI"
        case .macInteractiveCLI: return "Terminal"
        }
    }

    var systemImage: String {
        switch self {
        case .nativeChat: return "bubble.left.and.bubble.right"
        case .macVisibleCLI: return "terminal"
        case .macInteractiveCLI: return "terminal.fill"
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
        let defaults = ["codex", "claude", "openclaw", "droid", "forge", "hermes", "opencode"]
        let focused = focusedRuntime.rawValue
        return availableHarnesses.filter { defaults.contains($0.id) || $0.id == focused }
    }

    private static let availableHarnesses: [Harness] = [
        Harness(id: "codex", name: "Codex", symbol: "terminal"),
        Harness(id: "claude", name: "Claude Code", symbol: "curlybraces"),
        Harness(id: "openclaw", name: "OpenClaw", symbol: "bolt"),
        Harness(id: "droid", name: "Droid", symbol: "diamond.fill"),
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

#Preview {
    NavigationStack {
        CLIAgentConversationListView(runtime: .codex)
    }
}

private extension CLIAgentRuntime {
    /// Brand identity feeding the shared thinking spinner's `provider`
    /// color choice (and the style picker's live Provider swatch).
    var agentProvider: AgentProvider {
        switch self {
        case .codex:       return .codex
        case .claude:      return .claudeCode
        case .openClaw:    return .openClaw
        case .openClaude:    return .openClaude
        case .omp:         return .omp
        case .droid:       return .factory
        case .forge:       return .forgeDev
        case .antigravity: return .antigravity
        case .grok:        return .xAI
        case .cursorAgent: return .cursorAgent
        case .junie:       return .junie
        case .fx:          return .fx
        }
    }
}
