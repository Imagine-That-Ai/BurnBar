import FirebaseFirestore
import Foundation
import OpenBurnBarCore

protocol RoamingProfileLocalStoring: Sendable {
    func currentPayload(uid: String, deviceID: String, context: CloudSyncContext) async throws -> RoamingProfilePayload
    func apply(_ payload: RoamingProfilePayload, context: CloudSyncContext) async throws
}

final class RoamingProfileSyncService: CloudSyncDomain, Sendable {
    private let context: CloudSyncContext
    private let vaultKeyStore: any SessionLogVaultKeyProviding
    private let vaultKeyPublisher: any SessionLogVaultKeyPublishing
    private let localStore: any RoamingProfileLocalStoring

    private let state = Locked(CloudSyncDomainState())

    var isSyncing: Bool { state.read().isSyncing }
    var lastSyncError: String? { state.read().lastSyncError }
    var lastSyncDate: Date? { state.read().lastSyncDate }

    init(
        context: CloudSyncContext,
        vaultKeyStore: any SessionLogVaultKeyProviding = CloudVaultKeyStore(),
        vaultKeyPublisher: any SessionLogVaultKeyPublishing = FirebaseSessionLogVaultKeyPublisher(),
        localStore: any RoamingProfileLocalStoring = DefaultRoamingProfileLocalStore()
    ) {
        self.context = context
        self.vaultKeyStore = vaultKeyStore
        self.vaultKeyPublisher = vaultKeyPublisher
        self.localStore = localStore
    }

    func sync() async {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              gate.account.isCloudSyncEnabled,
              !gate.syncSuppressed,
              let uid = gate.account.uid else { return }
        guard state.beginSyncingIfIdle() else { return }
        defer { state.endSyncing() }

        do {
            let vaultKey = try vaultKeyStore.getOrCreateKey(uid: uid)
            try await vaultKeyPublisher.publishCloudVaultKey(uid: uid, vaultKey: vaultKey, context: context)
            try await syncCurrentProfile(uid: uid, deviceID: gate.account.deviceId, vaultKey: vaultKey)
            state.withLock { $0.lastSyncDate = Date() }
        } catch {
            state.withLock { $0.lastSyncError = error.localizedDescription }
            if Self.isPermissionDenied(error) {
                await context.suppressSync(for: CloudSyncBackoffPolicy.permissionDeniedCooldown)
            }
        }
    }

    private func syncCurrentProfile(uid: String, deviceID: String, vaultKey: Data) async throws {
        let document = context.firestoreGateway
            .collection("users")
            .document(uid)
            .collection("roaming_profile")
            .document("current")

        let local = try await localStore.currentPayload(uid: uid, deviceID: deviceID, context: context)
        let remoteEnvelope = try await withCloudSyncRetry(
            policy: context.retryPolicy,
            circuitBreaker: context.circuitBreaker,
            domain: "roaming_profile"
        ) { () -> CloudVaultSealedPayload? in
            guard let remoteData = try await document.getData() else {
                return nil
            }
            return try? Self.sealedPayload(from: remoteData["sealedPayload"])
        }
        if let remoteEnvelope {
            let remote = try CloudVaultCrypto.openRoamingProfile(remoteEnvelope, keyData: vaultKey, uid: uid)
            if remote.updatedAt >= local.updatedAt {
                try await localStore.apply(remote, context: context)
                return
            }
        }

        let sealed = try CloudVaultCrypto.sealRoamingProfile(local, keyData: vaultKey, uid: uid)
        try await withCloudSyncRetry(
            policy: context.retryPolicy,
            circuitBreaker: context.circuitBreaker,
            domain: "roaming_profile"
        ) {
            try await document.setData(Self.cloudDocument(payload: local, sealedPayload: sealed, uid: uid), merge: true)
        }
    }

    private static func cloudDocument(
        payload: RoamingProfilePayload,
        sealedPayload: CloudVaultSealedPayload,
        uid: String
    ) -> [String: Any] {
        [
            "uid": uid,
            "schemaVersion": 1,
            "payloadSchemaVersion": payload.schemaVersion,
            "sourceDeviceID": payload.sourceDeviceID,
            "updatedAt": payload.updatedAt,
            "sealedPayload": CloudVaultCrypto.sealedPayloadDictionary(sealedPayload)
        ]
    }

    private static func sealedPayload(from value: Any?) throws -> CloudVaultSealedPayload? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try JSONDecoder().decode(CloudVaultSealedPayload.self, from: data)
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == FirestoreErrorDomain,
              let code = FirestoreErrorCode.Code(rawValue: nsError.code) else {
            return false
        }
        return code == .permissionDenied || code == .unauthenticated
    }
}

