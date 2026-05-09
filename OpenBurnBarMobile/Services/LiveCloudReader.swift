import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import Security
import UIKit

enum MobileDeviceIdentity {
    static let deviceIDKey = "com.openburnbar.mobile.deviceId"

    /// Returns a stable per-install device id. We anchor on
    /// `UIDevice.identifierForVendor` so reinstalls of the **same** app
    /// from the same vendor land on the same Firestore document, which
    /// prevents the "same iPhone shows up many times" duplicate explosion
    /// in Settings → Devices.
    ///
    /// Vendor IDs do reset if the user uninstalls every OpenBurnBar-vendor
    /// app, so we still cache the first observed ID in UserDefaults to
    /// keep the doc stable across that edge case for the lifetime of this
    /// install. Generated UUIDs remain a last-resort fallback.
    static func loadOrCreateDeviceId(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: deviceIDKey), !stored.isEmpty {
            return stored
        }
        let resolved: String
        if let vendor = UIDevice.current.identifierForVendor?.uuidString, !vendor.isEmpty {
            resolved = vendor
        } else {
            resolved = UUID().uuidString
        }
        defaults.set(resolved, forKey: deviceIDKey)
        return resolved
    }
}

/// Production CloudReader + DeviceTrustGateway + EscrowGateway.
/// Reads Firestore, manages device trust state, handles encrypted credential import.
@MainActor
final class LiveCloudReader: CloudReader {
    private var db: Firestore { Firestore.firestore() }
    private let firestore: FirestoreRepository

    init(firestore: FirestoreRepository = FirestoreRepository()) { self.firestore = firestore }

    private var uid: String? {
        guard FirebaseApp.app() != nil else { return nil }
        return Auth.auth().currentUser?.uid
    }
    private var deviceId: String {
        MobileDeviceIdentity.loadOrCreateDeviceId()
    }

    // MARK: - CloudReader

    func loadSyncStatus() async throws -> CloudSyncStatusSnapshot {
        guard let uid else { throw CloudGatewayError.classified(.notAuthenticated) }
        do {
            // Find the primary Mac device to read its sync status
            let devicesSnap = try await db.collection("users/\(uid)/devices")
                .whereField("platform", isEqualTo: "macOS")
                .order(by: "lastActiveAt", descending: true)
                .limit(to: 1)
                .getDocuments()

            let macDeviceId: String
            let macName: String
            if let macDoc = devicesSnap.documents.first {
                let d = macDoc.data()
                macDeviceId = d["deviceId"] as? String ?? macDoc.documentID
                macName = d["deviceName"] as? String ?? "Mac"
            } else {
                // No Mac found; return empty snapshot
                return CloudSyncStatusSnapshot(
                    lastPublishedAt: nil,
                    lastReadAt: Date(),
                    publisher: nil,
                    lastErrorClassification: nil
                )
            }

            let doc = try await db.document("users/\(uid)/sync_status/\(macDeviceId)").getDocument()
            let d = doc.data()
            let lastPublished = (d?["lastSyncAt"] as? Timestamp)?.dateValue()
            let lastError = d?["lastError"] as? String

            return CloudSyncStatusSnapshot(
                lastPublishedAt: lastPublished,
                lastReadAt: Date(),
                publisher: CloudPublisherDevice(
                    deviceID: macDeviceId,
                    displayName: macName,
                    platform: "macOS",
                    lastSeen: lastPublished ?? Date()
                ),
                lastErrorClassification: lastError != nil ? .other(message: lastError!) : nil
            )
        } catch { throw classify(error) }
    }

    func loadProviderSummaries() async throws -> [ProviderConnectionDoc] {
        do { return try await firestore.fetchProviderConnections() }
        catch { throw classify(error) }
    }

