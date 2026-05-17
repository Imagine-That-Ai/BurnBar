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
        isEnabled: Bool = true
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
                        isEnabled: isEnabled
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
        apiKey: String? = nil
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
                    try? Self.providerRuntimeSecrets.delete(account: slotSecretAccount(providerID: providerID, slotID: slotID))
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
                                isEnabled: isEnabled ?? existingSlot?.isEnabled ?? true
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
            _ = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.updateConfig(snapshot, at: socketURL)
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

                    try? Self.providerRuntimeSecrets.delete(account: account)
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
            try? Self.providerRuntimeSecrets.delete(account: slotSecretAccount(providerID: providerID, slotID: slotID))
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
                    let apiKey = try Self.providerRuntimeSecrets.string(for: account)?.trimmingCharacters(in: .whitespacesAndNewlines)

                    if let apiKey, !apiKey.isEmpty {
                        do {
                            let quotaSnapshot = try await ProviderQuotaService.shared.fetchSnapshot(
                                for: quotaProvider,
                                apiKeyOverride: apiKey
                            )
                            let bucket = quotaSnapshot.primaryDisplayableBucket
                            slot.lastQuotaRemainingPercent = bucket?.remainingPercent
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
                                slot.cooldownUntil = Calendar.current.date(byAdding: .minute, value: 5, to: Date())
                            }
                        }
                    } else {
                        // New provider slots are daemon-owned. The app process cannot read
                        // those secrets, so a miss in the old app-side keychain namespace
                        // must not be treated as a missing daemon credential.
                        continue
                    }

                    slot.updatedAt = Date()
                    settings.credentialSlots[slotIndex] = slot
                    didMutate = true
                }

                snapshot.providers[providerIndex] = settings
            }

            if didMutate {
                let snapshotToWrite = snapshot
                _ = try await daemonRPC {
                    try OpenBurnBarDaemonSocketClient.updateConfig(snapshotToWrite, at: socketURL)
                }
            }
        }
    }

    func mutateProviderSettingsSnapshot(
        providerID: String,
        mutate: @escaping (BurnBarProviderSettings) throws -> BurnBarProviderSettings
    ) async throws {
        let socketURL = paths.socketURL
        var snapshot = try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.config(at: socketURL)
        }
        guard let index = snapshot.providers.firstIndex(where: { $0.providerID == providerID }) else {
            throw OpenBurnBarDaemonManagerError.rpcError("Provider '\(providerID)' is not available in daemon config.")
        }
        snapshot.providers[index] = try mutate(snapshot.providers[index])
        let snapshotToWrite = snapshot
        _ = try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.updateConfig(snapshotToWrite, at: socketURL)
        }
    }

    func slotSecretAccount(providerID: String, slotID: String) -> String {
        "provider.\(providerID).slot.\(slotID).apiKey"
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
        default:
            return nil
        }
    }
}