struct DefaultRoamingProfileLocalStore: RoamingProfileLocalStoring {
    func currentPayload(uid: String, deviceID: String, context: CloudSyncContext) async throws -> RoamingProfilePayload {
        let accounts = try await context.dataStore.fetchProviderAccounts()
            .sorted { lhs, rhs in
                if lhs.sortKey == rhs.sortKey { return lhs.id < rhs.id }
                return lhs.sortKey < rhs.sortKey
            }
        let quotaPreferences = await MainActor.run {
            quotaDisplayPreferences(from: context.settingsManager)
        }
        let (routerMode, quotaSettingsUpdatedAt, ollamaEndpoints) = await MainActor.run {
            let updatedAt = (context.settingsManager as? SettingsManager)?.quotas.updatedAt
                ?? Date(timeIntervalSince1970: 0)
            return (
                OpenBurnBarDaemonManager.shared.routerMode,
                updatedAt,
                Self.roamingOllamaEndpoints(from: OpenBurnBarDaemonManager.shared.providerConfigurations)
            )
        }
        let updatedAt = (accounts.map(\.updatedAt) + [quotaSettingsUpdatedAt]).max() ?? Date(timeIntervalSince1970: 0)
        return RoamingProfilePayload(
            routerMode: routerMode,
            crossProviderFailoverEnabled: !routerMode.usesExactSameModelInvariant,
            accountOrder: accounts.map(\.id),
            providerAccounts: accounts.map(RoamingProfileProviderAccount.init),
            ollamaEndpoints: ollamaEndpoints,
            equivalenceOverrides: [],
            quotaDisplayPreferences: quotaPreferences,
            updatedAt: updatedAt,
            sourceDeviceID: deviceID
        )
    }

    func apply(_ payload: RoamingProfilePayload, context: CloudSyncContext) async throws {
        _ = try payload.validatedForCloudVaultSeal()
        let localDeviceID = await context.deviceId
        for remoteAccount in payload.providerAccounts {
            let account = namespacedRemoteAccount(remoteAccount, localDeviceID: localDeviceID)
            if let local = try await context.dataStore.fetchProviderAccount(id: account.id),
               local.updatedAt > account.updatedAt {
                continue
            }
            try await context.dataStore.upsertProviderAccount(account.providerAccountDoc)
        }
        await MainActor.run {
            applyQuotaDisplayPreferences(payload.quotaDisplayPreferences, to: context.settingsManager)
        }
        await OpenBurnBarDaemonManager.shared.applyRoamingOllamaEndpoints(payload.ollamaEndpoints)
        await OpenBurnBarDaemonManager.shared.setRouterMode(payload.routerMode)
    }

    static func roamingOllamaEndpoints(
        from configurations: [OpenBurnBarDaemonProviderConfiguration]
    ) -> [RoamingOllamaEndpoint] {
        configurations
            .filter { isRoamingOllamaProviderID($0.providerID) }
            .flatMap(\.ollamaEndpoints)
            .map { endpoint in
                RoamingOllamaEndpoint(
                    id: endpoint.id,
                    baseURL: endpoint.baseURL,
                    label: endpoint.label,
                    priority: endpoint.priority
                )
            }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
    }

    static func providerOllamaEndpoints(
        from endpoints: [RoamingOllamaEndpoint]
    ) throws -> [BurnBarOllamaEndpointConfig] {
        try BurnBarOllamaEndpointConfig.normalizedList(
            endpoints.map { endpoint in
                BurnBarOllamaEndpointConfig(
                    id: endpoint.id,
                    baseURL: endpoint.baseURL,
                    label: endpoint.label,
                    priority: endpoint.priority,
                    enabled: true
                )
            }
        )
    }

    static func isRoamingOllamaProviderID(_ providerID: String) -> Bool {
        providerID.caseInsensitiveCompare("ollama-local") == .orderedSame
    }

    @MainActor
    private func quotaDisplayPreferences(from settingsManager: any SettingsManagerProtocol) -> RoamingQuotaDisplayPreferences {
        guard let settingsManager = settingsManager as? SettingsManager else {
            return RoamingQuotaDisplayPreferences()
        }
        return RoamingQuotaDisplayPreferences(
            providerOrder: settingsManager.quotas.providerOrder.map(\.persistedToken),
            visibleProviders: settingsManager.quotas.visibleProviders.map(\.persistedToken),
            hiddenBuckets: Array(settingsManager.quotas.hiddenBuckets).sorted(),
            bucketOrders: settingsManager.quotas.bucketOrders,
            percentageDisplayMode: settingsManager.quotas.percentageDisplayMode.rawValue,
            cumulativeAcrossAccounts: settingsManager.quotas.cumulativeAcrossAccounts
        )
    }