    func loadDevices() async throws -> [DeviceRecord] {
        guard let uid else { throw CloudGatewayError.classified(.notAuthenticated) }

        // Read from both devices and escrow_devices, merge by deviceId
        var deviceMap: [String: DeviceRecord] = [:]

        // General devices registry
        let deviceSnap = try await db.collection("users/\(uid)/devices").getDocuments()
        for doc in deviceSnap.documents {
            let d = doc.data()
            let did = d["deviceId"] as? String ?? doc.documentID
            deviceMap[did] = DeviceRecord(
                id: did, displayName: d["deviceName"] as? String ?? "Unknown",
                platform: d["platform"] as? String ?? "unknown",
                appVersion: d["appVersion"] as? String,
                lastSeen: (d["lastActiveAt"] as? Timestamp)?.dateValue(),
                trustState: did == deviceId ? .current : .trusted,
                approvedAt: nil, keyVersion: nil,
                isCurrentDevice: did == deviceId
            )
        }

        // Escrow devices (adds trust state, approval dates)
        let escrowSnap = try? await db.collection("users/\(uid)/escrow_devices").getDocuments()
        for doc in escrowSnap?.documents ?? [] {
            let d = doc.data()
            let did = d["deviceId"] as? String ?? doc.documentID
            let escrowTrustRaw = d["trustState"] as? String ?? EscrowDeviceTrustState.pending.rawValue
            let trustState: DeviceTrustState
            if did == deviceId {
                trustState = .current
            } else {
                switch escrowTrustRaw {
                case EscrowDeviceTrustState.trusted.rawValue: trustState = .trusted
                case EscrowDeviceTrustState.revoked.rawValue: trustState = .revoked
                default: trustState = .pending
                }
            }
            let approvedAt = (d["approvedAt"] as? Timestamp)?.dateValue()
            let keyVersion = d["keyVersion"] as? Int

            if var existing = deviceMap[did] {
                deviceMap[did] = DeviceRecord(
                    id: existing.id, displayName: existing.displayName,
                    platform: existing.platform, appVersion: existing.appVersion,
                    lastSeen: existing.lastSeen ?? (d["lastActiveAt"] as? Timestamp)?.dateValue(),
                    trustState: trustState, approvedAt: approvedAt,
                    keyVersion: keyVersion, isCurrentDevice: existing.isCurrentDevice
                )
            } else {
                deviceMap[did] = DeviceRecord(
                    id: did, displayName: d["deviceName"] as? String ?? "Unknown",
                    platform: d["platform"] as? String ?? "unknown",
                    appVersion: d["appVersion"] as? String,
                    lastSeen: (d["lastActiveAt"] as? Timestamp)?.dateValue(),
                    trustState: trustState, approvedAt: approvedAt,
                    keyVersion: keyVersion, isCurrentDevice: did == deviceId
                )
            }
        }

        return Array(deviceMap.values)
    }

