import SwiftUI
import OpenBurnBarCore
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
}

private enum HermesChatLayout {
    static let hiddenNavigationTrayReserve: CGFloat = 70
    static let composerBottomPadding: CGFloat = 8
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
                Text("For iPhone and iPad, Hermes works by talking to your Mac's local runtime directly on LAN/VPN or through your private Remote Relay.")
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

    @State private var showConnectionSheet = false
    @State private var showRuntimeSheet = false
    @State private var showModelPicker = false
    @State private var showSetupWizard = false
    @State private var didAutoPresentSetupWizard = false
    @State private var libraryStore = HermesCloudLibraryStore()
    @State private var historyStore: MobileChatHistoryStore = .shared
    @State private var selectedLibrarySession: HermesLibrarySession?
    @State private var presentedChatRoute: PresentedHermesChatRoute?
    @AppStorage(HermesMobileSetupWizardState.completionKey) private var hasCompletedHermesSetupWizard = false

    init(service: HermesService, dashboardSnapshot: DashboardStore? = nil) {
        self.service = service
        self.dashboardSnapshot = dashboardSnapshot
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showConnectionSheet = true
                    } label: {
                        Label("Connections", systemImage: "network")
                    }
                    Button {
                        showModelPicker = true
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
                    Divider()
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(MobileTheme.hermesAureate)
                }
            }
        }
        .sheet(isPresented: $showConnectionSheet) {
            HermesConnectionSheet(service: service)
        }
        .sheet(isPresented: $showRuntimeSheet) {
            HermesRuntimeSheet(service: service)
        }
        .sheet(isPresented: $showModelPicker) {
            AssistantModelPickerSheet(
                runtime: .hermes,
                hermesService: service,
                piService: PiService.shared
            )
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
        .onChange(of: service.isReachable) { _, _ in
            reconcileSetupWizardCompletion()
        }
        .onChange(of: service.selectedConnection.id) { _, _ in
            reconcileSetupWizardCompletion()
        }
        .onChange(of: service.suggestedRelayConnection?.id) { _, _ in
            reconcileSetupWizardCompletion()
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
            isReachable: service.isReachable,
            selectedConnection: service.selectedConnection,
            suggestedRelayConnection: service.suggestedRelayConnection
        )
    }

    private func reconcileSetupWizardCompletion() {
        guard hasUsableHermesSetup else { return }
        hasCompletedHermesSetupWizard = true
        showSetupWizard = false
    }

    @MainActor
    private func consumePendingHermesPrompt() async {
        guard let pending = AssistantPendingPrompt.shared.consume(.hermes),
              !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        // Small delay so the conversation list has settled before we
        // create a new session and start streaming.
        try? await Task.sleep(nanoseconds: 250_000_000)
        service.sendMessage(pending)
    }

    // MARK: - Brand Header

    private var brandHeader: some View {
        let lens = AssistantModelLens(hermesService: service, piService: PiService.shared)
        let snapshot = lens.snapshot(for: .hermes)
        return HStack(spacing: 12) {
            Button {
                showModelPicker = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    UnifiedProviderLogoView(provider: hermesAgentProvider(for: "hermes"), size: 34)
                    Circle()
                        .fill(service.isReachable ? MobileTheme.success : MobileTheme.warning)
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
            Button {
                showConnectionSheet = true
            } label: {
                Image(systemName: "network")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(MobileTheme.hermesAureate)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(MobileTheme.Colors.surface.opacity(0.65)))
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
                .font(.system(size: 10, weight: .bold))
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

    @State private var input: String = ""
    @State private var showClearConfirm = false
    @State private var showConnectionSheet = false
    @State private var showRuntimeSheet = false
    @State private var showModelPicker = false
    @State private var showSetupWizard = false
    @State private var didAutoPresentSetupWizard = false
    @AppStorage(HermesMobileSetupWizardState.completionKey) private var hasCompletedHermesSetupWizard = false
    @AppStorage(HermesMobileChatPreferences.showMessageTPSKey) private var showMessageTPS = false
    @AppStorage(HermesMobileChatPreferences.usePretextRenderingKey) private var usePretextRendering = true
    @State private var showPretextPlayground = false
    @State private var atomRouter = HermesAtomRouter()
    @State private var pendingAttachments: [HermesAttachment] = []
    @State private var attachmentImportError: String?
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
    private var visibleMessages: [HermesChatMessage] {
        service.messages.filter { $0.role != .tool }
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()
            VStack(spacing: 0) {
                connectionPill
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.bottom, 6)

                relaySuggestionBanner
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.bottom, service.hasPendingRelaySuggestion ? 8 : 0)

                runtimeRail
                    .padding(.bottom, 8)

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
                                        usePretextRendering: usePretextRendering
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
            // AuroraNavigationTray needs a reserve only while the keyboard is
            // hidden; using a safe-area spacer avoids shifting the whole chat
            // stack during UIKit's keyboard animation.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: inputFocused ? 0 : HermesChatLayout.hiddenNavigationTrayReserve)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
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
                    Divider()
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
                    Divider()
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(MobileTheme.hermesAureate)
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done", action: dismissKeyboard)
            }
        }
        .alert("Clear chat?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                withAnimation(AuroraDesign.Motion.auroraSpring) { service.clearChat() }
            }
        } message: {
            Text("This removes the entire conversation history.")
        }
        .sheet(isPresented: $showConnectionSheet) {
            HermesConnectionSheet(service: service)
        }
        .sheet(isPresented: $showRuntimeSheet) {
            HermesRuntimeSheet(service: service)
        }
        .sheet(isPresented: $showModelPicker) {
            AssistantModelPickerSheet(
                runtime: .hermes,
                hermesService: service,
                piService: PiService.shared
            )
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
        .sheet(isPresented: $showCameraSheet) {
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
        .alert("Couldn't attach file", isPresented: Binding(
            get: { attachmentImportError != nil },
            set: { if !$0 { attachmentImportError = nil } }
        )) {
            Button("OK", role: .cancel) { attachmentImportError = nil }
        } message: {
            Text(attachmentImportError ?? "")
        }
        .sheet(item: Binding(
            get: { atomRouter.pending },
            set: { atomRouter.pending = $0 }
        )) { pending in
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
        }
        .onDisappear {
            // Be explicit so the service drops its reference promptly
            // even if `atomRouter` doesn't deallocate immediately (the
            // chat list view stays in the navigation stack).
            service.setToolAtomNavigator(nil)
        }
        .onAppear {
            presentSetupWizardIfNeeded()
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
            isReachable: service.isReachable,
            selectedConnection: service.selectedConnection,
            suggestedRelayConnection: service.suggestedRelayConnection
        )
    }

    private func reconcileSetupWizardCompletion() {
        guard hasUsableHermesSetup else { return }
        hasCompletedHermesSetupWizard = true
        showSetupWizard = false
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
        service.sendMessage(pending)
    }

    private var navigationTitleText: String {
        switch route {
        case .new:
            return service.selectedSessionID.map(service.sessionTitle(for:)) ?? "New Conversation"
        case .existing(let id):
            return service.sessionTitle(for: id)
        }
    }

    // MARK: - Connection Pill

    private var connectionPill: some View {
        Button {
            showConnectionSheet = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(service.isReachable ? MobileTheme.success : MobileTheme.warning)
                    .frame(width: 8, height: 8)
                    .modifier(BreathingDot(active: service.isReachable))
                Text(connectionStatusText)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(service.isReachable ? MobileTheme.success : MobileTheme.warning)
                Spacer()
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(service.isReachable ? MobileTheme.success : MobileTheme.warning)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .auroraGlass(.compact, cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }

    private var connectionStatusText: String {
        if !service.isReachable,
           service.selectedConnection.id == HermesConnectionRecord.localDefault.id,
           let relay = service.suggestedRelayConnection {
            return "Local offline · relay available · \(relay.displayName)"
        }
        let name = service.selectedConnection.displayName
        return service.isReachable ? "Hermes online · \(name)" : "Hermes offline · \(name)"
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
                    showModelPicker = true
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
                .font(.system(size: 10, weight: .bold))
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
        let label = option?.displayName ?? service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "Choose model"
        let provider = option?.agentProvider ?? hermesAgentProvider(for: service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "hermes")
        return HStack(spacing: 6) {
            UnifiedProviderLogoView(provider: provider, size: 18, useFallbackColor: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .lineLimit(1)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                Text("Switch model")
                    .lineLimit(1)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
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
                .font(.system(size: 10, weight: .bold))
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
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .opacity(service.isStreaming ? 0.45 : 1)
    }

    private var prompts: [String] {
        var list: [String] = [
            "Why did I burn so much today?",
            "Show my biggest sessions this week",
            "Forecast end-of-day spend",
            "Which provider has the lowest quota?",
            "Top 3 projects by cost"
        ]
        if let topProvider = dashboardSnapshot?.topProviders.first?.provider,
           let provider = AgentProvider.fromPersistedToken(topProvider) {
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
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showCameraSheet = true
                } else {
                    attachmentImportError = "Camera is not available on this device. Choose Photo or Video Library instead."
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
        TextField("Ask Hermes…", text: $input, axis: .vertical)
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
                if newValue.hasSuffix("\n"), !service.isStreaming {
                    input = oldValue
                    send()
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

    // MARK: - Actions

    private func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard (!trimmed.isEmpty || !attachments.isEmpty), !service.isStreaming else { return }
        HapticBus.send()
        input = ""
        pendingAttachments = []
        inputFocused = false
        service.sendMessage(trimmed, context: dashboardContextPrompt, attachments: attachments)
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
}

// MARK: - Hermes Connection Sheet

private struct HermesConnectionSheet: View {
    @Bindable var service: HermesService
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = "Hermes Host"
    @State private var endpointURL = "http://192.168.1.2:8642"
    @State private var bearerToken = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Use Remote Relay away from home", systemImage: "antenna.radiowaves.left.and.right")
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.hermesAureate)
                        Text("Same account is not enough by itself: your iPhone/iPad must choose the Mac relay host, and your Mac must be online with Remote Relay enabled.")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let relay = service.suggestedRelayConnection,
                           service.selectedConnection.id != relay.id {
                            Button {
                                if service.connectToSuggestedRelay() {
                                    dismiss()
                                } else {
                                    errorText = service.lastError
                                }
                            } label: {
                                Label("Connect to my Mac", systemImage: "checkmark.shield.fill")
                                    .font(MobileTheme.Typography.body)
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.aurora(.hermes, fullWidth: true))
                            .padding(.top, 4)
                        } else if service.suggestedRelayConnection == nil {
                            Label("No Mac relay found yet", systemImage: "moon.zzz")
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Active Host") {
                    ForEach(service.connections) { connection in
                        Button {
                            if service.selectConnection(connection) {
                                dismiss()
                            } else {
                                errorText = service.lastError
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(connection.displayName)
                                        .font(MobileTheme.Typography.body)
                                        .fontWeight(.semibold)
                                    Text(connectionSubtitle(connection))
                                        .font(MobileTheme.Typography.tiny)
                                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                                }
                                Spacer()
                                Text(connection.status.rawValue.capitalized)
                                    .font(MobileTheme.Typography.tiny)
                                    .foregroundStyle(connection.status == .online ? MobileTheme.success : MobileTheme.warning)
                                if connection.id == service.selectedConnection.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(MobileTheme.hermesAureate)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if connection.id != HermesConnectionRecord.localDefault.id {
                                Button(role: .destructive) {
                                    Task { await revoke(connection) }
                                } label: {
                                    Label("Revoke", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                if let runtimeErrorText = service.runtimeErrorText {
                    Section {
                        Text(runtimeErrorText)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.error)
                        Button {
                            Task { await service.refreshConnections() }
                        } label: {
                            Label("Retry Connection Discovery", systemImage: "arrow.clockwise")
                        }
                    }
                }

                Section {
                    TextField("Display name", text: $displayName)
                    TextField("Hermes URL", text: $endpointURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API_SERVER_KEY (optional)", text: $bearerToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !endpointURL.isEmpty, HermesService.validatedEndpointURL(endpointURL) == nil {
                        Text("Use HTTPS, or HTTP only for localhost/private LAN Hermes hosts.")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.error)
                    }
                    Button {
                        Task { await addDirectConnection() }
                    } label: {
                        Label(isWorking ? "Registering…" : "Register and Connect", systemImage: "link.badge.plus")
                    }
                    .disabled(isWorking || displayName.isEmpty || HermesService.validatedEndpointURL(endpointURL) == nil)
                } header: {
                    Text("Add LAN/VPN Direct Host")
                } footer: {
                    Text("Use this for LAN/VPN/public HTTPS hosts. For cell signal away from home, keep OpenBurnBar running on your signed-in Mac and select its Remote Relay connection above; the Hermes API key stays on the Mac.")
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.error)
                    }
                }
            }
            .navigationTitle("Hermes Connections")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await service.refreshConnections() }
        }
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
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(MobileTheme.success)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use \(option.displayName)")
            .accessibilityValue(isSelected ? "Selected" : option.providerName)

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
        return modelOptions.first { $0.modelID == selectedModelID }
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
    if lower.contains("deepseek") { return .openClaw }
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

    var isUser: Bool { message.role == .user }

    var body: some View {
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

            if !message.text.isEmpty || message.toolCalls.isEmpty {
                assistantTextBody
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        assistantBubbleShape
                            .fill(MobileTheme.Colors.surface.opacity(0.85))
                    )
                    .overlay(
                        assistantBubbleShape
                            .stroke(message.isError ? AnyShapeStyle(MobileTheme.error) : AnyShapeStyle(AuroraDesign.Gradients.mercuryFoil), lineWidth: message.isError ? 1.5 : 1)
                    )
                    .overlay {
                        if !message.isError {
                            MercuryShimmerOverlay()
                                .clipShape(assistantBubbleShape)
                        }
                    }
            }

            if !message.toolCalls.isEmpty {
                toolCallsStrip
            }

            // Hermes Square §6.6 — typed UI cards the agent emitted on
            // this turn render inline above the tpsFooter. Host-drawn:
            // the agent never touches our view tree; the envelope decoder
            // enforces the 2 MB per-card budget.
            if !message.cards.isEmpty {
                cardsStrip
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

    // MARK: - Tool Calls Strip

    /// Horizontally scrollable tool strip, most recent on the left.
    private var toolCallsStrip: some View {
        let reversedCalls = Array(message.toolCalls.reversed())
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(reversedCalls) { tool in
                    toolCallPill(tool)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func toolCallPill(_ tool: HermesToolCall) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: toolCallIcon(for: tool.name))
                    .font(.system(size: 11, weight: .bold))
                Text(tool.name)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                Spacer(minLength: 8)
                Text(tool.status)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            if let detail = tool.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detail.isEmpty {
                Text(detail)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .truncationMode(.middle)
                    .accessibilityLabel("Tool detail: \(detail)")
            }
        }
        .foregroundStyle(MobileTheme.hermesAureate)
        .frame(maxWidth: 240, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AuroraDesign.Gradients.mercuryFoil, lineWidth: 0.75)
        )
    }

    private func toolCallIcon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("read") || n.contains("file") || n.contains("write") { return "doc.text" }
        if n.contains("bash") || n.contains("exec") || n.contains("run") || n.contains("terminal") { return "terminal" }
        if n.contains("search") || n.contains("grep") || n.contains("glob") || n.contains("find") { return "magnifyingglass" }
        if n.contains("web") || n.contains("browser") || n.contains("fetch") || n.contains("http") { return "globe" }
        if n.contains("edit") || n.contains("patch") || n.contains("replace") { return "pencil.and.outline" }
        if n.contains("memory") || n.contains("skill") || n.contains("learn") { return "brain" }
        if n.contains("image") || n.contains("vision") || n.contains("screenshot") { return "photo" }
        return "wrench.and.screwdriver.fill"
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
                    .font(.system(size: 9, weight: .bold))
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
                    .font(.system(size: 9, weight: .bold))
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
            // Completed assistant turn — atom-aware rich rendering, with
            // streaming-stable height + shrink-wrap width applied by the
            // wrapper.
            StreamingBubble(
                text: message.text,
                isStreaming: false,
                isError: false,
                baseSize: 15,
                lineHeight: 21
            ) {
                HermesRichBubble(
                    text: message.text,
                    baseColor: MobileTheme.Colors.textPrimary,
                    mentionColor: MobileTheme.hermesAureate,
                    codeColor: MobileTheme.Colors.textPrimary,
                    codeBackground: MobileTheme.Colors.surfaceElevated
                )
            }
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

// MARK: - Breathing Dot

private struct BreathingDot: ViewModifier {
    let active: Bool
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(active && phase ? 1.5 : 1.0)
            .opacity(active && phase ? 0.55 : 1.0)
            .animation(active ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : .default, value: phase)
            .onAppear { phase = true }
    }
}

// MARK: - String helpers

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