    @MainActor
    private func applyQuotaDisplayPreferences(
        _ preferences: RoamingQuotaDisplayPreferences,
        to settingsManager: any SettingsManagerProtocol
    ) {
        guard let settingsManager = settingsManager as? SettingsManager else {
            return
        }
        let validProviderTokens = Set(AgentProvider.quotaSignalProviders.map(\.persistedToken))
        let providerOrder = preferences.providerOrder.filter { validProviderTokens.contains($0) }
        let visibleProviders = preferences.visibleProviders.filter { validProviderTokens.contains($0) }
        if !providerOrder.isEmpty {
            settingsManager.quotas.providerOrderCSV = providerOrder.joined(separator: ",")
        }
        if !visibleProviders.isEmpty {
            settingsManager.quotas.visibleProvidersCSV = visibleProviders.joined(separator: ",")
        }
        settingsManager.quotas.hiddenBuckets = Set(preferences.hiddenBuckets)
        settingsManager.quotas.bucketOrders = preferences.bucketOrders
        if let mode = QuotaPercentageDisplayMode(rawValue: preferences.percentageDisplayMode) {
            settingsManager.quotas.percentageDisplayMode = mode
        }
        settingsManager.quotas.cumulativeAcrossAccounts = preferences.cumulativeAcrossAccounts
    }

    private func namespacedRemoteAccount(
        _ account: RoamingProfileProviderAccount,
        localDeviceID: String
    ) -> RoamingProfileProviderAccount {
        guard account.sourceDeviceID != localDeviceID,
              account.storageScope == .deviceKeychain || account.storageScope == .localOnly else {
            return account
        }
        let trimmedDeviceID = account.sourceDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let remoteDeviceID = trimmedDeviceID.isEmpty ? "unknown" : trimmedDeviceID
        return RoamingProfileProviderAccount(
            id: "remote-\(remoteDeviceID)-\(account.id)",
            providerID: account.providerID,
            label: account.label,
            identityHint: account.identityHint,
            status: account.status,
            credentialKind: account.credentialKind,
            storageScope: account.storageScope,
            redactedLabel: account.redactedLabel,
            sourceDeviceID: account.sourceDeviceID,
            linkedSwitcherProfileID: account.linkedSwitcherProfileID,
            isDefault: false,
            sortKey: account.sortKey,
            lastValidatedAt: account.lastValidatedAt,
            lastRefreshAt: account.lastRefreshAt,
            lastErrorCode: account.lastErrorCode,
            endpointProfileID: account.endpointProfileID,
            region: account.region,
            tokenPlanTier: account.tokenPlanTier,
            tokenPlanBillingCycle: account.tokenPlanBillingCycle,
            authMethodID: account.authMethodID,
            schemaVersion: account.schemaVersion,
            createdAt: account.createdAt,
            updatedAt: account.updatedAt
        )
    }
}

extension OpenBurnBarDaemonManager {
    func applyRoamingOllamaEndpoints(_ endpoints: [RoamingOllamaEndpoint]) async {
        guard !endpoints.isEmpty else { return }
        do {
            try await applyRoamingOllamaEndpointsOrThrow(endpoints)
        } catch {
            lastError = error.localizedDescription
            AppLogger.daemon.error(
                "roaming_profile.ollama_endpoints.apply_failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
        }
    }

    private func applyRoamingOllamaEndpointsOrThrow(_ endpoints: [RoamingOllamaEndpoint]) async throws {
        let providerEndpoints = try DefaultRoamingProfileLocalStore.providerOllamaEndpoints(from: endpoints)
        guard !providerEndpoints.isEmpty else { return }

        if case .healthy = status {
            // already healthy
        } else {
            await forceRefreshHealth()
            guard case .healthy = status else {
                throw OpenBurnBarDaemonManagerError.rpcError(
                    "OpenBurnBar daemon must be healthy before roaming Ollama endpoints can be restored."
                )
            }
        }

        try await performRequiredBusyWork {
            let socketURL = paths.socketURL
            let requestConfig = dependencies.requestConfig
            let updateConfig = dependencies.updateConfig
            var snapshot = try await daemonRPC {
                try requestConfig(socketURL)
            }

            if let index = snapshot.providers.firstIndex(where: {
                DefaultRoamingProfileLocalStore.isRoamingOllamaProviderID($0.providerID)
            }) {
                var settings = snapshot.providers[index]
                settings.isEnabled = true
                settings.baseURL = providerEndpoints.first?.baseURL ?? settings.baseURL
                settings.ollamaEndpoints = providerEndpoints
                snapshot.providers[index] = settings
            } else {
                snapshot.providers.append(
                    BurnBarProviderSettings(
                        providerID: "ollama-local",
                        isEnabled: true,
                        baseURL: providerEndpoints.first?.baseURL ?? "http://localhost:11434",
                        preferredModelIDs: [],
                        ollamaEndpoints: providerEndpoints
                    )
                )
            }

            let snapshotToWrite = snapshot
            _ = try await daemonRPC {
                try updateConfig(socketURL, snapshotToWrite)
            }
        }
    }
}
