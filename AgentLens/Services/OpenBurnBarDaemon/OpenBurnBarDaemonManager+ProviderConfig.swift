import Foundation
import OpenBurnBarCore

extension OpenBurnBarDaemonManager {

    func updateProviderConfiguration(
        providerID: String,
        isEnabled: Bool? = nil,
        baseURL: String? = nil,
        preferredModelIDs: [String]? = nil
    ) async {
        guard case .healthy = status else {
            lastError = "OpenBurnBar daemon must be healthy before provider settings can be updated."
            return
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
        apiKey: String
    ) async {
        guard case .healthy = status else {
            lastError = "OpenBurnBar daemon must be healthy before provider plans can be updated."
            return
        }

        await performBusyWork {
            let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedLabel.isEmpty, !normalizedKey.isEmpty else {
                throw OpenBurnBarDaemonManagerError.rpcError("Plan label and API key are required.")
            }

            let slotID = UUID().uuidString
            let newSlot = BurnBarProviderCredentialSlot(
                slotID: slotID,
                label: normalizedLabel,
                isEnabled: true,
                status: .ready
            )

            try await mutateProviderSettingsSnapshot(providerID: providerID) { settings in
                var mutable = settings
                mutable.credentialSlots.append(newSlot)
                if mutable.preferredCredentialSlotID == nil {
                    mutable.preferredCredentialSlotID = slotID
                }
                return mutable
            }

            try Self.providerRuntimeSecrets.set(
                normalizedKey,
                for: slotSecretAccount(providerID: providerID, slotID: slotID)
            )
        }
    }

    func updateProviderCredentialSlot(
        providerID: String,
        slotID: String,
        label: String? = nil,
        isEnabled: Bool? = nil,
        apiKey: String? = nil
    ) async {
        guard case .healthy = status else {
            lastError = "OpenBurnBar daemon must be healthy before provider plans can be updated."
            return
        }

        await performBusyWork {
            try await mutateProviderSettingsSnapshot(providerID: providerID) { settings in
                var mutable = settings
                guard let index = mutable.credentialSlots.firstIndex(where: { $0.slotID == slotID }) else {
                    throw OpenBurnBarDaemonManagerError.rpcError("Credential slot '\(slotID)' was not found.")
                }

                var slot = mutable.credentialSlots[index]
                if let label {
                    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        slot.label = trimmed
                    }
                }
                if let isEnabled {
                    slot.isEnabled = isEnabled
                    slot.status = isEnabled ? .ready : .disabled
                    if !isEnabled, mutable.preferredCredentialSlotID == slotID {
                        mutable.preferredCredentialSlotID = mutable.credentialSlots.first(where: { $0.slotID != slotID && $0.isEnabled })?.slotID
                    }
                }
                slot.updatedAt = Date()
                mutable.credentialSlots[index] = slot
                return mutable
            }

            if let apiKey {
                let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if normalizedKey.isEmpty {
                    try Self.providerRuntimeSecrets.delete(account: slotSecretAccount(providerID: providerID, slotID: slotID))
                } else {
                    try Self.providerRuntimeSecrets.set(
                        normalizedKey,
                        for: slotSecretAccount(providerID: providerID, slotID: slotID)
                    )
                }
            }
        }
    }

    func removeProviderCredentialSlot(
        providerID: String,
        slotID: String
    ) async {
        guard case .healthy = status else {
            lastError = "OpenBurnBar daemon must be healthy before provider plans can be updated."
            return
        }

        await performBusyWork {
            try await mutateProviderSettingsSnapshot(providerID: providerID) { settings in
                var mutable = settings
                mutable.credentialSlots.removeAll { $0.slotID == slotID }
                if mutable.preferredCredentialSlotID == slotID {
                    mutable.preferredCredentialSlotID = mutable.credentialSlots.first(where: { $0.isEnabled })?.slotID
                }
                return mutable
            }
            try Self.providerRuntimeSecrets.delete(account: slotSecretAccount(providerID: providerID, slotID: slotID))
        }
    }

    func setPreferredProviderCredentialSlot(
        providerID: String,
        slotID: String?
    ) async {
        guard case .healthy = status else {
            lastError = "OpenBurnBar daemon must be healthy before provider plans can be updated."
            return
        }

        await performBusyWork {
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
                        slot.status = .missingSecret
                        slot.lastStatusMessage = "Missing API key"
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
