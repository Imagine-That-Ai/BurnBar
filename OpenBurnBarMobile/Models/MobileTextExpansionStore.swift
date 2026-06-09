import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import Observation
import FirebaseAuth
import FirebaseFirestore
import UIKit

@MainActor
@Observable
final class MobileTextExpansionStore {
    private(set) var snippets: [TextExpansionSnippet] = []
    var statusMessage: String?
    private var syncTask: Task<Void, Never>?
    private var firestoreListener: ListenerRegistration?
    private var cachedVaultKey: Data?
    private var cachedUID: String?

    /// Darwin notification name for cross-process snippet updates.
    /// The keyboard extension listens for this to reload instantly.
    static let snippetsUpdatedNotification = "com.openburnbar.snippets.updated" as CFString

    init() {
        load()
        scheduleCloudSync()
        startRealtimeListener()
    }

    func load() {
        guard let url = TextExpansionSnapshotStore.snapshotURL() else {
            snippets = []
            return
        }
        do {
            snippets = try TextExpansionSnapshotStore.read(from: url).snippets
        } catch {
            snippets = []
        }
        ingestInbox()
    }

    /// Drains snippets created in the iOS keyboard extension and merges them into
    /// the live set so they sync to the cloud through the normal path. The keyboard
    /// already merged each addition into the shared snapshot for instant local use;
    /// this brings them into the app's source of truth and triggers an upload.
    private func ingestInbox() {
        let pending = TextExpansionInbox.drain()
        guard pending.isEmpty == false else { return }

        var byID = Dictionary(snippets.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        for snippet in pending {
            if let existing = byID[snippet.id] {
                if existing.updatedAt >= snippet.updatedAt { continue }
            } else if snippets.contains(where: {
                $0.id != snippet.id && $0.deletedAt == nil && $0.trigger == snippet.trigger
            }) {
                // Trigger was claimed by another snippet between keyboard add and
                // ingestion — drop the duplicate rather than create a conflict.
                continue
            }
            byID[snippet.id] = snippet
        }

        snippets = Self.sorted(Array(byID.values).filter(\.isActive))
        saveLocalSnapshot()
        scheduleCloudSync()
    }

    /// Foreground entry point: if the keyboard queued any additions, load them and
    /// push to the cloud. Cheap no-op when the inbox is empty, so it is safe to call
    /// on every `didBecomeActive`. The transient store is retained for the duration
    /// of the upload by the `await`.
    @MainActor
    static func ingestKeyboardInboxIfNeeded() async {
        guard TextExpansionInbox.hasPending() else { return }
        let store = MobileTextExpansionStore()
        await store.syncCloud()
    }

    func upsert(_ snippet: TextExpansionSnippet) {
        var normalized = snippet
        normalized.trigger = TextExpansionTrigger.canonicalName(snippet.trigger)
        if let validationError = TextExpansionTrigger.validationError(for: normalized.trigger) {
            statusMessage = validationError
            return
        }
        if snippets.contains(where: { $0.id != normalized.id && $0.deletedAt == nil && $0.trigger == normalized.trigger }) {
            statusMessage = "Trigger already exists."
            return
        }

        var all = snippets.filter { $0.id != normalized.id }
        all.append(normalized)
        snippets = all.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        saveLocalSnapshot()
        scheduleCloudSync()
    }

    func delete(id: String) {
        let existing = snippets.first { $0.id == id }
        snippets.removeAll { $0.id == id }
        saveLocalSnapshot()
        Task {
            if let existing {
                var tombstone = existing
                tombstone.isEnabled = false
                tombstone.updatedAt = Date()
                tombstone.deletedAt = tombstone.updatedAt
                tombstone.revision += 1
                await uploadTombstone(tombstone)
            }
            await syncCloud()
        }
    }

    func syncCloud() async {
        guard UserDefaults.standard.object(forKey: "textExpansion.cloudSyncEnabled") as? Bool ?? true else { return }
        do {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            let key = try await unlockOrCreateCloudVaultKey(uid: uid)
            try await publishCloudVaultKey(uid: uid, vaultKey: key)

            let db = Firestore.firestore()
            let collection = db.collection("users").document(uid).collection("text_snippets")
            let snapshot = try await collection.getDocuments()
            var merged = Dictionary(uniqueKeysWithValues: snippets.map { ($0.id, $0) })

            for document in snapshot.documents {
                guard let remote = try? Self.decodeSnippet(documentID: document.documentID, data: document.data(), key: key) else {
                    continue
                }
                if let local = merged[remote.id], local.updatedAt > remote.updatedAt {
                    try await upload(local, uid: uid, key: key)
                } else if remote.deletedAt != nil || remote.isEnabled == false {
                    merged.removeValue(forKey: remote.id)
                } else {
                    merged[remote.id] = remote
                }
            }

            snippets = Self.sorted(Array(merged.values).filter(\.isActive))
            saveLocalSnapshot()
            for snippet in snippets {
                try await upload(snippet, uid: uid, key: key)
            }
            statusMessage = "Synced"
        } catch {
            statusMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    private func saveLocalSnapshot() {
        guard let url = TextExpansionSnapshotStore.snapshotURL() else {
            statusMessage = "App Group storage is unavailable."
            return
        }
        do {
            try TextExpansionSnapshotStore.write(TextExpansionSnapshot(snippets: snippets.filter(\.isActive)), to: url)
            statusMessage = "Saved"
            // Notify the keyboard extension to reload immediately
            Self.postSnippetUpdateNotification()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Posts a Darwin notification so the keyboard extension can reload snippets.
    /// Darwin notifications are the only IPC mechanism available between an app
    /// and its keyboard extension (no App Groups notifications, no NSNotificationCenter).
    static func postSnippetUpdateNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(snippetsUpdatedNotification), nil, nil, true)
    }

    private func scheduleCloudSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await self?.syncCloud()
        }
    }

    private func uploadTombstone(_ snippet: TextExpansionSnippet) async {
        do {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            let key = try await unlockOrCreateCloudVaultKey(uid: uid)
            try await publishCloudVaultKey(uid: uid, vaultKey: key)
            try await upload(snippet, uid: uid, key: key)
        } catch {
            statusMessage = "Cloud tombstone failed: \(error.localizedDescription)"
        }
    }

    private func upload(_ snippet: TextExpansionSnippet, uid: String, key: Data) async throws {
        let data = try Self.encodeSnippet(snippet, uid: uid, key: key)
        try await Firestore.firestore()
            .collection("users").document(uid)
            .collection("text_snippets").document(snippet.id)
            .setData(data, merge: true)
    }

    private func unlockOrCreateCloudVaultKey(uid: String) async throws -> Data {
        try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid).keyData
    }

