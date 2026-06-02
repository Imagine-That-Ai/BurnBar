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

enum HermesChatRoute: Hashable {
    /// Resume a previously persisted Hermes session.
    case existing(sessionID: String)
    /// Start a fresh chat (clears `service.messages` and `selectedSessionID`).
    case new
}

private struct PresentedHermesChatRoute: Identifiable {
    let route: HermesChatRoute

    var id: String {
        switch route {
        case .new:
            return "new"
        case .existing(let sessionID):
            return "existing:\(sessionID)"
        }
    }
}

// MARK: - Hermes Mobile Setup

enum HermesMobileSetupStep: Int, CaseIterable, Identifiable {
    case keepMacReady
    case chooseHost
    case syncProjects
    case startChat

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .keepMacReady: return "Keep your Mac ready"
        case .chooseHost: return "Pick a Hermes host"
        case .syncProjects: return "Sync projects"
        case .startChat: return "Start chatting"
        }
    }

    var detail: String {
        switch self {
        case .keepMacReady:
            return "OpenBurnBar on macOS should be signed in, running, and set to allow Hermes Remote Relay."
        case .chooseHost:
            return "Use Remote Relay away from home; use a direct LAN/VPN URL only when your device can reach the Mac."
        case .syncProjects:
            return "The Mac shares recent BurnBar projects so Mission Control can offer selectable targets instead of a blank path."
        case .startChat:
            return "Ask about spend, sessions, quota pressure, or anything your connected Hermes runtime can answer."
        }
    }

    var systemImage: String {
        switch self {
        case .keepMacReady: return "macbook.and.iphone"
        case .chooseHost: return "antenna.radiowaves.left.and.right"
        case .syncProjects: return "folder.badge.gearshape"
        case .startChat: return "bubble.left.and.bubble.right.fill"
        }
    }
}

enum HermesMobileSetupWizardState {
    static let completionKey = "com.openburnbar.mobile.hermesSetupWizardCompleted"
}

enum HermesMobileSetupWizardGate {
    static func hasUsableSetup(
        isReachable: Bool,
        selectedConnection: HermesConnectionRecord,
        suggestedRelayConnection: HermesConnectionRecord?
    ) -> Bool {
        if isReachable { return true }
        if selectedConnection.mode == .relayLink && selectedConnection.status == .online {
            return true
        }
        return suggestedRelayConnection != nil
    }

    static func shouldAutoPresent(
        isScreenshotMode: Bool,
        hasCompletedSetup: Bool,
        didAutoPresent: Bool,
        hasUsableSetup: Bool
    ) -> Bool {
        !isScreenshotMode && !hasCompletedSetup && !didAutoPresent && !hasUsableSetup
    }
}

enum HermesMobileChatPreferences {
    /// `@AppStorage` key for the opt-in tokens-per-second footer on assistant
    /// bubbles. Defaults to `false` so existing chat surfaces stay unchanged
    /// until the user explicitly enables it.
    static let showMessageTPSKey = "hermesShowMessageTPS"
    /// `@AppStorage` key for opting into pretext-powered rich text rendering
    /// in assistant bubbles. Defaults to `true` — pretext degrades gracefully
    /// to native `Text` while measurement is in flight, and adds visible
    /// chips for `@mentions` and `` `code spans` `` when ready.
    static let usePretextRenderingKey = "hermesUsePretextRendering"
    /// `@AppStorage` key for opting into the interactive SwarmCanvasView live background
    /// in the Agents (formerly Hermes Square) root scene. Defaults to `false`.
    static let agentsLiveBackgroundEnabledKey = "agentsLiveBackgroundEnabled"
}


private enum HermesChatLayout {
    static let hiddenNavigationTrayReserve: CGFloat = 70
    static let composerBottomPadding: CGFloat = 8
}

/// How `HermesChatView` was presented to its host. The push variant
/// keeps the floating `AuroraNavigationTray` visible behind the chat
/// stack — so we add a 70pt reserve under the composer to keep the
/// input bar from sitting on top of the tray. The cover variant fully
/// occludes the tray (`fullScreenCover`), so that reserve becomes a
/// dead gap above the home indicator.
enum HermesChatPresentation {
    case push
    case cover
}

extension Notification.Name {
    /// Posted by `HermesChatView` when its text input focus changes so that
    /// `RootTabView` can hide the floating `AuroraNavigationTray` while the
    /// user is typing.
    static let hermesKeyboardFocusChanged = Notification.Name("hermesKeyboardFocusChanged")
}

private struct HermesMobileSetupWizardView: View {
    @Binding var isPresented: Bool
    @Binding var hasCompletedSetup: Bool
    let onOpenConnections: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                    header

                    VStack(spacing: 10) {
                        ForEach(HermesMobileSetupStep.allCases) { step in
                            setupStepRow(step)
                        }
                    }

                    Button {
                        complete()
                    } label: {
                        Text("Start Chatting")
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.aurora(.hermes, fullWidth: true))

