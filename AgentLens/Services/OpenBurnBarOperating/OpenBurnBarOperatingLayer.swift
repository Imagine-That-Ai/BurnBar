import Foundation
import SwiftUI

// Runtime operating layer: models and composition live alongside this type in `BurnBarOperating/`
// (`BurnBarOperatingModels`, `OpenBurnBarOperatingComposer`, `OpenBurnBarOperatingLayer+MissionActions`, …).
// `Services/OpenBurnBarOperatingLayer.swift` is excluded from the app target (reference-only twin); do not
// add it back without deleting that duplicate.

// MARK: - Operating Layer Store

@MainActor
@Observable
final class OpenBurnBarOperatingLayer {
    let dataStore: DataStore
    let settingsManager: SettingsManager
    let accountManager: AccountManager
    let daemonManager: OpenBurnBarDaemonManager

    var aggregator: UsageAggregator?
    var chatController: ChatSessionController?

    var stateRevision: Int = 0

    var actionFeedback: OpenBurnBarActionFeedback?
    var controllerFeedback: OpenBurnBarControllerFeedback?

    private struct SnapshotCacheKey: Equatable {
        let stateRevision: Int
        let lastRefresh: Date?
        let usageCount: Int
        let daemonStatus: OpenBurnBarDaemonStatus
        let conversationIndexingEnabled: Bool
        let controllerRuntimeEnabled: Bool
        let isSignedIn: Bool
        let aggregatorIsRefreshing: Bool
        let chatIsStreaming: Bool
    }

    private var snapshotCacheKey: SnapshotCacheKey?
    private var cachedSnapshot: OpenBurnBarOperatingSnapshot?

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager = .shared,
        accountManager: AccountManager = .shared,
        daemonManager: OpenBurnBarDaemonManager = .shared,
        aggregator: UsageAggregator? = nil,
        chatController: ChatSessionController? = nil
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.accountManager = accountManager
        self.daemonManager = daemonManager
        self.aggregator = aggregator
        self.chatController = chatController
    }

    var snapshot: OpenBurnBarOperatingSnapshot {
        let cacheKey = SnapshotCacheKey(
            stateRevision: stateRevision,
            lastRefresh: dataStore.lastRefresh,
            usageCount: dataStore.totalUsageSessionCount,
            daemonStatus: daemonManager.status,
            conversationIndexingEnabled: settingsManager.conversationIndexingEnabled,
            controllerRuntimeEnabled: settingsManager.controllerRuntimeEnabled,
            isSignedIn: accountManager.isSignedIn,
            aggregatorIsRefreshing: aggregator?.isRefreshing == true,
            chatIsStreaming: chatController?.isStreaming == true
        )
        if snapshotCacheKey == cacheKey, let cachedSnapshot {
            return cachedSnapshot
        }

        let actionRecords = (try? dataStore.fetchOperatingActionRecords(limit: 200)) ?? []
        let cachedControllerRuntime = (try? dataStore.fetchControllerRuntimeMirror()) ?? nil
        let composed = OpenBurnBarOperatingComposer.build(
            dataStore: dataStore,
            settingsManager: settingsManager,
            accountManager: accountManager,
            daemonStatus: daemonManager.status,
            aggregator: aggregator,
            chatController: chatController,
            actionRecords: actionRecords,
            cachedControllerRuntime: cachedControllerRuntime
        )
        snapshotCacheKey = cacheKey
        cachedSnapshot = composed
        return composed
    }

    func clearActionFeedback() {
        actionFeedback = nil
    }

    func clearControllerFeedback() {
        controllerFeedback = nil
    }
}
