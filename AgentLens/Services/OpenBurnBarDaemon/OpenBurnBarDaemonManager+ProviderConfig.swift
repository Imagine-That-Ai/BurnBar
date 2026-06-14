import Foundation
import OpenBurnBarCore

extension OpenBurnBarDaemonManager {

    func setRouterMode(_ mode: ProviderRouterMode) async {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before router mode can be updated."
                return
            }
        }

        await performBusyWork {
            let socketURL = paths.socketURL
            var snapshot = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.config(at: socketURL)
            }
            snapshot.routerMode = mode
            let snapshotToWrite = snapshot
            _ = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.updateConfig(snapshotToWrite, at: socketURL)
            }
            routerMode = mode
        }
    }

    func updateProviderConfiguration(
        providerID: String,
        isEnabled: Bool? = nil,
        baseURL: String? = nil,
        preferredModelIDs: [String]? = nil
    ) async {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before provider settings can be updated."
                return
            }
        }

        await performBusyWork {
            let socketURL = paths.socketURL
            var snapshot = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.config(at: socketURL)
            }
            guard let index = snapshot.providers.firstIndex(where: { $0.providerID == providerID }) else {
                throw OpenBurnBarDaemonManagerError.rpcError("Provider '\(providerID)' is not available in daemon config.")
            }

            var settings = snapshot.providers[index]
            if let isEnabled {
                settings.isEnabled = isEnabled
            }
            if let baseURL {
                settings.baseURL = baseURL
            }
            if let preferredModelIDs {
                settings.preferredModelIDs = preferredModelIDs
            }
            snapshot.providers[index] = settings

            let snapshotToWrite = snapshot
            _ = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.updateConfig(snapshotToWrite, at: socketURL)
            }
        }
    }

    func setProviderModelAdvertisement(
        providerID: String,
        modelID: String,
        isEnabled: Bool
    ) async {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before model advertising can be updated."
                return
            }
        }

        await performBusyWork {
            try await mutateProviderSettingsSnapshot(providerID: providerID) { settings in
                var mutable = settings
                mutable.setModelAdvertisement(modelID: modelID, isEnabled: isEnabled)
                return mutable
            }
        }
    }

    /// Bulk advertisement toggle for an entire provider — mute (or unmute)
    /// every supplied model id in a single config write so the user can turn a
    /// whole provider off and then cherry-pick a few models back on.
    func setProviderModelsAdvertisement(
        providerID: String,
        modelIDs: [String],
        isEnabled: Bool
    ) async {
        guard !modelIDs.isEmpty else { return }
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before model advertisement can be updated."
                return
            }
        }

        await performBusyWork {
            let socketURL = paths.socketURL
            var snapshot = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.config(at: socketURL)
            }
            guard let index = snapshot.providers.firstIndex(where: { $0.providerID == providerID }) else {
                return
            }
            var settings = snapshot.providers[index]
            settings.setModelsAdvertisement(modelIDs: modelIDs, isEnabled: isEnabled)
            snapshot.providers[index] = settings
            let updatedSnapshot = snapshot
            _ = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.updateConfig(updatedSnapshot, at: socketURL)
            }
        }
    }

    func addProviderCredentialSlot(
        providerID: String,
        label: String,
        apiKey: String,
        isEnabled: Bool = true
    ) async {
        do {
            _ = try await addProviderCredentialSlotReturningID(
                providerID: providerID,
                label: label,
                apiKey: apiKey,
                isEnabled: isEnabled
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func addProviderCredentialSlotReturningID(
        providerID: String,
        label: String,
        apiKey: String,
        isEnabled: Bool = true,
        endpointProfileID: String? = nil,
        region: ProviderEndpointRegion? = nil,
        tokenPlanTier: MimoTokenPlanTier? = nil,
        tokenPlanBillingCycle: MimoTokenPlanBillingCycle? = nil,
        authMethodID: String? = nil
    ) async throws -> String {
        if case .healthy = status {
            // already healthy
        } else {
            // The supervisor may be in crash-loop backoff while the daemon is
            // actually healthy. Force a re-probe before refusing the operation.
            await forceRefreshHealth()
            guard case .healthy = status else {
                throw OpenBurnBarDaemonManagerError.rpcError(
                    "OpenBurnBar daemon must be healthy before provider plans can be updated."
                )
            }
        }

        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty, !normalizedKey.isEmpty else {
            throw OpenBurnBarDaemonManagerError.rpcError("Plan label and API key are required.")
        }

        let slotID = UUID().uuidString
        try await performRequiredBusyWork {
            let socketURL = paths.socketURL
            _ = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.upsertProviderCredentialSlot(
                    BurnBarProviderCredentialSlotUpsertRequest(
                        providerID: providerID,
                        slotID: slotID,
                        label: normalizedLabel,
                        apiKey: normalizedKey,
                        isEnabled: isEnabled,
                        endpointProfileID: endpointProfileID,
                        region: region,
                        tokenPlanTier: tokenPlanTier,
                        tokenPlanBillingCycle: tokenPlanBillingCycle,
                        authMethodID: authMethodID
                    ),
                    at: socketURL
                )
            }
        }

        return slotID
    }

    func updateProviderCredentialSlot(
        providerID: String,
        slotID: String,
        label: String? = nil,
        isEnabled: Bool? = nil,
        apiKey: String? = nil
    ) async {
        do {
            try await updateProviderCredentialSlotOrThrow(
                providerID: providerID,
                slotID: slotID,
                label: label,
                isEnabled: isEnabled,
                apiKey: apiKey
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateProviderCredentialSlotOrThrow(
        providerID: String,
        slotID: String,
        label: String? = nil,
        isEnabled: Bool? = nil,
        apiKey: String? = nil,
        endpointProfileID: String? = nil,
        region: ProviderEndpointRegion? = nil,
        tokenPlanTier: MimoTokenPlanTier? = nil,
        tokenPlanBillingCycle: MimoTokenPlanBillingCycle? = nil,
        authMethodID: String? = nil
    ) async throws {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                throw OpenBurnBarDaemonManagerError.rpcError(
                    "OpenBurnBar daemon must be healthy before provider plans can be updated."
                )
            }
        }

        try await performRequiredBusyWork {
            let socketURL = paths.socketURL
            let currentSnapshot = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.config(at: socketURL)
            }
            let existingSlot = currentSnapshot
                .providerSettings(id: providerID)?
                .credentialSlots
                .first { $0.slotID == slotID }

            if let apiKey {
                let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedKey.isEmpty {
                    // Fail closed: a real keychain fault means we cannot prove the
                    // previous app-side plaintext key is purged, so we must reject
                    // the rotation rather than write the new credential on top of a
                    // still-readable stale secret.
                    try Self.purgeProviderSlotSecretFailClosed(
                        account: slotSecretAccount(providerID: providerID, slotID: slotID),
                        from: Self.providerRuntimeSecrets
                    )
                    _ = try await daemonRPC {
                        try OpenBurnBarDaemonSocketClient.upsertProviderCredentialSlot(
                            BurnBarProviderCredentialSlotUpsertRequest(
                                providerID: providerID,
                                slotID: slotID,
                                label: {
                                    let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if let trimmed, !trimmed.isEmpty { return trimmed }
                                    return existingSlot?.label ?? "Plan"
                                }(),
                                apiKey: normalizedKey,
                                isEnabled: isEnabled ?? existingSlot?.isEnabled ?? true,
                                endpointProfileID: endpointProfileID ?? existingSlot?.endpointProfileID,
                                region: region ?? existingSlot?.region,
                                tokenPlanTier: tokenPlanTier ?? existingSlot?.tokenPlanTier,
                                tokenPlanBillingCycle: tokenPlanBillingCycle ?? existingSlot?.tokenPlanBillingCycle,
                                authMethodID: authMethodID ?? existingSlot?.authMethodID
                            ),
                            at: socketURL
                        )
                    }
                    return
                }
            }

            var snapshot = currentSnapshot
            guard let providerIndex = snapshot.providers.firstIndex(where: { $0.providerID == providerID }) else {
                throw OpenBurnBarDaemonManagerError.rpcError("Provider '\(providerID)' is not available in daemon config.")
            }

            var settings = snapshot.providers[providerIndex]
            guard let index = settings.credentialSlots.firstIndex(where: { $0.slotID == slotID }) else {
                throw OpenBurnBarDaemonManagerError.rpcError("Credential slot '\(slotID)' was not found.")
            }

            var slot = settings.credentialSlots[index]
            if let label {
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    slot.label = trimmed
                }
            }
            if let isEnabled {
                slot.isEnabled = isEnabled
                slot.status = isEnabled ? .ready : .disabled
                if !isEnabled, settings.preferredCredentialSlotID == slotID {
                    settings.preferredCredentialSlotID = settings.credentialSlots.first(where: { $0.slotID != slotID && $0.isEnabled })?.slotID
                }
            }
            if apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                slot.status = .missingSecret
                slot.lastStatusMessage = "Missing API key"
            }
            slot.updatedAt = Date()
            settings.credentialSlots[index] = slot
            snapshot.providers[providerIndex] = settings
            let updatedSnapshot = snapshot
            _ = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.updateConfig(updatedSnapshot, at: socketURL)
            }
        }
    }

    func repairProviderCredentialSlotSecrets(providerID targetProviderID: String? = nil) async {
        guard case .healthy = status else { return }

        await performBusyWork {
            let socketURL = paths.socketURL
            let snapshot = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.config(at: socketURL)
            }

            for settings in snapshot.providers {
                if let targetProviderID, settings.providerID != targetProviderID {
                    continue
                }

                for slot in settings.credentialSlots {
                    let account = slotSecretAccount(providerID: settings.providerID, slotID: slot.slotID)
                    guard let apiKey = try Self.providerRuntimeSecrets.string(for: account)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !apiKey.isEmpty else {
                        continue
                    }

                    // Observable cleanup: ownership migrates to the daemon via the
                    // upsert below regardless, but a real keychain fault leaves an
                    // orphaned app-side plaintext copy. Log it (instead of the old
                    // diagnostic-free `try?`) so the leak is detectable, and keep
                    // repairing the remaining slots.
                    Self.purgeProviderSlotSecretObservable(
                        account: account,
                        from: Self.providerRuntimeSecrets
                    )
                    _ = try await daemonRPC {
                        try OpenBurnBarDaemonSocketClient.upsertProviderCredentialSlot(
                            BurnBarProviderCredentialSlotUpsertRequest(
                                providerID: settings.providerID,
                                slotID: slot.slotID,
                                label: slot.label,
                                apiKey: apiKey,
                                isEnabled: slot.isEnabled
                            ),
                            at: socketURL
                        )
                    }
                }
            }
        }
    }

    func removeProviderCredentialSlot(
        providerID: String,
        slotID: String
    ) async {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before provider plans can be updated."
                return
            }
        }

        await performBusyWork {
            let socketURL = paths.socketURL
            _ = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.removeProviderCredentialSlot(
                    BurnBarProviderCredentialSlotRemoveRequest(
                        providerID: providerID,
                        slotID: slotID
                    ),
                    at: socketURL
                )
            }
            // Observable cleanup: the daemon-side slot is already removed above, so
            // re-throwing here would falsely report the removal as failed. But a
            // real keychain fault leaves an orphaned plaintext API key behind after
            // the user asked to remove the credential — log it (instead of the old
            // diagnostic-free `try?`) so that leaked secret is detectable.
            Self.purgeProviderSlotSecretObservable(
                account: slotSecretAccount(providerID: providerID, slotID: slotID),
                from: Self.providerRuntimeSecrets
            )
        }
    }

    func setProviderModelVariant(
        providerID: String,
        variant: BurnBarModelVariant
    ) async {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before model variants can be updated."
                return
            }
        }

        await performBusyWork {
            let socketURL = paths.socketURL
            _ = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.upsertProviderModelVariant(
                    BurnBarProviderModelVariantUpsertRequest(
                        providerID: providerID,
                        variant: variant
                    ),
                    at: socketURL
                )
            }
        }
    }

    func removeProviderModelVariant(
        providerID: String,
        variantID: String
    ) async {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before model variants can be updated."
                return
            }
        }

        await performBusyWork {
            let socketURL = paths.socketURL
            _ = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.removeProviderModelVariant(
                    BurnBarProviderModelVariantRemoveRequest(
                        providerID: providerID,
                        variantID: variantID
                    ),
                    at: socketURL
                )
            }
        }
    }

    @discardableResult
    func setProviderModelAlias(
        providerID: String,
        alias: BurnBarModelAlias
    ) async -> Bool {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before model aliases can be updated."
                return false
            }
        }

        do {
            try await performRequiredBusyWork {
                let socketURL = paths.socketURL
                _ = try await daemonRPC {
                    try OpenBurnBarDaemonSocketClient.upsertProviderModelAlias(
                        BurnBarProviderModelAliasUpsertRequest(
                            providerID: providerID,
                            alias: alias
                        ),
                        at: socketURL
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    func removeProviderModelAlias(
        providerID: String,
        aliasID: String
    ) async {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before model aliases can be updated."
                return
            }
        }

        await performBusyWork {
            let socketURL = paths.socketURL
            _ = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.removeProviderModelAlias(
                    BurnBarProviderModelAliasRemoveRequest(
                        providerID: providerID,
                        aliasID: aliasID
                    ),
                    at: socketURL
                )
            }
        }
    }

    @discardableResult
    func setProviderCustomModel(
        providerID: String,
        customModel: BurnBarCustomModel
    ) async -> Bool {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before custom models can be added."
                return false
            }
        }

        do {
            try await performRequiredBusyWork {
                let socketURL = paths.socketURL
                _ = try await daemonRPC {
                    try OpenBurnBarDaemonSocketClient.upsertProviderCustomModel(
                        BurnBarProviderCustomModelUpsertRequest(
                            providerID: providerID,
                            customModel: customModel
                        ),
                        at: socketURL
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    func removeProviderCustomModel(
        providerID: String,
        modelID: String
    ) async {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before custom models can be removed."
                return
            }
        }

        await performBusyWork {
            let socketURL = paths.socketURL
            _ = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.removeProviderCustomModel(
                    BurnBarProviderCustomModelRemoveRequest(
                        providerID: providerID,
                        modelID: modelID
                    ),
                    at: socketURL
                )
            }
        }
    }

    @discardableResult
    func setProviderModelDisplayName(
        providerID: String,
        modelID: String,
        displayName: String
    ) async -> Bool {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before display names can be updated."
                return false
            }
        }

        do {
            try await performRequiredBusyWork {
                let socketURL = paths.socketURL
                _ = try await daemonRPC {
                    try OpenBurnBarDaemonSocketClient.setProviderModelDisplayName(
                        BurnBarProviderModelDisplayNameSetRequest(
                            providerID: providerID,
                            modelID: modelID,
                            displayName: displayName
                        ),
                        at: socketURL
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    func removeProviderModelDisplayName(
        providerID: String,
        modelID: String
    ) async {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                lastError = "OpenBurnBar daemon must be healthy before display names can be updated."
                return
            }
        }

        await performBusyWork {
            let socketURL = paths.socketURL
            _ = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.clearProviderModelDisplayName(
                    BurnBarProviderModelDisplayNameClearRequest(
                        providerID: providerID,
                        modelID: modelID
                    ),
                    at: socketURL
                )
            }
        }
    }

    func setPreferredProviderCredentialSlot(
        providerID: String,
        slotID: String?
    ) async {
        do {
            try await setPreferredProviderCredentialSlotOrThrow(providerID: providerID, slotID: slotID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setPreferredProviderCredentialSlotOrThrow(
        providerID: String,
        slotID: String?
    ) async throws {
        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                throw OpenBurnBarDaemonManagerError.rpcError(
                    "OpenBurnBar daemon must be healthy before provider plans can be updated."
                )
            }
        }

        try await performRequiredBusyWork {
            try await mutateProviderSettingsSnapshot(providerID: providerID) { settings in
                var mutable = settings
                if let slotID {
                    guard mutable.credentialSlots.contains(where: { $0.slotID == slotID }) else {
                        throw OpenBurnBarDaemonManagerError.rpcError("Credential slot '\(slotID)' was not found.")
                    }
                    mutable.preferredCredentialSlotID = slotID
                } else {
                    mutable.preferredCredentialSlotID = nil
                }
                return mutable
            }
        }
    }

    func refreshProviderCredentialSlotQuotas(providerID: String? = nil) async {
        guard case .healthy = status else {
            lastError = "OpenBurnBar daemon must be healthy before refreshing provider plan quotas."
            return
        }

        await performBusyWork {
            let socketURL = paths.socketURL
            var snapshot = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.config(at: socketURL)
            }

            let didMutate = try await applyProviderCredentialSlotQuotaRefresh(
                to: &snapshot,
                providerID: providerID,
                secretLookup: { account in
                    try Self.providerRuntimeSecrets.string(for: account)?.trimmingCharacters(in: .whitespacesAndNewlines)
                },
                fetchSnapshot: { quotaProvider, apiKey in
                    try await ProviderQuotaService.shared.fetchSnapshot(
                        for: quotaProvider,
                        apiKeyOverride: apiKey
                    )
                }
            )

            if didMutate {
                let snapshotToWrite = snapshot
                _ = try await daemonRPC {
                    try OpenBurnBarDaemonSocketClient.updateConfig(snapshotToWrite, at: socketURL)
                }
            }
        }
    }

    func applyProviderCredentialSlotQuotaRefresh(
        to snapshot: inout BurnBarProviderConfigurationSnapshot,
        providerID: String? = nil,
        secretLookup: (String) throws -> String?,
        fetchSnapshot: (AgentProvider, String) async throws -> ProviderQuotaSnapshot,
        now: () -> Date = Date.init
    ) async throws -> Bool {
        var didMutate = false
        for providerIndex in snapshot.providers.indices {
            var settings = snapshot.providers[providerIndex]
            if let providerID, settings.providerID != providerID {
                continue
            }
            guard let quotaProvider = quotaCapableProvider(for: settings.providerID) else {
                continue
            }

            for slotIndex in settings.credentialSlots.indices {
                var slot = settings.credentialSlots[slotIndex]
                let account = slotSecretAccount(providerID: settings.providerID, slotID: slot.slotID)
                let apiKey = try secretLookup(account)?.trimmingCharacters(in: .whitespacesAndNewlines)

                if let apiKey, !apiKey.isEmpty {
                    do {
                        let quotaSnapshot = try await fetchSnapshot(quotaProvider, apiKey)
                        let bucket = quotaSnapshot.primaryDisplayableBucket
                        if quotaProvider == .xAI,
                           bucket?.key == "xai-prepaid-credit-balance",
                           let remainingDollars = bucket?.remainingValue {
                            slot.lastQuotaRemainingPercent = remainingDollars <= 0
                                ? 0
                                : (remainingDollars <= 5 ? 15 : 100)
                        } else {
                            slot.lastQuotaRemainingPercent = bucket?.remainingPercent
                        }
                        slot.lastQuotaResetsAt = bucket?.resetsAt
                        slot.lastStatusMessage = quotaSnapshot.statusMessage
                        if slot.isEnabled {
                            if let remaining = bucket?.remainingPercent, remaining <= 0 {
                                slot.status = .exhausted
                            } else {
                                slot.status = .ready
                            }
                            slot.cooldownUntil = nil
                        }
                    } catch {
                        slot.lastStatusMessage = error.localizedDescription
                        if slot.isEnabled {
                            slot.status = .coolingDown
                            slot.cooldownUntil = Calendar.current.date(byAdding: .minute, value: 5, to: now())
                        }
                    }
                } else {
                    // New provider slots are daemon-owned. The app process cannot read
                    // those secrets, so a miss in the old app-side keychain namespace
                    // must not be treated as a missing daemon credential.
                    continue
                }

                slot.updatedAt = now()
                settings.credentialSlots[slotIndex] = slot
                didMutate = true
            }

            snapshot.providers[providerIndex] = settings
        }

        return didMutate
    }

    func mutateProviderSettingsSnapshot(
        providerID: String,
        mutate: @escaping (BurnBarProviderSettings) throws -> BurnBarProviderSettings
    ) async throws {
        let socketURL = paths.socketURL
        let requestConfig = dependencies.requestConfig
        let updateConfig = dependencies.updateConfig
        var snapshot = try await daemonRPC {
            try requestConfig(socketURL)
        }
        guard let index = snapshot.providers.firstIndex(where: { $0.providerID == providerID }) else {
            throw OpenBurnBarDaemonManagerError.rpcError("Provider '\(providerID)' is not available in daemon config.")
        }
        snapshot.providers[index] = try mutate(snapshot.providers[index])
        let snapshotToWrite = snapshot
        _ = try await daemonRPC {
            try updateConfig(socketURL, snapshotToWrite)
        }
        await refreshRuntimeSnapshot()
    }

    func slotSecretAccount(providerID: String, slotID: String) -> String {
        "provider.\(providerID).slot.\(slotID).apiKey"
    }

    /// Purges a stale app-side plaintext API key from the keychain, **failing
    /// closed** if the keychain cannot confirm the secret is gone.
    ///
    /// This is used before rotating a *new* credential in for a slot. The app no
    /// longer owns provider slot secrets — the daemon does — so the only reason
    /// to delete here is to guarantee the previous app-side plaintext copy is
    /// purged before a new key is written. A genuinely absent item is success
    /// (the `KeychainStore.delete` backend already maps `errSecItemNotFound` to a
    /// no-op). But a *real* keychain fault — a locked keychain, an ACL denial, an
    /// unhandled `OSStatus` — means we cannot prove the stale plaintext is gone.
    ///
    /// In that case we must NOT proceed to write the new credential, which would
    /// leave a stale, still-readable plaintext API key lingering in the keychain
    /// alongside the rotated one (a credential-continuity leak). We rethrow so the
    /// rotation is rejected and surfaced to the user instead of silently
    /// completing on top of an un-purged secret.
    ///
    /// Exposed at file-internal `static` visibility so the fault path is
    /// exercisable with an injected `KeychainStore` backend in tests.
    static func purgeProviderSlotSecretFailClosed(
        account: String,
        from secrets: KeychainStore,
        event: String = "provider_slot_secret_purge_failed"
    ) throws {
        do {
            try secrets.delete(account: account)
        } catch {
            AppLogger.daemon.error(
                event,
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            throw error
        }
    }

    /// Deletes a stale/orphaned app-side plaintext API key from the keychain,
    /// **logging but tolerating** a failure.
    ///
    /// This is used for cleanup *after* the authoritative state change has already
    /// happened: the daemon-side slot has been removed, or ownership of the secret
    /// has already migrated to the daemon via an upsert. The app-side copy is now
    /// strictly leftover plaintext. We still want it gone, but the load-bearing
    /// operation has already committed, and re-throwing here would either abort a
    /// best-effort multi-slot repair loop or mislead the user into believing a
    /// completed removal failed.
    ///
    /// A genuinely absent item is success. A *real* keychain fault leaves an
    /// orphaned plaintext credential behind, which historically was swallowed by
    /// `try?` with zero diagnostic. We now log it via `AppLogger` so the leaked
    /// secret is detectable, while preserving the original skip/continue behavior.
    ///
    /// Exposed at file-internal `static` visibility so the fault path is
    /// exercisable with an injected `KeychainStore` backend in tests.
    @discardableResult
    static func purgeProviderSlotSecretObservable(
        account: String,
        from secrets: KeychainStore,
        event: String = "provider_slot_secret_orphan_cleanup_failed"
    ) -> Bool {
        do {
            try secrets.delete(account: account)
            return true
        } catch {
            AppLogger.daemon.error(
                event,
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return false
        }
    }

    func quotaCapableProvider(for providerID: String) -> AgentProvider? {
        switch providerID.lowercased() {
        case "minimax":
            return .minimax
        case "zai", "z-ai":
            return .zai
        case "copilot":
            return .copilot
        case "ollama":
            return .ollama
        case "moonshot", "kimi":
            return .kimi
        case "mimo", "xiaomi", "xiaomimimo":
            return .mimo
        default:
            return nil
        }
    }
}