                    Button {
                        onOpenConnections()
                    } label: {
                        Label("Open Connections", systemImage: "network")
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MobileTheme.hermesAureate)
                    .frame(maxWidth: .infinity)
                }
                .padding(AuroraDesign.Layout.cardInset)
            }
            .background(AuroraBackdrop())
            .navigationTitle("Hermes Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(spacing: 12) {
                    HermesLiveGlyph(size: 44, isLive: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hermes in 1-2-3-4")
                            .font(MobileTheme.Typography.title)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text("One Mac host. One connection. Selectable projects. One chat.")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                Text("For iPhone and iPad, Hermes works through BurnBar Cloud Gateway, your Mac Remote Relay, or a direct LAN/VPN Hermes URL.")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setupStepRow(_ step: HermesMobileSetupStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(AuroraDesign.Gradients.mercuryFoil)
                    .frame(width: 34, height: 34)
                Text("\(step.number)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: step.systemImage)
                        .font(.system(size: 12, weight: .bold))
                    Text(step.title)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(MobileTheme.Colors.textPrimary)

                Text(step.detail)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MobileTheme.hermesAureate.opacity(0.22), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.number): \(step.title). \(step.detail)")
    }

    private func complete() {
        hasCompletedSetup = true
        isPresented = false
    }
}

// MARK: - Hermes Conversation List View

struct HermesConversationListView: View {
    @Bindable var service: HermesService
    let dashboardSnapshot: DashboardStore?
    let onSelectExistingThreadInSplit: ((String) -> Void)?

    @Environment(\.mobileAuthStore) private var authStore
    @State private var showConnectionSheet = false
    @State private var showRuntimeSheet = false
    @State private var showModelPicker = false
    @State private var permissionGrantThreadID: String?
    @State private var showSetupWizard = false
    @State private var didAutoPresentSetupWizard = false
    @State private var gatewayStore = HermesGatewaySettingsStore()
    @State private var pendingGatewayPlaceholderID: String?
    @State private var pendingGatewayEventID: String?
    @State private var libraryStore = HermesCloudLibraryStore()
    @State private var historyStore: MobileChatHistoryStore = .shared
    @State private var selectedLibrarySession: HermesLibrarySession?
    @State private var presentedChatRoute: PresentedHermesChatRoute?
    @AppStorage(HermesMobileSetupWizardState.completionKey) private var hasCompletedHermesSetupWizard = false

    init(
        service: HermesService,
        dashboardSnapshot: DashboardStore? = nil,
        onSelectExistingThreadInSplit: ((String) -> Void)? = nil
    ) {
        self.service = service
        self.dashboardSnapshot = dashboardSnapshot
        self.onSelectExistingThreadInSplit = onSelectExistingThreadInSplit
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
        !gatewayStore.activeClients.isEmpty && (!service.isReachable || service.modelOptions.isEmpty)
    }

    private var shouldSendViaBurnBarGateway: Bool {
        !service.isReachable && !gatewayStore.activeClients.isEmpty
    }

    private var gatewaySenderDisplayName: String {
        authStore?.currentIdentity?.displayName?.nilIfBlank ?? "OpenBurnBar iPhone"
    }

    private var conversationListBackgroundVisibility: MobileBackgroundVisibility {
        if showConnectionSheet
            || showRuntimeSheet
            || showModelPicker
            || selectedLibrarySession != nil
            || presentedChatRoute != nil
            || showSetupWizard {
            return .obscured
        }
        return .prominent
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(visibility: conversationListBackgroundVisibility)

            VStack(spacing: 0) {
                brandHeader
                Group {
                    if service.sessions.isEmpty && libraryStore.sessions.isEmpty && onDeviceThreads.isEmpty {
                        emptyState
                    } else {
                        conversationList
                    }
                }
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    newChatFAB
                        .padding(.trailing, AuroraDesign.Layout.cardInset)
                        .padding(.bottom, AuroraDesign.Layout.cardInset)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
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
                    senderDisplayName: authStore?.currentIdentity?.displayName ?? "OpenBurnBar iPhone",
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
        .sheet(item: $selectedLibrarySession) { session in
            HermesLibraryTranscriptSheet(store: libraryStore, session: session)
        }
        .fullScreenCover(item: $presentedChatRoute) { presented in
            NavigationStack {
                HermesChatView(
                    service: service,
                    dashboardSnapshot: dashboardSnapshot,
                    route: presented.route,
                    presentation: .cover
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") {
                            presentedChatRoute = nil
                        }
                    }
                }
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
        .navigationDestination(for: HermesChatRoute.self) { route in
            HermesChatView(
                service: service,
                dashboardSnapshot: dashboardSnapshot,
                route: route
            )
        }
        .task {
            historyStore.bootstrap()
            service.loadHistory()
            async let reachability: Void = service.checkReachability()
            async let library: Void = libraryStore.refresh()
            _ = await (reachability, library)
            reconcileSetupWizardCompletion()
        }
        .task(id: authStore?.currentIdentity?.uid) {
            await refreshGatewayForCurrentAuthState()
        }
        // Pending-prompt consumer — picks up prompts stashed by the
        // "Ask Hermes" widget chip AppIntent or a `burnbar://hermes?prompt=…`
        // deep link. Non-empty values auto-send; an empty slot left over from
        // a "focus the composer" widget tap is ignored at the list level
        // (the user already landed here, and tapping into a session focuses
        // the input).
        .task(id: AssistantPendingPrompt.shared.hermes) {
            await consumePendingHermesPrompt()
        }
        .onAppear {
            presentSetupWizardIfNeeded()
        }
        .onDisappear {
            gatewayStore.stopGatewayListening()
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
    }

    @MainActor
    private func refreshGatewayForCurrentAuthState() async {
        let uid = authStore?.currentIdentity?.uid
        let signedInState = authStore?.state.isSignedIn
        gatewayStore.startGatewayListening(uid: uid)
        await gatewayStore.refresh(isSignedIn: signedInState == true)
    }

    @MainActor
    private func consumePendingHermesPrompt() async {
        guard let pending = AssistantPendingPrompt.shared.consume(.hermes),
              !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        // Small delay so the conversation list has settled before we
        // create a new session and start streaming.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if shouldSendViaBurnBarGateway {
            sendViaBurnBarGateway(pending)
        } else {
            service.sendMessage(pending)
        }
    }

    private func sendViaBurnBarGateway(_ text: String) {
        let threadID = service.ensureBurnBarGatewayThreadID()
        let placeholderID = service.beginBurnBarGatewayTurn(displayText: text, wireText: text)
        pendingGatewayPlaceholderID = placeholderID
        Task { @MainActor in
            guard let event = await gatewayStore.sendGatewayMessage(
                text: text,
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

    // MARK: - Brand Header

    private var brandHeader: some View {
        let lens = AssistantModelLens(hermesService: service, piService: PiService.shared)
        let snapshot = lens.snapshot(for: .hermes)
        return HStack(spacing: 12) {
            Button {
                presentModelPicker()
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    UnifiedProviderLogoView(provider: hermesAgentProvider(for: "hermes"), size: 34)
                    Circle()
                        .fill(effectiveHermesReachable ? MobileTheme.success : MobileTheme.warning)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(MobileTheme.Colors.background, lineWidth: 1.5))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch Hermes model")

            VStack(alignment: .leading, spacing: 2) {
                Text(AssistantRuntimeID.hermes.displayName)
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(snapshot.displayName)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

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
                    Button {
                        showConnectionSheet = true
                    } label: {
                        Label("Connections", systemImage: "network")
                    }
                    Button {
                        presentModelPicker()
                    } label: {
                        Label("Switch model", systemImage: "cpu")
                    }
                    Button {
                        showRuntimeSheet = true
                    } label: {
                        Label("Runtime", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        showSetupWizard = true
                    } label: {
                        Label("Setup Guide", systemImage: "list.number")
                    }
                }

                Section {
                    Button {
                        Task { await service.refreshRuntime() }
                    } label: {
                        Label("Re-check connection", systemImage: "arrow.clockwise")
                    }
                    Button {
                        Task { await libraryStore.refresh() }
                    } label: {
                        Label("Refresh Library", systemImage: "icloud.and.arrow.down")
                    }
                }
            } label: {
                HermesDynamicStatusWidget(
                    provider: activeProvider,
                    isReachable: effectiveHermesReachable,
                    isRefreshing: service.isLoadingRuntime
                ) {
                    Task { await service.refreshRuntime() }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Manage Hermes connection")
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - Conversation List

    private var conversationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !onDeviceThreads.isEmpty {
                    let onDeviceSessionIDs = Set(sortedSessions.map(\.id))
                    let onlyDeviceThreads = onDeviceThreads.filter { !onDeviceSessionIDs.contains($0.id) }
                    if !onlyDeviceThreads.isEmpty {
                        librarySectionHeader("On This Device", systemImage: "iphone")
                        ForEach(onlyDeviceThreads) { thread in
                            Button {
                                openChat(.existing(sessionID: thread.id))
                            } label: {
                                OnDeviceHermesRow(thread: thread)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    service.deleteMobileThread(id: thread.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                if !sortedSessions.isEmpty {
                    librarySectionHeader("Live Hermes Host", systemImage: "antenna.radiowaves.left.and.right")
                        .padding(.top, onDeviceThreads.isEmpty ? 0 : 10)
                    ForEach(sortedSessions) { session in
                        Button {
                            openChat(.existing(sessionID: session.id))
                        } label: {
                            ConversationRow(
                                session: session,
                                isActive: service.selectedSessionID == session.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !sortedLibrarySessions.isEmpty {
                    librarySectionHeader("Imported Library", systemImage: "books.vertical.fill")
                        .padding(.top, sortedSessions.isEmpty ? 0 : 10)
                    ForEach(sortedLibrarySessions) { session in
                        Button {
                            HapticBus.sheetOpen()
                            selectedLibrarySession = session
                        } label: {
                            HermesLibraryRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let error = libraryStore.lastError, !error.isEmpty {
                    Text("Cloud library unavailable: \(error)")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.warning)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
            .padding(.bottom, 96) // FAB clearance
            .padding(.top, 4)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            HapticBus.refreshStarted()
            async let runtime: Void = service.refreshRuntime()
            async let library: Void = libraryStore.refresh()
            _ = await (runtime, library)
            HapticBus.refreshFinished()
        }
        .animation(AuroraDesign.Motion.auroraSpring, value: service.sessions.map(\.id))
    }

    private var sortedSessions: [HermesSessionSummary] {
        service.sessions.sorted {
            ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
        }
    }

    private var sortedLibrarySessions: [HermesLibrarySession] {
        libraryStore.sessions.sorted {
            ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
        }
    }

    private var onDeviceThreads: [MobileChatThread] {
        historyStore.threads(for: .hermes)
    }

    private func librarySectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(MobileTheme.Typography.caption)
            .fontWeight(.semibold)
            .foregroundStyle(MobileTheme.Colors.textSecondary)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: MobileTheme.Spacing.lg) {
                AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.heroCorner) {
                    VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                        HStack(spacing: 12) {
                            Text("☿")
                                .font(.system(size: 38, weight: .bold))
                                .foregroundStyle(AuroraDesign.Gradients.mercuryFoil)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No conversations yet")
                                    .font(MobileTheme.Typography.title)
                                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                                Text("Hermes is your AI fleet's runtime co-pilot.")
                                    .font(MobileTheme.Typography.caption)
                                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                            }
                            Spacer()
                        }
                        Text("Start a new chat to ask about today's burn, project breakdowns, quota pressure, or session details. Sessions persist on the connected Hermes host.")
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            openChat(.new)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.bubble.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Start your first conversation")
                                    .font(MobileTheme.Typography.body)
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(
                                Capsule().fill(AuroraDesign.Gradients.mercuryFoil)
                            )
                            .shadow(color: MobileTheme.hermesAureate.opacity(0.4), radius: 12, y: 4)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                .padding(.top, MobileTheme.Spacing.xl)

                if let relay = service.suggestedRelayConnection,
                   service.selectedConnection.id != relay.id {
                    connectRelayCard(relay)
                        .padding(.horizontal, AuroraDesign.Layout.cardInset)
                }

                if let runtimeErrorText = service.runtimeErrorText {
                    AuroraGlassCard(variant: .urgent) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Hermes is offline", systemImage: "exclamationmark.triangle.fill")
                                .font(MobileTheme.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.warning)
                            Text(runtimeErrorText)
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                Task { await service.refreshRuntime() }
                            } label: {
                                Label("Re-check connection", systemImage: "arrow.clockwise")
                                    .font(MobileTheme.Typography.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(MobileTheme.hermesAureate)
                        }
                    }
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                }

                Spacer(minLength: 96) // FAB clearance
            }
        }
        .refreshable {
            HapticBus.refreshStarted()
            await service.refreshRuntime()
            HapticBus.refreshFinished()
        }
    }

    private func connectRelayCard(_ relay: HermesConnectionRecord) -> some View {
        AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.standardCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Label("Use \(relay.displayName)", systemImage: "macbook.and.iphone")
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                Text("You're signed in to the same OpenBurnBar account on this iPhone/iPad and your Mac. Grant permission here to route Hermes chats through your Mac over private Remote Relay.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    HapticBus.primaryAction()
                    if !service.connectToSuggestedRelay() {
                        showConnectionSheet = true
                    }
                } label: {
                    Label("Connect to my Mac", systemImage: "checkmark.shield.fill")
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.aurora(.hermes, fullWidth: true))
                .accessibilityHint("Selects the available Mac Hermes Remote Relay for this device.")
            }
        }
    }

    // MARK: - FAB

    private var newChatFAB: some View {
        Button {
            openChat(.new)
        } label: {
            ZStack {
                Circle()
                    .fill(AuroraDesign.Gradients.mercuryFoil)
                    .frame(width: 56, height: 56)
                    .shadow(color: MobileTheme.hermesAureate.opacity(0.45), radius: 14, y: 6)
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay(
                Circle().stroke(.white.opacity(0.18), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start new Hermes conversation")
    }

    private func openChat(_ route: HermesChatRoute) {
        HapticBus.sheetOpen()
        if case .existing(let sessionID) = route,
           let onSelectExistingThreadInSplit {
            onSelectExistingThreadInSplit(sessionID)
            return
        }
        presentedChatRoute = PresentedHermesChatRoute(route: route)
    }
}

// MARK: - On-Device Hermes Row

private struct OnDeviceHermesRow: View {
    let thread: MobileChatThread

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(thread.title)
                        .font(MobileTheme.Typography.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "iphone")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MobileTheme.hermesAureate)
                }
                Spacer(minLength: 8)
                Text(thread.updatedAt, style: .relative)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary.opacity(0.85))
                    .lineLimit(1)
            }

            if !thread.preview.isEmpty {
                Text(thread.preview)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            MobileAttachmentSummaryStrip(attachments: thread.recentAttachmentPreviews)

            Text("\(thread.messageCount) messages")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textSecondary.opacity(0.65))
        }
        .padding(MobileTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AuroraDesign.Shape.standardCorner, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: AuroraDesign.Shape.standardCorner, style: .continuous)
                        .stroke(MobileTheme.Colors.border.opacity(0.45), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Conversation Row

private struct ConversationRow: View {
    let session: HermesSessionSummary
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title?.nilIfBlank ?? "New Conversation")
                    .font(MobileTheme.Typography.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let lastActiveAt = session.lastActiveAt {
                    Text(lastActiveAt, style: .relative)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(secondaryColor.opacity(0.85))
                        .lineLimit(1)
                }
            }

            if let preview = session.preview?.nilIfBlank {
                Text(preview)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: 8) {
                modelChip
                messageChip
                if session.isActive {
                    activeChip
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(rowBorder)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Chips

    private var modelChip: some View {
        HStack(spacing: 5) {
            HermesLiveGlyph(size: 12, isLive: false)
            Text(session.model?.nilIfBlank ?? "hermes")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .foregroundStyle(chipForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(chipFill))
        .overlay(Capsule().stroke(chipStroke, lineWidth: 0.5))
    }

    private var messageChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 12, weight: .bold))
            Text("\(session.messageCount)")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(secondaryColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(MobileTheme.Colors.surface.opacity(isActive ? 0.18 : 0.5)))
        .overlay(Capsule().stroke(MobileTheme.Colors.border.opacity(isActive ? 0.0 : 0.4), lineWidth: 0.5))
    }

    private var activeChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? .white : MobileTheme.success)
                .frame(width: 7, height: 7)
            Text("Active")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(isActive ? .white : MobileTheme.success)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(
                isActive
                    ? AnyShapeStyle(.white.opacity(0.18))
                    : AnyShapeStyle(MobileTheme.success.opacity(0.12))
            )
        )
    }

    // MARK: - Row Chrome

    @ViewBuilder
    private var rowBackground: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AuroraDesign.Gradients.mercuryFoil)
                .shadow(color: MobileTheme.hermesAureate.opacity(0.35), radius: 12, y: 6)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.85))
        }
    }

    @ViewBuilder
    private var rowBorder: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MobileTheme.Colors.border.opacity(0.45), lineWidth: 0.5)
        }
    }

    // MARK: - Color Tokens

    private var titleColor: Color {
        isActive ? .white : MobileTheme.Colors.textPrimary
    }

    private var secondaryColor: Color {
        isActive ? .white.opacity(0.82) : MobileTheme.Colors.textSecondary
    }

    private var chipForeground: Color {
        isActive ? .white : MobileTheme.hermesAureate
    }

    private var chipFill: AnyShapeStyle {
        isActive
            ? AnyShapeStyle(.white.opacity(0.18))
            : AnyShapeStyle(MobileTheme.hermesAureate.opacity(0.12))
    }

    private var chipStroke: Color {
        isActive
            ? .white.opacity(0.32)
            : MobileTheme.hermesAureate.opacity(0.3)
    }
}

private struct HermesLibraryRow: View {
    let session: HermesLibrarySession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title.nilIfBlank ?? "Hermes conversation")
                    .font(MobileTheme.Typography.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let lastActiveAt = session.lastActiveAt {
                    Text(lastActiveAt, style: .relative)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }

            Text(session.preview)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 8) {
                Label(session.sourceLabel, systemImage: session.source == .firebase ? "cloud.fill" : "icloud.fill")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.hermesAureate)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(MobileTheme.hermesAureate.opacity(0.12)))

                Label("\(session.messageCount)", systemImage: "bubble.left.and.bubble.right")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)

                Spacer()

                Text("Read-only")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MobileTheme.Colors.border.opacity(0.7), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct HermesLibraryTranscriptSheet: View {
    let store: HermesCloudLibraryStore
    let session: HermesLibrarySession

    @Environment(\.dismiss) private var dismiss
    @State private var transcript = ""
    @State private var errorText: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                    AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.standardCorner) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(session.sourceLabel, systemImage: session.source == .firebase ? "cloud.fill" : "icloud.fill")
                                .font(MobileTheme.Typography.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.hermesAureate)
                            Text(session.title)
                                .font(MobileTheme.Typography.title)
                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                            Text("Imported transcript. Connect to your Mac relay to continue live in Hermes.")
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                        }
                    }

                    if isLoading {
                        ProgressView("Loading transcript…")
                            .frame(maxWidth: .infinity)
                    } else if let errorText {
                        Text(errorText)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.error)
                    } else {
                        Text(transcript.isEmpty ? "No transcript body was found for this imported session." : transcript)
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(AuroraDesign.Layout.cardInset)
            }
            .background(AuroraBackdrop())
            .navigationTitle("Hermes Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadTranscript() }
    }

    private func loadTranscript() async {
        isLoading = true
        defer { isLoading = false }
        do {
            transcript = try await store.transcript(for: session)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Hermes Chat View

struct HermesChatView: View {
    @Bindable var service: HermesService
    let dashboardSnapshot: DashboardStore?
    let route: HermesChatRoute
    let presentation: HermesChatPresentation

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
    @AppStorage(HermesMobileSetupWizardState.completionKey) private var hasCompletedHermesSetupWizard = false
    @AppStorage(HermesMobileChatPreferences.showMessageTPSKey) private var showMessageTPS = false
    @AppStorage("chatViewMode") private var chatViewMode: ChatViewMode = .agent
    @AppStorage(HermesMobileChatPreferences.usePretextRenderingKey) private var usePretextRendering = true
    @State private var showPretextPlayground = false
    @State private var atomRouter = HermesAtomRouter()
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
        route: HermesChatRoute = .new,
        presentation: HermesChatPresentation = .push
    ) {
        self.service = service
        self.dashboardSnapshot = dashboardSnapshot
        self.route = route
        self.presentation = presentation
    }

    /// User-visible subset of `service.messages`. `.tool` role messages
    /// are context for the upstream model — they hold the JSON body the
    /// `MobileTool` returned so the next assistant turn can read it.
    /// We do *not* render them as chat bubbles; their presence is
    /// already conveyed by the tool pill on the assistant turn that
    /// produced the call.
    private var visibleMessages: [HermesChatMessage] {
        service.messages.filter { $0.role != .tool }
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
                                    showTPS: showMessageTPS,
                                    usePretextRendering: usePretextRendering,
                                    viewMode: chatViewMode,
                                    onRetry: canRetry(message) ? { service.retryLastUserTurn(context: dashboardContextPrompt) } : nil
                                )
                                    .id(message.id)
                            }
                            if service.isStreaming {
                                HStack {
                                    MercuryThinkingIndicator()
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
            || showPretextPlayground
            || showFileImporter
            || showCameraSheet
            || atomRouter.pending != nil {
            return .obscured
        }
        return .prominent
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(visibility: chatBackgroundVisibility)
            VStack(spacing: 0) {
                relaySuggestionBanner
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.bottom, service.hasPendingRelaySuggestion ? 8 : 0)

                runtimeRail
                    .padding(.bottom, 8)

                chatContent

                if service.messages.isEmpty || input.isEmpty {
                    promptCarousel
                        .padding(.bottom, 4)
                }

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

                inputBar
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.bottom, HermesChatLayout.composerBottomPadding)
            }
            // Keep the visible prompt/composer stack stable. The floating
            // AuroraNavigationTray needs a reserve only while the keyboard
            // is hidden AND we're being pushed inside the tab's
            // NavigationStack — the tray sits above the stack and would
            // otherwise overlap the composer. When presented as a
            // fullScreenCover the tray is fully occluded, so the reserve
            // becomes a dead gap above the home indicator.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: bottomReserveHeight)
                    .transaction { transaction in
                        transaction.disablesAnimations = true
                    }
            }
        }
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
        .sheet(isPresented: $showPretextPlayground) {
            PretextPlayground()
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
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 8) {
                MobileChatViewModePicker(chatViewMode: $chatViewMode)
                chatOptionsMenu
            }
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
                    Label("Rich text (mentions · code)", systemImage: "text.alignleft")
                }
                Button {
                    showPretextPlayground = true
                } label: {
                    Label("Text Layout Playground", systemImage: "textformat.size")
                }
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
            ProviderStatusGlobeView(provider: activeProvider, isReachable: effectiveHermesReachable)
        }
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
        !gatewayStore.activeClients.isEmpty && (!service.isReachable || service.modelOptions.isEmpty)
    }

    private var shouldSendViaBurnBarGateway: Bool {
        chatViewMode != .cli && !service.isReachable && !gatewayStore.activeClients.isEmpty
    }

    private var gatewaySenderDisplayName: String {
        authStore?.currentIdentity?.displayName?.nilIfBlank ?? "OpenBurnBar iPhone"
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
                        .font(.system(size: 14, weight: .bold))
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
                        .font(.system(size: 14, weight: .bold))
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

    private var runtimeRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    presentModelPicker()
                } label: {
                    modelSelectorChip
                }
                .buttonStyle(.plain)
                Button {
                    showRuntimeSheet = true
                } label: {
                    runtimeChip(icon: "wrench.and.screwdriver", label: "\(service.profiles.count) profiles · \(service.jobs.count) jobs")
                }
                runtimeChip(icon: "flame.fill", label: "\(service.currentConversationTokenBurn.formatted()) tokens")
                if let selectedSessionID = service.selectedSessionID {
                    runtimeChip(icon: "bubble.left.and.bubble.right", label: "Resuming \(service.sessionTitle(for: selectedSessionID))")
                }
            }
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
        }
    }

    private func runtimeChip(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
            Text(label)
                .lineLimit(1)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(MobileTheme.hermesAureate)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(MobileTheme.hermesAureate.opacity(0.1)))
        .overlay(Capsule().stroke(MobileTheme.hermesAureate.opacity(0.24), lineWidth: 0.5))
    }

    private var modelSelectorChip: some View {
        let option = service.selectedModelOption
            ?? gatewayStore.runtimeModelOptions.first(where: { $0.modelID == service.selectedModelID })
        let fallbackModel = service.selectedModelID ?? gatewayStore.runtimeModelId ?? service.selectedConnection.advertisedModel
        let label = option?.displayName ?? fallbackModel ?? "Choose model"
        let provider = option?.agentProvider ?? hermesAgentProvider(for: fallbackModel ?? "hermes")
        return HStack(spacing: 6) {
            UnifiedProviderLogoView(provider: provider, size: 18, useFallbackColor: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .lineLimit(1)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                Text("Switch model")
                    .lineLimit(1)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
        .foregroundStyle(MobileTheme.Colors.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(MobileTheme.Colors.surfaceElevated.opacity(0.72)))
        .overlay(Capsule().stroke(MobileTheme.hermesAureate.opacity(0.35), lineWidth: 0.7))
    }

    // MARK: - Welcome

    private var welcomeBlock: some View {
        AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(spacing: 12) {
                    HermesLiveGlyph(size: 42, isLive: service.isStreaming)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hermes")
                            .font(MobileTheme.Typography.title)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text("Your AI fleet's runtime co-pilot")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                Text("Ask questions about today's burn, project breakdowns, quota pressure, or session details. Responses use your live OpenBurnBar data as context.")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                contextChips
            }
        }
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
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
            Text(label).font(MobileTheme.Typography.tiny)
            Text(value)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(MobileTheme.hermesAureate)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(MobileTheme.hermesAureate.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(MobileTheme.hermesAureate.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Prompt Carousel

    private var promptCarousel: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(prompts, id: \.self) { prompt in
                        Button {
                            input = prompt
                            send()
                        } label: {
                            Text(prompt)
                                .font(MobileTheme.Typography.tiny)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .foregroundStyle(MobileTheme.hermesAureate)
                                .background(
                                    Capsule().fill(MobileTheme.hermesAureate.opacity(0.12))
                                )
                                .overlay(
                                    Capsule().stroke(MobileTheme.hermesAureate.opacity(0.35), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(service.isStreaming)
                    }
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
            }
            Text("Tip: use `/wiki <project>` to query Project Memory snapshots from Hermes.")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
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
        HStack(alignment: .bottom, spacing: 8) {
            attachmentButton
            field
            sendButton
        }
        .padding(10)
        .auroraGlass(.hermes, cornerRadius: 18)
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
            ZStack {
                Circle()
                    .fill(MobileTheme.Colors.surface.opacity(0.7))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Circle()
                            .stroke(MobileTheme.Colors.border.opacity(0.45), lineWidth: 0.5)
                    )
                Image(systemName: "paperclip")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(service.isStreaming ? MobileTheme.Colors.textMuted : MobileTheme.hermesAureate)
            }
        }
        .buttonStyle(.plain)
        .disabled(service.isStreaming)
        .accessibilityLabel("Attach file")
    }

    private var field: some View {
        TextField("Ask Hermes… (/wiki <project>)", text: $input, axis: .vertical)
            .font(MobileTheme.Typography.body)
            .focused($inputFocused)
            .submitLabel(.send)
            .onSubmit(send)
            .lineLimit(1...5)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(MobileTheme.Colors.surface.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                inputFocused ? MobileTheme.hermesAureate : MobileTheme.Colors.border.opacity(0.4),
                                lineWidth: inputFocused ? 1 : 0.5
                            )
                    )
            )
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
        Button(action: send) {
            ZStack {
                Circle()
                    .fill(sendDisabled
                          ? AnyShapeStyle(MobileTheme.Colors.surface.opacity(0.6))
                          : AnyShapeStyle(AuroraDesign.Gradients.mercuryFoil))
                    .frame(width: 38, height: 38)
                    .shadow(color: MobileTheme.hermesAureate.opacity(sendDisabled ? 0 : 0.4), radius: 10)
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(sendDisabled ? MobileTheme.Colors.textMuted : .white)
            }
        }
        .buttonStyle(.plain)
        .disabled(sendDisabled)
        .accessibilityLabel("Send")
    }

    private var sendDisabled: Bool {
        service.isStreaming
            || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty)
    }

    private var bottomReserveHeight: CGFloat {
        if UIDevice.current.userInterfaceIdiom == .pad { return 0 }
        if inputFocused { return 0 }
        switch presentation {
        case .cover: return 0
        case .push: return HermesChatLayout.hiddenNavigationTrayReserve
        }
    }

    // MARK: - Actions

    private func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard (!trimmed.isEmpty || !attachments.isEmpty), !service.isStreaming else { return }
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

