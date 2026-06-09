import CryptoKit
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import UIKit

struct MobileHermesAuthenticatedRelaySeal: Sendable {
    var payload: HermesRealtimeRelayPayload
    var keyData: Data
    var senderDeviceID: String
    var senderPeerNodeID: String
    var senderCounter: Int64
    var keyID: String
}

@MainActor
enum MobileHermesAuthenticatedRelayRequestSealer {
    private static let counterDefaultsPrefix = "com.openburnbar.mobile.hermesRelay.senderCounter.v3"

    static func seal(
        payload: HermesRelayPayload,
        uid: String,
        requestID: String,
        senderPeerNodeID: String? = nil
    ) async throws -> MobileHermesAuthenticatedRelaySeal {
        guard payload.relayEncryption == HermesRelayCrypto.relayEncryptionV3,
              payload.relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersionV3,
              let relayPublicKey = payload.relayPublicKey,
              relayPublicKey.isEmpty == false else {
            throw HermesServiceError.relayUnavailable("Update OpenBurnBar on your Mac and re-enable Remote Relay so this iPhone/iPad can use authenticated relay traffic.")
        }

        let senderKeypair = try HermesGatewayRelayKeypair.loadOrCreate()
        let senderDeviceID = MobileDeviceIdentity.loadOrCreateDeviceId()
        let resolvedPeerNodeID = senderPeerNodeID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? senderDeviceID
        let keyID = relaySenderKeyID(publicKeyBase64: senderKeypair.relayPublicKeyBase64)
        let signalIdentity = try OpenBurnBarSignalIdentityKeyStore().loadOrCreate(uid: uid, deviceId: senderDeviceID)
        try await publishSignalIdentityIfNeeded(uid: uid, deviceID: senderDeviceID, identity: signalIdentity)
        try await ComputerUseSecurityCallableClient.publishRelaySenderKey(
            deviceId: senderDeviceID,
            peerNodeId: resolvedPeerNodeID,
            keyId: keyID,
            publicKeyBase64: senderKeypair.relayPublicKeyBase64,
            relayKeyVersion: HermesRelayCrypto.gatewayRelayKeyVersionV3,
            publishedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
            signalIdentityKeyId: signalIdentity.identityKeyId,
            signalIdentityKeyVersion: signalIdentity.keyVersion,
            signalIdentityPublicKeyFingerprint: signalIdentity.publicKeyFingerprint
        )

        let counter = try nextCounter(connectionID: payload.connectionID, keyID: keyID)
        let keyData = try HermesRelayCrypto.generateSymmetricKeyData()
        let bodyString = payload.body.flatMap { String(data: $0, encoding: .utf8) }
        let encryptedPayload = HermesRelayEncryptedRequestPayload(
            path: payload.path,
            sessionId: payload.sessionID,
            body: bodyString
        )
        let plaintext = try JSONEncoder().encode(encryptedPayload)
        let keyAAD = HermesRelayCrypto.authenticatedKeyAAD(
            uid: uid,
            connectionID: payload.connectionID,
            requestID: requestID,
            operation: payload.operation,
            senderDeviceID: senderDeviceID,
            senderPeerNodeID: resolvedPeerNodeID,
            senderCounter: counter,
            keyID: keyID
        )
        let wrapped = try HermesRelayCrypto.sealKeyV3(
            keyData,
            recipientPublicKeyBase64: relayPublicKey,
            senderPrivateKey: senderKeypair.privateKey,
            aad: keyAAD
        )
        let payloadCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: plaintext,
            keyData: keyData,
            aad: HermesRelayCrypto.authenticatedRequestAAD(
                uid: uid,
                connectionID: payload.connectionID,
                requestID: requestID,
                operation: payload.operation,
                senderDeviceID: senderDeviceID,
                senderPeerNodeID: resolvedPeerNodeID,
                senderCounter: counter,
                keyID: keyID
            )
        )

        return MobileHermesAuthenticatedRelaySeal(
            payload: HermesRealtimeRelayPayload(
                operation: payload.operation,
                method: payload.method,
                payloadCiphertext: payloadCiphertext,
                enc: wrapped.encBase64,
                wrappedKey: wrapped.wrappedKeyBase64,
                relayEncryption: HermesRelayCrypto.relayEncryptionV3,
                relayKeyVersion: HermesRelayCrypto.gatewayRelayKeyVersionV3,
                senderPublicKey: senderKeypair.relayPublicKeyBase64,
                senderDeviceId: senderDeviceID,
                senderPeerNodeId: resolvedPeerNodeID,
                senderCounter: counter,
                keyId: keyID
            ),
            keyData: keyData,
            senderDeviceID: senderDeviceID,
            senderPeerNodeID: resolvedPeerNodeID,
            senderCounter: counter,
            keyID: keyID
        )
    }

    private static func publishSignalIdentityIfNeeded(
        uid: String,
        deviceID: String,
        identity: OpenBurnBarSignalIdentityKeypair
    ) async throws {
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        try await MobileSignalIdentityPublicKeyPublisher.publishIfNeeded(
            userRef: Firestore.firestore().collection("users").document(uid),
            deviceId: deviceID,
            platform: platform,
            identity: identity
        )
    }

    private static func nextCounter(connectionID: String, keyID: String) throws -> Int64 {
        let defaults = UserDefaults.standard
        let key = "\(counterDefaultsPrefix).\(connectionID).\(keyID)"
        let current = (defaults.object(forKey: key) as? NSNumber)?.int64Value ?? 0
        guard current < Int64.max else {
            throw HermesServiceError.relayUnavailable("Relay sender counter is exhausted. Re-pair this device before remote control.")
        }
        let next = current + 1
        defaults.set(NSNumber(value: next), forKey: key)
        return next
    }

    private static func relaySenderKeyID(publicKeyBase64: String) -> String {
        let bytes = Data(base64Encoded: publicKeyBase64) ?? Data(publicKeyBase64.utf8)
        let digest = Data(SHA256.hash(data: bytes))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "relay-v3-\(hex)"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
