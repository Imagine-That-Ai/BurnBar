import AppKit
import OpenBurnBarCore
import SwiftUI
import WebKit
import OpenBurnBarAnalytics

// MARK: - DashboardView + Inbox & Home

extension DashboardView {
    // MARK: - View helpers

    func presentAnalyticsConsentIfNeeded() {
        guard !AnalyticsConsentStore.shared.hasDecided,
              !showIndexingConsent,
              !showCLIConsentSheet,
              !showSessionLogCloudConsent else { return }
        showAnalyticsConsent = true
    }

    /// Presents the first-run memory consent once every other first-run sheet has
    /// settled, so the permission moments never stack. Memory consent is the last
    /// link in the chain: it waits for the indexing prompt, the CLI/cloud sheets,
    /// and the analytics decision before surfacing.
    func presentMemoryConsentIfNeeded() {
        guard let consentCoordinator,
              consentCoordinator.shouldShowMemoryConsent,
              !consentCoordinator.showMemoryConsent,
              !showIndexingConsent,
              !showCLIConsentSheet,
              !showSessionLogCloudConsent,
              !showAnalyticsConsent,
              AnalyticsConsentStore.shared.hasDecided else { return }
        consentCoordinator.showMemoryConsent = true
    }

    func autoExpandTimeRangeIfNeeded() {
        guard !didAutoExpandEmptyTimeRange else { return }
        defer { didAutoExpandEmptyTimeRange = true }
        let currentRangeEmpty = dataStore.usageWindowSummary(for: selectedTimeRange).sessionCount == 0
        let allTimeEmpty = dataStore.totalUsageSessionCount == 0
        if currentRangeEmpty, !allTimeEmpty {
            selectedTimeRange = .allTime
        }
    }

    // MARK: - Memory Review