// MARK: - Hermes Connection Sheet

private struct HermesConnectionSheet: View {
    @Bindable var service: HermesService
    let gatewayStore: HermesGatewaySettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var endpointURL = ""
    @State private var bearerToken = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(density: .subtle)

                ScrollView {
                    VStack(spacing: 20) {
                        // 1. Suggested Mac Relay Banner (Clean & Contextual)
                        if let relay = service.suggestedRelayConnection,
                           service.selectedConnection.id != relay.id {
                            AuroraGlassCard(variant: .hero, cornerRadius: AuroraDesign.Shape.standardCorner) {
                                VStack(alignment: .leading, spacing: 14) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "macbook.and.iphone")
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundStyle(MobileTheme.hermesAureate)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Mac Relay Available")
                                                .font(MobileTheme.Typography.body)
                                                .fontWeight(.bold)
                                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                                            Text("Connect to your signed-in Mac to access Hermes.")
                                                .font(MobileTheme.Typography.caption)
                                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                                        }
                                    }

                                    Button {
                                        if service.connectToSuggestedRelay() {
                                            dismiss()
                                        } else {
                                            errorText = service.lastError
                                        }
                                    } label: {
                                        Text("Connect to \(relay.displayName)")
                                            .font(MobileTheme.Typography.body)
                                            .fontWeight(.semibold)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.aurora(.hermes, fullWidth: true))
                                }
                            }
                        }

                        // 2. Error Display Cards
                        if let runtimeErrorText = service.runtimeErrorText {
                            AuroraGlassCard(variant: .urgent, cornerRadius: AuroraDesign.Shape.standardCorner) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(MobileTheme.error)
                                        Text("Connection Status")
                                            .font(MobileTheme.Typography.body)
                                            .fontWeight(.bold)
                                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                                    }
                                    Text(runtimeErrorText)
                                        .font(MobileTheme.Typography.caption)
                                        .foregroundStyle(MobileTheme.Colors.textSecondary)

                                    Button {
                                        Task { await service.refreshConnections() }
                                    } label: {
                                        Text("Retry Discovery")
                                            .font(MobileTheme.Typography.caption)
                                            .fontWeight(.semibold)
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.aurora(.hermes, fullWidth: true))
                                    .padding(.top, 4)
                                }
                            }
                        }

                        if let errorText {
                            AuroraGlassCard(variant: .urgent, cornerRadius: AuroraDesign.Shape.standardCorner) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Action Error")
                                        .font(MobileTheme.Typography.caption)
                                        .fontWeight(.bold)
                                        .foregroundStyle(MobileTheme.error)
                                    Text(errorText)
                                        .font(MobileTheme.Typography.caption)
                                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                                }
                            }
                        }

                        if !gatewayStore.activeClients.isEmpty {
                            burnBarGatewayConnectionCard
                        }

                        // 3. Active Hosts Section
                        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 8) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(MobileTheme.hermesAureate)
                                    Text("Available Hosts")
                                        .font(MobileTheme.Typography.headline)
                                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                                    Spacer()
                                }
                                .padding(.bottom, 2)

                                VStack(spacing: 0) {
                                    ForEach(Array(service.connections.enumerated()), id: \.element.id) { index, connection in
                                        let isSelected = connection.id == service.selectedConnection.id
                                        VStack(spacing: 0) {
                                            HStack(spacing: 12) {
                                                Button {
                                                    if service.selectConnection(connection) {
                                                        dismiss()
                                                    } else {
                                                        errorText = service.lastError
                                                    }
                                                } label: {
                                                    HStack(spacing: 12) {
                                                        // Glowing status dot
                                                        ZStack {
                                                            Circle()
                                                                .fill(connection.status == .online ? MobileTheme.success : MobileTheme.warning)
                                                                .frame(width: 8, height: 8)
                                                            if connection.status == .online {
                                                                Circle()
                                                                    .stroke(MobileTheme.success.opacity(0.4), lineWidth: 1.5)
                                                                    .frame(width: 14, height: 14)
                                                            }
                                                        }
                                                        .frame(width: 16, height: 16)

                                                        VStack(alignment: .leading, spacing: 2) {
                                                            Text(connection.displayName)
                                                                .font(MobileTheme.Typography.body)
                                                                .fontWeight(.semibold)
                                                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                                                            Text(connectionSubtitle(connection))
                                                                .font(MobileTheme.Typography.tiny)
                                                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                                                        }
                                                        Spacer()
                                                    }
                                                    .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)

                                                if isSelected {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .font(.system(size: 18))
                                                        .foregroundStyle(MobileTheme.hermesAureate)
                                                }

                                                if connection.id != HermesConnectionRecord.localDefault.id {
                                                    Button {
                                                        Task { await revoke(connection) }
                                                    } label: {
                                                        Image(systemName: "trash")
                                                            .font(.system(size: 13, weight: .medium))
                                                            .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.6))
                                                            .padding(6)
                                                            .background(Circle().fill(MobileTheme.Colors.surface.opacity(0.4)))
                                                    }
                                                    .buttonStyle(.plain)
                                                    .padding(.leading, 4)
                                                }
                                            }
                                            .padding(.vertical, 10)

                                            if index < service.connections.count - 1 {
                                                Divider()
                                                    .background(MobileTheme.Colors.border.opacity(0.3))
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // 4. Add Direct Host Section
                        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 8) {
                                    Image(systemName: "link.badge.plus")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(MobileTheme.hermesAureate)
                                    Text("Add Direct Host")
                                        .font(MobileTheme.Typography.headline)
                                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                                    Spacer()
                                }
                                .padding(.bottom, 2)

                                VStack(alignment: .leading, spacing: 14) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Host Name")
                                            .font(MobileTheme.Typography.tiny)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                                        TextField("e.g. Home Mac", text: $displayName)
                                            .font(MobileTheme.Typography.body)
                                            .padding(12)
                                            .background(MobileTheme.Colors.surface.opacity(0.35))
                                            .cornerRadius(10)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(MobileTheme.Colors.border.opacity(0.35), lineWidth: 0.8)
                                            )
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Hermes URL")
                                            .font(MobileTheme.Typography.tiny)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                                        TextField("http://192.168.1.2:8642", text: $endpointURL)
                                            .font(MobileTheme.Typography.body)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                            .padding(12)
                                            .background(MobileTheme.Colors.surface.opacity(0.35))
                                            .cornerRadius(10)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(MobileTheme.Colors.border.opacity(0.35), lineWidth: 0.8)
                                            )
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("API Server Key (optional)")
                                            .font(MobileTheme.Typography.tiny)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                                        SecureField("Bearer token key", text: $bearerToken)
                                            .font(MobileTheme.Typography.body)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                            .padding(12)
                                            .background(MobileTheme.Colors.surface.opacity(0.35))
                                            .cornerRadius(10)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(MobileTheme.Colors.border.opacity(0.35), lineWidth: 0.8)
                                            )
                                    }

                                    if !endpointURL.isEmpty, HermesService.validatedEndpointURL(endpointURL) == nil {
                                        Text("Use HTTPS, or HTTP only for localhost/private LAN Hermes hosts.")
                                            .font(MobileTheme.Typography.tiny)
                                            .foregroundStyle(MobileTheme.error)
                                    }

                                    Button {
                                        Task { await addDirectConnection() }
                                    } label: {
                                        if isWorking {
                                            ProgressView()
                                                .tint(.white)
                                                .frame(maxWidth: .infinity)
                                        } else {
                                            Text("Register and Connect")
                                                .font(MobileTheme.Typography.body)
                                                .fontWeight(.bold)
                                                .frame(maxWidth: .infinity)
                                        }
                                    }
                                    .buttonStyle(.aurora(.hermes, fullWidth: true))
                                    .disabled(isWorking || displayName.isEmpty || HermesService.validatedEndpointURL(endpointURL) == nil)
                                    .padding(.top, 6)
                                }
                            }
                        }

                        // 5. Secure Storage Footnote
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 11))
                            Text("API keys stay securely stored locally on this device.")
                                .font(MobileTheme.Typography.tiny)
                        }
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                    }
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("Hermes Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await service.refreshConnections() }
        }
    }

    private var burnBarGatewayConnectionCard: some View {
        let onlineCount = gatewayStore.onlineClients.count
        let activeCount = gatewayStore.activeClients.count
        let selectedClient = gatewayStore.selectedClient
        let isOnline = selectedClient.map { gatewayStore.isOnline($0) } ?? (onlineCount > 0)

        return AuroraGlassCard(variant: isOnline ? .success : .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill((isOnline ? MobileTheme.success : MobileTheme.warning).opacity(0.16))
                            .frame(width: 44, height: 44)
                        Image(systemName: isOnline ? "checkmark.seal.fill" : "link.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(isOnline ? MobileTheme.success : MobileTheme.warning)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("BurnBar Cloud Gateway")
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.bold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text(gatewayConnectionSheetSubtitle(activeCount: activeCount, onlineCount: onlineCount))
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Text(isOnline ? "Online" : "Paired")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.bold)
                        .foregroundStyle(isOnline ? MobileTheme.success : MobileTheme.warning)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill((isOnline ? MobileTheme.success : MobileTheme.warning).opacity(0.12)))
                }

                if let client = selectedClient ?? gatewayStore.onlineClients.first ?? gatewayStore.activeClients.first {
                    HStack(spacing: 8) {
                        Image(systemName: gatewayStore.selectedClient?.id == client.id ? "checkmark.circle.fill" : "iphone")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(gatewayStore.selectedClient?.id == client.id ? MobileTheme.hermesAureate : MobileTheme.Colors.textMuted)
                        Text(client.displayName)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(client.homeDestinationId)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("BurnBar Cloud Gateway. \(gatewayConnectionSheetSubtitle(activeCount: activeCount, onlineCount: onlineCount))")
    }

    private func gatewayConnectionSheetSubtitle(activeCount: Int, onlineCount: Int) -> String {
        if onlineCount > 0 {
            let noun = onlineCount == 1 ? "gateway client is" : "gateway clients are"
            return "\(onlineCount) \(noun) live. This is the official Hermes messaging gateway through BurnBar Cloud."
        }
        let noun = activeCount == 1 ? "gateway client is" : "gateway clients are"
        return "\(activeCount) \(noun) paired, but no gateway has checked in recently. Restart Hermes Gateway on the computer."
    }

    private func addDirectConnection() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await service.addDirectConnection(
                displayName: displayName,
                endpointURL: endpointURL,
                bearerToken: bearerToken
            )
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func revoke(_ connection: HermesConnectionRecord) async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await service.revokeConnection(connection)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func connectionSubtitle(_ connection: HermesConnectionRecord) -> String {
        if connection.mode == .relayLink {
            return "Remote Relay · works over cell signal"
        }
        return connection.endpointURL ?? connection.mode.rawValue
    }
}