    private func publishCloudVaultKey(uid: String, vaultKey: Data) async throws {
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: vaultKey)
        let db = Firestore.firestore()
        let userRef = db.collection("users").document(uid)
        let deviceId = MobileDeviceIdentity.loadOrCreateDeviceId()
        let keypair = try iOSDeviceKeypair()
        let deviceName = UIDevice.current.name

        let deviceRef = userRef.collection("escrow_devices").document(deviceId)
        let existingSnapshot = try? await deviceRef.getDocument()
        let existing = existingSnapshot?.data()
        let existingTrust = existing?["trustState"] as? String
        let sourceIsTrusted = existingTrust == EscrowDeviceTrustState.trusted.rawValue

        try await userRef.collection("devices").document(deviceId).setData([
            "deviceId": deviceId,
            "deviceName": deviceName,
            "platform": UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS",
            "lastActiveAt": FieldValue.serverTimestamp()
        ], merge: true)
        var devicePayload: [String: Any] = [
            "deviceId": deviceId,
            "deviceName": deviceName,
            "platform": UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS",
            "publicKeyFingerprint": keypair.publicKeyFingerprint,
            "keyVersion": keypair.keyVersion,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if existingSnapshot?.exists == false {
            devicePayload["trustState"] = EscrowDeviceTrustState.pending.rawValue
        }
        try await deviceRef.setData(devicePayload, merge: true)
        try await MobileEscrowPublicKeyPublisher.publishIfNeeded(
            userRef: userRef,
            deviceId: deviceId,
            publicKeyData: keypair.publicKeyData,
            publicKeyFingerprint: keypair.publicKeyFingerprint,
            keyVersion: keypair.keyVersion
        )
        let signalIdentity = try OpenBurnBarSignalIdentityKeyStore().loadOrCreate(uid: uid, deviceId: deviceId)
        try await MobileSignalIdentityPublicKeyPublisher.publishIfNeeded(
            userRef: userRef,
            deviceId: deviceId,
            platform: UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS",
            identity: signalIdentity
        )
        guard sourceIsTrusted else {
            return
        }

        let trusted = try await userRef.collection("escrow_devices")
            .whereField("trustState", isEqualTo: EscrowDeviceTrustState.trusted.rawValue)
            .getDocuments()
        for document in trusted.documents {
            let target = try await MobileCloudVaultTrustedDeviceChainVerifier.verifiedTrustedDevice(
                uid: uid,
                userRef: userRef,
                deviceDocument: document,
                localIdentity: signalIdentity
            )
            let wrapped = try CloudVaultCrypto.wrapVaultKey(
                vaultKey,
                recipientPublicKey: target.escrowPublicKeyData
            )
            try await userRef.collection("cloud_vault_key_wrappers")
                .document("\(target.deviceId)_\(target.keyVersion)")
                .setData([
                    "uid": uid,
                    "vaultKeyID": vaultKeyID,
                    "targetDeviceId": target.deviceId,
                    "sourceDeviceId": deviceId,
                    "publicKeyFingerprint": target.escrowPublicKeyFingerprint,
                    "keyVersion": target.keyVersion,
                    "wrappedVaultKey": wrapped.base64EncodedString(),
                    "algorithm": "ECIES-P256-AESGCM",
                    "status": "active",
                    "createdAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp(),
                    "schemaVersion": 2
                ], merge: true)
        }
    }

