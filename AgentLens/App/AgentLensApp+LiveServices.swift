import AppKit
import OpenBurnBarCore
import SwiftUI

// Extracted verbatim from AgentLensApp.swift (audit wave 4, item 14).
// Post-scene startup: installs the AppCommandRouter closures (dashboard,
// search, chat, settings, menu-bar popover factory) and starts the
// one-shot live-service stack (cloud sync, aggregator, daemon attach,
// relay/smart-display/Mercury services, probes, periodic refresh cadence).
extension OpenBurnBarApp {
    @MainActor
    func installCommandRouter() {
        let router = AppCommandRouter.shared
        guard let context = startupState.runtimeContext else {
            router.openDashboard = { openStartupRecoveryWindow() }
            router.openConversationSearch = { openStartupRecoveryWindow() }
            router.openChatPanel = { openStartupRecoveryWindow() }
            router.openSettings = { openStartupRecoveryWindow() }
            router.makeMenuBarPopoverContent = { _ in
                AnyView(EmptyView())
            }
            return
        }

        router.openDashboard = {
            openDashboard(context: context)
        }
        router.openCharts = {
            openDashboard(context: context)
            navigationCoordinator.setDashboardRoute(.charts)
        }
        router.routeDashboardDeepLink = { url in
            guard navigationCoordinator.handleDeepLink(url) else { return false }
            openDashboard(context: context)
            return true
        }
        router.openConversationSearch = {
            openDashboard(context: context)
            navigationCoordinator.openConversationSearch()
        }
        router.openChatPanel = {
            openDashboard(context: context)
            navigationCoordinator.openChatPanel()
        }
        router.openSettings = {
            windowManager.openSettings(
                settingsManager: context.settingsManager,
                accountManager: context.accountManager,
                cloudSyncService: context.cloudSyncService,
                iCloudSessionMirrorService: context.iCloudSessionMirrorService,
                dataStore: context.dataStore,
                runtimeContext: context
            )
        }
        router.makeMenuBarPopoverContent = { onDismiss in
            AnyView(
                MenuBarPopoverView(
                    dataStore: context.dataStore,
                    aggregator: context.aggregator,
                    quotaService: context.quotaService,
                    settingsManager: context.settingsManager,
                    smartHubBridgeController: context.smartHubBridgeController,
                    smartDisplayRepairCoordinator: context.smartDisplayRepairCoordinator,
                    operatingLayer: context.operatingLayer,
                    onOpenDashboard: {
                        onDismiss()
                        openDashboard(context: context)
                    },
                    onOpenSettings: {
                        onDismiss()
                        windowManager.openSettings(
                            settingsManager: context.settingsManager,
                            accountManager: context.accountManager,
                            cloudSyncService: context.cloudSyncService,
                            iCloudSessionMirrorService: context.iCloudSessionMirrorService,
                            dataStore: context.dataStore,
                            runtimeContext: context
                        )
                    },
                    chatController: context.chatController,
                    onOpenDashboardWithChat: {
                        onDismiss()
                        openDashboard(context: context)
                        navigationCoordinator.openChatPanel()
                    },
                    onOpenOnboardingWizard: {
                        onDismiss()
                        AppCommandRouter.shared.openOnboardingWizard?()
                    },
                    runtimeContext: context
                )
                .environment(context.settingsManager)
                .environment(context.accountManager)
            )
        }
        // One wizard entry, fully wired: the popover splash and Settings both
        // route here, so no caller can ever open the scan step with a nil
        // aggregator again.
        router.openOnboardingWizard = {
            windowManager.openOnboardingWizard(
                dataStore: context.dataStore,
                aggregator: context.aggregator,
                settingsManager: context.settingsManager,
                chatController: context.chatController,
                onOpenDashboard: {
                    openDashboard(context: context)
                }
            )
        }

        startLiveServicesIfNeeded(context: context)
    }

