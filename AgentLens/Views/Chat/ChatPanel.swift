import SwiftUI
import OpenBurnBarCore

// MARK: - Chat Panel

struct ChatPanel: View {
    @Bindable var controller: ChatSessionController
    var dataStore: DataStore
    var settingsManager: SettingsManager
    var sharedFeaturesAvailable: Bool
    /// Overlay geometry for clamping drag offset (same space as `GeometryReader` wrapping the chat stack).
    var containerSize: CGSize
    var edgePadding: CGFloat = 20
    var onOpenConversationJump: (ConversationJumpTarget) -> Void = { _ in }
    /// When set, replaces the floating panel with the maximized dashboard
    /// workspace (matches Claude.ai / ChatGPT full-canvas layout). When `nil`,
    /// the Maximize button is hidden.
    var onMaximize: (() -> Void)? = nil
    /// When set, opens a standalone pop-out chat window. When `nil`, the
    /// Pop-out button is hidden.
    var onPopOut: (() -> Void)? = nil
    var onClose: () -> Void

    @State private var brief = InsightBriefSnapshot()
    @State private var panelResizeStart: CGFloat?
    @State private var bottomResizeStart: CGFloat?
    @State private var cornerResizeStart: CGSize?
    @State private var headerDragStart: CGSize?
    @State private var showHistoryPopover = false
    @State private var showClearChatPrompt = false
    @State private var didRequestHermesFirstRunSetup = false
    @State private var showHermesRuntimePrompt = false
    @State private var hermesRuntimeLauncher = HermesRuntimeLauncher()
    /// Atom router shared with every Hermes assistant bubble in the panel.
    /// Owned here so the popover anchors against the panel itself and any
    /// chip tap (current message or history scroll-back) opens through the
    /// same router instance.
    @State private var atomRouter = HermesAtomRouter()

    private let cornerResizeHandle: CGFloat = 18

