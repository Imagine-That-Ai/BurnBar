import SwiftUI

// MARK: - Chat Panel

struct ChatPanel: View {
    @Bindable var controller: ChatSessionController
    var dataStore: DataStore
    var settingsManager: SettingsManager
    var sharedFeaturesAvailable: Bool
    /// Overlay geometry for clamping drag offset (same space as `GeometryReader` wrapping the chat stack).
    var containerSize: CGSize
    var edgePadding: CGFloat = 20
    var onClose: () -> Void

    @State private var brief = InsightBriefSnapshot()
    @State private var panelResizeStart: CGFloat?
    @State private var bottomResizeStart: CGFloat?
    @State private var cornerResizeStart: CGSize?
    @State private var headerDragStart: CGSize?
    @State private var showHistoryPopover = false
    @State private var showClearChatPrompt = false

    private let cornerResizeHandle: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            orchestratorStatusRibbon
            content
            if showInlineAgentContext {
                inlineAgentContextRibbon
            }
            Divider().opacity(0.35)
            inputRow
        }
        .frame(width: controller.panelWidth, height: controller.panelHeight)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.4))
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.whimsy.opacity(0.06),
                                Color.clear,
                                DesignSystem.Colors.ember.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            DesignSystem.Colors.whimsy.opacity(0.18),
                            DesignSystem.Colors.border.opacity(0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        )
        .shadow(color: Color.black.opacity(0.12), radius: 32, y: 14)
        .overlay(alignment: .trailing) {
            Color.clear
                .frame(width: 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if panelResizeStart == nil { panelResizeStart = controller.panelWidth }
                            let base = panelResizeStart ?? 400
                            controller.panelWidth = min(720, max(260, base + g.translation.width))
                        }
                        .onEnded { _ in
                            panelResizeStart = nil
                            controller.persistPanelGeometry()
                        }
                )
        }
        .overlay(alignment: .bottom) {
            Color.clear
                .frame(height: 10)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if bottomResizeStart == nil { bottomResizeStart = controller.panelHeight }
                            let base = bottomResizeStart ?? 440
                            controller.panelHeight = min(900, max(200, base + g.translation.height))
                        }
                        .onEnded { _ in
                            bottomResizeStart = nil
                            controller.persistPanelGeometry()
                        }
                )
        }
        .overlay(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: cornerResizeHandle, height: cornerResizeHandle)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if cornerResizeStart == nil {
                                cornerResizeStart = CGSize(width: controller.panelWidth, height: controller.panelHeight)
                            }
                            let base = cornerResizeStart ?? CGSize(width: 400, height: 440)
                            controller.panelWidth = min(720, max(260, base.width + g.translation.width))
                            controller.panelHeight = min(900, max(200, base.height + g.translation.height))
                        }
                        .onEnded { _ in
                            cornerResizeStart = nil
                            controller.persistPanelGeometry()
                        }
                )
        }
        .onAppear {
            brief = controller.buildInsightBriefSnapshot()
            controller.loadPersistedMessages()
            controller.refreshHistory()
            controller.refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
        }
        .onChange(of: dataStore.lastRefresh) { _, _ in
            Task { @MainActor in
                brief = controller.buildInsightBriefSnapshot()
                controller.refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
            }
        }
        .onChange(of: sharedFeaturesAvailable) { _, available in
            controller.refreshRetrievalHealth(sharedFeaturesAvailable: available)
        }
        .onChange(of: settingsManager.conversationIndexingEnabled) { _, _ in
            controller.refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
        }
        .onChange(of: settingsManager.preferredIndexEmbeddingVersionID) { _, _ in
            controller.reconfigureSearchService()
        }
        .onChange(of: containerSize) { _, new in
            controller.reclampPanelOffset(container: new, padding: edgePadding)
        }
        .confirmationDialog("Clear current chat?", isPresented: $showClearChatPrompt) {
            Button("Clear Current Chat", role: .destructive) {
                controller.clearChat()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This starts a new chat. Previous Burn Bar chats stay in History.")
        }
    }

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .medium))
                Text("Chat")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .frame(minWidth: 76, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .help("Drag to move")
            .highPriorityGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { g in
                        if headerDragStart == nil { headerDragStart = controller.panelFloatOffset }
                        let start = headerDragStart ?? .zero
                        controller.applyClampedPanelDrag(
                            start: start,
                            translation: g.translation,
                            container: containerSize,
                            padding: edgePadding
                        )
                    }
                    .onEnded { _ in
                        headerDragStart = nil
                        controller.persistPanelGeometry()
                    }
            )

            modePicker

            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            TextField("Search indexed sessions…", text: $controller.searchQuery)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.caption)
                .onSubmit { controller.performSearch() }
                .onChange(of: controller.searchQuery) { _, new in
                    if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Task { @MainActor in
                            controller.searchResults = []
                        }
                        return
                    }
                    let q = new
                    Task {
                        try? await Task.sleep(nanoseconds: 320_000_000)
                        guard controller.searchQuery == q else { return }
                        controller.performSearch()
                    }
                }

            if controller.isSearching {
                ProgressView().controlSize(.small)
            }

            Button {
                controller.refreshHistory()
                showHistoryPopover.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .help("Burn Bar chat history")
            .popover(isPresented: $showHistoryPopover, arrowEdge: .top) {
                historyPopover
            }

            Button {
                showClearChatPrompt = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .help("Clear current chat")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Mode picker (M4)

    /// The analyst/orchestrator mode switch lives in the EXISTING chat panel
    /// header — no parallel messenger surface (VAL-ORCH-006). The same input
    /// box, streaming placeholder, and history thread are used in both modes.
    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { controller.mode },
            set: { controller.setMode($0) }
        )) {
            ForEach(ChatMode.allCases, id: \.self) { mode in
                Label(mode.label, systemImage: mode.iconName)
                    .tag(mode)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .font(DesignSystem.Typography.tiny)
        .frame(width: 118)
        .help("Chat mode: Analyst (local index) or Orchestrator (fleet)")
    }

    /// Orchestrator-mode status ribbon: daemon designation + snapshot
    /// freshness. Typed degraded states are shown honestly — never a
    /// fabricated live channel (VAL-ORCH-025/035).
    @ViewBuilder
    private var orchestratorStatusRibbon: some View {
        if controller.mode == .orchestrator {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "network")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignSystem.Colors.whimsy)

                if let state = controller.orchestratorState {
                    switch state.designation {
                    case .none:
                        Text("No orchestrator designated")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.warning)
                    case .burnBarManaged:
                        Text("Orchestrator: BurnBar-managed")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    case .agent(let id, _):
                        Text("Orchestrator: \(id.wireValue)")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                } else if let error = controller.orchestratorStateError {
                    Text("Orchestrator unavailable: \(error)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.error)
                        .lineLimit(1)
                } else {
                    Text("Checking orchestrator…")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.whimsy.opacity(0.06))
            )
        }
    }

    private var content: some View {
        Group {
            if !controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !controller.searchResults.isEmpty {
                searchResultsList
            } else if !controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      controller.searchResults.isEmpty, !controller.isSearching {
                Text("No matches")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                            if !controller.retrievalHealthSnapshot.degradedModes.isEmpty {
                                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                    ForEach(controller.retrievalHealthSnapshot.degradedModes) { state in
                                        HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.system(size: 10))
                                                .foregroundStyle(DesignSystem.Colors.warning)
                                                .padding(.top, 2)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(state.title)
                                                    .font(DesignSystem.Typography.tiny)
                                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                                Text(state.message)
                                                    .font(DesignSystem.Typography.tiny)
                                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                        .padding(.horizontal, DesignSystem.Spacing.sm)
                                        .padding(.vertical, DesignSystem.Spacing.xs)
                                        .background(DesignSystem.Colors.warning.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                                    }
                                }
                            }

                            if !settingsManager.conversationIndexingEnabled {
                                Text("Conversation indexing is off. Enable it in Settings to unlock search and richer context.")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.warning)
                                    .padding(.horizontal, DesignSystem.Spacing.sm)
                            }

                            ForEach(controller.messages) { msg in
                                ChatMessageView(
                                    message: msg,
                                    isStreaming: controller.isStreaming && msg.id == controller.activeStreamMessageId && msg.role == .assistant,
                                    showViaBadge: msg.cliUsed != nil,
                                    onApproveProposal: { messageID in
                                        controller.approveProposal(messageID: messageID)
                                    },
                                    onDismissProposal: { messageID in
                                        controller.dismissProposal(messageID: messageID)
                                    },
                                    onRetryDelivery: { messageID in
                                        controller.retryDelivery(messageID: messageID)
                                    }
                                )
                                .id(msg.id)
                            }
                        }
                        .padding(DesignSystem.Spacing.md)
                    }
                    .onChange(of: controller.messages.count) { _, _ in
                        if let last = controller.messages.last {
                            Task { @MainActor in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(controller.searchResults) { r in
                    Button {
                        controller.selectSearchResult(r)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.conversation.inferredTaskTitle)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textPrimary)
                                .lineLimit(2)
                            Text(r.snippet.strippingSimpleTags)
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .lineLimit(2)
                            Text("\(r.conversation.provider.displayName) · \(r.conversation.projectName)")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignSystem.Spacing.sm)
                        .background {
                            ZStack {
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                    .fill(.thinMaterial)
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                    .fill(DesignSystem.Colors.surface.opacity(0.3))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.1), DesignSystem.Colors.border.opacity(0.3)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    /// Agent / session context: shown as plain inline text above the composer (not boxed at the top of the scroll).
    private var showInlineAgentContext: Bool {
        controller.messages.isEmpty
            && settingsManager.conversationIndexingEnabled
            && controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && brief.hasInlineContent
    }

    private var inlineAgentContextRibbon: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            if let statusLine = brief.rollupStatusLine {
                Text(statusLine)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let w = brief.whereLeftOff {
                Button {
                    controller.inputText = "Tell me more about my work on \(brief.whereLeftOffProject ?? "this project")"
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Where you left off")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(w)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
            }

            if let title = brief.heaviestTaskTitle, let cost = brief.heaviestTaskCost, let proj = brief.heaviestTaskProject {
                Button {
                    controller.inputText = "What did I spend on \(title) this week?"
                } label: {
                    Text("Heaviest this week: \(cost.formatAsCost()) on \(proj) — \(title)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if let m = brief.modelShiftHeadline {
                Button {
                    controller.inputText = "Tell me more about my new model usage"
                } label: {
                    Text(m)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if let inc = brief.incompleteHint {
                Button {
                    controller.inputText = "Help me continue where I left off"
                } label: {
                    Text(inc)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Burn Bar Chat History")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Spacer(minLength: 0)

                Button("New Chat") {
                    controller.clearChat()
                    showHistoryPopover = false
                }
                .font(DesignSystem.Typography.tiny)
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.primaryGradient)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                TextField("Search Burn Bar convos only…", text: $controller.historyQuery)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .onSubmit { controller.refreshHistory() }
                    .onChange(of: controller.historyQuery) { _, _ in
                        controller.refreshHistory()
                    }
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs + 2)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.35))
            )

            if controller.historyThreads.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No chats found")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Start a message in Burn Bar chat to build history.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, DesignSystem.Spacing.sm)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        ForEach(controller.historyThreads) { thread in
                            historyRow(thread)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 340, height: 420, alignment: .topLeading)
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.85))
    }

    private func historyRow(_ thread: ChatThreadSummary) -> some View {
        let isActive = thread.id == controller.activeThreadID

        return Button {
            controller.openHistoryThread(thread.id)
            showHistoryPopover = false
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(thread.title)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                    }
                }

                Text(thread.preview)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)

                Text("\(thread.messageCount) msgs · \(thread.lastActivityAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(isActive ? DesignSystem.Colors.whimsy.opacity(0.10) : DesignSystem.Colors.surface.opacity(0.30))
            )
        }
        .buttonStyle(.plain)
    }

    private var inputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.lastRetrievalHadNoEvidence, !controller.isStreaming {
                Text("No indexed excerpts matched your last question—try “Search indexed sessions”, enable indexing in Settings, or rephrase.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: DesignSystem.Spacing.sm) {
                TextField("Ask your local index…", text: $controller.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.body)
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .onSubmit {
                        Task { await controller.send() }
                    }
                    .padding(DesignSystem.Spacing.sm)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                .fill(.ultraThinMaterial)
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                                .fill(DesignSystem.Colors.surface.opacity(0.3))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [DesignSystem.Colors.whimsy.opacity(0.3), DesignSystem.Colors.border.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.75
                            )
                    )

                VStack(spacing: 6) {
                    if controller.isStreaming {
                        Button("Stop") {
                            controller.cancelGeneration()
                        }
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.error)
                    }

                    Button {
                        Task { await controller.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(DesignSystem.Colors.primaryGradient)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("chatSendButton")
                    .disabled(controller.isStreaming || controller.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
    }
}

private extension String {
    var strippingSimpleTags: String {
        replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
    }
}
