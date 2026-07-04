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
        let remoteData = try await document.getData()
        if let remoteData,
           let remoteEnvelope = try Self.sealedPayload(from: remoteData["sealedPayload"]) {
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
        let routerMode = await MainActor.run {
            OpenBurnBarDaemonManager.shared.routerMode
        }
        let updatedAt = accounts.map(\.updatedAt).max() ?? Date(timeIntervalSince1970: 0)
        return RoamingProfilePayload(
            routerMode: routerMode,
            crossProviderFailoverEnabled: !routerMode.usesExactSameModelInvariant,
            accountOrder: accounts.map(\.id),
            providerAccounts: accounts.map(RoamingProfileProviderAccount.init),
            ollamaEndpoints: [],
            equivalenceOverrides: [],
            quotaDisplayPreferences: quotaPreferences,
            updatedAt: updatedAt,
            sourceDeviceID: deviceID
        )
    }

    func apply(_ payload: RoamingProfilePayload, context: CloudSyncContext) async throws {
        _ = try payload.validatedForCloudVaultSeal()
        for remoteAccount in payload.providerAccounts {
            if let local = try await context.dataStore.fetchProviderAccount(id: remoteAccount.id),
               local.updatedAt > remoteAccount.updatedAt {
                continue
            }
            try await context.dataStore.upsertProviderAccount(remoteAccount.providerAccountDoc)
        }
        await MainActor.run {
            applyQuotaDisplayPreferences(payload.quotaDisplayPreferences, to: context.settingsManager)
        }
        await OpenBurnBarDaemonManager.shared.setRouterMode(payload.routerMode)
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
}
