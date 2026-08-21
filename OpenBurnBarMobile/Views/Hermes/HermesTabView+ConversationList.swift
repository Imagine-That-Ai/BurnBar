import SwiftUI
import AVFoundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// The conversation list view and its row/transcript subviews.
// Extracted from HermesTabView.swift (god-file decomposition) — same module, verbatim.

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
            isCLIMode: false
        )
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
                    route: presented.route
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

struct OnDeviceHermesRow: View {
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
                Text(HermesAtomParser.plainText(thread.preview))
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

struct ConversationRow: View {
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
            Text(FriendlyModelName.format(session.model?.nilIfBlank ?? "Hermes"))
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

struct HermesLibraryRow: View {
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

            Text(HermesAtomParser.plainText(session.preview))
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

struct HermesLibraryTranscriptSheet: View {
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
