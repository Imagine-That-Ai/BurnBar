import Foundation
import os
import OpenBurnBarCore

extension ProviderQuotaService {
    func isRefreshing(_ provider: AgentProvider) -> Bool {
        activeProviders.contains(provider)
    }

    func refreshIfNeeded(dataStore: DataStore, maxAge: TimeInterval = 5 * 60) async {
        if maxAge <= 0 {
            await refreshAll(dataStore: dataStore)
            return
        }
        let due = QuotaRefreshPolicy.providersDueForRefresh(
            refreshProviders,
            snapshots: snapshotsByProvider
        )
        if due.isEmpty {
            await refreshRoutingState(dataStore: dataStore, request: currentRoutingRequest())
            return
        }
        await refreshProviders(due, dataStore: dataStore, clearAllErrors: false)
    }

    func startAutomaticRefresh(
        dataStore: DataStore,
        initialDelay: Duration = .seconds(5 * 60),
        interval: Duration = .seconds(15 * 60)
    ) {
        automaticRefreshLifecycle.replaceRefreshTask(Task(priority: .utility) { [weak self, weak dataStore] in
            guard let self, let dataStore else { return }
            try? await Task.sleep(for: initialDelay) // try?-ok(sleep cancellation only)
            while !Task.isCancelled {
                await self.refreshIfNeeded(dataStore: dataStore, maxAge: 15 * 60)
                try? await Task.sleep(for: interval) // try?-ok(sleep cancellation only)
            }
        })

        startClaudeStatuslineWatcher(dataStore: dataStore)

        guard !automaticRefreshLifecycle.hasAPIKeyObserver else { return }
        let providerUserInfoKey = ProviderAPIKeyStore.providerUserInfoKey
        let observer = NotificationCenter.default.addObserver(
            forName: ProviderAPIKeyStore.didChangeNotification,
            object: keyStore,
            queue: nil
        ) { [weak self, weak dataStore] notification in
            guard let providerKey = notification.userInfo?[providerUserInfoKey] as? String else {
                return
            }
            Task { @MainActor [weak self, weak dataStore] in
                guard let self, let dataStore else { return }
                if let provider = self.quotaProvider(forKeyIdentifier: providerKey) {
                    await self.refresh(provider: provider, dataStore: dataStore)
                } else {
                    await self.refreshIfNeeded(dataStore: dataStore, maxAge: 0)
                }
            }
        }
        automaticRefreshLifecycle.setAPIKeyObserver(observer)
    }

    func stopAutomaticRefresh() {
        automaticRefreshLifecycle.cancelRefreshTask()
        stopClaudeStatuslineWatcher()
        automaticRefreshLifecycle.removeAPIKeyObserver()
    }

    /// Arms an FS-event watcher on Claude Code's statusline snapshot file.
    /// When the statusline bridge writes a fresh payload, we re-read the
    /// Claude snapshot immediately instead of waiting for the next
    /// auto-refresh tick — which dropped Nest Hub freshness from "up to
    /// two minutes stale" to "as fast as Claude can write the hook".
    ///
    /// Idempotent. Calling twice replaces the existing watcher.
    func startClaudeStatuslineWatcher(dataStore: DataStore) {
        claudeStatuslineWatcher?.stop()
        let url = appPaths.claudeStatuslineSnapshotURL
        let watcher = ClaudeStatuslineWatcher(url: url) { [weak self, weak dataStore] in
            guard let self, let dataStore else { return }
            Task { @MainActor [weak self, weak dataStore] in
                guard let self, let dataStore else { return }
                await self.refreshClaudeFromStatuslineHook(dataStore: dataStore)
            }
        }
        watcher.start()
        claudeStatuslineWatcher = watcher
    }

    func stopClaudeStatuslineWatcher() {
        claudeStatuslineWatcher?.stop()
        claudeStatuslineWatcher = nil
    }

    func refreshAll(dataStore: DataStore) async {
        await refreshProviders(refreshProviders, dataStore: dataStore, clearAllErrors: true)
    }

    private func refreshProviders(
        _ providers: [AgentProvider],
        dataStore: DataStore,
        clearAllErrors: Bool
    ) async {
        guard !providers.isEmpty else { return }
        if clearAllErrors, let existing = inFlightRefreshAllTask {
            await existing.value
            return
        }
        let task = Task { @MainActor [self] in
            isFetching = true
            defer {
                isFetching = false
                activeProviders.removeAll()
            }
            if clearAllErrors {
                errors = [:]
            } else {
                for provider in providers {
                    errors.removeValue(forKey: provider)
                }
            }
            refreshClaudeBridgeStatus()

            activeProviders = Set(providers)
            let switcherProfileFetcher = makeSwitcherProfileFetcher(dataStore: dataStore)
            let batch = await quotaRefreshActor.fetchAllSnapshots(
                switcherProfileFetcher: switcherProfileFetcher,
                providers: providers
            )
            for (provider, snapshot) in batch.providerSnapshots {
                upsertSnapshot(snapshot, for: provider)
            }
            replaceAccountSnapshots(
                batch.accountSnapshots,
                pruningManagedAccountSnapshotsFor: Set(providers)
            )
            await persistDaemonCredentialSlotAccounts(
                dataStore: dataStore,
                providers: clearAllErrors ? nil : Set(providers)
            )
            await refreshRoutingState(dataStore: dataStore, request: currentRoutingRequest())

            lastFetch = Date()
            persistSnapshots()
        }
        if clearAllErrors {
            inFlightRefreshAllTask = task
            await task.value
            inFlightRefreshAllTask = nil
        } else {
            await task.value
        }
    }