// MARK: - Hermes Runtime Sheet

struct HermesGatewayModelPickerSheet: View {
    @Bindable var service: HermesService
    @Bindable var gatewayStore: HermesGatewaySettingsStore
    let senderDisplayName: String
    let threadId: String

    @Environment(\.dismiss) private var dismiss
    @State private var customModelID = ""

    private var options: [HermesRuntimeModelOption] {
        gatewayStore.runtimeModelOptions
    }

    private var currentModelText: String {
        service.selectedModelID
            ?? gatewayStore.runtimeModelId
            ?? "Hermes default"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(density: .subtle)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusCard
                        customModelCard
                        modelListCard
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Gateway Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var statusCard: some View {
        let selectedGateway = gatewayStore.selectedClient
        let selectedOnline = selectedGateway.map { gatewayStore.isOnline($0) } ?? false
        return AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
            HStack(spacing: 12) {
                Image(systemName: selectedOnline ? "checkmark.seal.fill" : "link.circle")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(selectedOnline ? MobileTheme.success : MobileTheme.warning)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill((selectedOnline ? MobileTheme.success : MobileTheme.warning).opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentModelText)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.bold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(2)
                    Text(selectedGateway.map { "Switches are sent to \($0.displayName) through BurnBar Cloud and apply before the next queued message in this conversation." } ?? "Switches are sent to the selected Hermes gateway through BurnBar Cloud.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var customModelCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Exact model id", systemImage: "terminal")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                TextField("minimax-m2.7-highspeed", text: $customModelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(MobileTheme.Colors.surfaceElevated.opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(MobileTheme.Colors.border.opacity(0.5), lineWidth: 0.7)
                    )
                    .onSubmit {
                        Task { await switchModel(customModelID) }
                    }

                Button {
                    Task { await switchModel(customModelID) }
                } label: {
                    Label(gatewayStore.isSwitchingModel ? "Switching" : "Switch Gateway Model", systemImage: "arrow.left.arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aurora(.hermes, fullWidth: true))
                .disabled(gatewayStore.isSwitchingModel || customModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var modelListCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: AuroraDesign.Shape.standardCorner) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Published by Gateway", systemImage: "cpu")
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                    Spacer()
                    Text("\(options.count)")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }

                if options.isEmpty {
                    Text("Hermes has not published a model catalog yet. Restart the gateway after this update, or type an exact model id above.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(options) { option in
                        HermesModelPickerRow(
                            option: option,
                            isSelected: service.selectedModelID == option.modelID || gatewayStore.runtimeModelId == option.modelID,
                            isFavorite: service.isFavoriteModel(option)
                        ) {
                            Task { await switchModel(option.modelID) }
                        } onToggleFavorite: {
                            service.toggleFavoriteModel(option)
                            HapticBus.toggle()
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func switchModel(_ modelID: String) async {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let event = await gatewayStore.switchGatewayModel(
            modelId: trimmed,
            senderDisplayName: senderDisplayName,
            threadId: threadId
        )
        guard event != nil else {
            HapticBus.threshold()
            return
        }
        service.selectGatewayModelID(trimmed)
        HapticBus.primaryAction()
        dismiss()
    }
}

private struct HermesRuntimeSheet: View {
    @Bindable var service: HermesService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let runtimeErrorText = service.runtimeErrorText {
                    Section {
                        Text(runtimeErrorText)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.error)
                        Button {
                            Task { await service.refreshRuntime() }
                        } label: {
                            Label("Retry Runtime Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }

                Section("Models") {
                    if service.modelOptions.isEmpty {
                        Text("No models discovered")
                    } else {
                        ForEach(service.modelOptions) { option in
                            HermesModelPickerRow(
                                option: option,
                                isSelected: service.selectedModelID == option.modelID,
                                isFavorite: service.isFavoriteModel(option)
                            ) {
                                service.selectModel(option)
                                HapticBus.primaryAction()
                                dismiss()
                            } onToggleFavorite: {
                                service.toggleFavoriteModel(option)
                                HapticBus.toggle()
                            }
                        }
                    }
                }

                Section("Profiles") {
                    if service.profiles.isEmpty {
                        Text("No profiles discovered")
                    } else {
                        ForEach(service.profiles) { profile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name)
                                    .font(MobileTheme.Typography.body)
                                Text([profile.provider, profile.model].compactMap { $0 }.joined(separator: " · "))
                                    .font(MobileTheme.Typography.tiny)
                                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                            }
                        }
                    }
                }

                Section("Jobs") {
                    if service.jobs.isEmpty {
                        Text("No scheduled jobs discovered")
                    } else {
                        ForEach(service.jobs) { job in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(job.name ?? job.prompt)
                                        .font(MobileTheme.Typography.body)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(job.enabled ? job.state : "disabled")
                                        .font(MobileTheme.Typography.tiny)
                                        .foregroundStyle(job.enabled ? MobileTheme.success : MobileTheme.Colors.textMuted)
                                }
                                if let nextRunAt = job.nextRunAt {
                                    Text("Next run \(nextRunAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(MobileTheme.Typography.tiny)
                                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Hermes Runtime")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await service.refreshRuntime() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await service.refreshRuntime() }
        }
    }
}

// MARK: - Hermes Model Picker

struct HermesModelPickerSheet: View {
    @Bindable var service: HermesService
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ChatTilePreferencesStorage.userDefaultsKey) private var tilePreferencesJSON: String = ""

    /// Visible Hermes sub-providers per user preference. Empty set means
    /// "no filter" — every advertised model passes through.
    private var visibleSubProviders: Set<HermesSubProvider> {
        let prefs = ChatTilePreferences.from(jsonString: tilePreferencesJSON)
        return prefs.enabledHermesSubProviders
    }

    /// Live `HermesRuntimeModelOption` list filtered by the user's enabled
    /// sub-providers. When the relay hasn't advertised any models we render
    /// the static six-row fallback below.
    private var filteredModelOptions: [HermesRuntimeModelOption] {
        let raw = service.modelOptions
        guard !visibleSubProviders.isEmpty else { return raw }
        return raw.filter { option in
            // Drop the option only when its provider tag maps to a sub-provider
            // that the user has explicitly hidden. Unknown provider tags pass
            // through so we never silently drop advertised models.
            if let sub = HermesSubProvider.fromProviderToken(option.providerID) {
                return visibleSubProviders.contains(sub)
            }
            if let sub = HermesSubProvider.fromProviderToken(option.providerName) {
                return visibleSubProviders.contains(sub)
            }
            return true
        }
    }

    private var groupedModels: [(provider: String, options: [HermesRuntimeModelOption])] {
        Dictionary(grouping: filteredModelOptions, by: \.providerName)
            .map { (provider: $0.key, options: $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { $0.provider < $1.provider }
    }

    private var favoriteModels: [HermesRuntimeModelOption] {
        let visible = Set(filteredModelOptions.map(\.id))
        return service.favoriteModelOptions.filter { visible.contains($0.id) }
    }

    /// Sub-providers shown as static fallback rows when the relay hasn't
    /// advertised concrete models yet. Always honors the user's visibility set.
    private var staticFallbackSubProviders: [HermesSubProvider] {
        let prefs = ChatTilePreferences.from(jsonString: tilePreferencesJSON)
        return prefs.orderedVisibleHermesSubProviders
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(density: .subtle)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        currentModelCard
                        if filteredModelOptions.isEmpty {
                            staticFallbackGroup
                            emptyModelsCard
                        } else {
                            if !favoriteModels.isEmpty {
                                favoriteGroup
                            }
                            ForEach(groupedModels, id: \.provider) { group in
                                providerGroup(group)
                            }
                        }
                    }
                    .padding(AuroraDesign.Layout.cardInset)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Switch Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await service.refreshRuntime() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh Hermes models")
                }
            }
            .task { await service.refreshRuntime() }
        }
    }

    private var currentModelCard: some View {
        let option = service.selectedModelOption
        let provider = option?.agentProvider ?? hermesAgentProvider(for: service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "hermes")
        let title = option?.displayName ?? service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "Automatic"
        let subtitle = option?.providerName ?? provider.displayName
        return AuroraGlassCard(variant: .hermes, cornerRadius: 18) {
            HStack(spacing: 12) {
                UnifiedProviderLogoView(provider: provider, size: 42, useFallbackColor: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(MobileTheme.success)
            }
        }
    }

    private var emptyModelsCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MobileTheme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No live models yet")
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("Pick a sub-provider above to route Hermes through it. The relay will fill in concrete model names once it reports them.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Static six-row fallback rendered when the relay hasn't advertised any
    /// concrete models. Tapping a row selects the sub-provider's default
    /// model hint so Hermes routes through that sub-provider until the relay
    /// reports something more specific.
    private var staticFallbackGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MobileTheme.hermesAureate)
                Text("Hermes sub-providers")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer()
                Text("\(staticFallbackSubProviders.count)")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            ForEach(staticFallbackSubProviders) { sub in
                let option = HermesRuntimeModelOption(
                    providerID: sub.providerToken,
                    providerName: sub.displayName,
                    modelID: sub.defaultModelHint,
                    displayName: sub.displayName
                )
                HermesModelPickerRow(
                    option: option,
                    isSelected: service.selectedModelID == option.modelID,
                    isFavorite: service.isFavoriteModel(option)
                ) {
                    service.selectModel(option)
                    HapticBus.primaryAction()
                    dismiss()
                } onToggleFavorite: {
                    service.toggleFavoriteModel(option)
                    HapticBus.toggle()
                }
            }
        }
    }

    private func providerGroup(_ group: (provider: String, options: [HermesRuntimeModelOption])) -> some View {
        let provider = hermesAgentProvider(for: group.options.first?.providerID ?? group.provider)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                UnifiedProviderLogoView(provider: provider, size: 24, useFallbackColor: true)
                Text(group.provider)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer()
                Text("\(group.options.count)")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            ForEach(group.options) { option in
                HermesModelPickerRow(
                    option: option,
                    isSelected: service.selectedModelID == option.modelID,
                    isFavorite: service.isFavoriteModel(option)
                ) {
                    service.selectModel(option)
                    HapticBus.primaryAction()
                    dismiss()
                } onToggleFavorite: {
                    service.toggleFavoriteModel(option)
                    HapticBus.toggle()
                }
            }
        }
    }

    private var favoriteGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MobileTheme.amber)
                Text("Favorites")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer()
                Text("\(favoriteModels.count)")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            ForEach(favoriteModels) { option in
                HermesModelPickerRow(
                    option: option,
                    isSelected: service.selectedModelID == option.modelID,
                    isFavorite: true
                ) {
                    service.selectModel(option)
                    HapticBus.primaryAction()
                    dismiss()
                } onToggleFavorite: {
                    service.toggleFavoriteModel(option)
                    HapticBus.toggle()
                }
            }
        }
    }
}

struct HermesModelPickerRow: View {
    let option: HermesRuntimeModelOption
    let isSelected: Bool
    let isFavorite: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    UnifiedProviderLogoView(provider: option.agentProvider, size: 30, useFallbackColor: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.displayName)
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Text(option.modelID)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .lineLimit(1)
                        if let detail = option.liveCatalogDetailText {
                            Text(detail)
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(option.isRouteEligible ? MobileTheme.Colors.textSecondary : MobileTheme.error)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if !option.isRouteEligible {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(MobileTheme.error)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(MobileTheme.success)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use \(option.displayName)")
            .accessibilityValue(isSelected ? "Selected" : option.providerName)
            .disabled(!option.isRouteEligible)
            .opacity(option.isRouteEligible ? 1 : 0.62)

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isFavorite ? MobileTheme.amber : MobileTheme.Colors.textMuted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(MobileTheme.Colors.surfaceElevated.opacity(0.75)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Remove \(option.displayName) from favorites" : "Add \(option.displayName) to favorites")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? MobileTheme.hermesAureate.opacity(0.16) : MobileTheme.Colors.surfaceElevated.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? MobileTheme.hermesAureate.opacity(0.6) : MobileTheme.Colors.border.opacity(0.45), lineWidth: isSelected ? 1 : 0.5)
        )
    }
}

extension HermesService {
    var selectedModelOption: HermesRuntimeModelOption? {
        guard let selectedModelID else { return nil }
        let resolved = AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(
            selectedModelID,
            in: modelOptions
        ) ?? selectedModelID
        return modelOptions.first { $0.modelID == resolved }
    }
}

extension HermesRuntimeModelOption {
    var agentProvider: AgentProvider {
        hermesAgentProvider(for: [providerID, providerName, modelID].joined(separator: " "))
    }
}

func hermesAgentProvider(for raw: String) -> AgentProvider {
    let lower = raw.lowercased()
    if lower.contains("openai") || lower.contains("gpt") { return .openAI }
    if lower.contains("anthropic") || lower.contains("claude") { return .claudeCode }
    if lower.contains("minimax") || lower.contains("abab") { return .minimax }
    if lower.contains("zai") || lower.contains("z.ai") || lower.contains("glm") { return .zai }
    if lower.contains("kimi") || lower.contains("moonshot") { return .kimi }
    if lower.contains("deepseek") { return .deepSeek }
    if lower.contains("antigravity") { return .antigravity }
    if lower.contains("grok") || lower.contains("xai") { return .xAI }
    if lower.contains("google") || lower.contains("gemini") { return .geminiCLI }
    if lower.contains("meta") || lower.contains("llama") || lower.contains("qwen") { return .ollama }
    if lower.contains("codex") { return .codex }
    if lower.contains("hermes") { return .hermes }
    return .openClaw
}

// MARK: - Hermes Message Bubble

struct HermesMessageBubble: View {
    let message: HermesChatMessage
    var showTPS: Bool = false
    /// When true, assistant text is rendered through `PretextRichBubble` so
    /// `@mentions` and `` `code spans` `` get inline chips and pretext line
    /// breaking. Falls back to native `Text` if the engine isn't ready.
    var usePretextRendering: Bool = true
    /// Display mode: rich agent bubbles or raw CLI output.
    var viewMode: ChatViewMode = .agent
    /// Optional retry callback. The container passes a non-nil value
    /// only for the most recent assistant turn whose outcome supports
    /// retry — the bubble renders the inline "Try again" pill in that
    /// case. Earlier turns and successful replies pass nil (no pill).
    var onRetry: (() -> Void)? = nil

    @State private var permissionSheetItem: SystemPermissionItem?
    @State private var permissionStore = SystemPermissionInboxStore.shared

    var isUser: Bool { message.role == .user }

    @ViewBuilder
    fileprivate var systemPermissionPillIfNeeded: some View {
        let threadID = HermesService.shared.selectedSessionID ?? ""
        if !threadID.isEmpty,
           let item = permissionStore.latestItem(forThread: threadID),
           item.originatingToolCallId == message.id
            || message.toolCalls.contains(where: { $0.id == item.originatingToolCallId }) {
            SystemPermissionInlinePill(item: item) {
                permissionSheetItem = item
            }
            .padding(.leading, 6)
            .padding(.top, 4)
            .sheet(item: $permissionSheetItem) { sheetItem in
                if let sender = makeSystemPermissionGrantSender() {
                    SystemPermissionGrantSheet(item: sheetItem, sender: sender)
                } else {
                    SystemPermissionGrantSheet(
                        item: sheetItem,
                        sender: SystemPermissionGrantSender(senderFactory: { nil })
                    )
                }
            }
        }
    }

    private func makeSystemPermissionGrantSender() -> SystemPermissionGrantSender? {
        // Resolve via the live AgentWatchOverlaySingleton so the sender
        // shares the same Computer Use control stream + signing key that
        // every other phone-control surface uses.
        let factory: SystemPermissionGrantSender.SenderFactory = {
            AgentWatchOverlaySingleton.shared.activePhoneControlSender()
        }
        return SystemPermissionGrantSender(senderFactory: factory)
    }

    var body: some View {
        if viewMode == .cli {
            iosCLIMessageRow
        } else {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachments.isEmpty {
                        ChatBubbleAttachmentStrip(attachments: message.attachments)
                            .frame(maxWidth: 270)
                    }
                    if !message.text.isEmpty {
                        userBubble
                    }
                }
            } else {
                assistantStack
                Spacer(minLength: 48)
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
        }
    }

    // MARK: - CLI View

    @ViewBuilder
    private var iosCLIMessageRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isUser {
                HStack(alignment: .top, spacing: 4) {
                    Text(">")
                        .font(MobileTheme.Typography.mono)
                        .foregroundStyle(MobileTheme.Colors.success)
                        .frame(width: 14, alignment: .trailing)
                    Text(message.text)
                        .font(MobileTheme.Typography.monoSmall)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .top, spacing: 4) {
                    Text("☿")
                        .font(MobileTheme.Typography.mono)
                        .foregroundStyle(MobileTheme.hermesAureate)
                        .frame(width: 14, alignment: .trailing)
                    Text(iosCLITranscriptText)
                        .font(MobileTheme.Typography.monoSmall)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private var iosCLITranscriptText: String {
        let toolLines = message.toolCalls.map { tc in
            "⟨\(tc.name)\(tc.detail != nil ? ": \(tc.detail!)" : "")⟩"
        }
        if toolLines.isEmpty { return message.text }
        return ([message.text] + toolLines).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var userBubble: some View {
        Text(message.text)
            .font(MobileTheme.Typography.body)
            .foregroundStyle(MobileTheme.Colors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                userBubbleShape
                    .fill(MobileTheme.Colors.surfaceElevated.opacity(0.85))
            )
            .overlay(
                userBubbleShape
                    .stroke(MobileTheme.chatUserStroke, lineWidth: 1)
            )
    }

    @ViewBuilder
    private var assistantStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            modelBadge
                .padding(.leading, 6)

            if message.outcome != .normal {
                outcomeBadge
                    .padding(.leading, 6)
                    .padding(.bottom, 2)
            }

            if !message.text.isEmpty || message.toolCalls.isEmpty {
                assistantTextBody
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        assistantBubbleShape
                            .fill(bubbleFill)
                    )
                    .overlay(
                        assistantBubbleShape
                            .stroke(bubbleStroke, lineWidth: bubbleStrokeWidth)
                    )
                    .overlay {
                        if !message.isError && message.outcome == .normal {
                            MercuryShimmerOverlay()
                                .clipShape(assistantBubbleShape)
                        }
                    }
            }

            if let onRetry, message.outcome.supportsRetry {
                retryPill(onRetry: onRetry)
                    .padding(.leading, 6)
                    .padding(.top, 2)
            }

            if !message.toolCalls.isEmpty {
                UnifiedToolCallAccordion(calls: unifiedToolCalls, accent: .hermes)
            }

            systemPermissionPillIfNeeded

            // Hermes Square §6.6 — typed UI cards the agent emitted on
            // this turn render inline above the tpsFooter. Host-drawn:
            // the agent never touches our view tree; the envelope decoder
            // enforces the 2 MB per-card budget.
            if !message.cards.isEmpty {
                cardsStrip
            }

            if !sourceLinks.isEmpty {
                sourceLinksFooter
                    .padding(.leading, 6)
                    .padding(.top, 4)
            }

            tpsFooter
        }
    }

    private var cardsStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.cards) { envelope in
                CardEnvelopeView(envelope: envelope, agentAccent: DesignSystemColors.ember)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Tool Calls

    /// Maps this turn's Hermes tool calls into the shared display model. The
    /// most recent call (last in the array) becomes the collapsed row; the
    /// live call pulses while the turn is still streaming.
    private var unifiedToolCalls: [UnifiedToolCallDisplay] {
        let lastID = message.toolCalls.last?.id
        return message.toolCalls.map { tc in
            UnifiedToolCallDisplay(
                id: tc.id,
                name: tc.name,
                statusRaw: tc.status,
                detail: tc.detail,
                arguments: tc.arguments,
                isRunning: message.isStreaming && tc.id == lastID
            )
        }
    }

    /// Honest "via Hermes" header. Renders one of three states:
    /// - `via Hermes · gpt-5.5` — server confirmed model (no asterisk needed).
    /// - `via Hermes · asked gpt-5.5 → got minimax-m2.7` — server routed to a
    ///   different model than the user requested.
    /// - `via Hermes · gpt-5.5 (requested)` — server never confirmed which
    ///   model it ran. We say "requested" so the user knows we're echoing
    ///   their pick rather than asserting a fact.
    @ViewBuilder
    private var modelBadge: some View {
        HStack(spacing: 5) {
            HermesLiveGlyph(size: 16, isLive: message.isStreaming)
            Text(modelBadgeText)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(MobileTheme.hermesAureate)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(modelBadgeAccessibilityLabel)
    }

    private var modelBadgeText: String {
        let requested = message.requestedModelID?.nilIfBlank
        let response = message.responseModelID?.nilIfBlank

        if message.serverRoutedToDifferentModel,
           let requested,
           let response {
            return "via Hermes · asked \(requested) → got \(response)"
        }
        if let response {
            return "via Hermes · \(response)"
        }
        if let requested {
            return "via Hermes · \(requested) (requested)"
        }
        if let fallback = message.modelName?.nilIfBlank {
            return "via Hermes · \(fallback) (requested)"
        }
        return "via Hermes"
    }

    private var modelBadgeAccessibilityLabel: String {
        if message.serverRoutedToDifferentModel,
           let requested = message.requestedModelID?.nilIfBlank,
           let response = message.responseModelID?.nilIfBlank {
            return "Hermes routed: requested \(requested), server ran \(response)."
        }
        if let response = message.responseModelID?.nilIfBlank {
            return "Hermes ran model \(response)."
        }
        if let requested = message.requestedModelID?.nilIfBlank {
            return "Hermes was requested \(requested). Server did not confirm the model."
        }
        return "Hermes assistant message."
    }

    @ViewBuilder
    private var tpsFooter: some View {
        if shouldRenderTPS, let display = message.tokensPerSecondDisplayText {
            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .bold))
                Text(display)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                if message.isTokensPerSecondEstimated {
                    Text("est.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
            .foregroundStyle(MobileTheme.Colors.textSecondary)
            .padding(.leading, 6)
            .padding(.top, 2)
            .frame(minHeight: 16, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tpsAccessibilityLabel(display))
        } else if shouldRenderBufferedNotice {
            // Stream was buffered by a relay/proxy so wall-clock would lie.
            // Tell the user we're hiding the rate instead of fabricating one.
            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .bold))
                Text("rate hidden — buffered stream")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(MobileTheme.Colors.textMuted)
            .padding(.leading, 6)
            .padding(.top, 2)
            .frame(minHeight: 16, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Generation rate hidden because the stream was buffered.")
        }
    }

    private var shouldRenderTPS: Bool {
        showTPS && !isUser && !message.isError
    }

    /// Surface the buffered notice only when (a) the user opted into TPS,
    /// (b) the server gave us a token count and (c) we deliberately suppressed
    /// the rate because the wall-clock was implausibly short.
    private var shouldRenderBufferedNotice: Bool {
        showTPS
            && !isUser
            && !message.isError
            && message.tokensPerSecond == nil
            && message.outputTokenCount.map { $0 > 0 } ?? false
            && message.generationDurationSource == .bufferedWallClock
    }

    private var sourceLinks: [HermesSourceLink] {
        guard !isUser, !message.text.isEmpty else { return [] }
        return HermesSourceLinkExtractor.extract(from: message.text)
    }

    private var sourceLinksFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .bold))
                Text("Sources")
                    .font(MobileTheme.Typography.tiny.weight(.semibold))
            }
            .foregroundStyle(MobileTheme.Colors.textMuted)

