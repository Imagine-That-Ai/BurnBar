import SwiftUI
import AVFoundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Hermes Navigation
//
// Hermes is now a two-level flow:
//   1. `HermesConversationListView` — the tab landing. Lists every Hermes
//      session exposed by the connected host and provides a mercury FAB for
//      starting a new chat.
//   2. `HermesChatView` — the thread UI (welcome block, runtime rail, prompt
//      carousel, streaming bubbles, input bar). Pushed from the list via the
//      enclosing `NavigationStack`.
//
// `HermesChatRoute` is the value-typed destination both surfaces use, so push
// works on iPhone and iPad with system navigation chrome.

/// Identifiable wrapper over the fusion-receipt token so `.sheet(item:)` presents
/// a fresh receipt for each completed fusion run.
private struct FusionReceiptPresentation: Identifiable {
    let id: UUID
}

struct HermesChatView: View {
    @Bindable var service: HermesService
    let dashboardSnapshot: DashboardStore?
    let route: HermesChatRoute

    @Environment(\.mobileAuthStore) private var authStore
    @State private var input: String = ""
    @State private var showClearConfirm = false
    @State private var showConnectionSheet = false
    @State private var showRuntimeSheet = false
    @State private var showModelPicker = false
    @State private var showSetupWizard = false
    @State private var permissionGrantThreadID: String?
    @State private var didAutoPresentSetupWizard = false
    @State private var gatewayStore = HermesGatewaySettingsStore()
    @State private var pendingGatewayPlaceholderID: String?
    @State private var pendingGatewayEventID: String?
    @State private var showGatewayPrivacySheet = false
    @AppStorage(HermesMobileSetupWizardState.completionKey) private var hasCompletedHermesSetupWizard = false
    @AppStorage(HermesMobileChatPreferences.showMessageTPSKey) private var showMessageTPS = false
    @AppStorage("chatViewMode") private var chatViewMode: ChatViewMode = .agent
    @AppStorage(HermesMobileChatPreferences.usePretextRenderingKey) private var usePretextRendering = true
    @State private var showPretextPlayground = false
    @State private var showThinkingStylePicker = false
    @State private var showElderWandConfigurator = false
    @State private var showElderWandPaywall = false
    @State private var atomRouter = HermesAtomRouter()

    /// Presents the end-of-session fusion receipt: the service mints a fresh
    /// `fusionReceiptToken` when a fusion run completes; dismissing clears it so
    /// back-to-back runs each present their own receipt.
    private var fusionReceiptPresentation: Binding<FusionReceiptPresentation?> {
        Binding(
            get: { service.fusionReceiptToken.map(FusionReceiptPresentation.init(id:)) },
            set: { if $0 == nil { service.fusionReceiptToken = nil } }
        )
    }
    @State private var pendingAttachments: [HermesAttachment] = []
    @State private var attachmentImportError: String?
    @State private var textExpansionSnippets: [TextExpansionSnippet] = []
    @State private var isApplyingTextExpansion = false
    @State private var showFileImporter = false
    @State private var showCameraSheet = false
    @State private var photoPickerSelection: [PhotosPickerItem] = []
    @FocusState private var inputFocused: Bool
    @Namespace private var bubbleNamespace

    init(
        service: HermesService,
        dashboardSnapshot: DashboardStore? = nil,
        route: HermesChatRoute = .new
    ) {
        self.service = service
        self.dashboardSnapshot = dashboardSnapshot
        self.route = route
    }

    /// User-visible subset of `service.messages`. `.tool` role messages
    /// are context for the upstream model — they hold the JSON body the
    /// `MobileTool` returned so the next assistant turn can read it.
    /// We do *not* render them as chat bubbles; their presence is
    /// already conveyed by the tool pill on the assistant turn that
    /// produced the call.
    ///
    /// remediation(chat-message-windowing): cached, not computed. The old
    /// computed property re-ran `service.messages.filter { … }` and allocated
    /// a fresh array on *every* `body` evaluation — including the many evals
    /// triggered by unrelated state (typing in the composer, focus changes,
    /// sheet toggles). We now memoize the filtered slice in `@State` and
    /// recompute it only when `service.messages` actually changes, driven by
    /// `.onChange(of: service.messages)` on the body (see `body`'s modifier
    /// chain) plus the `initial: true` seed. `[HermesChatMessage]` is
    /// `Equatable`, so `onChange` fires for any mutation site (append/remove
    /// and the per-index streaming/finalize edits in
    /// `HermesConversationStateStore`), keeping the rendered bubbles live.
    @State private var visibleMessages: [HermesChatMessage] = []

    /// Recompute the cached `visibleMessages` from the live transcript. Same
    /// predicate as before — drop `.tool` turns, preserve order. Cheap to call
    /// from `onChange`; it runs once per real transcript mutation rather than
    /// once per render.
    private func recomputeVisibleMessages() {
        visibleMessages = service.messages.filter { $0.role != .tool }
    }