    @MainActor
    private func startLiveServicesIfNeeded(context: OpenBurnBarRuntimeContext) {
        guard !OpenBurnBarApp.didStartLiveServices else { return }
        OpenBurnBarApp.didStartLiveServices = true
        guard !OpenBurnBarRuntime.shouldUseTestStubScene else { return }

        Analytics.shared.track(.appSessionStarted)

        #if canImport(AppKit) && !DISTRIBUTION_MAS
        // Wire the trust sheet before anything can ask for a permission. The ladder
        // fails closed without an explainer, so installing this early is what turns
        // "BurnBar speaks first" from a convention into a guarantee.
        SystemPermissionTrustSheetPresenter.install()
        #endif

        Task { @MainActor in
            let shouldStartBackgroundServices =
                OpenBurnBarRuntime.shouldStartBackgroundApplicationServices(
                    isPerformanceGateLaunch: OpenBurnBarRuntime.isPerformanceGateLaunch
                )
            StartupProfiler.event("live_services_start")
            if shouldStartBackgroundServices {
                startMemoryExtractionIfNeeded(context: context)
            }

            let sync: CloudSyncService
            sync = StartupProfiler.interval("cloud_sync_init") {
                if let existingSync = context.cloudSyncService {
                    return existingSync
                }
                return CloudSyncService(
                    dataStore: context.dataStore,
                    accountManager: context.accountManager,
                    settingsManager: context.settingsManager
                )
            }
            context.cloudSyncService = sync

            appDelegate.settingsManager = context.settingsManager
            appDelegate.dataStore = context.dataStore
            appDelegate.daemonManager = context.daemonManager
            AppCommandRouter.shared.linkCliUserIDProvider = { [weak accountManager = context.accountManager] in
                accountManager?.userID
            }

            if shouldStartBackgroundServices {
                StartupProfiler.interval("relay_services_start") {
                    context.startRelayServices()
                }
                StartupProfiler.interval("smart_display_services_start") {
                    context.startSmartDisplayServices()
                }
                StartupProfiler.interval("mercury_services_start") {
                    context.startMercuryServices()
                }
                #if canImport(AppKit) && !DISTRIBUTION_MAS
                StartupProfiler.interval("text_expansion_start") {
                    context.textExpansionRuntimeController?.start()
                }
                #endif
            }

            let mirror: ICloudSessionMirrorService
            mirror = StartupProfiler.interval("icloud_mirror_init") {
                if let existingMirror = context.iCloudSessionMirrorService {
                    return existingMirror
                }
                return ICloudSessionMirrorService(settingsManager: context.settingsManager)
            }
            context.iCloudSessionMirrorService = mirror

            let aggregator: UsageAggregator
            aggregator = StartupProfiler.interval("usage_aggregator_init") {
                if let existingAggregator = context.aggregator {
                    return existingAggregator
                }
                return UsageAggregator(
                    dataStore: context.dataStore,
                    cloudSync: sync,
                    sessionMirror: mirror,
                    settingsManager: context.settingsManager,
                    quotaService: context.quotaService,
                    memoryCloudSyncDomain: context.memoryCloudSyncDomain
                )
            }
            context.aggregator = aggregator
            context.operatingLayer.aggregator = aggregator
            appDelegate.usageAggregator = aggregator
            context.operatingLayer.chatController = context.chatController
            if shouldStartBackgroundServices {
                StartupProfiler.interval("memory_watchdog_start") {
                    context.memoryFootprintWatchdog.start(aggregator: aggregator)
                }
                StartupProfiler.interval("daemon_attach") {
                    context.daemonManager.attach(
                        dataStore: context.dataStore,
                        cloudSyncService: sync
                    )
                }
                #if !DISTRIBUTION_MAS
                StartupProfiler.interval("computer_use_approval_start") {
                    ComputerUseDaemonApprovalPresenter.shared.start(
                        daemonManager: context.daemonManager
                    )
                }
                #endif
                StartupProfiler.interval("cursor_connector_attach") {
                    context.cursorConnectorManager.attach(dataStore: context.dataStore)
                }
                StartupProfiler.interval("quota_refresh_schedule") {
                    context.quotaService.startAutomaticRefresh(dataStore: context.dataStore)
                }
                // Routing decides with the DAEMON's copy of quota state, whose
                // only writers used to be the Provider Plan wizard's dashboard
                // and save steps — so slot freshness died the moment the wizard
                // closed, and the router fell back to learning quota from
                // response headers and failures. Push fresh slot quotas on the
                // app's own cadence whenever routing can actually use them
                // (gateway on, daemon healthy).
                Task(priority: .utility) {
                    try? await Task.sleep(for: .seconds(7 * 60))
                    while !Task.isCancelled {
                        if context.settingsManager.gatewayEnabled,
                           case .healthy = context.daemonManager.status {
                            await context.daemonManager.refreshProviderCredentialSlotQuotas()
                        }
                        try? await Task.sleep(for: .seconds(15 * 60))
                    }
                }
                StartupProfiler.interval("agent_reply_listener_start") {
                    MacAgentReplyNotificationListener.shared.start(
                        chatController: context.chatController,
                        accountManager: context.accountManager
                    )
                }
                StartupProfiler.interval("pet_companion_activate") {
                    PetCompanionFeature.activateIfEnabled(chat: context.chatController)
                    PetOnboardingWindowPresenter.openIfNeeded(
                        chatController: context.chatController
                    )
                }
            }

            if !hasShownInitialDashboard {
                hasShownInitialDashboard = true
                StartupProfiler.interval("first_dashboard_open") {
                    windowManager.openDashboard(
                        dataStore: context.dataStore,
                        aggregator: aggregator,
                        accountManager: context.accountManager,
                        cloudSyncService: sync,
                        iCloudSessionMirrorService: mirror,
                        chatController: context.chatController,
                        operatingLayer: context.operatingLayer,
                        navigationCoordinator: navigationCoordinator,
                        settingsManager: context.settingsManager,
                        runtimeContext: context
                    )
                }
            }
            StartupProfiler.event("first_ui_ready")

            // The performance harness now has the real dashboard and backdrop
            // it came to measure. Do not contaminate that process-level sample
            // with probes, uploads, notifications, or refresh cadences.
            guard shouldStartBackgroundServices else { return }

            Task(priority: .utility) {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if context.settingsManager.launchHermesWithOpenBurnBar {
                    let baseURL = URL(string: context.settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                        ?? URL(string: "http://127.0.0.1:8642")!
                    let bearerToken = context.settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    _ = await HermesRuntimeLauncher().openHermesAndGateway(
                        baseURL: baseURL,
                        bearerToken: bearerToken.isEmpty ? nil : bearerToken
                    )
                }
                if context.settingsManager.launchPiAgentsWithOpenBurnBar {
                    let baseURL = URL(string: context.settingsManager.piAgentGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                        ?? URL(string: "http://127.0.0.1:8765")!
                    let bearerToken = context.settingsManager.piAgentBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    let preferred = context.settingsManager.piAgentSelectedInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
                    let redisRaw = context.settingsManager.piAgentRedisURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    let piAdapter = PiAgentRuntimeAdapter(
                        preferredInstanceID: preferred.isEmpty ? nil : preferred,
                        redisURL: redisRaw.isEmpty ? nil : URL(string: redisRaw)
                    )
                    _ = await piAdapter.openManagedRuntime(
                        baseURL: baseURL,
                        bearerToken: bearerToken.isEmpty ? nil : bearerToken
                    )
                }
                let enabledBackends = Set(context.settingsManager.enabledChatBackends)
                if enabledBackends.contains(.hermes) || context.chatController.chatBackend == .hermes {
                    await context.chatController.probeHermesAvailability()
                } else {
                    context.chatController.hermesAvailable = false
                }
                if enabledBackends.contains(.openclaw) || context.chatController.chatBackend == .openclaw {
                    await context.chatController.probeOpenClawAvailability()
                } else {
                    context.chatController.openClawAvailable = false
                }
                if enabledBackends.contains(.piAgent) || context.chatController.chatBackend == .piAgent {
                    await context.chatController.probePiAgentAvailability()
                } else {
                    context.chatController.piAgentAvailable = false
                }
                StartupProfiler.event("startup_probe_work_start")
                await context.daemonManager.refreshHealth()
                await context.operatingLayer.refreshControllerRuntime()
                StartupProfiler.event("startup_probe_work_end")
            }

            // The first scan is the product. The logs are already on disk, so
            // read them NOW — a signed-out stranger's first number must never
            // wait behind a cloud sign-in poll or a courtesy sleep (the old
            // 30×1s + 15s/600s path meant the app said nothing true for its
            // first minute on exactly the launch that decides the install).
            let firstScan = Task(priority: .userInitiated) {
                guard !Task.isCancelled else { return }
                StartupProfiler.event("first_scan_start")
                await aggregator.refreshAll()
                StartupProfiler.event("first_scan_end")
            }

            Task(priority: .utility) {
                // Cloud catch-up stays sign-in gated; it just no longer holds
                // the local scan hostage.
                for _ in 0..<30 where !context.accountManager.isSignedIn {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                }
                await sync.uploadPending()
                // Preserve the original ordering guarantee: conversation upload
                // runs against a completed first scan, not a moving one.
                _ = await firstScan.value
                guard !Task.isCancelled else { return }
                await sync.uploadPendingConversations()
                await sync.uploadPendingChatThreads()
                await sync.syncTextExpansionSnippets()
                if context.settingsManager.dailyDigestEnabled {
                    await DailyDigestManager.shared.requestAuthorization()
                }
                // Registered whether or not the digest is on: the cadence reads
                // both settings live, so it arms, re-arms and clears itself
                // without waiting for the next launch.
                DailyDigestManager.shared.activate(
                    from: context.dataStore,
                    isEnabled: { context.settingsManager.dailyDigestEnabled },
                    hour: { context.settingsManager.dailyDigestHour }
                )
            }

            periodicRefreshTask?.cancel()
            // Coordinator-managed cadence: same active interval as before
            // (`max(settingsManager.refreshInterval, minimum)`), but the
            // coordinator pauses the loop entirely while the display sleeps
            // and stretches the interval 5× when the app is in the
            // background. Net: no work happens while the laptop lid is
            // closed and on idle the cadence honours the user setting.
            let cadenceID = "agentlens-periodic-refresh"
            BackgroundCadenceCoordinator.shared.register(
                BackgroundCadenceCoordinator.Cadence(
                    id: cadenceID,
                    activeIntervalProvider: {
                        let minimumRefreshInterval: TimeInterval = context.settingsManager.pixelClockConfig.enabled
                            ? 10 * 60
                            : 60
                        return max(context.settingsManager.refreshInterval, minimumRefreshInterval)
                    },
                    backgroundIntervalProvider: nil,
                    sleepIntervalProvider: { nil }, // paused on sleep
                    isEnabled: { true },
                    fireImmediately: false,
                    cancellableInFlight: false,
                    work: { [weak aggregator] in
                        await aggregator?.refreshAll()
                        await context.daemonManager.refreshHealth()
                        await context.operatingLayer.refreshControllerRuntime()
                        // The AI Inbox is written by the daemon in another
                        // process, so there is nothing local to observe. Nudge
                        // the badge on the same pass rather than registering a
                        // second timer — the read is one COUNT.
                        NotificationCenter.default.post(
                            name: DashboardView.inboxBadgeRefreshNotification,
                            object: nil
                        )
                    }
                )
            )
            // Sentinel so re-entrant `startBackgroundWork()` paths leave the
            // cadence registered exactly once.
            periodicRefreshTask = Task { @MainActor in }
        }
    }

    nonisolated(unsafe) private static var didStartLiveServices = false

    @MainActor
    private func openDashboard(context: OpenBurnBarRuntimeContext) {
        windowManager.openDashboard(
            dataStore: context.dataStore,
            aggregator: context.aggregator,
            accountManager: context.accountManager,
            cloudSyncService: context.cloudSyncService,
            iCloudSessionMirrorService: context.iCloudSessionMirrorService,
            chatController: context.chatController,
            operatingLayer: context.operatingLayer,
            navigationCoordinator: navigationCoordinator,
            settingsManager: context.settingsManager,
            runtimeContext: context
        )
    }
}
