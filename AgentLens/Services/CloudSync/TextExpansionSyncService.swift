import FirebaseFirestore
import Foundation
import OpenBurnBarCore

final class TextExpansionSyncService: CloudSyncDomain, @unchecked Sendable {
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

    func sync() async {
        let gate = await context.syncGate()
        let textExpansionCloudSyncEnabled = await MainActor.run {
            SettingsManager.shared.textExpansion.cloudSyncEnabled
        }
        guard !gate.syncSuppressed,
              textExpansionCloudSyncEnabled,
              let uid = gate.account.uid else { return }
        guard state.beginSyncingIfIdle() else { return }
        defer { state.endSyncing() }

        do {
            let vaultKey = try vaultKeyStore.getOrCreateKey(uid: uid)
            try await vaultKeyPublisher.publishCloudVaultKey(uid: uid, vaultKey: vaultKey, context: context)
            try await uploadPending(uid: uid, vaultKey: vaultKey, deviceId: gate.account.deviceId)
            try await downloadRemote(uid: uid, vaultKey: vaultKey)
            state.withLock { $0.lastSyncDate = Date() }
        } catch {
            state.withLock { $0.lastSyncError = error.localizedDescription }
            await context.suppressSync(for: CloudSyncBackoffPolicy.permissionDeniedCooldown)
        }
    }

    private func uploadPending(uid: String, vaultKey: Data, deviceId: String) async throws {
        let snippets = try context.dataStore.fetchUnsyncedTextExpansionSnippets(limit: 200)
        guard !snippets.isEmpty else { return }
        let collection = context.firestoreGateway
            .collection("users")
            .document(uid)
            .collection("text_snippets")
        let batch = context.firestoreGateway.batch()
        for snippet in snippets {
            let document = collection.document(snippet.id)
            batch.setData(
                try Self.cloudDocument(
                    snippet: snippet,
                    uid: uid,
                    deviceID: deviceId,
                    vaultKey: vaultKey
                ),
                forDocument: document,
                merge: true
            )
        }
        try await batch.commit()
        try context.dataStore.markTextExpansionSnippetsSynced(ids: snippets.map(\.id))
    }

    private func downloadRemote(uid: String, vaultKey: Data) async throws {
        let local = Dictionary(
            uniqueKeysWithValues: (try context.dataStore.fetchTextExpansionSnippets(includeDeleted: true)).map { ($0.id, $0) }
        )
        let snapshot = try await context.firestoreGateway
            .collection("users")
            .document(uid)
            .collection("text_snippets")
            .limit(to: 500)
            .getDocuments()

        for doc in snapshot.documents {
            let data = doc.data()
            guard let remote = try Self.snippet(from: data, documentID: doc.documentID, vaultKey: vaultKey) else {
                continue
            }
            if let localSnippet = local[remote.id], localSnippet.updatedAt > remote.updatedAt {
                continue
            }
            try context.dataStore.saveRemoteTextExpansionSnippet(remote)
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

    private static func snippet(from data: [String: Any], documentID: String, vaultKey: Data) throws -> TextExpansionSnippet? {
        guard let sealedTitle = sealedText(from: data["sealedTitle"]),
              let sealedTrigger = sealedText(from: data["sealedTrigger"]),
              let sealedBody = sealedText(from: data["sealedBody"]),
              let sealedScope = sealedText(from: data["sealedScope"]),
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

    private static func sealedText(from value: Any?) -> CloudVaultSealedText? {
        guard let dictionary = value as? [String: Any] else {
            return nil
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dictionary)
            return try JSONDecoder().decode(CloudVaultSealedText.self, from: data)
        } catch {
            return nil
        }
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
