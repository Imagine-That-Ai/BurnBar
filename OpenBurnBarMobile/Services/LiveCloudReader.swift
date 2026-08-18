import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import os.log
import Security
import UIKit

@MainActor
enum MobileDeviceIdentity {
    static let deviceIDKey = "com.openburnbar.mobile.deviceId"
    private static let zeroUUID = UUID(uuid: (
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0
    ))

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
        loadOrCreateDeviceId(
            defaults: defaults,
            vendorIdentifierProvider: { UIDevice.current.identifierForVendor?.uuidString },
            uuidGenerator: UUID.init
        )
    }

    /// Injectable implementation used by unit tests so identity validation
    /// never depends on the simulator's UIKit hardware state.
    static func loadOrCreateDeviceId(
        defaults: UserDefaults,
        vendorIdentifierProvider: () -> String?,
        uuidGenerator: () -> UUID
    ) -> String {
        if let stored = defaults.string(forKey: deviceIDKey) {
            if isValidDeviceID(stored) {
                return stored
            }

            // A persisted invalid identity (including the all-zero simulator
            // UUID) must be replaced instead of becoming a permanent trust
            // principal. Generate once, persist it, and keep it stable for the
            // remainder of this install.
            return persistGeneratedDeviceID(defaults: defaults, uuidGenerator: uuidGenerator)
        }

        if let vendor = vendorIdentifierProvider(), isValidDeviceID(vendor) {
            defaults.set(vendor, forKey: deviceIDKey)
            return vendor
        }

        return persistGeneratedDeviceID(defaults: defaults, uuidGenerator: uuidGenerator)
    }

    private static func isValidDeviceID(_ candidate: String) -> Bool {
        guard !candidate.isEmpty,
              candidate == candidate.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: candidate)
        else {
            return false
        }
        return uuid != zeroUUID
    }

    private static func persistGeneratedDeviceID(
        defaults: UserDefaults,
        uuidGenerator: () -> UUID
    ) -> String {
        var generated = uuidGenerator()
        while generated == zeroUUID {
            generated = UUID()
        }
        let resolved = generated.uuidString
        defaults.set(resolved, forKey: deviceIDKey)
        return resolved
    }
}

enum CloudDeviceActivityDateResolver {
    static func date(from data: [String: Any]) -> Date? {
        [
            firestoreDate(data["lastActiveAt"]),
            firestoreDate(data["lastSeenAt"]),
            firestoreDate(data["updatedAt"])
        ]
        .compactMap(\.self)
        .max()
    }

    private static func firestoreDate(_ value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let date = value as? Date { return date }
        return nil
    }
}

/// Production CloudReader + DeviceTrustGateway + EscrowGateway.
/// Reads Firestore, manages device trust state, handles encrypted credential import.
@MainActor
final class LiveCloudReader: CloudReader {
    private static let log = Logger(subsystem: "com.openburnbar.mobile", category: "LiveCloudReader")
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
                .getDocuments()

            let macDeviceId: String?
            let macName: String
            let macLastSeen: Date?
            if let macDoc = devicesSnap.documents.max(by: { lhs, rhs in
                let left = CloudDeviceActivityDateResolver.date(from: lhs.data()) ?? .distantPast
                let right = CloudDeviceActivityDateResolver.date(from: rhs.data()) ?? .distantPast
                return left < right
            }) {
                let d = macDoc.data()
                macDeviceId = d["deviceId"] as? String ?? macDoc.documentID
                macName = d["deviceName"] as? String ?? "Mac"
                macLastSeen = CloudDeviceActivityDateResolver.date(from: d)
            } else {
                macDeviceId = nil
                macName = "Mac"
                macLastSeen = nil
            }

