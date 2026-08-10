import Foundation
import os
import OpenBurnBarCore

/// Single source of truth for "which `AgentProvider` does this daemon
/// credential-slot provider id belong to, for quota purposes".
///
/// This map used to exist twice — once for the per-account quota *fetch*
/// (`QuotaRefreshActor`) and once for the `ProviderAccountDoc` *projection*
/// (`ProviderQuotaService.persistDaemonCredentialSlotAccounts`) — and the two
/// copies drifted: xAI was in the fetch list but not the projection, so xAI
/// credential slots produced per-account quota snapshots that never became
/// accounts. `connectedQuotaProviderIDs` then missed xAI, which in turn skewed
/// popover visibility, setup-slot classification, the Connections list, and the
/// removed-slot tombstone sweep. Keep this the only copy.
enum QuotaCapableProviderMap {
    /// Providers whose quota endpoint reports **organization-wide** usage, so a
    /// per-credential-slot fetch would return the same numbers for every slot.
    /// Fetching per account would triple-count one org in the cumulative merge
    /// and render N identical cards, so these stay provider-level only.
    ///
    /// OpenAI: `/v1/organization/usage/completions` requires an org admin key
    /// and is scoped to the whole organization, not the key.
    static let organizationScopedProviders: Set<AgentProvider> = [.openAI]

    static func provider(forDaemonProviderID providerID: String) -> AgentProvider? {
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
        case "xai", "x-ai", "x.ai", "grok":
            return .xAI
        default:
            return nil
        }
    }

    /// Whether per-account quota snapshots are meaningful for `provider`.
    static func supportsPerAccountQuota(_ provider: AgentProvider) -> Bool {
        !organizationScopedProviders.contains(provider)
    }
}

/// Human-facing naming for a quota snapshot's account slot, shared by every
/// surface that renders one (Quota workspace cards, the provider dashboard
/// panel, the reset atlas). Centralised because each surface previously did
/// its own `accountLabel ?? accountID ?? sourceId` chain, which surfaced the
/// literal string `"default"` as an account name on provider-rollup cards.
enum ProviderQuotaAccountDisplay {
    /// The synthetic cross-account merge produced by `cumulativeSnapshot`.
    static func isMerged(_ snapshot: ProviderQuotaSnapshot) -> Bool {
        snapshot.sourceId.hasPrefix("cumulative:")
    }

    /// A provider-level rollup carrying no account attribution at all.
    static func isRollup(_ snapshot: ProviderQuotaSnapshot) -> Bool {
        guard nonEmpty(snapshot.accountID) == nil else { return false }
        let sourceID = snapshot.sourceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sourceID.isEmpty || sourceID == "default"
    }

    static func label(for snapshot: ProviderQuotaSnapshot, provider: AgentProvider) -> String {
        if let label = nonEmpty(snapshot.accountLabel) { return label }
        if let accountID = nonEmpty(snapshot.accountID) { return accountID }
        guard isRollup(snapshot) else { return snapshot.sourceId }
        return QuotaCapableProviderMap.organizationScopedProviders.contains(provider)
            ? "Organization · all keys"
            : "Default login"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

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
        QuotaCapableProviderMap.provider(forDaemonProviderID: providerID)
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
