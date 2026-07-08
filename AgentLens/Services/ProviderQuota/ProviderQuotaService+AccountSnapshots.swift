import Foundation
import os
import OpenBurnBarCore

extension ProviderQuotaService {
    internal func upsertSnapshot(_ snapshot: ProviderQuotaSnapshot, for provider: AgentProvider? = nil) {  // pure-move: was private
        if Self.normalizedSnapshotIdentifier(snapshot.accountID) == nil {
            // Filter out snapshots whose provider string doesn't map to a known
            // AgentProvider — drop rather than crash or mislabel as .claudeCode
            // (which would corrupt the real Claude Code entry in the dict).
            guard let resolvedProvider = provider ?? snapshot.quotaProvider ?? AgentProvider(rawValue: snapshot.provider) else { return }
            snapshotsByProvider[resolvedProvider] = snapshot
        }
        snapshotsByAccountID[ProviderQuotaSnapshotStore.accountSnapshotKey(snapshot)] = snapshot
    }

    private func upsertAccountSnapshots(_ snapshots: [String: ProviderQuotaSnapshot]) {
        for (key, snapshot) in snapshots {
            snapshotsByAccountID[key] = snapshot
        }
    }

    internal func replaceAccountSnapshots(  // pure-move: was private
        _ snapshots: [String: ProviderQuotaSnapshot],
        pruningManagedAccountSnapshotsFor providers: Set<AgentProvider>
    ) {
        let providerIDs = Set(providers.map(\.providerID))
        let replacementKeys = Set(snapshots.keys)

        snapshotsByAccountID = snapshotsByAccountID.filter { key, snapshot in
            guard providerIDs.contains(snapshot.providerID),
                  Self.isManagedAccountSnapshot(snapshot) else {
                return true
            }
            return replacementKeys.contains(key)
        }

        upsertAccountSnapshots(snapshots)
    }

    internal func persistDaemonCredentialSlotAccounts(  // pure-move: was private
        dataStore: DataStore,
        providers: Set<AgentProvider>? = nil
    ) async {
        let accounts = daemonCredentialSlotAccounts(providers: providers)
        let scopedProviderIDs = daemonCredentialSlotProviderIDs(providers: providers)

        do {
            for account in accounts {
                try await dataStore.upsertProviderAccount(account)
            }
            try await markRemovedDaemonCredentialSlotAccountsDeleted(
                dataStore: dataStore,
                scopedProviderIDs: scopedProviderIDs,
                activeAccountIDs: Set(accounts.map(\.id))
            )
            connectedQuotaProviderIDsCache = nil
        } catch {
            AppLogger.dataStore.silentFailure("ProviderQuotaService: Failed to persist daemon provider accounts", error: error)
        }
    }

    private func daemonCredentialSlotProviderIDs(providers: Set<AgentProvider>? = nil) -> Set<ProviderID> {
        Set(
            OpenBurnBarDaemonManager.shared.providerConfigurations.compactMap { configuration in
                guard let provider = Self.quotaCapableProvider(forProviderID: configuration.providerID),
                      providers?.contains(provider) ?? true else {
                    return nil
                }
                return ProviderID(rawValue: configuration.providerID)
            }
        )
    }

    private func markRemovedDaemonCredentialSlotAccountsDeleted(
        dataStore: DataStore,
        scopedProviderIDs: Set<ProviderID>,
        activeAccountIDs: Set<String>
    ) async throws {
        guard !scopedProviderIDs.isEmpty else { return }
        let now = Date()
        for providerID in scopedProviderIDs {
            let existingAccounts = try await dataStore.fetchProviderAccounts(providerID: providerID)
            for account in existingAccounts where account.storageScope == .deviceKeychain && !activeAccountIDs.contains(account.id) {
                try await dataStore.upsertProviderAccount(
                    ProviderAccountDoc(
                        id: account.id,
                        providerID: account.providerID,
                        label: account.label,
                        identityHint: account.identityHint,
                        status: .deleted,
                        credentialKind: account.credentialKind,
                        storageScope: account.storageScope,
                        redactedLabel: account.redactedLabel,
                        sourceDeviceID: account.sourceDeviceID,
                        linkedSwitcherProfileID: account.linkedSwitcherProfileID,
                        isDefault: false,
                        sortKey: account.sortKey,
                        lastValidatedAt: account.lastValidatedAt,
                        lastRefreshAt: account.lastRefreshAt,
                        lastErrorCode: "credential_slot_removed",
                        schemaVersion: account.schemaVersion,
                        createdAt: account.createdAt,
                        updatedAt: now
                    )
                )
            }
        }
    }

    private func daemonCredentialSlotAccounts(providers: Set<AgentProvider>? = nil) -> [ProviderAccountDoc] {
        let allowedProviderIDs = Set(
            OpenBurnBarDaemonManager.shared.providerConfigurations.compactMap { configuration -> ProviderID? in
                guard let provider = Self.quotaCapableProvider(forProviderID: configuration.providerID),
                      providers?.contains(provider) ?? true else {
                    return nil
                }
                return ProviderID(rawValue: configuration.providerID)
            }
        )
        guard !allowedProviderIDs.isEmpty else { return [] }

        return DaemonCredentialSlotAccountProjection
            .accounts(from: OpenBurnBarDaemonManager.shared.providerConfigurations)
            .filter { allowedProviderIDs.contains($0.providerID) }
    }

    private static func quotaCapableProvider(forProviderID providerID: String) -> AgentProvider? {
        switch ProviderID.normalize(providerID) {
        case "minimax":
            return .minimax
        case "zai", "z-ai":
            return .zai
        case "ollama":
            return .ollama
        case "openai":
            return .openAI
        case "anthropic", "claude", "claude-code":
            return .claudeCode
        case "opencode", "open-code":
            return .openCode
        case "deepseek", "deep-seek":
            return .deepSeek
        case "moonshot", "kimi":
            return .kimi
        default:
            return nil
        }
    }

    internal static func normalizedSnapshotIdentifier(_ value: String?) -> String? {  // pure-move: was private
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized.lowercased()
    }

    internal static func isAccountLevelSnapshot(_ snapshot: ProviderQuotaSnapshot) -> Bool {  // pure-move: was private
        if normalizedSnapshotIdentifier(snapshot.accountID) != nil {
            return true
        }
        guard let sourceID = normalizedSnapshotIdentifier(snapshot.sourceId) else {
            return false
        }
        return sourceID != "default"
    }

    private static func isManagedAccountSnapshot(_ snapshot: ProviderQuotaSnapshot) -> Bool {
        guard isAccountLevelSnapshot(snapshot),
              let sourceID = normalizedSnapshotIdentifier(snapshot.sourceId) else {
            return false
        }
        return sourceID.hasPrefix("switcher-cli:")
            || sourceID.hasPrefix("switcher:")
            || sourceID.hasPrefix("provider:")
    }

}