    func refresh(provider: AgentProvider, dataStore: DataStore) async {
        guard Self.supportedProviders.contains(provider) else { return }
        activeProviders.insert(provider)
        defer { activeProviders.remove(provider) }
        let start = Date()
        Analytics.shared.track(.quotaRefreshStarted, ["provider_name": .string(provider.rawValue)])

        do {
            let context = makeContext()
            let snapshot = try await quotaRefreshActor.fetchSnapshot(for: provider, context: context)
            upsertSnapshot(snapshot, for: provider)
            let accountSnapshots = await quotaRefreshActor.fetchAccountSnapshots(
                for: provider,
                switcherProfileFetcher: makeSwitcherProfileFetcher(dataStore: dataStore)
            )
            replaceAccountSnapshots(
                accountSnapshots,
                pruningManagedAccountSnapshotsFor: [provider]
            )
            await persistDaemonCredentialSlotAccounts(dataStore: dataStore, providers: [provider])
            await refreshRoutingState(dataStore: dataStore, request: currentRoutingRequest(provider: provider))
            errors.removeValue(forKey: provider)
            lastFetch = Date()
            persistSnapshots()
            if provider == .claudeCode {
                refreshClaudeBridgeStatus()
            }
            Analytics.shared.track(.quotaRefreshSucceeded, [
                "provider_name": .string(provider.rawValue),
                "duration_ms_bucket": .string(AnalyticsBuckets.durationMs(Int(Date().timeIntervalSince(start) * 1000)))
            ])
            TelemetryService.shared.record(feature: .providerQuotaRefresh, outcome: .success, durationMs: Int(Date().timeIntervalSince(start) * 1000))
            OpenBurnBarMetrics.counter(name: "quota_refresh_success", labels: ["provider": provider.rawValue])
        } catch {
            Analytics.shared.track(.quotaRefreshFailed, [
                "provider_name": .string(provider.rawValue),
                "duration_ms_bucket": .string(AnalyticsBuckets.durationMs(Int(Date().timeIntervalSince(start) * 1000))),
                "error_code": .string(String(describing: type(of: error)))
            ])
            TelemetryService.shared.record(feature: .providerQuotaRefresh, outcome: .failure, durationMs: Int(Date().timeIntervalSince(start) * 1000))
            OpenBurnBarMetrics.counter(name: "quota_refresh_failure", labels: ["provider": provider.rawValue])
            errors[provider] = error.localizedDescription
            if snapshotsByProvider[provider] == nil {
                upsertSnapshot(ProviderQuotaSnapshot(
                    provider: provider,
                    fetchedAt: Date(),
                    source: .unavailable,
                    confidence: .unavailable,
                    managementURL: nil,
                    statusMessage: error.localizedDescription,
                    buckets: []
                ), for: provider)
            }
        }
    }

    /// Re-reads only the Claude snapshot in response to a statusline hook
    /// write. Deliberately does NOT bump `lastFetch`: a Claude-only refresh
    /// must not gate the next all-provider auto-refresh tick, otherwise a
    /// chatty Claude session could starve Codex/Cursor/etc. of updates.
    /// Skipped silently while a full `refreshAll` is already in flight to
    /// avoid stomping its outputs mid-flight.
    func refreshClaudeFromStatuslineHook(dataStore: DataStore) async {
        guard Self.supportedProviders.contains(.claudeCode) else { return }
        guard !isFetching else { return }
        activeProviders.insert(.claudeCode)
        defer { activeProviders.remove(.claudeCode) }

        do {
            let context = makeContext()
            let snapshot = try await quotaRefreshActor.fetchSnapshot(for: .claudeCode, context: context)
            upsertSnapshot(snapshot, for: .claudeCode)
            let accountSnapshots = await quotaRefreshActor.fetchAccountSnapshots(
                for: .claudeCode,
                switcherProfileFetcher: makeSwitcherProfileFetcher(dataStore: dataStore)
            )
            replaceAccountSnapshots(
                accountSnapshots,
                pruningManagedAccountSnapshotsFor: [.claudeCode]
            )
            errors.removeValue(forKey: .claudeCode)
            refreshClaudeBridgeStatus()
            persistSnapshots()
            OpenBurnBarMetrics.counter(name: "quota_refresh_success", labels: ["provider": "claudeCode-hook"])
        } catch {
            OpenBurnBarMetrics.counter(name: "quota_refresh_failure", labels: ["provider": "claudeCode-hook"])
        }
    }

    func fetchSnapshot(
        for provider: AgentProvider,
        apiKeyOverride: String
    ) async throws -> ProviderQuotaSnapshot {
        switch provider {
        case .minimax, .zai, .deepSeek, .copilot, .ollama, .kimi:
            let context = makeContext(apiKeyOverrides: [provider: apiKeyOverride])
            return try await quotaRefreshActor.fetchSnapshot(for: provider, context: context)
        default:
            return ProviderQuotaSnapshot(
                provider: provider,
                fetchedAt: Date(),
                source: .unavailable,
                confidence: .unavailable,
                managementURL: nil,
                statusMessage: "Per-plan quota refresh is available for MiniMax, Z.ai, DeepSeek, Kimi, Copilot, and Ollama Cloud.",
                buckets: []
            )
        }
    }

    func installClaudeQuotaBridge() throws {
        try bridgeManager.installClaudeQuotaBridge()
        refreshClaudeBridgeStatus()
    }

    func removeClaudeQuotaBridge() throws {
        try bridgeManager.removeClaudeQuotaBridge()
        refreshClaudeBridgeStatus()
    }

    func refreshClaudeBridgeStatus() {
        claudeBridgeStatus = bridgeManager.refreshClaudeBridgeStatus()
    }

}