    var body: some View {
        Group {
            if controller.isMinimized {
                minimizedPill
            } else {
                expandedPanel
            }
        }
        .environment(\.hermesAtomNavigator, atomRouter)
        .popover(item: Binding(
            get: { atomRouter.pending },
            set: { atomRouter.pending = $0 }
        )) { pending in
            HermesAtomDetailPopover(
                atom: pending.atom,
                label: pending.label,
                onOpen: {
                    atomRouter.confirm(pending)
                    atomRouter.pending = nil
                }
            )
        }
        .task {
            // Eagerly warm the Pretext engine so the first assistant turn
            // doesn't pay the WKWebView load latency mid-stream. Idempotent.
            PretextEngine.shared.start()
            // Install a destination handler once. Default: notify; the
            // sidebar/dashboard layer subscribes via
            // `Notification.Name.hermesAtomActivated` and dispatches.
            atomRouter.onPerform = { _ in
                // Notification is already broadcast by `confirm(_:)`. The
                // hook is reserved here for surfaces that want to handle
                // the destination synchronously without going through
                // `NotificationCenter`.
            }
        }
        .onAppear {
            brief = controller.buildInsightBriefSnapshot(refreshRollups: false)
            controller.syncChatBackendWithEnabledBackends()
            controller.loadPersistedMessages()
            controller.reclampPanelOffset(container: containerSize, padding: edgePadding)
            presentHermesSetupIfNeeded()
            Task {
                let enabled = settingsManager.enabledChatBackends
                if enabled.contains(.hermes) {
                    await controller.probeHermesAvailability()
                }
                if enabled.contains(.openclaw) {
                    await controller.probeOpenClawAvailability()
                }
            }
        }
        .onChange(of: controller.chatBackend) { _, _ in
            presentHermesSetupIfNeeded()
        }
        .onChange(of: dataStore.lastRefresh) { _, _ in
            Task { @MainActor in
                brief = controller.buildInsightBriefSnapshot(refreshRollups: false)
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
        .onChange(of: settingsManager.enabledChatBackendIDsCSV) { _, _ in
            controller.syncChatBackendWithEnabledBackends()
            Task {
                let enabled = settingsManager.enabledChatBackends
                if enabled.contains(.hermes) {
                    await controller.probeHermesAvailability()
                } else {
                    controller.hermesAvailable = false
                }
                if enabled.contains(.openclaw) {
                    await controller.probeOpenClawAvailability()
                } else {
                    controller.openClawAvailable = false
                }
            }
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
        .confirmationDialog("Open Hermes?", isPresented: $showHermesRuntimePrompt) {
            Button("Open Hermes + Gateway") {
                Task { await openHermesRuntime() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Hermes is enabled but the local gateway is not reachable. OpenBurnBar can start the Hermes Dashboard and gateway for you.")
        }
    }

    private func presentHermesSetupIfNeeded() {
        guard controller.chatBackend == .hermes else { return }
        if settingsManager.hermesSetupWizardCompleted {
            if controller.hermesAvailable == false {
                Task {
                    await controller.probeHermesAvailability()
                    if controller.hermesAvailable == false {
                        showHermesRuntimePrompt = true
                    }
                }
            }
            return
        }
        guard !didRequestHermesFirstRunSetup else { return }
        didRequestHermesFirstRunSetup = true
        WindowManager.shared.openHermesSetupWizard(
            settingsManager: settingsManager,
            chatController: controller,
            dataStore: dataStore
        )
    }

    private func openHermesRuntime() async {
        await hermesRuntimeLauncher.openHermesAndGateway(
            baseURL: resolvedHermesGatewayBaseURL,
            bearerToken: resolvedHermesBearerToken
        )
        await controller.probeHermesAvailability()
        if controller.hermesAvailable {
            controller.setChatBackend(.hermes)
        }
    }

    private var resolvedHermesGatewayBaseURL: URL {
        URL(string: settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8642")!
    }

    private var resolvedHermesBearerToken: String? {
        let token = settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    // MARK: - Minimized Pill

    @State private var pillDragStart: CGSize?

    private var minimizedPill: some View {
        let modeColor: Color = controller.chatBackend == .hermes
            ? DesignSystem.Colors.hermesAureate
            : DesignSystem.Colors.whimsy
        let modeIcon = controller.chatBackend == .hermes ? "\u{263F}" : "bubble.left.and.bubble.right.fill"

        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                controller.isMinimized = false
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                if controller.chatBackend == .hermes {
                    Text(modeIcon)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(modeColor)
                } else {
                    Image(systemName: modeIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(modeColor)
                }

                if controller.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(modeColor)
                } else if let last = controller.messages.last {
                    Text(last.role == .user ? last.content : ChatMessageRecord.joinedText(from: last.displayTranscript))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 160)
                }

                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                    Capsule(style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                }
            }
            .clipShape(Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [modeColor.opacity(0.5), DesignSystem.Colors.border.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: Color.black.opacity(0.15), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .highPriorityGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { g in
                    if pillDragStart == nil { pillDragStart = controller.panelFloatOffset }
                    let start = pillDragStart ?? .zero
                    controller.applyClampedPanelDrag(
                        start: start,
                        translation: g.translation,
                        container: containerSize,
                        padding: edgePadding
                    )
                }
                .onEnded { _ in
                    pillDragStart = nil
                    controller.persistPanelGeometry()
                }
        )
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    // MARK: - Expanded Panel

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
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
        .compositingGroup()
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
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    @State private var showChatMenu = false

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 20)
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

            // Mode toggle
            ChatEngineBackendStrip(controller: controller, settingsManager: settingsManager)

            ChatEngineModelMenu(controller: controller)

            Button {
                controller.revealChatWorkspaceInFinder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        controller.chatBackend == .hermes
                            ? DesignSystem.Colors.hermesAureate
                            : DesignSystem.Colors.whimsy
                    )
            }
            .buttonStyle(.plain)
            .help("Show this chat’s workspace in Finder — each new chat uses its own folder under OpenBurnBar’s Application Support.")

            Spacer(minLength: 0)

            // New Chat — always visible
            Button {
                controller.clearChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        controller.chatBackend == .hermes
                            ? DesignSystem.Colors.hermesAureate
                            : DesignSystem.Colors.whimsy
                    )
            }
            .buttonStyle(.plain)
            .help("New chat")

            // Consolidated menu — search, history, clear, close
            Button {
                showChatMenu.toggle()
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .help("Chat options")
            .popover(isPresented: $showChatMenu, arrowEdge: .top) {
                chatMenuPopover
            }

            // Pop out to its own window
            if let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            controller.chatBackend == .hermes
                                ? DesignSystem.Colors.hermesAureate
                                : DesignSystem.Colors.whimsy
                        )
                }
                .buttonStyle(.plain)
                .help("Pop out chat into its own window")
            }

            // Maximize into the dashboard chat workspace
            if let onMaximize {
                Button(action: onMaximize) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right.square")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            controller.chatBackend == .hermes
                                ? DesignSystem.Colors.hermesAureate
                                : DesignSystem.Colors.whimsy
                        )
                }
                .buttonStyle(.plain)
                .help("Maximize chat into the dashboard workspace")
            }