            let syncStatusCollection = db.collection("users/\(uid)/sync_status")
            if let macDeviceId {
                let doc = try await syncStatusCollection.document(macDeviceId).getDocument()
                if doc.exists {
                    return Self.syncStatusSnapshot(
                        deviceID: macDeviceId,
                        displayName: macName,
                        data: doc.data(),
                        fallbackLastSeen: macLastSeen
                    )
                } else if let macLastSeen {
                    return Self.syncStatusSnapshot(
                        deviceID: macDeviceId,
                        displayName: macName,
                        data: nil,
                        fallbackLastSeen: macLastSeen
                    )
                }
            }

            let latestSyncStatus = try await syncStatusCollection
                .order(by: "lastSyncAt", descending: true)
                .limit(to: 1)
                .getDocuments()
            if let latest = latestSyncStatus.documents.first {
                return Self.syncStatusSnapshot(
                    deviceID: latest.documentID,
                    displayName: macName,
                    data: latest.data()
                )
            }

            return CloudSyncStatusSnapshot(
                lastPublishedAt: nil,
                lastReadAt: Date(),
                publisher: nil,
                lastErrorClassification: nil
            )
        } catch { throw classify(error) }
    }

    static func syncStatusSnapshot(
        deviceID: String,
        displayName: String,
        data: [String: Any]?,
        fallbackLastSeen: Date? = nil,
        readAt: Date = Date()
    ) -> CloudSyncStatusSnapshot {
        let lastPublished = (data?["lastSyncAt"] as? Timestamp)?.dateValue()
            ?? (data?["updatedAt"] as? Timestamp)?.dateValue()
            ?? fallbackLastSeen
        let lastError = data?["lastError"] as? String

        return CloudSyncStatusSnapshot(
            lastPublishedAt: lastPublished,
            lastReadAt: readAt,
            publisher: CloudPublisherDevice(
                deviceID: deviceID,
                displayName: displayName,
                platform: "macOS",
                lastSeen: lastPublished ?? readAt
            ),
            lastErrorClassification: lastError != nil ? .other(message: lastError!) : nil
        )
    }

    func loadProviderSummaries() async throws -> [ProviderConnectionDoc] {
        do { return try await firestore.fetchProviderConnections() } catch { throw classify(error) }
    }

    func loadDevices() async throws -> [DeviceRecord] {
        guard let uid else { throw CloudGatewayError.classified(.notAuthenticated) }
        do {
            return try await loadDevices(uid: uid)
        } catch {
            throw classify(error)
        }
    }

    private func loadDevices(uid: String) async throws -> [DeviceRecord] {
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
                lastSeen: CloudDeviceActivityDateResolver.date(from: d),
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
            // Stream 6: surface both the stored fingerprint and the published
            // key bytes. The trust UX only enables approval when they match.
            let publicKeyFingerprint = d["publicKeyFingerprint"] as? String
            let publicKeyData = await escrowPublicKeyData(uid: uid, deviceId: did, keyVersion: keyVersion)

            if let existing = deviceMap[did] {
                deviceMap[did] = DeviceRecord(
                    id: existing.id, displayName: existing.displayName,
                    platform: existing.platform, appVersion: existing.appVersion,
                    lastSeen: existing.lastSeen ?? CloudDeviceActivityDateResolver.date(from: d),
                    trustState: trustState, approvedAt: approvedAt,
                    keyVersion: keyVersion, isCurrentDevice: existing.isCurrentDevice,
                    publicKeyFingerprint: publicKeyFingerprint,
                    publicKeyData: publicKeyData
                )
            } else {
                deviceMap[did] = DeviceRecord(
                    id: did, displayName: d["deviceName"] as? String ?? "Unknown",
                    platform: d["platform"] as? String ?? "unknown",
                    appVersion: d["appVersion"] as? String,
                    lastSeen: CloudDeviceActivityDateResolver.date(from: d),
                    trustState: trustState, approvedAt: approvedAt,
                    keyVersion: keyVersion, isCurrentDevice: did == deviceId,
                    publicKeyFingerprint: publicKeyFingerprint,
                    publicKeyData: publicKeyData
                )
            }
        }

        return Array(deviceMap.values)
    }

    private func escrowPublicKeyData(uid: String, deviceId: String, keyVersion: Int?) async -> String? {
        guard let keyVersion else { return nil }
        do {
            let snapshot = try await db.collection("users").document(uid)
                .collection("escrow_public_keys")
                .document("\(deviceId)_\(keyVersion)")
                .getDocument()
            return snapshot.data()?["publicKeyData"] as? String
        } catch {
            // nil just hides the key material in the device list; log so a systematic
            // read failure (rules, offline) doesn't masquerade as "no key published".
            Self.log.warning("escrow public key fetch failed device=\(deviceId, privacy: .public) v=\(keyVersion, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
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
            case .permissionDenied:
                return CloudGatewayError.classified(
                    CloudErrorClassification.permissionDeniedClassification(message: ns.localizedDescription)
                )
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
    private static let log = Logger(subsystem: "com.openburnbar.mobile", category: "LiveDeviceTrustGateway")
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
        let name = UIDevice.current.name
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let keypair = try? iOSDeviceKeypair()

        // General devices registry
        try? await db.collection("users").document(uid).collection("devices")
            .document(deviceId).setData([
                "deviceId": deviceId,
                "deviceName": name,
                "platform": "iOS",
                "appVersion": version,
                "lastActiveAt": FieldValue.serverTimestamp()
            ], merge: true)

        // Escrow device registry (pending by default) via server callable
        let escrowPlatform = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        do {
            try await ComputerUseSecurityCallableClient.registerEscrowDevice(
                deviceId: deviceId,
                deviceName: name,
                platform: escrowPlatform,
                appVersion: version,
                publicKeyFingerprint: keypair?.publicKeyFingerprint,
                keyVersion: keypair?.keyVersion
            )
        } catch {
            // Registration may already exist; ignore failed-precondition for trusted devices.
            // Anything else (offline, auth, server bug) means the device never shows up in
            // Settings → Devices — surface it instead of swallowing every error here.
            let nsError = error as NSError
            let isExpectedPrecondition = nsError.domain == FunctionsErrorDomain
                && FunctionsErrorCode(rawValue: nsError.code) == .failedPrecondition
            if !isExpectedPrecondition {
                Self.log.error("registerEscrowDevice failed device=\(self.deviceId, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if let keypair {
            try? await db.collection("users").document(uid)
                .collection("escrow_devices").document(deviceId)
                .setData([
                    "publicKeyFingerprint": keypair.publicKeyFingerprint,
                    "keyVersion": keypair.keyVersion,
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
            try? await MobileEscrowPublicKeyPublisher.publishIfNeeded(
                userRef: db.collection("users").document(uid),
                deviceId: deviceId,
                publicKeyData: keypair.publicKeyData,
                publicKeyFingerprint: keypair.publicKeyFingerprint,
                keyVersion: keypair.keyVersion
            )
        }
    }

    func bootstrapApproveSelf() async throws {
        guard let uid else { throw CloudGatewayError.classified(.notAuthenticated) }
        await registerSelfIfNeeded()
        let ref = db.collection("users").document(uid).collection("escrow_devices")
        let others = try await ref.whereField("trustState", isEqualTo: EscrowDeviceTrustState.trusted.rawValue).getDocuments()
        guard others.documents.isEmpty else {
            throw CloudGatewayError.classified(.other(message: "Another trusted device already exists. Approve from that device."))
        }
        try await ComputerUseSecurityCallableClient.approveEscrowDeviceTrust(
            deviceId: deviceId,
            approverDeviceId: deviceId
        )
    }

    func approve(deviceID targetDeviceID: String) async throws {
        guard uid != nil else { throw CloudGatewayError.classified(.notAuthenticated) }
        guard targetDeviceID != deviceId else {
            throw CloudGatewayError.classified(
                .other(message: "Use the bootstrap approval flow for this device.")
            )
        }
        try await ComputerUseSecurityCallableClient.approveEscrowDeviceTrust(
            deviceId: targetDeviceID,
            approverDeviceId: deviceId
        )
    }

    func trustSelfForComputerUseControl() async throws {
        guard uid != nil else { throw CloudGatewayError.classified(.notAuthenticated) }
        await registerSelfIfNeeded()
        try await ComputerUseSecurityCallableClient.approveEscrowDeviceTrust(
            deviceId: deviceId,
            approverDeviceId: deviceId
        )
    }

    func isSelfTrustedForComputerUseControl() async throws -> Bool {
        guard let uid else { throw CloudGatewayError.classified(.notAuthenticated) }
        await registerSelfIfNeeded()
        let snapshot = try await db.collection("users").document(uid)
            .collection("escrow_devices")
            .document(deviceId)
            .getDocument()
        return (snapshot.data()?["trustState"] as? String) == EscrowDeviceTrustState.trusted.rawValue
    }

    func renameSelf(_ newName: String) async throws {
        guard let uid else { throw CloudGatewayError.classified(.notAuthenticated) }
        try await db.collection("users").document(uid).collection("escrow_devices")
            .document(deviceId).setData(["deviceName": newName, "updatedAt": FieldValue.serverTimestamp()], merge: true)
        try await db.collection("users").document(uid).collection("devices")
            .document(deviceId).setData(["deviceName": newName], merge: true)
    }

    func revoke(deviceID: String) async throws {
        guard uid != nil else { throw CloudGatewayError.classified(.notAuthenticated) }
        _ = try await ComputerUseSecurityCallableClient.revokeEscrowDeviceTrust(
            deviceId: deviceID,
            rotatingDeviceId: deviceId
        )
        NotificationCenter.default.post(name: .openBurnBarDidRevokeDeviceTrust, object: nil)
    }

}

// MARK: - LiveEscrowGateway

@MainActor
final class LiveEscrowGateway: EscrowGateway {
    private var db: Firestore { Firestore.firestore() }
    private let keypair: iOSDeviceKeypair?
    private var listener: ListenerRegistration?

    init(keypair: iOSDeviceKeypair? = nil) {
        self.keypair = keypair ?? (try? iOSDeviceKeypair())
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
        // Device and grant binding need the stored document, so preflight only
        // what is knowable here: a referencable envelope and a usable device key.
        guard !envelope.id.isEmpty else {
            let failure = MobileEscrowImportFailure.malformedEnvelope
            onStage(.failed(CredentialImportFailure(failure)))
            await writeAudit(uid: uid, type: "import_\(failure.rawValue)", envelopeId: envelope.id, providerId: envelope.provider.persistedToken, error: failure.userVisibleLabel)
            return
        }
        guard let keypair else {
            onStage(.failed(.missingPrivateKey))
            await writeAudit(uid: uid, type: "import_device_key_unavailable", envelopeId: envelope.id, providerId: envelope.provider.persistedToken, error: MobileEscrowImportFailure.missingKey.userVisibleLabel)
            return
        }
        let pid = envelope.provider.persistedToken

        // Download
        onStage(.downloading)
        let doc: DocumentSnapshot
        do {
            doc = try await db.collection("users").document(uid).collection("escrow_envelopes").document(envelope.id).getDocument()
        } catch {
            onStage(.failed(.permissionDenied))
            await writeAudit(uid: uid, type: "import_download_failed", envelopeId: envelope.id, providerId: pid, error: error.localizedDescription)
            return
        }

        guard let data = doc.data(),
              let ctB64 = data["ciphertext"] as? String,
              let ct = Data(base64Encoded: ctB64) else {
            onStage(.failed(.malformedEnvelope))
            await writeAudit(uid: uid, type: "import_ciphertext_missing", envelopeId: envelope.id, providerId: pid, error: "ciphertext field missing or invalid")
            return
        }
        let targetDeviceId = data["targetDeviceId"] as? String
        var grantStatus: String?
        var grantExpiresAtMs: Int64?
        let grantId = data["grantId"] as? String
        let envelopeVersion = Self.intValue(data["envelopeVersion"]) ?? 1
        if let gid = grantId, !gid.isEmpty {
            let gd = try? await db.collection("users").document(uid).collection("escrow_grants").document(gid).getDocument()
            grantStatus = gd?.data()?["status"] as? String
            grantExpiresAtMs = Self.intValue(gd?.data()?["expiresAtMillis"]).map(Int64.init)
        }
        // `ct` above already proves the ciphertext decodes.
        let wellFormed = !ctB64.isEmpty
            && !(grantId ?? "").isEmpty
            && envelopeVersion >= EscrowCredentialMetadataBinding.envelopeVersion
        if let failure = MobileEscrowEnvelopePolicy.classify(
            targetDeviceId: targetDeviceId,
            currentDeviceId: deviceId,
            grantStatus: grantStatus,
            grantExpiresAtMs: grantExpiresAtMs,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            hasPrivateKey: true,
            envelopeWellFormed: wellFormed
        ) {
            onStage(.failed(CredentialImportFailure(failure)))
            await writeAudit(uid: uid, type: "import_\(failure.rawValue)", envelopeId: envelope.id, providerId: pid, error: failure.userVisibleLabel)
            return
        }
        guard let metadataBinding = Self.metadataBinding(
            from: data,
            expectedEnvelope: envelope,
            currentDeviceId: deviceId
        ) else {
            onStage(.failed(.malformedEnvelope))
            await writeAudit(uid: uid, type: "import_metadata_binding_failed", envelopeId: envelope.id, providerId: pid)
            return
        }

        // Decrypt
        onStage(.decrypting)
        let plain: Data
        do {
            if let kv = Self.intValue(data["keyVersion"]), kv != keypair.keyVersion {
                plain = try keypair.decryptWithOldVersion(ct, version: kv, authenticating: metadataBinding)
            } else { plain = try keypair.decrypt(ct, authenticating: metadataBinding) }
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

    static func metadataBinding(
        from data: [String: Any],
        expectedEnvelope: AvailableEnvelope,
        currentDeviceId: String
    ) -> Data? {
        let envelopeVersion = intValue(data["envelopeVersion"]) ?? 1
        guard envelopeVersion >= EscrowCredentialMetadataBinding.envelopeVersion else {
            return nil
        }
        guard (data["metadataBinding"] as? String) == EscrowCredentialMetadataBinding.metadataBinding,
              let grantId = data["grantId"] as? String,
              let sourceDeviceId = data["sourceDeviceId"] as? String,
              let targetDeviceId = data["targetDeviceId"] as? String,
              targetDeviceId == currentDeviceId,
              let providerId = data["providerId"] as? String,
              providerId == expectedEnvelope.provider.persistedToken,
              let credentialKindRaw = data["credentialKind"] as? String,
              let credentialKind = EscrowCredentialKind(rawValue: credentialKindRaw),
              credentialKind == expectedEnvelope.credentialKind,
              let keyVersion = intValue(data["keyVersion"]) else {
            return nil
        }
        let accountLabel = (data["accountLabel"] as? String) ?? expectedEnvelope.provider.displayName
        guard accountLabel.trimmingCharacters(in: .whitespacesAndNewlines) == expectedEnvelope.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines),
              sourceDeviceId == expectedEnvelope.sourceDeviceID else {
            return nil
        }
        return EscrowCredentialMetadataBinding(
            grantId: grantId,
            sourceDeviceId: sourceDeviceId,
            targetDeviceId: targetDeviceId,
            providerId: providerId,
            credentialKind: credentialKind,
            accountLabel: accountLabel,
            keyVersion: keyVersion,
            envelopeVersion: envelopeVersion
        ).associatedData
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
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