    private static func sorted(_ snippets: [TextExpansionSnippet]) -> [TextExpansionSnippet] {
        snippets.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Real-Time Firestore Listener

    /// Starts a Firestore snapshot listener on `text_snippets` so changes from
    /// any device (Mac, other iPhones) are reflected on this device within seconds.
    private func startRealtimeListener() {
        guard firestoreListener == nil else { return }
        guard UserDefaults.standard.object(forKey: "textExpansion.cloudSyncEnabled") as? Bool ?? true else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }

        let collection = Firestore.firestore()
            .collection("users").document(uid)
            .collection("text_snippets")

        firestoreListener = collection.addSnapshotListener { [weak self] snapshot, error in
            guard let self, let snapshot, error == nil else { return }
            // Skip the initial snapshot (we already loaded from local)
            guard !snapshot.metadata.hasPendingWrites else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleRealtimeUpdate(snapshot)
            }
        }
    }

    /// Processes a real-time Firestore snapshot update.
    private func handleRealtimeUpdate(_ snapshot: QuerySnapshot) async {
        do {
            guard let uid = Auth.auth().currentUser?.uid else { return }

            // Get or cache the vault key
            if cachedVaultKey == nil || cachedUID != uid {
                cachedVaultKey = try await unlockOrCreateCloudVaultKey(uid: uid)
                cachedUID = uid
            }
            guard let key = cachedVaultKey else { return }

            var merged = Dictionary(uniqueKeysWithValues: snippets.map { ($0.id, $0) })
            var changed = false

            for change in snapshot.documentChanges {
                let doc = change.document
                guard let remote = try? Self.decodeSnippet(documentID: doc.documentID, data: doc.data(), key: key) else {
                    continue
                }

                switch change.type {
                case .added, .modified:
                    if remote.deletedAt != nil || !remote.isEnabled {
                        if merged.removeValue(forKey: remote.id) != nil { changed = true }
                    } else {
                        let local = merged[remote.id]
                        if local == nil || remote.updatedAt > (local?.updatedAt ?? .distantPast) {
                            merged[remote.id] = remote
                            changed = true
                        }
                    }
                case .removed:
                    if merged.removeValue(forKey: remote.id) != nil { changed = true }
                }
            }

            if changed {
                snippets = Self.sorted(Array(merged.values).filter(\.isActive))
                saveLocalSnapshot()
            }
        } catch {
            // Vault key not available yet — fall back to polling sync
        }
    }

    /// Stops the real-time listener (call on deinit or sign-out).
    func stopRealtimeListener() {
        firestoreListener?.remove()
        firestoreListener = nil
        cachedVaultKey = nil
        cachedUID = nil
    }

    private static func encodeSnippet(_ snippet: TextExpansionSnippet, uid: String, key: Data) throws -> [String: Any] {
        let scopeJSON = String(data: try jsonData(snippet.scope), encoding: .utf8) ?? "{}"
        let triggerHash = try CloudVaultCrypto.tokenHashes(for: snippet.trigger, keyData: key, limit: 1).first
            ?? CloudVaultCrypto.sha256Hex(snippet.trigger)
        func seal(_ value: String, field: String) throws -> [String: Any] {
            try dictionary(CloudVaultCrypto.sealText(
                value,
                keyData: key,
                aadContext: CloudVaultAADContext(
                    uid: uid,
                    collection: "text_snippets",
                    docID: snippet.id,
                    field: field
                )
            ))
        }
        return [
            "id": snippet.id,
            "uid": uid,
            "sourceDeviceID": snippet.sourceDeviceID ?? MobileDeviceIdentity.loadOrCreateDeviceId(),
            "triggerHash": triggerHash,
            "sealedTitle": try seal(snippet.title, field: "sealedTitle"),
            "sealedTrigger": try seal(snippet.trigger, field: "sealedTrigger"),
            "sealedBody": try seal(snippet.body, field: "sealedBody"),
            "sealedScope": try seal(scopeJSON, field: "sealedScope"),
            "mode": snippet.mode.rawValue,
            "isEnabled": snippet.isEnabled,
            "revision": snippet.revision,
            "createdAt": Timestamp(date: snippet.createdAt),
            "updatedAt": Timestamp(date: snippet.updatedAt),
            "deletedAt": snippet.deletedAt.map(Timestamp.init(date:)) as Any? ?? NSNull(),
            "schemaVersion": CloudVaultCrypto.currentSealedTextSchemaVersion,
            "encryption": [
                "algorithm": CloudVaultCrypto.aesGCMAlgorithm,
                "keyVersion": CloudVaultCrypto.currentKeyVersion,
                "tokenHashVersion": CloudVaultCrypto.tokenHashVersion
            ]
        ]
    }

    private static func decodeSnippet(documentID: String, data: [String: Any], key: Data) throws -> TextExpansionSnippet? {
        guard let sealedTitle = sealedText(data["sealedTitle"]),
              let sealedTrigger = sealedText(data["sealedTrigger"]),
              let sealedBody = sealedText(data["sealedBody"]),
              let sealedScope = sealedText(data["sealedScope"]),
              let modeRaw = data["mode"] as? String,
              let mode = TextExpansionMode(rawValue: modeRaw) else {
            return nil
        }
        let snippetID = data["id"] as? String ?? documentID
        let snippetUID = data["uid"] as? String
        func open(_ envelope: CloudVaultSealedText, field: String) throws -> String {
            if (envelope.schemaVersion ?? 1) >= CloudVaultCrypto.currentSealedTextSchemaVersion {
                guard let snippetUID, !snippetUID.isEmpty else {
                    throw CloudVaultCryptoError.invalidEnvelope
                }
                return try CloudVaultCrypto.openText(
                    envelope,
                    keyData: key,
                    aadContext: CloudVaultAADContext(
                        uid: snippetUID,
                        collection: "text_snippets",
                        docID: snippetID,
                        field: field
                    )
                )
            }
            return try CloudVaultCrypto.openText(envelope, keyData: key)
        }
        let scopeJSON = try open(sealedScope, field: "sealedScope")
        let scope = (try? JSONDecoder().decode(TextExpansionScope.self, from: Data(scopeJSON.utf8))) ?? .global
        return TextExpansionSnippet(
            id: snippetID,
            title: try open(sealedTitle, field: "sealedTitle"),
            trigger: try open(sealedTrigger, field: "sealedTrigger"),
            body: try open(sealedBody, field: "sealedBody"),
            mode: mode,
            isEnabled: data["isEnabled"] as? Bool ?? true,
            scope: scope,
            revision: data["revision"] as? Int ?? 1,
            createdAt: timestamp(data["createdAt"]) ?? Date(),
            updatedAt: timestamp(data["updatedAt"]) ?? Date(),
            deletedAt: timestamp(data["deletedAt"]),
            sourceDeviceID: data["sourceDeviceID"] as? String
        )
    }

    private static func timestamp(_ value: Any?) -> Date? {
        if let timestamp = value as? Timestamp {
            return timestamp.dateValue()
        }
        return value as? Date
    }

    private static func sealedText(_ raw: Any?) -> CloudVaultSealedText? {
        guard let raw else { return nil }
        if let envelope = raw as? CloudVaultSealedText { return envelope }
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else {
            return nil
        }
        return try? JSONDecoder().decode(CloudVaultSealedText.self, from: data)
    }

    private static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return dictionary
    }

    private static func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}