            // Minimize
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    controller.isMinimized = true
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Minimize to pill")

            // Close
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Consolidated Chat Menu

    private var chatMenuPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search section
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    TextField("Search indexed sessions...", text: $controller.searchQuery)
                        .textFieldStyle(.plain)
                        .font(DesignSystem.Typography.caption)
                        .onSubmit { controller.performSearch() }
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs + 2)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.35))
                )
            }
            .padding(DesignSystem.Spacing.md)

            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

            // History section
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack {
                    Text("Chat History")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                    Spacer()
                }

                if controller.historyThreads.isEmpty {
                    Text("No chats yet")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            ForEach(controller.historyThreads) { thread in
                                historyRow(thread)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)

            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

            // Actions
            VStack(spacing: 2) {
                chatMenuAction(icon: "trash", label: "Clear current chat", color: DesignSystem.Colors.error.opacity(0.8)) {
                    showChatMenu = false
                    showClearChatPrompt = true
                }
            }
            .padding(DesignSystem.Spacing.sm)
        }
        .frame(width: 300)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.95))
        .onAppear {
            controller.refreshHistory()
        }
    }

    private func chatMenuAction(icon: String, label: String, color: Color = DesignSystem.Colors.textSecondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(label)
                    .font(DesignSystem.Typography.caption)
                Spacer()
            }
            .foregroundStyle(color)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs + 2)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var content: some View {
        ChatMessagesStream(
            controller: controller,
            settingsManager: settingsManager,
            maxContentWidth: .infinity,
            horizontalPadding: DesignSystem.Spacing.md,
            verticalPadding: DesignSystem.Spacing.md,
            onJumpToConversation: onOpenConversationJump
        )
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

    // historyPopover consolidated into chatMenuPopover

    private func historyRow(_ thread: ChatThreadSummary) -> some View {
        let isActive = thread.id == controller.activeThreadID

        return Button {
            controller.openHistoryThread(thread.id)
            showChatMenu = false
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

    private var inputPlaceholder: String {
        switch controller.chatBackend {
        case .codex: return "Ask Codex\u{2026}"
        case .claude: return "Ask Claude Code\u{2026}"
        case .hermes: return "Ask Hermes\u{2026}"
        case .openclaw: return "Ask OpenClaw\u{2026}"
        case .piAgent: return "Ask Pi\u{2026}"
        }
    }

    private var inputStrokeGradient: LinearGradient {
        controller.chatBackend == .hermes
            ? LinearGradient(
                colors: [DesignSystem.Colors.hermesMercury.opacity(0.4), DesignSystem.Colors.hermesAureate.opacity(0.3)],
                startPoint: .topLeading, endPoint: .bottomTrailing
              )
            : LinearGradient(
                colors: [DesignSystem.Colors.whimsy.opacity(0.3), DesignSystem.Colors.border.opacity(0.3)],
                startPoint: .topLeading, endPoint: .bottomTrailing
              )
    }

    private var inputRow: some View {
        ChatInputRow(
            controller: controller,
            chatBackend: controller.chatBackend,
            onSubmit: { Task { await controller.send() } }
        )
    }
}
