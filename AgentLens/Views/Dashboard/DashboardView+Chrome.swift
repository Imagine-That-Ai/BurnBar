import SwiftUI

extension DashboardView {
    @ViewBuilder
    func chrome<Content: View>(content: Content) -> some View {
        content
            .background {
                DashboardBackdrop(moodBand: dataStore.moodBand)
                GeometryReader { geo in
                    Color.clear
                        .onAppear { dashboardCanvasSize = geo.size }
                        .onChange(of: geo.size) { _, newSize in dashboardCanvasSize = newSize }
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                DashboardChatOverlay(
                    chatController: chatController,
                    dataStore: dataStore,
                    settingsManager: settingsManager,
                    accountManager: accountManager,
                    containerSize: dashboardCanvasSize,
                    sharedFeaturesAvailable: accountManager.isSignedIn,
                    isOpen: $chatPanelOpen,
                    hasNewInsights: {
                        let n = UserDefaults.standard.integer(forKey: "lastSeenSessionCountForChatBadge")
                        return dataStore.totalUsageSessionCount > n && dataStore.totalUsageSessionCount > 0
                    }(),
                    isChatRoute: navigationModel.mainRoute == .chat,
                    onRequestOpen: {
                        consentCoordinator?.openChatPanelIfConsented(chatController: chatController) {
                            if preferMaximizedChat {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    navigationModel.navigate(to: .chat)
                                }
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    chatPanelOpen = true
                                }
                            }
                        }
                    },
                    onOpenConversationJump: { target in
                        sessionLogJumpTarget = target
                        if navigationModel.mainRoute != .sessionLogs {
                            navigationModel.navigate(to: .sessionLogs)
                        }
                    },
                    onMaximize: {
                        preferMaximizedChat = true
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            chatPanelOpen = false
                            navigationModel.navigate(to: .chat)
                        }
                    },
                    onPopOut: {
                        WindowManager.shared.openChatPopOutWindow(
                            controller: chatController,
                            dataStore: dataStore,
                            settingsManager: settingsManager,
                            accountManager: accountManager
                        )
                    },
                    onClose: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            chatPanelOpen = false
                            UserDefaults.standard.set(dataStore.totalUsageSessionCount, forKey: "lastSeenSessionCountForChatBadge")
                        }
                    }
                )
            }
            .toolbar {
                DashboardToolbar(
                    navigationModel: navigationModel,
                    settingsManager: settingsManager,
                    totalCost: dataStore.usageWindowSummary(for: navigationModel.selectedTimeRange).totalCost,
                    totalTokens: dataStore.usageWindowSummary(for: navigationModel.selectedTimeRange).totalTokens,
                    isScanning: isScanning,
                    canRunRecount: canRunRecount,
                    backButtonHelpText: navigationModel.backButtonHelpText,
                    onBack: { navigationModel.goBack() },
                    onViewModeChange: { mode in
                        navigationModel.viewMode = mode
                        navigationModel.resetToOverview()
                    },
                    onScan: { Task { await aggregator?.refreshAll() } },
                    onRecount: { Task { await aggregator?.recountAll() } },
                    onSettings: { showingSettings = true }
                )
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(
                    settingsManager: settingsManager,
                    accountManager: accountManager,
                    cloudSyncService: cloudSyncService,
                    iCloudSessionMirrorService: iCloudSessionMirrorService,
                    dataStore: dataStore,
                    runtimeContext: runtimeContext
                )
            }
            .onAppear {
                navigationModel.viewMode = storedViewMode
                sidebarAppeared = true
                overviewAppeared = true
                consentCoordinator?.onDashboardAppear(aggregator: aggregator)
            }
            .onChange(of: navigationModel.viewMode) { _, newMode in storedViewMode = newMode }
            .alert("Index conversation history?", isPresented: Binding(
                get: { consentCoordinator?.showIndexingConsent ?? false },
                set: { consentCoordinator?.showIndexingConsent = $0 }
            )) {
                Button("Enable") { consentCoordinator?.confirmIndexingConsent(enable: true, aggregator: aggregator) }
                Button("Not now", role: .cancel) { consentCoordinator?.confirmIndexingConsent(enable: false, aggregator: aggregator) }
            } message: {
                Text("OpenBurnBar can index your conversation history for search and chat. This data stays on your Mac.")
            }
            .sheet(isPresented: Binding(
                get: { consentCoordinator?.showCLIConsentSheet ?? false },
                set: { consentCoordinator?.showCLIConsentSheet = $0 }
            )) {
                CLIAssistantConsentSheet(settingsManager: settingsManager) {
                    consentCoordinator?.showCLIConsentSheet = false
                }
                .presentationBackground(Material.ultraThinMaterial)
            }
            .sheet(isPresented: Binding(
                get: { consentCoordinator?.showSessionLogCloudConsent ?? false },
                set: { consentCoordinator?.showSessionLogCloudConsent = $0 }
            )) {
                SessionLogCloudConsentSheet(settingsManager: settingsManager) {
                    consentCoordinator?.showSessionLogCloudConsent = false
                }
                .presentationBackground(Material.ultraThinMaterial)
            }
            .onChange(of: accountManager.isSignedIn) { _, isSignedIn in
                consentCoordinator?.onSignInChange(isSignedIn: isSignedIn, chatController: chatController)
            }
            .onChange(of: navigationCoordinator.pendingNavigation) { _, destination in
                guard let destination else { return }
                switch destination {
                case .conversationSearch, .chatPanel:
                    if preferMaximizedChat {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            navigationModel.navigate(to: .chat)
                        }
                    } else if !chatPanelOpen {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { chatPanelOpen = true }
                    }
                case .chatPopOut:
                    WindowManager.shared.openChatPopOutWindow(
                        controller: chatController,
                        dataStore: dataStore,
                        settingsManager: settingsManager,
                        accountManager: accountManager
                    )
                default:
                    break
                }
                navigationCoordinator.clearPendingNavigation()
            }
            .onChange(of: navigationCoordinator.chatPanelOpen) { _, isOpen in
                guard isOpen, !chatPanelOpen else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { chatPanelOpen = true }
            }
            .preferredColorScheme(settingsManager.preferredSwiftUIColorScheme)
            .environment(settingsManager)
    }

    func openBurnBarCursorExtension() {
        let id = "openburnbar.openburnbar"
        let candidates = [
            URL(string: "cursor:extension/\(id)"),
            URL(string: "vscode:extension/\(id)"),
        ].compactMap { $0 }
        for url in candidates {
            if NSWorkspace.shared.open(url) { return }
        }
    }

    #if DEBUG
    func testTriggerNavigate(to route: DashboardMainRoute) {
        navigationModel.navigate(to: route)
    }

    func testTriggerGoBack() {
        navigationModel.goBack()
    }

    func testTriggerScan() {
        Task { await aggregator?.refreshAll() }
    }

    func testTriggerRecount() {
        Task { await aggregator?.recountAll() }
    }
    #endif
}