    /// First-class Memory Review destination. The inbox is the human approval gate
    /// for extracted memories. The closures bind directly to the SHARED
    /// `ControlPlaneStore` published on the runtime context; when that store is not
    /// yet wired (e.g. the test-stub scene), we render a graceful unavailable state
    /// mirroring how other routes degrade on a missing dependency.
    @ViewBuilder
    var memoryReviewView: some View {
        if let store = runtimeContext?.chatMemoryStore {
            MemoryReviewInboxHost(
                store: store,
                scope: memoryReviewScope,
                userID: accountManager.userID,
                afterStatusChange: {
                    await refreshPendingMemoryReviewCount()
                    // Any status change can revoke an already-exported inbox
                    // memory. The export is a FULL-SET replacement, so pushing
                    // after every change makes revocation propagate to the
                    // daemon by omission — without this, a rejected fact keeps
                    // entering model prompts until the next unrelated approval.
                    if let store = runtimeContext?.chatMemoryStore {
                        await InboxMemoryExportService(
                            store: store,
                            scope: memoryReviewScope,
                            socketURL: OpenBurnBarDaemonRuntimePaths.live().socketURL
                        ).pushApprovedSnippets()
                    }
                }
            )
            .id(ObjectIdentifier(store))
        } else {
            ContentUnavailableView(
                "Memory is unavailable",
                systemImage: "brain.head.profile",
                description: Text("The memory store is not ready yet. It activates once OpenBurnBar finishes starting up.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(dashboardLiveBackdropActive ? Color.clear : DesignSystem.Colors.background)
        }
    }

    /// Chat-memory extraction writes app-scoped quarantined rows. The review inbox
    /// must read that same bucket so signed-in users can approve extracted memories.
    private var memoryReviewScope: MemoryScope {
        MemoryScope(appID: "openburnbar")
    }

    /// The AI Inbox destination.
    ///
    /// Rows are written by the daemon into the shared database, so this reads
    /// straight through `DataStore` rather than round-tripping the socket — the
    /// surface renders instantly even while the daemon is restarting.
    ///
    /// The memory-approval handler is bound to the SAME scope the Memory review
    /// surface uses, so a fact approved from the inbox is visible and revocable
    /// there too rather than living in a parallel bucket.
    /// Builds the inbox view model.
    ///
    /// Extracted so the Home surface and the focused `.inbox` route construct
    /// the *same* nine closures. Two call sites building this inline is how the
    /// two surfaces silently drift — one gaining a capability the other lacks.
    func makeInboxModel() -> InboxModel {
        InboxModel(
            loadRows: { [dataStore] states in
                try await dataStore.fetchAIInboxRows(states: states)
            },
            loadMarker: { [dataStore] in try await dataStore.aiInboxChangeMarker() },
            markRead: { [dataStore] id in try await dataStore.markAIInboxItemRead(id: id) },
            markUnread: { [dataStore] id in try await dataStore.markAIInboxItemUnread(id: id) },
            setArchived: { [dataStore] id, archived in
                try await dataStore.setAIInboxItemArchived(id: id, archived: archived)
            },
            snooze: { [dataStore] id, until in
                try await dataStore.snoozeAIInboxItem(id: id, until: until)
            },
            setFeedback: { [dataStore] id, feedback in
                try await dataStore.setAIInboxItemFeedback(id: id, feedback: feedback)
            },
            markAllRead: { [dataStore] in try await dataStore.markAllAIInboxItemsRead() },
            loadRuns: { [dataStore] in try await dataStore.fetchAIInboxRuns() },
            shelf: inboxShelf
        )
    }

    /// Opens a cited conversation at the passage that justified the item.
    ///
    /// Shared by the focused inbox and the Home surface. If the conversation is
    /// no longer indexed we still navigate — going nowhere reads as a broken
    /// link.
    func openInboxSessionLog(conversationID: String) {
        requestSessionLogJump(conversationID: conversationID)
        navigate(to: .sessionLogs)
    }

    /// Cancels an in-flight lookup so a later `openburnbar://sessions/…`
    /// link cannot be overwritten by the earlier one finishing last.
    func requestSessionLogJump(conversationID: String) {
        sessionLogJumpTask?.cancel()
        let requestID = UUID()
        sessionLogJumpRequestID = requestID
        sessionLogJumpTarget = nil
        sessionLogJumpTask = Task { @MainActor in
            await resolveSessionLogJump(conversationID: conversationID, requestID: requestID)
        }
    }

    /// Resolves a Session Logs jump from either a conversation row id or a
    /// receipt `sessionId`. Receipts have been minted against both.
    func resolveSessionLogJump(conversationID: String, requestID: UUID) async {
        let resolver = InboxConversationJumpResolver(dataStore: dataStore)
        if let target = await resolver.jumpTarget(conversationID: conversationID) {
            guard !Task.isCancelled, requestID == sessionLogJumpRequestID else { return }
            sessionLogJumpTarget = target
            return
        }
        if let record = try? await dataStore.fetchConversationForReceipt(sessionId: conversationID),
           let target = await resolver.jumpTarget(conversationID: record.id) {
            guard !Task.isCancelled, requestID == sessionLogJumpRequestID else { return }
            sessionLogJumpTarget = target
        }
    }

    /// The memory-approval handler, bound to the SAME scope the Memory review
    /// surface uses so a fact approved from the inbox is visible and revocable
    /// there rather than living in a parallel bucket.
    func makeInboxMemoryApproval() -> InboxMemoryApprovalHandler? {
        runtimeContext?.chatMemoryStore.map { store in
            InboxMemoryApprovalHandler(
                store: store,
                scope: memoryReviewScope,
                // After each approval, push the refreshed approved-snippet set
                // to the daemon so the next tick can cite the fact (L21).
                // Best-effort: approval never fails on daemon-down.
                exporter: { [memoryReviewScope] in
                    await InboxMemoryExportService(
                        store: store,
                        scope: memoryReviewScope,
                        socketURL: OpenBurnBarDaemonRuntimePaths.live().socketURL
                    ).pushApprovedSnippets()
                }
            )
        }
    }

    /// The launch surface: inbox + fleet/quota rail.
    @ViewBuilder
    var homeView: some View {
        let model = homeInboxModel ?? makeInboxModel()
        DashboardHomeView(
            dataStore: dataStore,
            settingsManager: settingsManager,
            inboxModel: model,
            fleetModel: fleetModel,
            onOpenSessionLog: { openInboxSessionLog(conversationID: $0) },
            onOpenSettings: { presentSettings(itemID: SettingsDeepLinkRouting.aiInboxItemID) },
            onOpenInbox: { itemID in
                pendingInboxItemID = itemID
                navigate(to: .inbox)
            },
            onOpenQuota: { navigate(to: .quota) },
            onAsk: { question in
                chatController.inputText = question
                withAnimation(DesignSystem.Animation.standard) { navigate(to: .chat) }
                Task { await chatController.send() }
            },
            memoryApproval: makeInboxMemoryApproval()
        )
        .background(dashboardLiveBackdropActive ? Color.clear : DesignSystem.Colors.background)
        .task {
            if homeInboxModel == nil { homeInboxModel = model }
            await startFleetIfNeeded()
        }
    }

    /// Arms the fleet watchers once, and does the first presence/usage merge.
    ///
    /// Idempotent: `.task` re-fires on every route return, and `arm` skips
    /// providers that already hold a stream.
    @MainActor
    private func startFleetIfNeeded() async {
        let providers = settingsManager.detectAvailableProviders()
            .filter(\.value)
            .map(\.key)
            .sorted { $0.displayName < $1.displayName }

        if fleetWatcher == nil {
            fleetWatcher = ProviderSessionActivityWatcher(model: fleetModel)
        }
        fleetWatcher?.arm(providers: providers)
        refreshFleet(providers: providers)
    }

    /// Display sleep tears the watchers down and marks external rows
    /// unobservable.
    ///
    /// A stream that survives sleep wakes the process on every write from a
    /// CLI running with the lid closed — strictly worse than the 60s poll it
    /// replaced. And showing pre-sleep timestamps as if they were current is
    /// the exact dishonesty the whole liveness model exists to prevent.
    var fleetSleepObservers: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
                fleetWatcher?.handleWillSleep()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                Task { @MainActor in await startFleetIfNeeded() }
            }
            // The shared cadence already fires on the app's refresh interval and
            // pauses during sleep, so the fleet's parsed-usage half rides it
            // rather than owning a second timer.
            .onReceive(NotificationCenter.default.publisher(for: DashboardView.inboxBadgeRefreshNotification)) { _ in
                Task { @MainActor in
                    let providers = settingsManager.detectAvailableProviders()
                        .filter(\.value)
                        .map(\.key)
                        .sorted { $0.displayName < $1.displayName }
                    refreshFleet(providers: providers)
                }
            }
    }

