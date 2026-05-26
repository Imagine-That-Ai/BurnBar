import FirebaseFirestore
import Foundation
import OpenBurnBarCore

@MainActor
final class TextExpansionSyncService: CloudSyncDomain {
    private let context: CloudSyncContext
    private let vaultKeyStore: CloudVaultKeyStore
    private let vaultKeyPublisher: FirebaseSessionLogVaultKeyPublisher

    private(set) var isSyncing = false
    private(set) var lastSyncError: String?
    private(set) var lastSyncDate: Date?

    init(
        context: CloudSyncContext,
        vaultKeyStore: CloudVaultKeyStore = CloudVaultKeyStore(),
        vaultKeyPublisher: FirebaseSessionLogVaultKeyPublisher = FirebaseSessionLogVaultKeyPublisher()
    ) {
        self.context = context
        self.vaultKeyStore = vaultKeyStore
        self.vaultKeyPublisher = vaultKeyPublisher
    }

    func sync() async {
        guard !isSyncing,
              !context.syncIsSuppressed(),
              SettingsManager.shared.textExpansion.cloudSyncEnabled,
              let uid = context.currentUID else { return }
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        do {
            let vaultKey = try vaultKeyStore.getOrCreateKey(uid: uid)
            try await vaultKeyPublisher.publishCloudVaultKey(uid: uid, vaultKey: vaultKey, context: context)
            try await uploadPending(uid: uid, vaultKey: vaultKey)
            try await downloadRemote(uid: uid, vaultKey: vaultKey)
            lastSyncDate = Date()
        } catch {
            lastSyncError = error.localizedDescription
            context.suppressedSyncUntil = Date().addingTimeInterval(CloudSyncBackoffPolicy.permissionDeniedCooldown)
        }
    }

    private func uploadPending(uid: String, vaultKey: Data) async throws {
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
                    deviceID: context.deviceId,
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
        var data: [String: Any] = [
            "id": snippet.id,
            "uid": uid,
            "sourceDeviceID": snippet.sourceDeviceID ?? deviceID,
            "triggerHash": triggerHash,
            "sealedTitle": try dictionary(CloudVaultCrypto.sealText(snippet.title, keyData: vaultKey)),
            "sealedTrigger": try dictionary(CloudVaultCrypto.sealText(snippet.trigger, keyData: vaultKey)),
            "sealedBody": try dictionary(CloudVaultCrypto.sealText(snippet.body, keyData: vaultKey)),
            "sealedScope": try dictionary(CloudVaultCrypto.sealText(scopeJSON, keyData: vaultKey)),
            "mode": snippet.mode.rawValue,
            "isEnabled": snippet.isEnabled,
            "revision": snippet.revision,
            "createdAt": snippet.createdAt,
            "updatedAt": snippet.updatedAt,
            "schemaVersion": 1,
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
        let scopeJSON = try CloudVaultCrypto.openText(sealedScope, keyData: vaultKey)
        let scope = scopeJSON.data(using: .utf8).flatMap {
            try? JSONDecoder().decode(TextExpansionScope.self, from: $0)
        } ?? .global
        return TextExpansionSnippet(
            id: (data["id"] as? String) ?? documentID,
            title: try CloudVaultCrypto.openText(sealedTitle, keyData: vaultKey),
            trigger: try CloudVaultCrypto.openText(sealedTrigger, keyData: vaultKey),
            body: try CloudVaultCrypto.openText(sealedBody, keyData: vaultKey),
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
        guard let dictionary = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dictionary) else {
            return nil
        }
        return try? JSONDecoder().decode(CloudVaultSealedText.self, from: data)
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