    @ViewBuilder
    private var chatContent: some View {
        if chatViewMode == .cli {
            InlineAgentMirrorView(
                singleton: AgentWatchOverlaySingleton.shared,
                hermesService: service
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if visibleMessages.isEmpty {
                            welcomeBlock
                        } else {
                            ForEach(visibleMessages) { message in
                                HermesMessageBubble(
                                    message: message,
                                    hermesService: service,
                                    showTPS: showMessageTPS,
                                    usePretextRendering: usePretextRendering,
                                    viewMode: chatViewMode,
                                    // The context rides as an equatable input
                                    // (`retryContext`) instead of being captured,
                                    // so the bubble's `==` can see it change.
                                    onRetry: canRetry(message)
                                        ? { context in service.retryLastUserTurn(context: context) }
                                        : nil,
                                    retryContext: canRetry(message) ? dashboardContextPrompt : nil
                                )
                                    // Skip re-rendering unchanged rows on
                                    // every streaming commit — the bubble's
                                    // semantic Equatable ignores the retry
                                    // closure identity (see its extension).
                                    .equatable()
                                    .id(message.id)
                            }
                            if service.isStreaming {
                                HStack {
                                    HermesThinkingSpinner(
                                        // Hermes IS the agent here; the routed
                                        // model supplies the second mark.
                                        provider: .hermes,
                                        modelName: service.selectedModelID ?? service.selectedConnection.advertisedModel
                                    )
                                    .padding(.leading, 8)
                                    Spacer()
                                }
                                .id("thinking")
                            }
                        }
                    }
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.bottom, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
                .onChange(of: service.messages.count) { _, _ in
                    if let last = service.messages.last {
                        withAnimation(AuroraDesign.Motion.auroraSpring) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                // `utf8.count` is O(1) (native strings store it); `.count`
                // walked every grapheme of the accumulated reply on every
                // body evaluation — O(n) per streamed commit, O(n²) per
                // stream. Both grow monotonically on append, so the scroll
                // trigger fires identically.
                .onChange(of: service.messages.last?.text.utf8.count ?? 0) { _, _ in
                    if let last = service.messages.last, last.isStreaming {
                        // Plain scroll: a spring per streamed chunk stacks
                        // interrupted animations and burns the frame budget.
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: service.isStreaming) { _, streaming in
                    if streaming {
                        withAnimation(AuroraDesign.Motion.auroraSpring) {
                            proxy.scrollTo("thinking", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var chatBackgroundVisibility: MobileBackgroundVisibility {
        if showConnectionSheet
            || showRuntimeSheet
            || showModelPicker
            || permissionGrantThreadID != nil
            || showSetupWizard
            || showGatewayPrivacySheet
            || showPretextPlayground
            || showFileImporter
            || showCameraSheet
            || atomRouter.pending != nil {
            return .obscured
        }
        // `.subtle`, not `.prominent`: the chat reads like ChatGPT — calm
        // canvas, content first. It also resolves to the `subtleLive` swarm
        // plan (15 fps cap, ~45% particles), so the murmuration's shape
        // formation stops competing with message rendering for the main
        // thread's frame budget.
        return .subtle
    }

    // remediation(hermes-typecheck): extracted from the main `body` VStack so the
    // Swift type-checker stays under its per-expression time budget. The inline
    // ChatAttachmentTray closure + chained modifiers + transition pushed `body`
    // into "unable to type-check this expression in reasonable time". Pure
    // behavior-preserving extraction — identical view, identical modifiers.
    @ViewBuilder
    private var attachmentTraySection: some View {
        if !pendingAttachments.isEmpty {
            ChatAttachmentTray(
                attachments: pendingAttachments,
                onRemove: { id in
                    withAnimation(AuroraDesign.Motion.auroraSpring) {
                        pendingAttachments.removeAll { $0.id == id }
                    }
                }
            )
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(visibility: chatBackgroundVisibility)
            VStack(spacing: 0) {
                relaySuggestionBanner
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.bottom, service.hasPendingRelaySuggestion ? 8 : 0)

                if showsRuntimeRail {
                    runtimeRail
                        .padding(.bottom, 8)
                }

                chatContent

                // Suggestions are an empty-state affordance only — once the
                // conversation starts, the composer stands alone (ChatGPT-style).
                if service.messages.isEmpty {
                    promptCarousel
                        .padding(.bottom, 4)
                }

                attachmentTraySection

                inputBar
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.bottom, HermesChatLayout.composerBottomPadding)
            }
        }
        // Tells the swarm background to throttle its frame rate while a reply
        // streams — see WebsiteBackgroundView. Only the swarm/editorial skins
        // react; the default Aurora mesh is already paused at `.subtle`
        // visibility on this screen.
        .environment(\.hermesStreamingActive, service.isStreaming)
        .onChange(of: inputFocused) { _, focused in
            NotificationCenter.default.post(
                name: .hermesKeyboardFocusChanged,
                object: nil,
                userInfo: ["focused": focused]
            )
        }
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { chatToolbar }
        .alert("Clear chat?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                withAnimation(AuroraDesign.Motion.auroraSpring) { service.clearChat() }
            }
        } message: {
            Text("This starts a new chat. Previous Hermes chats stay in History.")
        }
        .sheet(isPresented: $showConnectionSheet) {
            HermesConnectionSheet(service: service, gatewayStore: gatewayStore)
        }
        .sheet(isPresented: $showRuntimeSheet) {
            HermesRuntimeSheet(service: service)
        }
        .sheet(isPresented: $showModelPicker) {
            if shouldUseGatewayModelPicker {
                HermesGatewayModelPickerSheet(
                    service: service,
                    gatewayStore: gatewayStore,
                    senderDisplayName: gatewaySenderDisplayName,
                    threadId: service.selectedSessionID ?? HermesGatewayMessageResolver.defaultThreadID
                )
            } else {
                AssistantModelPickerSheet(
                    runtime: .hermes,
                    hermesService: service,
                    piService: PiService.shared
                )
            }
        }
        .sheet(isPresented: permissionGrantSheetPresented) {
            if let threadID = permissionGrantThreadID {
                AgentPermissionGrantSheet(runtimeID: .hermes, threadID: threadID)
            }
        }
        .sheet(isPresented: $showSetupWizard) {
            HermesMobileSetupWizardView(
                isPresented: $showSetupWizard,
                hasCompletedSetup: $hasCompletedHermesSetupWizard,
                onOpenConnections: {
                    showSetupWizard = false
                    showConnectionSheet = true
                }
            )
        }
        .sheet(isPresented: $showGatewayPrivacySheet) {
            gatewayPrivacySheet
        }
        .sheet(isPresented: $showPretextPlayground) {
            PretextPlayground()
        }
        .sheet(isPresented: $showThinkingStylePicker) {
            HermesThinkingStylePickerSheet(
                provider: .hermes,
                modelName: service.selectedModelID ?? service.selectedConnection.advertisedModel
            )
        }
        .elderWandConfiguratorSheet(isPresented: $showElderWandConfigurator, service: service)
        .elderWandPaywallSheet(isPresented: $showElderWandPaywall)
        .sheet(item: fusionReceiptPresentation) { _ in
            // The end-of-session receipt. `capturedFusionSpend` is the itemized
            // session from the daemon's final SSE frame (it has landed by the time
            // the stream completes on the dominant streaming path); `nil` falls
            // back to the authoritative quota-only receipt.
            FusionReceiptSheet(session: service.capturedFusionSpend)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: chatFileImporterTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileImporterResult(result)
        }
        .fullScreenCover(isPresented: $showCameraSheet) {
            CameraCaptureSheet { image in
                showCameraSheet = false
                guard let image else { return }
                ingestImage(image)
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoPickerSelection) { _, newSelection in
            guard !newSelection.isEmpty else { return }
            handlePhotosPickerSelection(newSelection)
        }
        .alert("Couldn't attach file", isPresented: attachmentImportErrorPresented) {
            Button("OK", role: .cancel) { attachmentImportError = nil }
        } message: {
            Text(attachmentImportError ?? "")
        }
        .sheet(item: pendingAtomSheetItem) { pending in
            HermesAtomDetailSheet(
                atom: pending.atom,
                label: pending.label,
                onOpen: { atomRouter.confirm(pending) }
            )
        }
        .environment(\.hermesAtomNavigator, atomRouter)
        .task(id: route) { await applyRoute() }
        .task(id: AssistantPendingPrompt.shared.hermes) {
            await consumePendingHermesPromptIfNeeded()
        }
        .task(id: authStore?.currentIdentity?.uid) {
            await refreshGatewayForCurrentAuthState()
        }
        .task {
            // Register this surface's instance as the conversation-state
            // owner for cross-cutting services (notification replies, the
            // Computer Use permission inbox). They previously wrote to
            // `HermesService.shared`, which no chat UI binds.
            HermesService.mainSurface = service
            // Idempotent: refreshRuntime coalesces concurrent callers and loads
            // both remote relay discovery and selected-host reachability.
            await service.refreshRuntime()
            reconcileSetupWizardCompletion()
            // Warm the offscreen Pretext WKWebView so the first assistant
            // turn doesn't stall on initial load. Idempotent.
            PretextEngine.shared.start()
            // Reserved hook for surfaces that want a synchronous handler;
            // notifications still fire from `confirm(_:)` for ambient
            // listeners (e.g. RootTabView).
            atomRouter.onPerform = { _ in }
            // Plug the navigator into the chat service so the
            // `burnbar_atom_open` tool can drive in-app navigation when
            // the model decides to call it. Held weakly inside the
            // service — disconnected automatically when this view goes
            // away.
            service.setToolAtomNavigator(atomRouter)
            reloadTextExpansionSnippets()
        }
        .onDisappear {
            // Be explicit so the service drops its reference promptly
            // even if `atomRouter` doesn't deallocate immediately (the
            // chat list view stays in the navigation stack).
            service.setToolAtomNavigator(nil)
            gatewayStore.stopGatewayListening()
        }
        .onAppear {
            presentSetupWizardIfNeeded()
            reloadTextExpansionSnippets()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            reloadTextExpansionSnippets()
        }
        .onChange(of: authStore?.state.isSignedIn) { _, _ in
            Task { @MainActor in
                await refreshGatewayForCurrentAuthState()
            }
        }
        .onChange(of: service.isReachable) { _, _ in
            reconcileSetupWizardCompletion()
        }
        .onChange(of: service.selectedConnection.id) { _, _ in
            reconcileSetupWizardCompletion()
        }
        .onChange(of: service.suggestedRelayConnection?.id) { _, _ in
            reconcileSetupWizardCompletion()
        }
        .onChange(of: gatewayStore.onlineClients.count) { _, _ in
            reconcileSetupWizardCompletion()
        }
        .onChange(of: gatewayStore.latestReply?.id) { _, _ in
            applyPendingGatewayReplyIfNeeded()
        }
        // remediation(chat-message-windowing): refresh the cached visible
        // slice exactly when the transcript changes (`initial: true` seeds it
        // on first appearance). This replaces the old per-render `.filter`
        // allocation. Lives on `body` — not on `chatContent` — so the cache
        // stays correct in both `.agent` and `.cli` view modes.
        .onChange(of: service.messages, initial: true) { _, _ in
            recomputeVisibleMessages()
        }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        // ChatGPT-style centered title: "Hermes · <model> ⌄" opens the model
        // picker. Replaces the session-ID title and the rail's two-line
        // "Switch model" chip.
        ToolbarItem(placement: .principal) {
            Button {
                presentModelPicker()
            } label: {
                modelSelectorChip
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch model")
            .accessibilityHint("Opens the model picker.")
        }

        ToolbarItem(placement: .topBarTrailing) {
            chatOptionsMenu
        }

        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done", action: dismissKeyboard)
        }
    }

    private var chatOptionsMenu: some View {
        Menu {
            Section {
                Button {
                    showConnectionSheet = true
                } label: {
                    Label(
                        connectionStatusText,
                        systemImage: effectiveHermesReachable ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                    )
                }
            }

            Section {
                Picker("View", selection: $chatViewMode) {
                    ForEach(ChatViewMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }

            Section {
                Button {
                    permissionGrantThreadID = service.ensureDesktopGrantThreadID()
                } label: {
                    Label("Agent permissions", systemImage: "hand.raised")
                }
                Button {
                    showConnectionSheet = true
                } label: {
                    Label("Connections", systemImage: "network")
                }
                Button {
                    showRuntimeSheet = true
                } label: {
                    Label("Runtime", systemImage: "slider.horizontal.3")
                    Text("\(service.profiles.count) profiles · \(service.jobs.count) jobs")
                }
                Button {
                    showSetupWizard = true
                } label: {
                    Label("Setup Guide", systemImage: "list.number")
                }
            }

            Section {
                Toggle(isOn: $showMessageTPS) {
                    Label("Show tokens/sec", systemImage: "speedometer")
                }
                Toggle(isOn: $usePretextRendering) {
                    Label("Rich text (bold · mentions · code)", systemImage: "text.alignleft")
                }
                Button {
                    showThinkingStylePicker = true
                } label: {
                    Label("Thinking Style", systemImage: "circle.dotted")
                }
                Button {
                    showPretextPlayground = true
                } label: {
                    Label("Text Layout Playground", systemImage: "textformat.size")
                }
            }

            Section {
                ElderWandChatMenuButton(
                    showConfigurator: $showElderWandConfigurator,
                    showPaywall: $showElderWandPaywall
                )
            }

            Section {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("Clear chat", systemImage: "trash")
                }
                .disabled(service.messages.isEmpty)
                Button {
                    Task { await service.refreshRuntime() }
                } label: {
                    Label("Re-check connection", systemImage: "arrow.clockwise")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
                // Quiet by default; a small dot only when something is wrong.
                .overlay(alignment: .topTrailing) {
                    if !effectiveHermesReachable {
                        Circle()
                            .fill(MobileTheme.error)
                            .frame(width: 7, height: 7)
                            .offset(x: -2, y: 4)
                    }
                }
        }
        .accessibilityLabel(effectiveHermesReachable ? "Chat options" : "Chat options. Hermes unreachable.")
    }

    private var permissionGrantSheetPresented: Binding<Bool> {
        Binding(
            get: { permissionGrantThreadID != nil },
            set: { isPresented in
                if !isPresented {
                    permissionGrantThreadID = nil
                }
            }
        )
    }

    private var attachmentImportErrorPresented: Binding<Bool> {
        Binding(
            get: { attachmentImportError != nil },
            set: { isPresented in
                if !isPresented {
                    attachmentImportError = nil
                }
            }
        )
    }

    private var pendingAtomSheetItem: Binding<HermesAtomRouter.PendingAtom?> {
        Binding(
            get: { atomRouter.pending },
            set: { atomRouter.pending = $0 }
        )
    }

    private func presentSetupWizardIfNeeded() {
        if hasUsableHermesSetup {
            reconcileSetupWizardCompletion()
            return
        }
        guard HermesMobileSetupWizardGate.shouldAutoPresent(
            isScreenshotMode: AppStoreScreenshotMode.isEnabled,
            hasCompletedSetup: hasCompletedHermesSetupWizard,
            didAutoPresent: didAutoPresentSetupWizard,
            hasUsableSetup: hasUsableHermesSetup
        ) else { return }
        didAutoPresentSetupWizard = true
        showSetupWizard = true
    }

    private var hasUsableHermesSetup: Bool {
        HermesMobileSetupWizardGate.hasUsableSetup(
            isReachable: effectiveHermesReachable,
            selectedConnection: service.selectedConnection,
            suggestedRelayConnection: service.suggestedRelayConnection
        )
    }

    private func reconcileSetupWizardCompletion() {
        guard hasUsableHermesSetup else { return }
        hasCompletedHermesSetupWizard = true
        showSetupWizard = false
    }

    private func presentModelPicker() {
        showModelPicker = true
        // Warm the gateway roster in the background so the sheet opens onto
        // fresh model options instead of waiting for the next listener tick.
        Task { await refreshGatewayForCurrentAuthState() }
    }

    @MainActor
    private func refreshGatewayForCurrentAuthState() async {
        let uid = authStore?.currentIdentity?.uid
        let signedInState = authStore?.state.isSignedIn
        gatewayStore.startGatewayListening(uid: uid)
        await gatewayStore.refresh(isSignedIn: signedInState == true)
    }

    // MARK: - Route Binding

    private func applyRoute() async {
        switch route {
        case .new:
            if !service.messages.isEmpty || service.selectedSessionID != nil {
                service.startNewSession()
            }
        case .existing(let sessionID):
            guard service.selectedSessionID != sessionID else { return }
            if let summary = service.sessions.first(where: { $0.id == sessionID }) {
                await service.resumeSession(summary)
            } else if MobileChatHistoryStore.shared.thread(id: sessionID)?.runtime == AssistantRuntimeID.hermes.rawValue {
                // Mobile-only thread (host never assigned a session id, or the
                // host is currently unreachable). Restore from the device cache.
                service.loadMobileThread(id: sessionID)
            } else {
                // Sessions list may not be loaded yet; refresh and try again once.
                await service.refreshRuntime()
                if let summary = service.sessions.first(where: { $0.id == sessionID }) {
                    await service.resumeSession(summary)
                } else if MobileChatHistoryStore.shared.thread(id: sessionID)?.runtime == AssistantRuntimeID.hermes.rawValue {
                    service.loadMobileThread(id: sessionID)
                }
            }
        }
    }

    @MainActor
    private func consumePendingHermesPromptIfNeeded() async {
        guard case .new = route,
              let pending = AssistantPendingPrompt.shared.consume(.hermes),
              !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        let commandBias = wikiCommandContext(for: pending)
        let context = mergedContextPrompt(
            dashboardContext: dashboardContextPrompt,
            commandBias: commandBias
        )
        if shouldSendViaBurnBarGateway {
            sendViaBurnBarGateway(pending, context: context)
        } else {
            service.sendMessage(pending, context: context)
        }
    }

    private var navigationTitleText: String {
        switch route {
        case .new:
            return service.selectedSessionID.map(service.sessionTitle(for:)) ?? "New Conversation"
        case .existing(let id):
            return service.sessionTitle(for: id)
        }
    }

    private var activeProvider: AgentProvider {
        let option = service.selectedModelOption
            ?? gatewayStore.runtimeModelOptions.first(where: { $0.modelID == service.selectedModelID })
        return option?.agentProvider ?? hermesAgentProvider(for: service.selectedModelID ?? gatewayStore.runtimeModelId ?? service.selectedConnection.advertisedModel ?? "hermes")
    }

    private var connectionStatusText: String {
        if !gatewayStore.onlineClients.isEmpty {
            let count = gatewayStore.onlineClients.count
            let suffix = count == 1 ? "1 gateway live" : "\(count) gateways live"
            if service.isReachable {
                return "Hermes online · BurnBar Cloud · \(suffix)"
            }
            return "BurnBar Cloud online · \(suffix)"
        }
        if !gatewayStore.activeClients.isEmpty, !service.isReachable {
            return "BurnBar Cloud paired · gateway waiting"
        }
        if !service.isReachable,
           service.selectedConnection.id == HermesConnectionRecord.localDefault.id,
           let relay = service.suggestedRelayConnection {
            return "Local offline · relay available · \(relay.displayName)"
        }
        let name = service.selectedConnection.displayName
        return service.isReachable ? "Hermes online · \(name)" : "Hermes offline · \(name)"
    }

    private var effectiveHermesReachable: Bool {
        service.isReachable || !gatewayStore.onlineClients.isEmpty
    }

    private var shouldUseGatewayModelPicker: Bool {
        shouldSendViaBurnBarGateway
            || (!gatewayStore.activeClients.isEmpty
                && service.suggestedRelayConnection == nil
                && service.modelOptions.isEmpty)
    }

    private var shouldSendViaBurnBarGateway: Bool {
        HermesChatTransportPolicy.shouldSendViaBurnBarGateway(
            isHostReachable: service.isReachable,
            hasSuggestedRelay: service.suggestedRelayConnection != nil,
            hasActiveGatewayClient: !gatewayStore.activeClients.isEmpty,
            isCLIMode: chatViewMode == .cli
        )
    }

    private var gatewaySenderDisplayName: String {
        authStore?.currentIdentity?.displayName?.nilIfBlank ?? "OpenBurnBar iPhone"
    }

    // MARK: - Gateway Privacy (E2E lock)

    /// The gateway client this chat seals to / opens replies from, when the
    /// BurnBar Cloud path is the active route. `nil` when this turn goes over a
    /// direct/relay host (which carries its own transport security and doesn't
    /// surface the gateway lock).
    private var gatewayPrivacyClient: HermesGatewayClientRecord? {
        // Only when the BurnBar Cloud path is the active route for this chat. CLI
        // mode and the direct/relay host path carry their own transport security
        // and don't surface the gateway lock, keeping the rail uncluttered.
        guard chatViewMode != .cli,
              shouldSendViaBurnBarGateway || !gatewayStore.onlineClients.isEmpty else {
            return nil
        }
        return gatewayStore.selectedClient
    }

    /// The live E2E privacy state for the active gateway client, derived from the
    /// store's real key/pin comparison. `nil` hides the lock entirely (no gateway
    /// client in play), keeping the rail uncluttered on the direct-host path.
    private var gatewayPrivacyState: HermesGatewayPrivacyState? {
        guard let client = gatewayPrivacyClient else { return nil }
        // A reply sealed for a device this one can no longer open (reinstall / new
        // phone) is the same recoverable situation as a changed connection, so the
        // chip and sheet both surface "Reconnect" — keeping the affordance honest
        // and consistent even before the send-path key-change guard trips.
        if hasUndecryptableGatewayReply {
            return .reconnectNeeded
        }
        return HermesGatewayPrivacyState.resolve(
            client: client,
            keyChanged: gatewayStore.agentRelayKeyChanged(for: client)
        )
    }

    /// True when a reply in this thread was sealed for a device that no longer
    /// holds the key (reinstall / new phone), so the conversation can offer the
    /// same reconnect recovery the lock sheet does even when the key-change guard
    /// hasn't tripped on the send path yet.
    private var hasUndecryptableGatewayReply: Bool {
        gatewayStore.latestReply?.isUndecryptableHere == true
    }

    @ViewBuilder
    private var gatewayPrivacySheet: some View {
        if let client = gatewayPrivacyClient, let state = gatewayPrivacyState {
            // Offer the explicit, consented reconnect whenever the connection
            // can't be trusted as-is (changed connection — the seal guard is
            // fail-closed) or a reply arrived sealed for a device this one can no
            // longer open. A verified, openable connection shows no reconnect
            // button — just the explainer and the safety code.
            let needsReconnect = (state == .reconnectNeeded)
            HermesGatewayPrivacySheet(
                state: state,
                clientDisplayName: client.displayName,
                safetyCode: gatewayStore.agentSafetyCode(for: client),
                onReconnect: needsReconnect
                    ? {
                        HapticBus.primaryAction()
                        gatewayStore.repinAgentKeyAfterUserConfirmation(for: client)
                    }
                    : nil
            )
        }
    }

    @ViewBuilder
    private var relaySuggestionBanner: some View {
        if let relay = service.suggestedRelayConnection,
           service.hasPendingRelaySuggestion {
            Button {
                HapticBus.primaryAction()
                if !service.connectToSuggestedRelay() {
                    showConnectionSheet = true
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "macbook.and.iphone")
                        .font(MobileTheme.Typography.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use \(relay.displayName)")
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text("Route this chat through your signed-in Mac")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right.circle.fill")
                        .font(MobileTheme.Typography.caption)
                }
                .foregroundStyle(MobileTheme.hermesAureate)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .auroraGlass(.compact, cornerRadius: 14)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Selects the available Mac Hermes Remote Relay for this chat.")
        }
    }

    /// The quiet session strip under the nav bar. Renders only when there is
    /// something worth saying beyond a fresh local chat — the gateway privacy
    /// state, this conversation's token burn, or a resumed session. Model
    /// switching lives in the navigation title now (ChatGPT-style) and the
    /// profile/job counts moved into the options menu's Runtime row.
    private var showsRuntimeRail: Bool {
        gatewayPrivacyState != nil
            || service.currentConversationTokenBurn > 0
            || service.selectedSessionID != nil
    }

    private var runtimeRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let gatewayPrivacyState {
                    HermesGatewayLockChip(state: gatewayPrivacyState) {
                        HapticBus.sheetOpen()
                        showGatewayPrivacySheet = true
                    }
                }
                if service.currentConversationTokenBurn > 0 {
                    runtimeChip(icon: "flame.fill", label: "\(service.currentConversationTokenBurn.formatted()) tokens")
                }
                if let selectedSessionID = service.selectedSessionID {
                    runtimeChip(icon: "bubble.left.and.bubble.right", label: "Resuming \(service.sessionTitle(for: selectedSessionID))")
                }
            }
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
        }
    }

    private func runtimeChip(icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(MobileScaledFont.system(size: 11, weight: .semibold))
            Text(label)
                .lineLimit(1)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.medium)
        }
        .foregroundStyle(MobileTheme.Colors.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(MobileTheme.Colors.surface.opacity(0.6)))
    }

    /// ChatGPT-style centered title content: "Hermes <model> ⌄". Rendered
    /// inside the principal toolbar button — no capsule chrome.
    private var modelSelectorChip: some View {
        let option = service.selectedModelOption
            ?? gatewayStore.runtimeModelOptions.first(where: { $0.modelID == service.selectedModelID })
        let fallbackModel = service.selectedModelID ?? gatewayStore.runtimeModelId ?? service.selectedConnection.advertisedModel
        let label = FriendlyModelName.format(option?.displayName ?? fallbackModel ?? "Choose model")
        return HStack(spacing: 5) {
            Text("Hermes")
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(label)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(MobileScaledFont.system(size: 11, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .frame(maxWidth: 230)
    }

    // MARK: - Welcome

    private var welcomeBlock: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            HermesLiveGlyph(size: 52, isLive: service.isStreaming)
                .padding(.bottom, MobileTheme.Spacing.xs)
            Text("How can Hermes help?")
                .font(MobileTheme.Typography.title)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text("Ask about today's burn, project breakdowns, quota pressure, or session details. Answers use your live OpenBurnBar data.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MobileTheme.Spacing.lg)
            contextChips
                .padding(.top, MobileTheme.Spacing.sm)
            Text("Tip: /wiki <project> queries Project Memory snapshots.")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .padding(.top, MobileTheme.Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
        .padding(.bottom, MobileTheme.Spacing.lg)
    }

    @ViewBuilder
    private var contextChips: some View {
        if let snapshot = dashboardSnapshot, let totals = snapshot.windowTotals[.today] {
            HStack(spacing: 8) {
                contextChip(icon: "flame.fill", label: "Today", value: totals.costUsd.formatAsCost())
                contextChip(icon: "rectangle.stack", label: "Sessions", value: "\(totals.requests)")
                contextChip(icon: "number", label: "Tokens", value: totals.tokens.formatAsTokenVolume())
            }
        }
    }

    private func contextChip(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(MobileScaledFont.system(size: 11, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text(label)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Text(value)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(MobileTheme.Colors.surface.opacity(0.7)))
        .overlay(Capsule().stroke(MobileTheme.Colors.border.opacity(0.3), lineWidth: 0.5))
    }

    // MARK: - Prompt Carousel

    private var promptCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(prompts, id: \.self) { prompt in
                    Button {
                        input = prompt
                        send()
                    } label: {
                        Text(prompt)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(MobileTheme.Colors.surface.opacity(0.8))
                            )
                            .overlay(
                                Capsule().stroke(MobileTheme.Colors.border.opacity(0.35), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(service.isStreaming)
                }
            }
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .opacity(service.isStreaming ? 0.45 : 1)
    }

    private var prompts: [String] {
        var list: [String] = [
            "/wiki",
            "/wiki top project risks",
            "Why did I burn so much today?",
            "Show my biggest sessions this week",
            "Forecast end-of-day spend",
            "Which provider has the lowest quota?",
            "Top 3 projects by cost"
        ]
        if let topProvider = dashboardSnapshot?.topProviders.first?.provider,
           let provider = AgentProvider.fromCatalogProviderID(topProvider) ?? AgentProvider.fromPersistedToken(topProvider) {
            list.append("How is \(provider.displayName) trending?")
        }
        return list
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        // One glass layer, ChatGPT pill shape. `.compact` keeps the Liquid
        // Glass refraction (native `glassEffect` on iOS 26, material fallback
        // earlier) without the mercury-foil edge — chrome stays quiet, the
        // glass does the talking. Buttons and field sit directly on the glass;
        // no nested fills (nothing under glass).
        HStack(alignment: .bottom, spacing: 6) {
            attachmentButton
            field
            sendButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .auroraGlass(.compact, cornerRadius: 26)
    }

    private var attachmentButton: some View {
        Menu {
            PhotosPicker(
                selection: $photoPickerSelection,
                maxSelectionCount: 5,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            ) {
                Label("Photo or Video Library", systemImage: "photo.on.rectangle")
            }
            Button {
                Task {
                    await prepareTakePhotoAttachment()
                }
            } label: {
                Label("Take Photo", systemImage: "camera")
            }
            Button {
                showFileImporter = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(MobileScaledFont.system(size: 19, weight: .medium))
                .foregroundStyle(service.isStreaming ? MobileTheme.Colors.textMuted : MobileTheme.Colors.textSecondary)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(service.isStreaming)
        .accessibilityLabel("Attach file")
    }

    private var field: some View {
        TextField("Ask Hermes…", text: $input, axis: .vertical)
            .font(MobileTheme.Typography.body)
            .focused($inputFocused)
            .submitLabel(.send)
            .onSubmit(send)
            .lineLimit(1...5)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            // Catch return-key inserts on multi-line text fields where
            // `.onSubmit` can be unreliable, and treat them as send.
            .onChange(of: input) { oldValue, newValue in
                guard !isApplyingTextExpansion else { return }
                if newValue.hasSuffix("\n"), !service.isStreaming {
                    input = oldValue
                    send()
                    return
                }
                if let result = TextExpansionMatcher.expandStaticIfAvailable(
                    in: newValue,
                    snippets: textExpansionSnippets,
                    surface: .inAppThread,
                    threadID: textExpansionThreadID
                ) {
                    isApplyingTextExpansion = true
                    input = result.text
                    DispatchQueue.main.async {
                        isApplyingTextExpansion = false
                    }
                }
            }
    }

    private var sendButton: some View {
        // While a stream is in flight the button becomes a stop control
        // (matching the macOS chat) instead of a dead disabled circle —
        // the only way out of a hung generation used to be losing the
        // whole chat via "New chat".
        Button {
            if service.isStreaming {
                HapticBus.threshold()
                if let placeholderID = pendingGatewayPlaceholderID {
                    // Gateway turns aren't driven by the service's stream
                    // task — stop waiting on the pending reply instead.
                    service.failBurnBarGatewayTurn(
                        placeholderID: placeholderID,
                        message: "Stopped waiting for the BurnBar Cloud Gateway reply."
                    )
                    pendingGatewayPlaceholderID = nil
                    pendingGatewayEventID = nil
                } else {
                    service.cancelGeneration()
                }
            } else {
                send()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(sendDisabled
                          ? AnyShapeStyle(MobileTheme.Colors.surfaceElevated.opacity(0.8))
                          : AnyShapeStyle(MobileTheme.Colors.textPrimary))
                    .frame(width: 44, height: 44)
                Image(systemName: service.isStreaming ? "stop.fill" : "arrow.up")
                    .font(MobileScaledFont.system(size: service.isStreaming ? 13 : 15, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(sendDisabled ? MobileTheme.Colors.textMuted : MobileTheme.Colors.background)
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(sendDisabled)
        .accessibilityLabel(MobileAccessibilityLabelPolicy.stopButton(isStreaming: service.isStreaming))
    }

    private var sendDisabled: Bool {
        !service.isStreaming
            && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pendingAttachments.isEmpty
    }

    // MARK: - Actions

    private func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !trimmed.isEmpty || !attachments.isEmpty, !service.isStreaming else { return }
        if shouldSendViaBurnBarGateway, !attachments.isEmpty {
            HapticBus.threshold()
            service.failBurnBarGatewayTurn(
                placeholderID: nil,
                message: "BurnBar Cloud Gateway chat currently supports text messages from iPhone. Remove the attachment or switch to a direct Hermes host/Remote Relay for this turn."
            )
            return
        }
        HapticBus.send()
        input = ""
        pendingAttachments = []
        inputFocused = false
        let commandBias = wikiCommandContext(for: trimmed)
        let context = mergedContextPrompt(
            dashboardContext: dashboardContextPrompt,
            commandBias: commandBias
        )
        if shouldSendViaBurnBarGateway {
            sendViaBurnBarGateway(trimmed, context: context)
        } else if chatViewMode == .cli {
            service.sendVisibleCLIMessage(trimmed, context: context, attachments: attachments)
        } else {
            service.sendMessage(trimmed, context: context, attachments: attachments)
        }
    }

    private func sendViaBurnBarGateway(_ text: String, context: String?) {
        let wireText = gatewayWireText(userText: text, context: context)
        let threadID = service.ensureBurnBarGatewayThreadID()
        let placeholderID = service.beginBurnBarGatewayTurn(displayText: text, wireText: wireText)
        pendingGatewayPlaceholderID = placeholderID
        Task { @MainActor in
            guard let event = await gatewayStore.sendGatewayMessage(
                text: wireText,
                senderDisplayName: gatewaySenderDisplayName,
                threadId: threadID
            ) else {
                service.failBurnBarGatewayTurn(
                    placeholderID: placeholderID,
                    message: gatewayStore.noticeText ?? "Could not send through BurnBar Cloud Gateway."
                )
                pendingGatewayPlaceholderID = nil
                pendingGatewayEventID = nil
                return
            }
            pendingGatewayEventID = event.id
        }
    }

    private func gatewayWireText(userText: String, context: String?) -> String {
        guard let context = context?.trimmingCharacters(in: .whitespacesAndNewlines),
              !context.isEmpty else {
            return userText
        }
        return """
        \(context)

        User message:
        \(userText)
        """
    }

    private func applyPendingGatewayReplyIfNeeded() {
        guard let placeholderID = pendingGatewayPlaceholderID,
              let reply = gatewayStore.latestReply else { return }
        if let pendingGatewayEventID, reply.replyToEventId != pendingGatewayEventID {
            return
        }
        service.finishBurnBarGatewayTurn(placeholderID: placeholderID, reply: reply)
        pendingGatewayPlaceholderID = nil
        pendingGatewayEventID = nil
    }

    private var textExpansionThreadID: String? {
        if let selectedSessionID = service.selectedSessionID {
            return selectedSessionID
        }
        if case .existing(let sessionID) = route {
            return sessionID
        }
        return nil
    }

    private func reloadTextExpansionSnippets() {
        guard let url = TextExpansionSnapshotStore.snapshotURL(),
              let snapshot = try? TextExpansionSnapshotStore.read(from: url) else {
            textExpansionSnippets = []
            return
        }
        textExpansionSnippets = snapshot.snippets
    }

    private func dismissKeyboard() {
        inputFocused = false
    }

    private var chatFileImporterTypes: [UTType] {
        var types: [UTType] = [.image, .pdf, .text, .plainText, .json, .commaSeparatedText, .rtf, .audio, .movie, .data]
        if let yaml = UTType("public.yaml") { types.append(yaml) }
        if let log = UTType(filenameExtension: "log") { types.append(log) }
        if let md = UTType("net.daringfireball.markdown") { types.append(md) }
        return types
    }

    private func handlePhotosPickerSelection(_ items: [PhotosPickerItem]) {
        Task { @MainActor in
            for item in items {
                do {
                    let attachment = try await HermesAttachmentLoader.importPhotosPickerItem(item)
                    appendAttachment(attachment)
                } catch {
                    attachmentImportError = error.localizedDescription
                }
            }
            photoPickerSelection = []
        }
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                do {
                    let attachment = try HermesAttachmentLoader.importFileURL(url)
                    appendAttachment(attachment)
                } catch {
                    attachmentImportError = error.localizedDescription
                }
            }
        case .failure(let error):
            attachmentImportError = error.localizedDescription
        }
    }

    @MainActor
    private func prepareTakePhotoAttachment() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            attachmentImportError = "Camera is not available on this device. Choose Photo or Video Library instead."
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await presentCameraAfterMenuDismissal()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                await presentCameraAfterMenuDismissal()
            } else {
                attachmentImportError = "Camera access was not allowed. Open Settings > OpenBurnBar to allow camera access, or choose Photo or Video Library instead."
            }
        case .denied, .restricted:
            attachmentImportError = "Camera access is off for OpenBurnBar. Open Settings > OpenBurnBar to allow camera access, or choose Photo or Video Library instead."
        @unknown default:
            attachmentImportError = "Camera access is unavailable on this device. Choose Photo or Video Library instead."
        }
    }

    @MainActor
    private func presentCameraAfterMenuDismissal() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
        showCameraSheet = true
    }

    private func ingestImage(_ image: UIImage) {
        do {
            let attachment = try HermesAttachmentLoader.importImage(image)
            appendAttachment(attachment)
        } catch {
            attachmentImportError = error.localizedDescription
        }
    }

    private func appendAttachment(_ attachment: HermesAttachment) {
        withAnimation(AuroraDesign.Motion.auroraSpring) {
            pendingAttachments.append(attachment)
        }
    }

    /// Show the inline "Try again" affordance only on the most recent
    /// assistant turn, only when its outcome supports retry, and only
    /// when no stream is in flight. Earlier turns stay frozen so the
    /// thread doesn't get rewritten by tapping an old failure.
    private func canRetry(_ message: HermesChatMessage) -> Bool {
        guard !service.isStreaming,
              message.role == .assistant,
              message.outcome.supportsRetry else {
            return false
        }
        // Only the trailing assistant message — earlier turns are
        // frozen relative to the user's history.
        let lastAssistantID = visibleMessages.last(where: { $0.role == .assistant })?.id
        return lastAssistantID == message.id
    }

    private var dashboardContextPrompt: String? {
        guard let snapshot = dashboardSnapshot else { return nil }
        var lines = ["OpenBurnBar mobile context for this Hermes turn:"]
        if let totals = snapshot.windowTotals[.today] {
            lines.append("Today: \(totals.costUsd.formatAsCost()), \(totals.tokens.formatAsTokenVolume()) tokens, \(totals.requests) requests.")
        }
        if let week = snapshot.windowTotals[.sevenDays] {
            lines.append("7 days: \(week.costUsd.formatAsCost()), \(week.tokens.formatAsTokenVolume()) tokens, \(week.requests) requests.")
        }
        if !snapshot.topProviders.isEmpty {
            let providers = snapshot.topProviders.prefix(5).map { summary in
                "\(summary.provider): \(summary.totalTokens.formatAsTokenVolume()) tokens"
            }.joined(separator: "; ")
            lines.append("Top providers: \(providers).")
        }
        return lines.joined(separator: "\n")
    }

    private func wikiCommandContext(for input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("/wiki") else { return nil }
        let commandBody = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        if commandBody.isEmpty || commandBody.lowercased() == "list" {
            return """
            /wiki command mode:
            - The user requested project wiki discovery.
            - Call `burnbar_project_memory_list` first.
            - Then either ask for clarification or call `burnbar_project_memory_wiki` with a concrete `project_id`.
            - Ground the answer in snapshot sections, citations, and visuals.
            """
        }
        return """
        /wiki command mode:
        - The user requested project wiki info: \(commandBody)
        - Prefer `burnbar_project_memory_wiki` with a concrete `project_id`.
        - If `project_id` is ambiguous, call `burnbar_project_memory_list` before answering.
        - Ground the answer in snapshot sections, citations, and visuals.
        """
    }

    private func mergedContextPrompt(
        dashboardContext: String?,
        commandBias: String?
    ) -> String? {
        let parts = [dashboardContext, commandBias]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }
}
