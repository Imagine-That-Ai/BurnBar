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
    var onMaximize: (() -> Void)?
    /// When set, opens a standalone pop-out chat window. When `nil`, the
    /// Pop-out button is hidden.
    var onPopOut: (() -> Void)?
    var onClose: () -> Void

    @State private var brief = InsightBriefSnapshot()
    @State private var panelResizeStart: CGFloat?
    @State private var bottomResizeStart: CGFloat?
    @State private var cornerResizeStart: CGSize?
    @State private var headerDragStart: CGSize?
    @State private var showHistoryPopover = false
    @State private var showClearChatPrompt = false
    @State private var showCLIAssistantConsent = false
    @State private var showElderWand = false
    /// Live Cloud tier so the Elder Wand entry gates against the member's real
    /// entitlement (`.gatedFeature(.elderWand, tier:)`).
    @StateObject private var cloudEntitlement = MacCloudEntitlementStore.shared
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
                    .accessibilityIdentifier(OBBAccessibilityID.chatPanelMinimized)
            } else {
                expandedPanel
                    .accessibilityIdentifier(OBBAccessibilityID.chatPanel)
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
            controller.syncChatBackendWithEnabledBackends()
            controller.loadPersistedMessages()
            controller.reclampPanelOffset(container: containerSize, padding: edgePadding)
            presentHermesSetupIfNeeded()
            Task { @MainActor in
                brief = await controller.buildInsightBriefSnapshotAsync(refreshRollups: false)
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
        .onChange(of: dataStore.usagesVersion) { _, _ in
            Task { @MainActor in
                controller.refreshRetrievalHealth(sharedFeaturesAvailable: sharedFeaturesAvailable)
                brief = await controller.buildInsightBriefSnapshotAsync(refreshRollups: false)
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
            Text("This starts a new chat. Previous BurnBar chats stay in History.")
        }
        .confirmationDialog("Open Hermes?", isPresented: $showHermesRuntimePrompt) {
            Button("Open Hermes + Gateway") {
                Task { await openHermesRuntime() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Hermes is enabled but the local gateway is not reachable. OpenBurnBar can start the Hermes Dashboard and gateway for you.")
        }
        .sheet(isPresented: $showCLIAssistantConsent) {
            CLIAssistantConsentSheet(settingsManager: settingsManager) {
                showCLIAssistantConsent = false
            }
        }
        .sheet(item: fusionReceiptToken) { token in
            // The Elder Wand end-of-session receipt. `ChatSessionController` sets
            // `completedFusionSessionToken` to a fresh token the instant a fusion
            // run finishes; the model reads the newest fusion run from the daemon
            // ledger. Dismiss clears the token so the same run never re-presents.
            FusionReceiptModal(model: FusionReceiptModalModel())
                .id(token.id)
        }
    }

    /// Binds the controller's `String?` fusion token to an `Identifiable`
    /// item so `.sheet(item:)` presents the receipt exactly once per run and
    /// clears the token on dismiss.
    private var fusionReceiptToken: Binding<FusionReceiptToken?> {
        Binding(
            get: { controller.completedFusionSessionToken.map(FusionReceiptToken.init(id:)) },
            set: { controller.completedFusionSessionToken = $0?.id }
        )
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
        _ = await hermesRuntimeLauncher.openHermesAndGateway(
            baseURL: resolvedHermesGatewayBaseURL,
            bearerToken: resolvedHermesBearerToken
        )
        await controller.probeHermesAvailability()
        if controller.hermesAvailable {
            controller.setChatBackend(.hermes)
        } else {
            controller.streamError = "Hermes launched but its gateway at \(resolvedHermesGatewayBaseURL.absoluteString) still isn't responding. Check the gateway URL and bearer token in Settings → Agents, then try again."
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

    // MARK: - Panel helpers

    private var panelIconTint: Color {
        switch controller.chatBackend {
        case .hermes:   return DesignSystem.Colors.hermesAureate
        case .piAgent:  return DesignSystem.Colors.whimsy
        default:        return DesignSystem.Colors.whimsy
        }
    }

    private var minimizedPill: some View {
        let backend = controller.chatBackend
        let modeColor: Color = backend == .hermes
            ? DesignSystem.Colors.hermesAureate
            : (backend == .piAgent ? DesignSystem.Colors.whimsy : DesignSystem.Colors.whimsy)

        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                controller.isMinimized = false
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                if let provider = backend.agentProvider {
                    ProviderLogoView(provider: provider, size: 16, useFallbackColor: false)
                } else {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
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
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                }
            }
            .liquidGlassInteractive(in: Capsule(style: .continuous), fallback: .ultraThinMaterial)
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
        .liquidGlassSurface(in: RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous), fallback: .ultraThinMaterial)
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
            InteractiveResizeOverlay(direction: .trailing) { translation in
                if panelResizeStart == nil { panelResizeStart = controller.panelWidth }
                let base = panelResizeStart ?? 400
                controller.panelWidth = min(720, max(260, base + translation.width))
            } onEnded: {
                panelResizeStart = nil
                controller.persistPanelGeometry()
            }
        }
        .overlay(alignment: .bottom) {
            InteractiveResizeOverlay(direction: .bottom) { translation in
                if bottomResizeStart == nil { bottomResizeStart = controller.panelHeight }
                let base = bottomResizeStart ?? 440
                controller.panelHeight = min(900, max(200, base + translation.height))
            } onEnded: {
                bottomResizeStart = nil
                controller.persistPanelGeometry()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            InteractiveResizeOverlay(direction: .bottomTrailing) { translation in
                if cornerResizeStart == nil {
                    cornerResizeStart = CGSize(width: controller.panelWidth, height: controller.panelHeight)
                }
                let base = cornerResizeStart ?? CGSize(width: 400, height: 440)
                controller.panelWidth = min(720, max(260, base.width + translation.width))
                controller.panelHeight = min(900, max(200, base.height + translation.height))
            } onEnded: {
                cornerResizeStart = nil
                controller.persistPanelGeometry()
            }
        }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    @State private var showChatMenu = false

    private var header: some View {
        // The header packs a long control cluster (drag handle, backend +
        // model strips, view-mode picker, model menu, Elder Wand, quota chip,
        // folder, new-chat, overflow menu, pop-out, maximize, minimize,
        // close). The panel is resizable down to 260pt and can be restored
        // from a persisted 260pt width, so the row must render cleanly at the
        // narrow end instead of overflowing. `ViewThatFits` picks the richest
        // tier that fits the current width and degrades gracefully: secondary
        // controls fold into the always-present overflow menu, while the
        // identity strip and window controls stay visible at every width.
        ViewThatFits(in: .horizontal) {
            headerFull
            headerMedium
            headerCompact
        }
        .animation(DesignSystem.Animation.gentle, value: controller.chatBackend)
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(Color.white.opacity(0.02))
        .onAppear { cloudEntitlement.start() }
        .sheet(isPresented: $showElderWand) {
            ElderWandConfiguratorView(controller: controller, settingsManager: settingsManager)
        }
    }

    // MARK: - Header tiers (progressive degradation)

    /// Widest tier: every control inline, matching the original layout.
    private var headerFull: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            dragHandle
            backendStrips
            ChatViewModePicker(controller: controller)
            ChatEngineModelMenu(controller: controller)
            elderWandControl
            quotaChipControl
            folderButton
            Spacer(minLength: 0)
            newChatButton
            overflowMenuButton
            popOutButton
            maximizeButton
            minimizeButton
            closeButton
        }
    }

    /// Mid tier: the view-mode picker, model menu and folder reveal fold into
    /// the overflow menu; the backend identity strip, Elder Wand, quota chip,
    /// new-chat, and window controls stay inline.
    private var headerMedium: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            dragHandle
            backendStrips
            elderWandControl
            quotaChipControl
            Spacer(minLength: 0)
            newChatButton
            overflowMenuButton
            minimizeButton
            closeButton
        }
    }

    /// Narrowest tier (guaranteed fit at the 260pt floor): drag handle,
    /// backend identity strip, the overflow menu (which carries every folded
    /// secondary action), and the close button.
    private var headerCompact: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            dragHandle
            backendStrips
            Spacer(minLength: 0)
            overflowMenuButton
            minimizeButton
            closeButton
        }
    }

    // MARK: - Header control builders

    private var dragHandle: some View {
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
    }

    // Mode toggle
    private var backendStrips: some View {
        VStack(spacing: 4) {
            ChatEngineBackendStrip(controller: controller, settingsManager: settingsManager)
            HermesModelStrip(controller: controller, settingsManager: settingsManager)
        }
    }

    // The Elder Wand — multi-model fusion configurator. Gated to Cloud
    // Pro; the gate modifier presents the unlock sheet when locked and
    // opens the configurator when entitled.
    private var elderWandControl: some View {
        Image(systemName: "wand.and.stars")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(panelIconTint)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .help("The Elder Wand — answer with a panel of models and a judge")
            .accessibilityLabel("The Elder Wand")
            .accessibilityAddTraits(.isButton)
            .gatedFeature(.elderWand, tier: cloudEntitlement.cloudTier) {
                showElderWand = true
            }
    }

    @ViewBuilder
    private var quotaChipControl: some View {
        if let quotaChip = ProviderQuotaChip(backend: controller.chatBackend) {
            quotaChip
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    private var folderButton: some View {
        Button {
            controller.revealChatWorkspaceInFinder()
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(panelIconTint)
        }
        .buttonStyle(.plain)
        .help("Show this chat’s workspace in Finder — each new chat uses its own folder under OpenBurnBar’s Application Support.")
    }

    // New Chat — always visible (inline in the full/medium tiers, and also
    // reachable from the overflow menu so the compact tier keeps it).
    private var newChatButton: some View {
        Button {
            controller.clearChat()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(panelIconTint)
        }
        .buttonStyle(.plain)
        .help("New chat")
    }

    // Consolidated menu — search, history, clear, plus any actions the current
    // tier folded away (Elder Wand, folder, new-chat, pop-out, maximize).
    private var overflowMenuButton: some View {
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
    }

    // Pop out to its own window
    @ViewBuilder
    private var popOutButton: some View {
        if let onPopOut {
            Button {
                Analytics.shared.track(.chatPanelAction, ["action": "popped_out"])
                onPopOut()
            } label: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(panelIconTint)
            }
            .buttonStyle(.plain)
            .help("Pop out chat into its own window")
        }
    }

    // Maximize into the dashboard chat workspace
    @ViewBuilder
    private var maximizeButton: some View {
        if let onMaximize {
            Button {
                Analytics.shared.track(.chatPanelAction, ["action": "maximized"])
                onMaximize()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right.square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(panelIconTint)
            }
            .buttonStyle(.plain)
            .help("Maximize chat into the dashboard workspace")
        }
    }

    // Minimize
    private var minimizeButton: some View {
        Button {
            Analytics.shared.track(.chatPanelAction, ["action": "minimized"])
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
    }

    // Close
    private var closeButton: some View {
        Button {
            Analytics.shared.track(.chatPanelAction, ["action": "closed"])
            onClose()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Consolidated Chat Menu

    private var chatMenuPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search section
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ChatViewModePicker(controller: controller)
                    ChatEngineModelMenu(controller: controller)
                }

                if let quotaChip = ProviderQuotaChip(backend: controller.chatBackend) {
                    quotaChip
                }

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

            // Actions. The secondary controls (new chat, reveal in Finder,
            // pop out, maximize) live here too so they stay reachable when a
            // narrow panel width folds them out of the header row.
            VStack(spacing: 2) {
                chatMenuAction(icon: "square.and.pencil", label: "New chat") {
                    showChatMenu = false
                    controller.clearChat()
                }
                elderWandMenuAction
                chatMenuAction(icon: "folder", label: "Show workspace in Finder") {
                    showChatMenu = false
                    controller.revealChatWorkspaceInFinder()
                }
                if let onPopOut {
                    chatMenuAction(icon: "rectangle.on.rectangle", label: "Pop out into its own window") {
                        showChatMenu = false
                        Analytics.shared.track(.chatPanelAction, ["action": "popped_out"])
                        onPopOut()
                    }
                }
                if let onMaximize {
                    chatMenuAction(icon: "arrow.up.left.and.arrow.down.right.square", label: "Maximize into dashboard") {
                        showChatMenu = false
                        Analytics.shared.track(.chatPanelAction, ["action": "maximized"])
                        onMaximize()
                    }
                }
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

    private var elderWandMenuAction: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
            Text("Configure Elder Wand")
                .font(DesignSystem.Typography.caption)
            Spacer()
        }
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs + 2)
        .contentShape(Rectangle())
        .gatedFeature(.elderWand, tier: cloudEntitlement.cloudTier) {
            showChatMenu = false
            showElderWand = true
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

                Text(HermesAtomParser.plainText(thread.preview))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)

                MacAttachmentSummaryStrip(attachments: thread.attachments)

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
        case .droid: return "Ask Droid\u{2026}"
        case .forge: return "Ask Forge\u{2026}"
        case .antigravity: return "Ask Antigravity\u{2026}"
        case .cursorAgent: return "Ask Cursor Agent\u{2026}"
        case .openClaude: return "Ask OpenClaude\u{2026}"
        case .omp: return "Ask OMP\u{2026}"
        case .junie: return "Ask Junie\u{2026}"
        }
    }

    private var inputStrokeGradient: LinearGradient {
        switch controller.chatBackend {
        case .hermes:
            return LinearGradient(
                colors: [DesignSystem.Colors.hermesMercury.opacity(0.4), DesignSystem.Colors.hermesAureate.opacity(0.3)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .piAgent:
            return LinearGradient(
                colors: [DesignSystem.Colors.whimsy.opacity(0.4), DesignSystem.Colors.whimsy.opacity(0.2)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [DesignSystem.Colors.whimsy.opacity(0.3), DesignSystem.Colors.border.opacity(0.3)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    private var inputRow: some View {
        ChatInputRow(
            controller: controller,
            chatBackend: controller.chatBackend,
            cliAssistantAllowed: settingsManager.cliAssistantAllowed,
            onRequestCLIAssistantConsent: {
                showCLIAssistantConsent = true
            },
            onSubmit: { Task { await controller.send() } }
        )
    }
}

// MARK: - Reusable Interactive Resize Overlay
struct InteractiveResizeOverlay: View {
    enum Direction {
        case trailing
        case bottom
        case bottomTrailing
    }

    var direction: Direction
    var onResize: (CGSize) -> Void
    var onEnded: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var cursorPushed = false

    var body: some View {
        Color.clear
            .frame(
                width: direction == .bottom ? nil : (direction == .trailing ? 16 : 24),
                height: direction == .trailing ? nil : (direction == .bottom ? 16 : 24)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                updateCursor()
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        isDragging = true
                        updateCursor()
                        onResize(value.translation)
                    }
                    .onEnded { _ in
                        isDragging = false
                        updateCursor()
                        onEnded()
                    }
            )
            .onDisappear {
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
    }

    private func updateCursor() {
        let shouldShowCursor = isHovering || isDragging
        if shouldShowCursor {
            if !cursorPushed {
                switch direction {
                case .trailing:
                    NSCursor.resizeLeftRight.push()
                case .bottom:
                    NSCursor.resizeUpDown.push()
                case .bottomTrailing:
                    NSCursor.pointingHand.push()
                }
                cursorPushed = true
            }
        } else {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
    }
}
