import FirebaseFirestore
import Foundation
import OpenBurnBarCore

final class TextExpansionSyncService: CloudSyncDomain, Sendable {
    private let context: CloudSyncContext
    private let vaultKeyStore: any SessionLogVaultKeyProviding
    private let vaultKeyPublisher: any SessionLogVaultKeyPublishing

    private let state = Locked(CloudSyncDomainState())

    var isSyncing: Bool { state.read().isSyncing }
    var lastSyncError: String? { state.read().lastSyncError }
    var lastSyncDate: Date? { state.read().lastSyncDate }

    init(
        context: CloudSyncContext,
        vaultKeyStore: any SessionLogVaultKeyProviding = CloudVaultKeyStore(),
        vaultKeyPublisher: any SessionLogVaultKeyPublishing = FirebaseSessionLogVaultKeyPublisher()
    ) {
        self.context = context
        self.vaultKeyStore = vaultKeyStore
        self.vaultKeyPublisher = vaultKeyPublisher

        // Observe immediate sync requests from the settings UI
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSnippetChangeNotification),
            name: .textExpansionSnippetsDidChange,
            object: nil
        )
    }

    @objc private func handleSnippetChangeNotification() {
        Task { await sync() }
    }

    /// The raw Firestore handle the Signal payload APIs require, sourced from
    /// the gateway so this service never resolves the global singleton itself.
    /// Internal (not private) so the nil-guard is directly unit-testable: the
    /// Signal-gated call sites only run with a configured FirebaseApp.
    func signalPayloadFirestore() throws -> Firestore {
        guard let firestore = context.firestoreGateway.rawSignalPayloadFirestore() else {
            throw TextExpansionSignalSyncError.signalFirestoreUnavailable
        }
        return firestore // cov:ignore -- a real handle exists only with a configured FirebaseApp; the nil-guard throw path is unit-tested (TextExpansionSyncServiceTests).
    }

    func sync() async {
        let gate = await context.syncGate()
        guard !gate.syncSuppressed,
              gate.settings.textExpansionCloudSyncEnabled,
              let uid = gate.account.uid else { return }
        guard state.beginSyncingIfIdle() else { return }
        defer { state.endSyncing() }

        do {
            let vaultKey = try vaultKeyStore.getOrCreateKey(uid: uid)
            try await vaultKeyPublisher.publishCloudVaultKey(uid: uid, vaultKey: vaultKey, context: context)
            let signalResolvedKey: CloudVaultResolvedKey?
            if MacCloudVaultSignalPayloads.signalSealingIsEnabled(domainID: "conversations_chat") {
                let resolved = try await MacCloudVaultKeyAccess.keyForWriting(
                    uid: uid,
                    deviceId: gate.account.deviceId,
                    firestore: signalPayloadFirestore() // cov:ignore -- Signal-gated call site; the gate is ON only with a configured FirebaseApp + Remote Config, and the helper's guard is unit-tested.
                )
                guard resolved.keyData == vaultKey else {
                    throw TextExpansionSignalSyncError.vaultKeyMismatch
                }
                signalResolvedKey = resolved
            } else {
                signalResolvedKey = nil
            }
            try await uploadPending(
                uid: uid,
                vaultKey: vaultKey,
                deviceId: gate.account.deviceId,
                signalResolvedKey: signalResolvedKey
            )
            try await downloadRemote(uid: uid, vaultKey: vaultKey, signalResolvedKey: signalResolvedKey)
            state.withLock { $0.lastSyncDate = Date() }
        } catch {
            state.withLock { $0.lastSyncError = error.localizedDescription }
            await context.suppressSync(for: CloudSyncBackoffPolicy.permissionDeniedCooldown)
        }
    }

    private func uploadPending(
        uid: String,
        vaultKey: Data,
        deviceId: String,
        signalResolvedKey: CloudVaultResolvedKey?
    ) async throws {
        let snippets = try await context.dataStore.fetchUnsyncedTextExpansionSnippets(limit: 200)
        guard !snippets.isEmpty else { return }
        let collection = context.firestoreGateway
            .collection("users")
            .document(uid)
            .collection("text_snippets")
        let batch = context.firestoreGateway.batch()
        for snippet in snippets {
            let document = collection.document(snippet.id)
            var payload = try Self.cloudDocument(
                    snippet: snippet,
                    uid: uid,
                    deviceID: deviceId,
                    vaultKey: vaultKey
                )
            // NOTE: no `source` producer marker here — the text_snippets Firestore
            // allowlists (legacy validator and Signal mirror gate) reject it.
            if let signalResolvedKey {
                let signalPayload = try await MacCloudVaultSignalPayloads.applyingSignalEnvelope(
                    to: payload as NSDictionary,
                    domainID: "conversations_chat",
                    uid: uid,
                    firestore: try signalPayloadFirestore(), // cov:ignore -- Signal-gated call site; the gate is ON only with a configured FirebaseApp + Remote Config, and the helper's guard is unit-tested.
                    collection: "text_snippets",
                    docId: snippet.id,
                    plaintext: try Self.signalPlaintext(snippet),
                    resolvedKey: signalResolvedKey,
                    legacyPrivateFields: [
                        "sealedTitle", "sealedTrigger", "sealedBody", "sealedScope", "triggerHash", "encryption"
                    ],
                    mergeWrite: true
                )
                payload = CloudSyncFirestoreLiveGateway.firestoreData(signalPayload)
            }
            batch.setData(
                payload,
                forDocument: document,
                merge: true
            )
        }
        try await batch.commit()
        try await context.dataStore.markTextExpansionSnippetsSynced(ids: snippets.map(\.id))
    }

    private func downloadRemote(
        uid: String,
        vaultKey: Data,
        signalResolvedKey: CloudVaultResolvedKey?
    ) async throws {
        let local = Dictionary(
            uniqueKeysWithValues: (try await context.dataStore.fetchTextExpansionSnippets(includeDeleted: true)).map { ($0.id, $0) }
        )
        let snapshot = try await context.firestoreGateway
            .collection("users")
            .document(uid)
            .collection("text_snippets")
            .limit(to: 500)
            .getDocuments()

        let trustedSenders: [String: Data]
        let senderSetComplete: Bool
        if let identity = signalResolvedKey?.signalIdentity {
            do {
                let recipients = try await MacCloudVaultSignalPayloads.atRestRecipients(
                    uid: uid,
                    firestore: signalPayloadFirestore(), // cov:ignore -- Signal-gated call site; the gate is ON only with a configured FirebaseApp + Remote Config, and the helper's guard is unit-tested.
                    localIdentity: identity
                )
                trustedSenders = Dictionary(
                    uniqueKeysWithValues: recipients.map { ($0.recipientIdentityKeyId, $0.publicKeyData) }
                )
                senderSetComplete = true
            } catch {
                trustedSenders = [identity.identityKeyId: identity.atRestRecipient().publicKeyData]
                senderSetComplete = false
            }
        } else {
            trustedSenders = [:]
            senderSetComplete = false
        }

        for doc in snapshot.documents {
            let data = doc.data()
            let remote: TextExpansionSnippet?
            if data["signalEnvelope"] != nil {
                do {
                    let plaintext = try MacCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                        data,
                        uid: uid,
                        collection: "text_snippets",
                        docId: doc.documentID,
                        signalIdentity: signalResolvedKey?.signalIdentity,
                        trustedSenderPublicKeys: trustedSenders
                    )
                    remote = plaintext.flatMap(Self.snippetFromSignalPayload)
                } catch {
                    let required = MacCloudVaultSignalPayloads.signalSealingIsRequired(
                        domainID: "conversations_chat"
                    )
                    guard !required,
                          MacCloudVaultSignalPayloads.allowsLegacyAtRestFallback(
                            for: error,
                            senderSetComplete: senderSetComplete
                          ) else {
                        throw error
                    }
                    remote = try Self.snippet(from: data, documentID: doc.documentID, vaultKey: vaultKey)
                }
            } else {
                remote = try Self.snippet(from: data, documentID: doc.documentID, vaultKey: vaultKey)
            }
            guard let remote else {
                continue
            }
            if let localSnippet = local[remote.id], localSnippet.updatedAt > remote.updatedAt {
                continue
            }
            try await context.dataStore.saveRemoteTextExpansionSnippet(remote)
        }
    }

    private static func cloudDocument(
        snippet: TextExpansionSnippet,
        uid: String,
        deviceID: String,
        vaultKey: Data
    ) throws -> [String: Any] {
        let scopeJSON = try OpenBurnBarDatabase.encodeJSON(snippet.scope)
        let triggerHash = try CloudVaultCrypto.tokenHashes(for: snippet.trigger, keyData: vaultKey, limit: 1).first
            ?? CloudVaultCrypto.sha256Hex(snippet.trigger)
        func seal(_ value: String, field: String) throws -> [String: Any] {
            try dictionary(CloudVaultCrypto.sealText(
                value,
                keyData: vaultKey,
                aadContext: CloudVaultAADContext(
                    uid: uid,
                    collection: "text_snippets",
                    docID: snippet.id,
                    field: field
                )
            ))
        }
        var data: [String: Any] = [
            "id": snippet.id,
            "uid": uid,
            "sourceDeviceID": snippet.sourceDeviceID ?? deviceID,
            "triggerHash": triggerHash,
            "sealedTitle": try seal(snippet.title, field: "sealedTitle"),
            "sealedTrigger": try seal(snippet.trigger, field: "sealedTrigger"),
            "sealedBody": try seal(snippet.body, field: "sealedBody"),
            "sealedScope": try seal(scopeJSON, field: "sealedScope"),
            "mode": snippet.mode.rawValue,
            "isEnabled": snippet.isEnabled,
            "revision": snippet.revision,
            "createdAt": snippet.createdAt,
            "updatedAt": snippet.updatedAt,
            "schemaVersion": CloudVaultCrypto.currentSealedTextSchemaVersion,
            "encryption": [
                "algorithm": CloudVaultCrypto.aesGCMAlgorithm,
                "keyVersion": CloudVaultCrypto.currentKeyVersion,
                "tokenHashVersion": CloudVaultCrypto.tokenHashVersion
            ]
        ]
        data["deletedAt"] = snippet.deletedAt ?? NSNull()
        return data
    }

    private static func signalPlaintext(_ snippet: TextExpansionSnippet) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snippet)
    }

    /// Internal (not private) so decode behavior is directly unit-testable: the
    /// Signal-envelope download path only runs with a configured FirebaseApp.
    static func snippetFromSignalPayload(_ payload: Data) -> TextExpansionSnippet? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return AppLogger.sync.silentlyOptional(
            "text_expansion_signal_payload_decode",
            try decoder.decode(TextExpansionSnippet.self, from: payload)
        )
    }

    private static func snippet(from data: [String: Any], documentID: String, vaultKey: Data) throws -> TextExpansionSnippet? {
        guard let sealedTitle = CloudVaultCrypto.decodeSealedText(from: data["sealedTitle"]),
              let sealedTrigger = CloudVaultCrypto.decodeSealedText(from: data["sealedTrigger"]),
              let sealedBody = CloudVaultCrypto.decodeSealedText(from: data["sealedBody"]),
              let sealedScope = CloudVaultCrypto.decodeSealedText(from: data["sealedScope"]),
              let modeRaw = data["mode"] as? String,
              let mode = TextExpansionMode(rawValue: modeRaw),
              let createdAt = date(from: data["createdAt"]),
              let updatedAt = date(from: data["updatedAt"]) else {
            return nil
        }
        let snippetID = (data["id"] as? String) ?? documentID
        let snippetUID = data["uid"] as? String
        func open(_ envelope: CloudVaultSealedText, field: String) throws -> String {
            if (envelope.schemaVersion ?? 1) >= CloudVaultCrypto.currentSealedTextSchemaVersion {
                guard let snippetUID, !snippetUID.isEmpty else {
                    throw CloudVaultCryptoError.invalidEnvelope
                }
                return try CloudVaultCrypto.openText(
                    envelope,
                    keyData: vaultKey,
                    aadContext: CloudVaultAADContext(
                        uid: snippetUID,
                        collection: "text_snippets",
                        docID: snippetID,
                        field: field
                    )
                )
            }
            return try CloudVaultCrypto.openText(envelope, keyData: vaultKey)
        }
        let scopeJSON = try open(sealedScope, field: "sealedScope")
        let scope: TextExpansionScope
        if let scopeData = scopeJSON.data(using: .utf8) {
            do {
                scope = try JSONDecoder().decode(TextExpansionScope.self, from: scopeData)
            } catch {
                scope = .global
            }
        } else {
            scope = .global
        }
        return TextExpansionSnippet(
            id: snippetID,
            title: try open(sealedTitle, field: "sealedTitle"),
            trigger: try open(sealedTrigger, field: "sealedTrigger"),
            body: try open(sealedBody, field: "sealedBody"),
            mode: mode,
            isEnabled: (data["isEnabled"] as? Bool) ?? true,
            scope: scope,
            revision: revision(from: data["revision"]) ?? 1,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: date(from: data["deletedAt"]),
            syncedAt: Date(),
            sourceDeviceID: data["sourceDeviceID"] as? String
        )
    }

    private static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { return [:] }
        return dictionary
    }

    private static func date(from value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        return OpenBurnBarDatabase.parseDateValue(value)
    }

    private static func revision(from value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

enum TextExpansionSignalSyncError: LocalizedError {
    case vaultKeyMismatch
    case signalFirestoreUnavailable

    var errorDescription: String? {
        switch self {
        case .vaultKeyMismatch:
            return "Signal identity and CloudVault resolved different vault keys. Re-verify this device before syncing snippets."
        case .signalFirestoreUnavailable:
            return "The Firestore gateway does not expose a raw handle for Signal payload sealing. Snippet sync was skipped."
        }
    }
}
