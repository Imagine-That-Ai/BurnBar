import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore

final class FirestoreHermesRelaySenderTrustResolver: HermesRelaySenderTrustResolving, @unchecked Sendable {
    static let shared = FirestoreHermesRelaySenderTrustResolver()

    private let firestoreProvider: @Sendable () -> Firestore
    private let maximumAge: TimeInterval
    private let allowedPlatforms: Set<String>

    init(
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() },
        maximumAge: TimeInterval = 10 * 60,
        allowedPlatforms: Set<String> = ["iOS", "iPadOS", "Android"]
    ) {
        self.firestoreProvider = firestoreProvider
        self.maximumAge = maximumAge
        self.allowedPlatforms = allowedPlatforms
    }

    func pinnedRelaySenderPublicKeyBase64(
        for context: HermesRelayAuthenticatedRequestTrustContext
    ) async throws -> String {
        let record = try await fetchTrustedSenderRecord(context: context)
        return record.publicKeyBase64
    }

    func requireVerifiedSignalIdentity(
        for context: HermesRelayAuthenticatedRequestTrustContext
    ) async throws {
        let record = try await fetchTrustedSenderRecord(context: context)
        guard record.signalIdentityVerification == "verified",
              record.signalIdentityKeyID.isEmpty == false else {
            throw HermesRelayAuthenticatedRequestError.rejected(.signalIdentityUnverified)
        }

        let identity = try await firestoreProvider()
            .collection("users").document(context.uid)
            .collection("signal_identity_public_keys")
            .document(record.signalIdentityKeyID)
            .getDocument()
        guard identity.exists, let data = identity.data(),
              (data["deviceId"] as? String) == context.sender.deviceID,
              (data["identityKeyId"] as? String) == record.signalIdentityKeyID else {
            throw HermesRelayAuthenticatedRequestError.rejected(.signalIdentityUnverified)
        }
        if let expectedFingerprint = record.signalIdentityPublicKeyFingerprint,
           expectedFingerprint.isEmpty == false,
           data["publicKeyFingerprint"] as? String != expectedFingerprint {
            throw HermesRelayAuthenticatedRequestError.rejected(.signalIdentityUnverified)
        }
        if let keyVersion = intValue(data["keyVersion"]),
           keyVersion != record.signalIdentityKeyVersion {
            throw HermesRelayAuthenticatedRequestError.rejected(.signalIdentityUnverified)
        }
    }

    private func fetchTrustedSenderRecord(
        context: HermesRelayAuthenticatedRequestTrustContext
    ) async throws -> TrustedRelaySenderRecord {
        let db = firestoreProvider()
        let snapshot = try await db
            .collection("users").document(context.uid)
            .collection("relay_sender_keys")
            .document(context.sender.deviceID)
            .getDocument()
        guard snapshot.exists, let data = snapshot.data() else {
            throw HermesRelayAuthenticatedRequestError.rejected(.senderKeyUntrusted)
        }
        guard let record = TrustedRelaySenderRecord(data: data),
              record.deviceID == context.sender.deviceID,
              record.peerNodeID == context.sender.peerNodeID,
              record.keyID == context.sender.keyID,
              record.relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersionV3,
              record.status == "active",
              record.publicKeyBase64Data?.count == 65 else {
            throw HermesRelayAuthenticatedRequestError.rejected(.senderKeyUntrusted)
        }
        guard Date().timeIntervalSince1970 - (Double(record.publishedAtMillis) / 1000.0) <= maximumAge else {
            throw HermesRelayAuthenticatedRequestError.rejected(.senderKeyUntrusted)
        }

        let device = try await db
            .collection("users").document(context.uid)
            .collection("escrow_devices")
            .document(context.sender.deviceID)
            .getDocument()
        guard device.exists, let deviceData = device.data(),
              (deviceData["trustState"] as? String) == "trusted",
              allowedPlatforms.contains(deviceData["platform"] as? String ?? "") else {
            throw HermesRelayAuthenticatedRequestError.rejected(.senderKeyUntrusted)
        }
        if let escrowPeerNodeID = deviceData["peerNodeId"] as? String,
           escrowPeerNodeID.isEmpty == false,
           escrowPeerNodeID != context.sender.peerNodeID {
            throw HermesRelayAuthenticatedRequestError.rejected(.senderKeyUntrusted)
        }
        if let escrowKeyVersion = intValue(deviceData["keyVersion"]),
           escrowKeyVersion != record.signalIdentityKeyVersion {
            throw HermesRelayAuthenticatedRequestError.rejected(.signalIdentityUnverified)
        }
        return record
    }

    private struct TrustedRelaySenderRecord {
        var deviceID: String
        var peerNodeID: String
        var keyID: String
        var publicKeyBase64: String
        var relayKeyVersion: Int
        var status: String
        var publishedAtMillis: Int64
        var signalIdentityKeyID: String
        var signalIdentityKeyVersion: Int
        var signalIdentityVerification: String
        var signalIdentityPublicKeyFingerprint: String?

        var publicKeyBase64Data: Data? {
            Data(base64Encoded: publicKeyBase64)
        }

        init?(data: [String: Any]) {
            guard let deviceID = data["deviceId"] as? String,
                  let peerNodeID = data["peerNodeId"] as? String,
                  let keyID = data["keyId"] as? String,
                  let publicKeyBase64 = data["publicKeyBase64"] as? String,
                  let relayKeyVersion = intValue(data["relayKeyVersion"]),
                  let status = data["status"] as? String,
                  let publishedAtMillis = int64Value(data["publishedAtMillis"]),
                  let signalIdentityKeyID = data["signalIdentityKeyId"] as? String,
                  let signalIdentityKeyVersion = intValue(data["signalIdentityKeyVersion"]) else {
                return nil
            }
            self.deviceID = deviceID
            self.peerNodeID = peerNodeID
            self.keyID = keyID
            self.publicKeyBase64 = publicKeyBase64
            self.relayKeyVersion = relayKeyVersion
            self.status = status
            self.publishedAtMillis = publishedAtMillis
            self.signalIdentityKeyID = signalIdentityKeyID
            self.signalIdentityKeyVersion = signalIdentityKeyVersion
            self.signalIdentityVerification = data["signalIdentityVerification"] as? String ?? ""
            self.signalIdentityPublicKeyFingerprint = data["signalIdentityPublicKeyFingerprint"] as? String
        }
    }
}

enum HermesRelayAuthenticatedRequestOpeners {
    static let sharedReplayCache = HermesRelayReplayCache(
        persistenceURL: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("OpenBurnBar", isDirectory: true)
            .appendingPathComponent("HermesRelay", isDirectory: true)
            .appendingPathComponent("authenticated-request-replay-cache.json")
    )

    static let shared = HermesRelayAuthenticatedRequestOpener(
        replayCache: sharedReplayCache,
        trustResolver: FirestoreHermesRelaySenderTrustResolver.shared
    )
}

private func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    return nil
}

private func int64Value(_ value: Any?) -> Int64? {
    if let int64 = value as? Int64 { return int64 }
    if let int = value as? Int { return Int64(int) }
    if let number = value as? NSNumber { return number.int64Value }
    return nil
}