            ForEach(sourceLinks) { source in
                Link(destination: source.url) {
                    HStack(spacing: 7) {
                        Image(systemName: "safari")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MobileTheme.hermesAureate)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.title)
                                .font(MobileTheme.Typography.caption.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(source.displayHost)
                                .font(MobileTheme.Typography.tiny)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(MobileTheme.Colors.surfaceElevated.opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(MobileTheme.Colors.border.opacity(0.28), lineWidth: 0.7)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open source: \(source.title)")
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(MobileTheme.Colors.border.opacity(0.24), lineWidth: 0.7)
        )
    }

    private func tpsAccessibilityLabel(_ display: String) -> String {
        let prefix: String
        switch message.generationDurationSource {
        case .providerEvalDuration: prefix = ""
        case .wallClock:            prefix = "Estimated "
        case .bufferedWallClock:    prefix = "Estimated "
        case nil:                   prefix = "Estimated "
        }
        return "\(prefix)Generation speed \(display)"
    }

    /// Routes to either pretext rich rendering or plain native `Text` based on
    /// the user's preference and whether the message is in an error state.
    /// Streaming and error messages always use plain Text — streaming because
    /// pretext can't keep up with chunk-by-chunk text mutation, error because
    /// the contract is "render exactly what the server returned".
    @ViewBuilder
    private var assistantTextBody: some View {
        if usePretextRendering, !message.isError, !message.isStreaming {
            // Completed rich turns should be sized by the same atom/link
            // renderer that draws them. The generic streaming wrapper
            // measures plain text, which overestimates rich lines and leaves
            // the dead space shown in the chat bubble.
            HermesRichBubble(
                text: HermesSourceLinkExtractor.collapseExternalLinksForDisplay(in: message.text),
                baseColor: MobileTheme.Colors.textPrimary,
                mentionColor: MobileTheme.hermesAureate,
                codeColor: MobileTheme.Colors.textPrimary,
                codeBackground: MobileTheme.Colors.surfaceElevated,
                lineHeight: 21
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if usePretextRendering, !message.isError, message.isStreaming {
            // In-flight — plain Text inside StreamingBubble so the bubble's
            // outer frame animates smoothly even while text mutates.
            StreamingBubble(
                text: message.text,
                isStreaming: true,
                isError: false,
                baseSize: 15,
                lineHeight: 21
            ) {
                Text(message.text)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(message.text)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(message.isError ? MobileTheme.Colors.error : MobileTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Bubble background tint, keyed off `outcome`. Refusals and the
    /// reasoning-channel fallback get a soft tinted background so the
    /// user sees they're not reading a normal answer; hard errors get
    /// a faint red wash; everything else uses the standard surface.
    private var bubbleFill: AnyShapeStyle {
        switch message.outcome {
        case .normal:
            if message.isError {
                return AnyShapeStyle(MobileTheme.error.opacity(0.06))
            }
            return AnyShapeStyle(MobileTheme.Colors.surface.opacity(0.85))
        case .refusal, .reasoningFallback:
            return AnyShapeStyle(MobileTheme.hermesAureate.opacity(0.07))
        case .lengthCap, .contentFilter, .toolCallNoFollowUp, .empty:
            return AnyShapeStyle(MobileTheme.error.opacity(0.06))
        }
    }

    private var bubbleStroke: AnyShapeStyle {
        if message.isError {
            return AnyShapeStyle(MobileTheme.error)
        }
        switch message.outcome {
        case .normal:
            return AnyShapeStyle(AuroraDesign.Gradients.mercuryFoil)
        case .refusal, .reasoningFallback:
            return AnyShapeStyle(MobileTheme.hermesAureate.opacity(0.55))
        case .lengthCap, .contentFilter, .toolCallNoFollowUp, .empty:
            return AnyShapeStyle(MobileTheme.error)
        }
    }

    private var bubbleStrokeWidth: CGFloat {
        message.isError ? 1.5 : 1
    }

    /// Inline tag rendered above the bubble for non-`.normal`
    /// outcomes. Symbol + label so power users can tell at a glance
    /// why the model didn't produce a normal reply. Returns `nil`
    /// for `.normal` so the call site can skip rendering entirely.
    @ViewBuilder
    private var outcomeBadge: some View {
        if let label = message.outcome.badgeLabel,
           let symbol = message.outcome.badgeSymbol {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                Text(label)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(outcomeBadgeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(outcomeBadgeColor.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .stroke(outcomeBadgeColor.opacity(0.45), lineWidth: 0.5)
            )
            .accessibilityLabel(Text("Reply outcome: \(label)"))
        }
    }

    private var outcomeBadgeColor: Color {
        switch message.outcome {
        case .normal: return MobileTheme.Colors.textSecondary
        case .refusal, .reasoningFallback: return MobileTheme.hermesAureate
        case .lengthCap, .contentFilter, .toolCallNoFollowUp, .empty: return MobileTheme.error
        }
    }

    /// Inline retry pill rendered for the most recent assistant turn
    /// when its outcome supports retry. Tactile (haptic on tap),
    /// styled to match the bubble context — soft for soft outcomes,
    /// red for hard errors.
    @ViewBuilder
    private func retryPill(onRetry: @escaping () -> Void) -> some View {
        Button {
            HapticBus.send()
            onRetry()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                Text("Try again")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(outcomeBadgeColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(outcomeBadgeColor.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .stroke(outcomeBadgeColor.opacity(0.55), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Try again")
        .accessibilityHint("Re-sends your last message to Hermes.")
    }

    private var userBubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 18,
                bottomLeading: 18,
                bottomTrailing: 6,
                topTrailing: 18
            ),
            style: .continuous
        )
    }

    private var assistantBubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 18,
                bottomLeading: 6,
                bottomTrailing: 18,
                topTrailing: 18
            ),
            style: .continuous
        )
    }
}

// MARK: - Provider Status Globe View

private struct ProviderStatusGlobeView: View {
    let provider: AgentProvider
    let isReachable: Bool
    let size: CGFloat = 24

    @Environment(\.mobileBackgroundVisibility) private var backgroundVisibility
    @Environment(\.scenePhase) private var scenePhase
    @State private var animateGlow = false

    var body: some View {
        ZStack {
            // Animated Glow Background (Perfectly Centered)
            Circle()
                .fill((isReachable ? DesignSystemColors.primary(for: provider) : DesignSystemColors.error).opacity(0.2))
                .frame(width: size * 1.4, height: size * 1.4)
                .scaleEffect(shouldAnimateGlow && animateGlow ? 1.25 : 0.85)
                .blur(radius: 2)
                .animation(
                    .easeInOut(duration: 1.8)
                    .repeatForever(autoreverses: true),
                    value: animateGlow
                )

            // Globe icon with provider or offline color gradient (Perfectly Centered)
            Image(systemName: "globe")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: isReachable ? [
                            DesignSystemColors.primary(for: provider),
                            DesignSystemColors.accent(for: provider)
                        ] : [
                            DesignSystemColors.error,
                            DesignSystemColors.error.opacity(0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(
                    color: (isReachable ? DesignSystemColors.primary(for: provider) : DesignSystemColors.error).opacity(0.45),
                    radius: isReachable ? 4 : 1,
                    x: 0,
                    y: 1
                )
                .overlay(
                    // Status Indicator Badge at bottom trailing of the globe, offset outward
                    Circle()
                        .fill(isReachable ? MobileTheme.success : MobileTheme.warning)
                        .frame(width: size * 0.38, height: size * 0.38)
                        .overlay(
                            Circle()
                                .stroke(MobileTheme.Colors.background, lineWidth: 1.2)
                        )
                        .modifier(BreathingDot(active: isReachable))
                        .offset(x: 2.5, y: 2.5),
                    alignment: .bottomTrailing
                )
        }
        .frame(width: size, height: size)
        .onAppear {
            animateGlow = shouldAnimateGlow
        }
        .onChange(of: shouldAnimateGlow) { _, shouldAnimate in
            animateGlow = shouldAnimate
        }
    }

    private var shouldAnimateGlow: Bool {
        MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: backgroundVisibility,
            scenePhaseActive: scenePhase == .active
        )
    }
}

// MARK: - Breathing Dot

private struct BreathingDot: ViewModifier {
    let active: Bool
    @Environment(\.mobileBackgroundVisibility) private var backgroundVisibility
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shouldAnimate && phase ? 1.5 : 1.0)
            .opacity(shouldAnimate && phase ? 0.55 : 1.0)
            .animation(shouldAnimate ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : .default, value: phase)
            .onAppear { phase = shouldAnimate }
            .onChange(of: shouldAnimate) { _, shouldAnimate in
                phase = shouldAnimate
            }
    }

    private var shouldAnimate: Bool {
        active && MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: backgroundVisibility,
            scenePhaseActive: scenePhase == .active
        )
    }
}

// MARK: - String helpers

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Dynamic Status Widget

private struct HermesDynamicStatusWidget: View {
    let provider: AgentProvider
    let isReachable: Bool
    let isRefreshing: Bool
    let refreshAction: () -> Void

    @Environment(\.mobileBackgroundVisibility) private var backgroundVisibility
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeState: WidgetState = .globe
    @State private var animateGlow = false

    enum WidgetState: Int, CaseIterable {
        case globe
        case model
        case refresh

        func next(isRefreshing: Bool) -> WidgetState {
            switch self {
            case .globe:
                return .model
            case .model:
                return isRefreshing ? .refresh : .globe
            case .refresh:
                return .globe
            }
        }
    }

    private var stateBorderColors: [Color] {
        if !isReachable {
            return [DesignSystemColors.error.opacity(0.48), DesignSystemColors.error.opacity(0.18)]
        }
        switch activeState {
        case .globe:
            return [
                DesignSystemColors.primary(for: provider).opacity(0.45),
                DesignSystemColors.accent(for: provider).opacity(0.2)
            ]
        case .model:
            return [
                DesignSystemColors.primary(for: provider).opacity(0.45),
                DesignSystemColors.accent(for: provider).opacity(0.2)
            ]
        case .refresh:
            return [
                MobileTheme.hermesAureate.opacity(0.6),
                MobileTheme.hermesAureate.opacity(0.24)
            ]
        }
    }

    private var stateShadowColor: Color {
        if !isReachable {
            return DesignSystemColors.error.opacity(0.35)
        }
        switch activeState {
        case .globe:
            return DesignSystemColors.primary(for: provider).opacity(0.25)
        case .model:
            return DesignSystemColors.primary(for: provider).opacity(0.25)
        case .refresh:
            return MobileTheme.hermesAureate.opacity(0.25)
        }
    }

    var body: some View {
        ZStack {
            if activeState == .globe {
                ProviderStatusGlobeView(provider: provider, isReachable: isReachable)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.75)),
                        removal: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.75))
                    ))
            } else if activeState == .model {
                modelBadge
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.75)),
                        removal: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.75))
                    ))
            } else {
                refreshBadge
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.75)),
                        removal: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.75))
                    ))
            }
        }
        .frame(width: 34, height: 34)
        .background(
            Circle()
                .fill(MobileTheme.Colors.surface.opacity(0.65))
                .shadow(color: stateShadowColor, radius: 4, x: 0, y: 0.8)
        )
        .overlay(
            Circle()
                .stroke(
                    LinearGradient(
                        colors: stateBorderColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
        )
        .onAppear {
            if isRefreshing {
                activeState = .refresh
            }
        }
        .task(id: statusWidgetTickerKey) { await runStatusWidgetTicker() }
        .onChange(of: shouldUpdateStatusWidget) { _, shouldUpdate in
            animateGlow = shouldUpdate
        }
        .onChange(of: isRefreshing) { _, refreshing in
            if refreshing {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                    activeState = .refresh
                }
            } else {
                if activeState == .refresh {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                        activeState = .globe
                    }
                }
            }
        }
    }

    private var shouldUpdateStatusWidget: Bool {
        MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: backgroundVisibility,
            scenePhaseActive: scenePhase == .active
        )
    }

    private var statusWidgetTickerKey: String {
        "\(shouldUpdateStatusWidget)-\(isRefreshing)"
    }

    private func runStatusWidgetTicker() async {
        guard shouldUpdateStatusWidget else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled, shouldUpdateStatusWidget else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.76, blendDuration: 0)) {
                    activeState = activeState.next(isRefreshing: isRefreshing)
                }
            }
        }
    }

    private var modelBadge: some View {
        ZStack {
            // Pulse glow for model
            Circle()
                .fill(
                    (isReachable ? DesignSystemColors.primary(for: provider) : DesignSystemColors.error)
                        .opacity(0.15)
                )
                .frame(width: 28, height: 28)
                .scaleEffect(animateGlow ? 1.15 : 0.9)
                .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: animateGlow)
                .onAppear { animateGlow = shouldUpdateStatusWidget }

            UnifiedProviderLogoView(provider: provider, size: 20, useFallbackColor: true)
                .grayscale(isReachable ? 0.0 : 0.6)
                .opacity(isReachable ? 1.0 : 0.65)
        }
    }

    private var refreshBadge: some View {
        ZStack {
            Circle()
                .fill(MobileTheme.hermesAureate.opacity(0.12))
                .frame(width: 28, height: 28)
                .scaleEffect(animateGlow ? 1.15 : 0.9)
                .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: animateGlow)
                .onAppear { animateGlow = shouldUpdateStatusWidget }

            SpinningRefreshIcon(isRefreshing: isRefreshing)
        }
    }
}

private struct SpinningRefreshIcon: View {
    let isRefreshing: Bool
    @Environment(\.mobileBackgroundVisibility) private var backgroundVisibility
    @Environment(\.scenePhase) private var scenePhase
    @State private var spinDegree = 0.0

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(MobileTheme.hermesAureate)
            .rotationEffect(.degrees(spinDegree))
            .id(shouldSpin)
            .onAppear { syncSpinState() }
            .onChange(of: shouldSpin) { _, _ in
                syncSpinState()
            }
    }

    private var shouldSpin: Bool {
        isRefreshing && MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: backgroundVisibility,
            scenePhaseActive: scenePhase == .active
        )
    }

    private func syncSpinState() {
        guard shouldSpin else {
            spinDegree = 0.0
            return
        }
        spinDegree = 0.0
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            spinDegree = 360.0
        }
    }
}
