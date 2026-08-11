import Foundation
import os
import OpenBurnBarCore

extension ProviderQuotaService {
    func routingState(for providerID: ProviderID) -> ProviderRoutingStateSnapshot? {
        routingStatesByProviderID[providerID]
    }

    @discardableResult
    func refreshRoutingState(
        dataStore: DataStore,
        request: ProviderRoutingRequest = ProviderRoutingRequest()
    ) async -> [ProviderID: ProviderRoutingStateSnapshot] {
        // A local-store read fault must not be invisible: routing decides
        // which credential/account serves traffic, and a silent `[]` here
        // drops every locally-known account from the candidate set without a
        // trace. We still degrade gracefully (the union below also draws on
        // live snapshots, daemon configs, and the caller's preferred IDs, so
        // routing can proceed), but the read failure is now logged.
        let accounts: [ProviderAccountDoc]
        do {
            accounts = try await dataStore.fetchProviderAccounts()
        } catch {
            AppLogger.dataStore.error(
                "ProviderQuotaService: refreshRoutingState fetchAll failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            accounts = []
        }
        let providerIDs = Set(
            accounts.map(\.providerID)
                + snapshotsByProvider.values.filter(\.hasDisplayableQuotaSignal).map(\.providerID)
                + OpenBurnBarDaemonManager.shared.providerConfigurations.map { ProviderID(rawValue: $0.providerID) }
                + request.preferredProviderIDs
        )

        var updatedStates: [ProviderID: ProviderRoutingStateSnapshot] = [:]
        let wasSuppressingPersistence = suppressRoutingEventPersistence
        suppressRoutingEventPersistence = true
        defer {
            suppressRoutingEventPersistence = wasSuppressingPersistence
            if !wasSuppressingPersistence, routingEventsDirty {
                routingEventsDirty = false
                persistRoutingEvents()
            }
        }

        for providerID in providerIDs {
            let scopedRequest = ProviderRoutingRequest(
                modelID: request.modelID,
                preferredProviderIDs: request.preferredProviderIDs.isEmpty ? [providerID] : request.preferredProviderIDs,
                allowProviderFallback: request.allowProviderFallback,
                routerMode: request.routerMode,
                selectedProviderID: request.selectedProviderID ?? providerID,
                selectedAccountID: request.selectedAccountID,
                taskCategory: request.taskCategory,
                benchmarkStatus: request.benchmarkStatus
            )
            let candidates = routingCandidates(
                providerID: providerID,
                accounts: accounts.filter { $0.providerID == providerID }
            )
            guard !candidates.isEmpty else { continue }

            let decision = ProviderRoutingPolicy.decide(
                request: scopedRequest,
                candidates: candidates
            )
            appendRoutingEvent(decision.event)
            updatedStates[providerID] = ProviderRoutingStateSnapshot(
                routerMode: decision.routerMode,
                selectedProviderID: scopedRequest.selectedProviderID,
                selectedAccountID: scopedRequest.selectedAccountID,
                selectedModelID: scopedRequest.modelID,
                activeAccount: decision.selected,
                nextFallback: decision.nextFallback,
                exhaustedOrCoolingDownAccounts: decision.exhaustedOrCoolingDown,
                lastSwitchReason: decision.lastSwitchReason,
                latestExplanation: decision.event.explanation,
                rejectedAlternatives: decision.rejectedAlternatives,
                benchmarkStatus: decision.benchmarkStatus,
                recentEvents: Array(
                    routingEvents
                        .filter {
                            $0.selectedProviderID == providerID
                            || $0.nextFallbackProviderID == providerID
                            || $0.originalProviderID == providerID
                            || $0.failoverDestinationProviderID == providerID
                        }
                        .suffix(100)
                )
            )
        }

        routingStatesByProviderID = updatedStates
        return updatedStates
    }

    internal func currentRoutingRequest(provider: AgentProvider? = nil) -> ProviderRoutingRequest {  // pure-move: was private
        let mode = OpenBurnBarDaemonManager.shared.routerMode
        return ProviderRoutingRequest(
            preferredProviderIDs: provider.map { [$0.providerID] } ?? [],
            routerMode: mode,
            selectedProviderID: provider?.providerID,
            taskCategory: .coding,
            benchmarkStatus: mode == .intelligentModelRouter
                ? ProviderModelBenchmarkStatus(
                    source: .cachedFixture,
                    freshness: .unavailable,
                    message: "No local benchmark snapshot is available yet.",
                    attribution: "OpenBurnBar model landscape adapters"
                )
                : nil
        )
    }

    private func appendRoutingEvent(_ event: ProviderRoutingDecisionEvent) {
        if routingEvents.last?.selectedProviderID == event.selectedProviderID,
           routingEvents.last?.selectedAccountID == event.selectedAccountID,
           routingEvents.last?.reason == event.reason {
            return
        }
        routingEvents.append(event)
        if routingEvents.count > Self.maxPersistedRoutingEvents {
            routingEvents.removeFirst(routingEvents.count - Self.maxPersistedRoutingEvents)
        }
        routingEventsDirty = true
        if !suppressRoutingEventPersistence {
            routingEventsDirty = false
            persistRoutingEvents()
        }
        // Emit a SuperGrok pacing event whenever the router selects xAI
        // under a consumer-plan tier — the adapter's pacing branch relies
        // on this log for "remaining %" estimates.
        if event.selectedProviderID == .xAI {
            XAISuperGrokUsageLog.recordPromptDispatched(
                plan: xaiPlanProvider(),
                model: event.modelID,
                source: "routing-decision",
                homeDirectoryURL: homeDirectoryURL,
                fileManager: fileManager
            )
        }
    }

    internal func connectedQuotaProviderIDs(dataStore: DataStore) async -> Set<ProviderID> {  // pure-move: was private
        if let cache = connectedQuotaProviderIDsCache,
           Date().timeIntervalSince(cache.fetchedAt) < 15 {
            return cache.ids
        }
        let accounts: [ProviderAccountDoc]
        do {
            accounts = try await dataStore.fetchProviderAccounts()
        } catch {
            // Correctness over silence: this set gates popover visibility and
            // which providers get a quota refresh. A swallowed read fault used
            // to return `[]` AND pin that empty set in the 15s cache, so a
            // single transient DB hiccup could hide every connected account
            // for a quarter minute. Log the fault and return empty WITHOUT
            // caching, so the next call re-probes and self-heals instead of
            // serving a stale-empty answer.
            AppLogger.dataStore.error(
                "ProviderQuotaService: connectedQuotaProviderIDs fetchAll failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return []
        }
        // Callers ask "is `provider.providerID` connected?", so the answer set
        // has to speak canonical ids. Accounts written before identities were
        // canonicalized (and any synced from an older device) still carry a
        // daemon alias, which `AgentProvider.fromProviderID` alone does not
        // recognise — resolving through the daemon map as well keeps those
        // accounts counted instead of silently hiding a connected provider.
        let ids: Set<ProviderID> = Set(accounts.compactMap { account in
            guard Self.isConnectedQuotaAccount(account) else { return nil }
            guard let provider = AgentProvider.fromProviderID(account.providerID)
                    ?? QuotaCapableProviderMap.provider(forDaemonProviderID: account.providerID.rawValue),
                  Self.supportedProviders.contains(provider) else {
                return nil
            }
            return provider.providerID
        })
        connectedQuotaProviderIDsCache = (Date(), ids)
        return ids
    }

    private static func isConnectedQuotaAccount(_ account: ProviderAccountDoc) -> Bool {
        switch account.status {
        case .connected, .stale, .error:
            return true
        case .disconnected, .disabled, .deleted:
            return false
        }
    }

    private func routingCandidates(
        providerID: ProviderID,
        accounts: [ProviderAccountDoc]
    ) -> [ProviderRoutingCandidate] {
        let accountCandidates = accounts
            .filter { $0.status != .deleted }
            .map { account in
                routingCandidate(for: account)
            }

        if !accountCandidates.isEmpty {
            return accountCandidates
        }

        if let agentProvider = AgentProvider.fromProviderID(providerID),
           snapshotsByProvider[agentProvider]?.hasDisplayableQuotaSignal == true || ProviderQuotaService.supportedProviders.contains(agentProvider) {
            return [
                .defaultLegacyAccount(
                    providerID: providerID,
                    providerLabel: agentProvider.displayName,
                    credentialHandle: "legacy-default",
                    localCredentialAvailable: true
                )
            ]
        }

        return []
    }

    private func routingCandidate(for account: ProviderAccountDoc) -> ProviderRoutingCandidate {
        let slot = daemonSlot(forAccount: account)
        let snapshot = accountSnapshot(providerID: account.providerID, accountID: account.id)
        let quotaState = routingQuotaState(account: account, snapshot: snapshot, slot: slot)
        let utilizationBucket = routingUtilizationBucket(for: snapshot)
        let cooldownUntil = slot?.cooldownUntil

        return ProviderRoutingCandidate(
            providerID: account.providerID,
            accountID: account.id,
            accountLabel: account.label,
            credentialHandle: account.redactedLabel,
            storageScope: account.storageScope,
            modelCompatibility: .unknown,
            quotaState: quotaState,
            quotaResetsAt: utilizationBucket?.resetsAt ?? slot?.lastQuotaResetsAt,
            remainingPercent: utilizationBucket?.remainingPercent ?? slot?.lastQuotaRemainingPercent,
            cooldownUntil: cooldownUntil,
            priority: Int(account.sortKey),
            routingEnabled: account.status != .disabled && account.status != .deleted,
            lastUsedAt: slot?.lastSelectedAt,
            lastFailureCode: account.lastErrorCode ?? slot?.lastStatusMessage,
            localCredentialAvailable: account.storageScope == .deviceKeychain || account.storageScope == .localOnly
        )
    }

    private func daemonSlot(forAccount account: ProviderAccountDoc) -> OpenBurnBarDaemonProviderConfiguration.CredentialSlot? {
        guard let configuration = OpenBurnBarDaemonManager.shared.providerConfigurations.first(where: { configuration in
            ProviderID(rawValue: configuration.providerID) == account.providerID
        }) else {
            return nil
        }
        for slot in configuration.credentialSlots {
            let accountID = "\(account.providerID.rawValue)-\(ProviderID.normalize(slot.slotID))"
            if accountID == account.id {
                return slot
            }
        }
        return nil
    }

    private func routingUtilizationBucket(for snapshot: ProviderQuotaSnapshot?) -> ProviderQuotaBucket? {
        let now = Date()
        return snapshot?.displayableQuotaBuckets(relativeTo: now).min { lhs, rhs in
            if let resetOrder = ProviderQuotaUtilizationOrdering.compareQuotaReset(lhs.resetsAt, rhs.resetsAt, now: now) {
                return resetOrder
            }
            if let remainingOrder = ProviderQuotaUtilizationOrdering.compareRemainingPercent(lhs.remainingPercent, rhs.remainingPercent) {
                return remainingOrder
            }
            return lhs.key < rhs.key
        }
    }

    private func routingQuotaState(
        account: ProviderAccountDoc,
        snapshot: ProviderQuotaSnapshot?,
        slot: OpenBurnBarDaemonProviderConfiguration.CredentialSlot?
    ) -> ProviderRoutingQuotaState {
        if account.status == .deleted { return .deleted }
        if account.status == .disabled { return .disabled }
        if account.status == .error {
            if let code = account.lastErrorCode?.lowercased(),
               code.contains("auth") || code.contains("401") || code.contains("403") || code.contains("secret") {
                return .authFailed
            }
        }

        if let slot {
            switch slot.effectiveRoutingStatus() {
            case .ready:
                break
            case .coolingDown:
                return .coolingDown
            case .exhausted:
                return .exhausted
            case .disabled:
                return .disabled
            case .missingSecret:
                return .authFailed
            }
        }

        if snapshot?.isTooOldForQuotaDecisions() == true {
            return .pressure
        }

        guard let bucket = snapshot?.primaryDisplayableBucket else {
            return account.status == .error ? .authFailed : .unknown
        }

        if account.providerID == .xAI,
           bucket.key == "xai-prepaid-credit-balance",
           let remainingDollars = bucket.remainingValue {
            if remainingDollars <= 0 { return .exhausted }
            if remainingDollars <= 5 { return .pressure }
            return .healthy
        }

        if let remaining = bucket.remainingPercent {
            if remaining <= 0 { return bucket.isEstimated ? .pressure : .exhausted }
            if remaining <= 20 { return .pressure }
            return .healthy
        }

        return snapshot?.confidence == .unavailable ? .unknown : .healthy
    }

}
