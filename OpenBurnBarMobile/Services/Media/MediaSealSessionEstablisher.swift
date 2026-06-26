#if canImport(UIKit)
import CryptoKit
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import OpenBurnBarSignalCore

/// F7 — phone-side media-seal establishment, shared by every mirror-request
/// call site. Mirrors `ControlSealSessionEstablisher` for the media lane.
@MainActor
enum MediaSealSessionEstablisher {
    struct Session: Sendable {
        let envelope: HermesRealtimeRelayControlSealKeyEnvelope
        let key: SymmetricKey
    }

    enum EstablishmentError: LocalizedError, Equatable {
        case negotiatedSessionUnavailable

        var errorDescription: String? {
            "The Mac requires protected media frames, but this device could not prepare the media seal."
        }
    }

    /// Establish when (and only when) the default-off RC flag is on AND the
    /// Mac advertised `media_frame_aead_v1` in its heartbeat reply. Returns
    /// nil only when the lane was not negotiated, preserving byte-compatible
    /// legacy screen share. Once negotiated, failure to prepare the seal is a
    /// hard refusal so the phone cannot silently downgrade to unsealed frames.
    static func establishIfNegotiated(
        uid: String,
        connectionID: String,
        viewerId: String,
        macCapabilities: [String],
        macRelayPublicKeyBase64: String?
    ) async throws -> Session? {
        guard MobileComputerUseRemoteConfig.mediaFrameAeadEnabled(),
              macCapabilities.contains(MediaFrameAeadNegotiation.capability) else {
            return nil
        }
        guard let recipientKey = macRelayPublicKeyBase64?.trimmingCharacters(in: .whitespacesAndNewlines),
              recipientKey.isEmpty == false else {
            throw EstablishmentError.negotiatedSessionUnavailable
        }
        do {
            let senderKeypair = try HermesGatewayRelayKeypair.loadOrCreate()
            let senderDeviceID = MobileDeviceIdentity.loadOrCreateDeviceId()
            let keyID = MobileHermesAuthenticatedRelayRequestSealer.relaySenderKeyID(
                publicKeyBase64: senderKeypair.relayPublicKeyBase64
            )
            let signalIdentity = try OpenBurnBarSignalIdentityKeyStore().loadOrCreate(uid: uid, deviceId: senderDeviceID)
            try await MobileHermesAuthenticatedRelayRequestSealer.publishSignalIdentityIfNeeded(
                uid: uid,
                deviceID: senderDeviceID,
                identity: signalIdentity
            )
            try await ComputerUseSecurityCallableClient.publishRelaySenderKey(
                deviceId: senderDeviceID,
                peerNodeId: senderDeviceID,
                keyId: keyID,
                publicKeyBase64: senderKeypair.relayPublicKeyBase64,
                relayKeyVersion: HermesRelayCrypto.gatewayRelayKeyVersionV3,
                publishedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
                signalIdentityKeyId: signalIdentity.identityKeyId,
                signalIdentityKeyVersion: signalIdentity.keyVersion,
                signalIdentityPublicKeyFingerprint: signalIdentity.publicKeyFingerprint
            )
            let counter = try MobileHermesAuthenticatedRelayRequestSealer.nextCounter(
                connectionID: connectionID,
                keyID: "media-seal.\(keyID)"
            )
            let (envelope, key) = try MediaFrameSealSession.establish(
                uid: uid,
                connectionID: connectionID,
                viewerId: viewerId,
                senderDeviceID: senderDeviceID,
                senderPeerNodeID: senderDeviceID,
                senderKeyID: keyID,
                senderCounter: counter,
                recipientPublicKeyBase64: recipientKey,
                senderPrivateKey: senderKeypair.privateKey
            )
            return Session(envelope: envelope, key: key)
        } catch {
            throw EstablishmentError.negotiatedSessionUnavailable
        }
    }
}
#endif