    func loadAvailableEnvelopes() async throws -> [AvailableEnvelope] {
        guard let uid else { return [] }
        let grants = try await db.collection("users/\(uid)/escrow_grants")
            .whereField("targetDeviceId", isEqualTo: deviceId)
            .whereField("status", isEqualTo: EscrowGrantStatus.granted.rawValue)
            .getDocuments()
        let grantIds = Set(grants.documents.map { $0.documentID })

        let snap = try await db.collection("users/\(uid)/escrow_envelopes")
            .whereField("targetDeviceId", isEqualTo: deviceId)
            .getDocuments()

        return snap.documents.compactMap { doc in
            let d = doc.data()
            guard let gid = d["grantId"] as? String, grantIds.contains(gid) else { return nil }
            guard let pid = d["providerId"] as? String,
                  let prov = AgentProvider.allCases.first(where: { $0.persistedToken == pid }) else { return nil }
            let kindRaw = d["credentialKind"] as? String ?? EscrowCredentialKind.apiKey.rawValue
            let credKind: EscrowCredentialKind
            switch kindRaw {
            case "oauth_token": credKind = .oauthToken
            case "bearer_token": credKind = .bearerToken
            default: credKind = .apiKey
            }
            return AvailableEnvelope(
                id: doc.documentID, provider: prov,
                accountLabel: d["accountLabel"] as? String ?? prov.displayName,
                credentialKind: credKind,
                sourceDeviceID: d["sourceDeviceId"] as? String ?? "Mac",
                sourceDeviceName: d["sourceDeviceId"] as? String ?? "Mac",
                createdAt: (d["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            )
        }
    }

    func loadUnsupportedEnvelopes() async throws -> [UnsupportedEnvelope] { [] }

    func loadImportHistory() async throws -> [ImportHistoryEntry] {
        guard let uid else { return [] }
        let snap = try await db.collection("users/\(uid)/escrow_audit_events")
            .whereField("actorDeviceId", isEqualTo: deviceId)
            .order(by: "timestamp", descending: true)
            .limit(to: 50)
            .getDocuments()

        return snap.documents.compactMap { doc in
            let d = doc.data()
            guard let eventType = d["eventType"] as? String,
                  let providerId = d["providerId"] as? String,
                  let prov = AgentProvider.allCases.first(where: { $0.persistedToken == providerId }),
                  let ts = d["timestamp"] as? Timestamp else { return nil }

            let status: ImportHistoryStatus
            switch eventType {
            case "envelope_imported": status = .validated
            case "import_grant_revoked": status = .revoked
            default: status = .failed
            }

            return ImportHistoryEntry(
                id: doc.documentID,
                provider: prov,
                accountLabel: prov.displayName,
                status: status,
                occurredAt: ts.dateValue(),
                detail: eventType
            )
        }
    }

    private func classify(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == FirestoreErrorDomain {
            switch FirestoreErrorCode.Code(rawValue: ns.code) {
            case .permissionDenied: return CloudGatewayError.classified(.permissionDenied)
            case .unavailable: return CloudGatewayError.classified(.firestoreUnavailable)
            case .unauthenticated: return CloudGatewayError.classified(.notAuthenticated)
            default: break
            }
        }
        if ns.domain == NSURLErrorDomain { return CloudGatewayError.classified(.networkUnavailable) }
        return CloudGatewayError.classified(.other(message: error.localizedDescription))
    }
}

// MARK: - LiveDeviceTrustGateway

@MainActor
final class LiveDeviceTrustGateway: DeviceTrustGateway {
    private var db: Firestore { Firestore.firestore() }
    private var uid: String? {
        guard FirebaseApp.app() != nil else { return nil }
        return Auth.auth().currentUser?.uid
    }
    private var deviceId: String {
        MobileDeviceIdentity.loadOrCreateDeviceId()
    }

    /// Register this device in both the general devices registry and escrow_devices.
    /// Called on sign-in so the device appears in lists immediately.
    func registerSelfIfNeeded() async {
        guard let uid else { return }
        let name = await UIDevice.current.name
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        // General devices registry
        try? await db.collection("users").document(uid).collection("devices")
            .document(deviceId).setData([
                "deviceId": deviceId,
                "deviceName": name,
                "platform": "iOS",
                "appVersion": version,
                "lastActiveAt": FieldValue.serverTimestamp()
            ], merge: true)

        // Escrow device registry (pending by default)
        let escrowDoc = try? await db.collection("users").document(uid)
            .collection("escrow_devices").document(deviceId).getDocument()
        if escrowDoc?.exists != true {
            try? await db.collection("users").document(uid)
                .collection("escrow_devices").document(deviceId)
                .setData([
                    "deviceId": deviceId,
                    "deviceName": name,
                    "platform": "iOS",
                    "appVersion": version,
                    "trustState": EscrowDeviceTrustState.pending.rawValue,
                    "createdAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
        }
    }

    func bootstrapApproveSelf() async throws {
        guard let uid else { throw CloudGatewayError.classified(.notAuthenticated) }
        let ref = db.collection("users").document(uid).collection("escrow_devices")
        let others = try await ref.whereField("trustState", isEqualTo: EscrowDeviceTrustState.trusted.rawValue).getDocuments()
        guard others.documents.isEmpty else {
            throw CloudGatewayError.classified(.other(message: "Another trusted device already exists. Approve from that device."))
        }
        let name = await UIDevice.current.name
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        try await ref.document(deviceId).setData([
            "deviceId": deviceId, "deviceName": name, "platform": "iOS",
            "appVersion": version, "trustState": EscrowDeviceTrustState.trusted.rawValue,
            "approvedAt": FieldValue.serverTimestamp(),
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    func renameSelf(_ newName: String) async throws {
        guard let uid else { throw CloudGatewayError.classified(.notAuthenticated) }
        try await db.collection("users").document(uid).collection("escrow_devices")
            .document(deviceId).setData(["deviceName": newName, "updatedAt": FieldValue.serverTimestamp()], merge: true)
        try await db.collection("users").document(uid).collection("devices")
            .document(deviceId).setData(["deviceName": newName], merge: true)
    }

    func revoke(deviceID: String) async throws {
        guard let uid else { throw CloudGatewayError.classified(.notAuthenticated) }
        try await db.collection("users").document(uid).collection("escrow_devices")
            .document(deviceID).setData(["trustState": EscrowDeviceTrustState.revoked.rawValue,
                                          "updatedAt": FieldValue.serverTimestamp()], merge: true)
        let grants = try await db.collection("users").document(uid).collection("escrow_grants")
            .whereField("targetDeviceId", isEqualTo: deviceID)
            .whereField("status", isEqualTo: EscrowGrantStatus.granted.rawValue).getDocuments()
        for doc in grants.documents {
            try await doc.reference.setData(["status": EscrowGrantStatus.revoked.rawValue,
                                              "revokedAt": FieldValue.serverTimestamp()], merge: true)
        }
    }
}

// MARK: - LiveEscrowGateway

@MainActor
final class LiveEscrowGateway: EscrowGateway {
    private var db: Firestore { Firestore.firestore() }
    private let keypair: iOSDeviceKeypair?
    private let keypairInitializationError: Error?
    private var listener: ListenerRegistration?

    init(keypair: iOSDeviceKeypair? = nil) {
        if let keypair {
            self.keypair = keypair
            self.keypairInitializationError = nil
            return
        }

        do {
            self.keypair = try iOSDeviceKeypair()
            self.keypairInitializationError = nil
        } catch {
            self.keypair = nil
            self.keypairInitializationError = error
        }
    }

    private var uid: String? {
        guard FirebaseApp.app() != nil else { return nil }
        return Auth.auth().currentUser?.uid
    }
    private var deviceId: String {
        MobileDeviceIdentity.loadOrCreateDeviceId()
    }

    func observeEnvelopes(_ onChange: @escaping @MainActor () -> Void) {
        guard let uid else { return }
        listener?.remove()
        listener = db.collection("users").document(uid).collection("escrow_envelopes")
            .whereField("targetDeviceId", isEqualTo: deviceId)
            .addSnapshotListener { _, _ in Task { @MainActor in onChange() } }
    }

    func runImport(envelope: AvailableEnvelope, onStage: @escaping @MainActor (ImportStage) -> Void) async {
        guard let uid else { onStage(.failed(.permissionDenied)); return }
        guard let keypair else {
            let message = keypairInitializationError?.localizedDescription ?? "This device's escrow key is unavailable."
            onStage(.failed(.other(message: message)))
            await writeAudit(uid: uid, type: "import_device_key_unavailable", envelopeId: envelope.id, providerId: envelope.provider.persistedToken, error: message)
            return
        }
        let pid = envelope.provider.persistedToken

        // Download
        onStage(.downloading)
        let doc: DocumentSnapshot
        do { doc = try await db.collection("users").document(uid).collection("escrow_envelopes").document(envelope.id).getDocument() }
        catch { onStage(.failed(.permissionDenied)); await writeAudit(uid: uid, type: "import_download_failed", envelopeId: envelope.id, providerId: pid, error: error.localizedDescription); return }

        guard let data = doc.data(),
              let ctB64 = data["ciphertext"] as? String,
              let ct = Data(base64Encoded: ctB64) else {
            onStage(.failed(.decryptionFailed))
            await writeAudit(uid: uid, type: "import_ciphertext_missing", envelopeId: envelope.id, providerId: pid, error: "ciphertext field missing or invalid")
            return
        }

        // Check grant
        if let gid = data["grantId"] as? String {
            let gd = try? await db.collection("users").document(uid).collection("escrow_grants").document(gid).getDocument()
            if let s = gd?.data()?["status"] as? String, s == EscrowGrantStatus.revoked.rawValue {
                onStage(.failed(.grantRevoked))
                await writeAudit(uid: uid, type: "import_grant_revoked", envelopeId: envelope.id, providerId: pid, grantId: gid)
                return
            }
        }

        // Decrypt
        onStage(.decrypting)
        let plain: Data
        do {
            if let kv = data["keyVersion"] as? Int, kv != keypair.keyVersion {
                plain = try keypair.decryptWithOldVersion(ct, version: kv)
            } else { plain = try keypair.decrypt(ct) }
        } catch {
            onStage(.failed(.decryptionFailed))
            await writeAudit(uid: uid, type: "import_decryption_failed", envelopeId: envelope.id, providerId: pid, error: error.localizedDescription)
            return
        }

        guard let credStr = String(data: plain, encoding: .utf8) else {
            onStage(.failed(.decryptionFailed))
            await writeAudit(uid: uid, type: "import_utf8_decode_failed", envelopeId: envelope.id, providerId: pid)
            return
        }

        // Store in iOS Keychain
        onStage(.storing)
        do {
            try Self.store(provider: pid, credential: credStr)
        } catch {
            onStage(.failed(.other(message: "Keychain write failed: \(error.localizedDescription)")))
            await writeAudit(uid: uid, type: "import_keychain_store_failed", envelopeId: envelope.id, providerId: pid, error: error.localizedDescription)
            return
        }

        // Validate: read credential back from Keychain to confirm persistence
        onStage(.validating)
        guard let stored = Self.readCredential(provider: pid), stored == credStr else {
            onStage(.failed(.providerValidationFailed(providerLabel: envelope.provider.displayName)))
            await writeAudit(uid: uid, type: "import_validation_failed", envelopeId: envelope.id, providerId: pid, error: "Keychain readback mismatch")
            return
        }

        // Success: write audit event
        await writeAudit(uid: uid, type: "envelope_imported", envelopeId: envelope.id, providerId: pid)
        onStage(.validated)
    }

    // MARK: - Keychain

    static func store(provider: String, credential: String) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "escrow_\(provider)",
            kSecAttrService as String: "com.openburnbar.mobile",
            kSecValueData as String: credential.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(q as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw EscrowCryptoError.keychainError(status: Int(status)) }
    }

    static func readCredential(provider: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "escrow_\(provider)",
            kSecAttrService as String: "com.openburnbar.mobile",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    // MARK: - Audit

    private func writeAudit(uid: String, type: String, envelopeId: String, providerId: String, grantId: String? = nil, error: String? = nil) async {
        var meta: [String: String] = [:]
        if let error { meta["error"] = error }
        if let grantId { meta["grantId"] = grantId }
        try? await db.collection("users").document(uid)
            .collection("escrow_audit_events")
            .document(UUID().uuidString)
            .setData([
                "eventType": type,
                "actorDeviceId": deviceId,
                "envelopeId": envelopeId,
                "providerId": providerId,
                "timestamp": FieldValue.serverTimestamp(),
                "metadata": meta
            ])
    }

    deinit { listener?.remove() }
}