    @MainActor
    private func refreshFleet(providers: [AgentProvider]) {
        let presenceModel = chatController.agentDeck.presence
        fleetModel.rebuild(
            providers: providers,
            presence: presenceModel.presence,
            busyLocation: presenceModel.busyLocation,
            usages: dataStore.usages,
            usagesVersion: dataStore.usagesVersion
        )
    }

    @ViewBuilder
    var inboxView: some View {
        InboxView(
            model: homeInboxModel ?? makeInboxModel(),
            onOpenSessionLog: { conversationID in openInboxSessionLog(conversationID: conversationID) },
            onOpenSettings: { presentSettings(itemID: SettingsDeepLinkRouting.aiInboxItemID) },
            memoryApproval: makeInboxMemoryApproval(),
            openItemID: pendingInboxItemID
        )
        // Consume the deep link so returning to the Inbox later opens normally.
        .onAppear { pendingInboxItemID = nil }
        .background(dashboardLiveBackdropActive ? Color.clear : DesignSystem.Colors.background)
    }

    /// Name posted by the shared background cadence after each pass, so the
    /// badge tracks daemon-written rows without the view owning a second timer.
    static let inboxBadgeRefreshNotification = Notification.Name("openburnbar.aiInbox.badgeRefresh")

    /// Refreshes the inbox badge.
    ///
    /// Deliberately a `COUNT` rather than a fetch: this runs on the shared
    /// background cadence, and the whole point of the feature is that an idle
    /// inbox is free. A failure (daemon never ran, table absent) clears the badge
    /// instead of surfacing an error — a badge is not the place to report a fault.
    @MainActor
    func refreshAIInboxUnreadCount() async {
        aiInboxUnreadCount = try? await dataStore.aiInboxUnreadCount()
    }

    @MainActor
    func refreshPendingMemoryReviewCount() async {
        guard let store = runtimeContext?.chatMemoryStore else {
            pendingMemoryReviewCount = nil
            return
        }
        do {
            // The inbox serves chat + usage + agent-lane memories, so the badge
            // counts all three — otherwise it would disagree with the inbox's
            // own pill. The agent count takes the member, not a scope: those
            // rows carry the daemon's project id and none of the app's scope
            // columns, and the unclaimed-or-mine account rule keeps the badge
            // honest about rows this account cannot act on (review #2565).
            let chatCount = try await store.pendingChatMemoryReviewCount(scope: memoryReviewScope)
            let usageCount = try await store.pendingUsageMemoryReviewCount(scope: memoryReviewScope)
            let agentCount = try await store.pendingAgentMemoryReviewCount(accountUserID: accountManager.userID)
            pendingMemoryReviewCount = chatCount + usageCount + agentCount
        } catch {
            pendingMemoryReviewCount = nil
        }
    }
}
