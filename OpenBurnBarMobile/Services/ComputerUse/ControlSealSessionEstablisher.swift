#if canImport(UIKit)
import CryptoKit
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarSignalCore

/// F10 — phone-side control-seal session establishment plus the sealing frame
/// sink, shared by every `PhoneControlSender` call site so the negotiation,
/// key wrap, and seal behavior cannot drift between surfaces.
@MainActor
enum ControlSealSessionEstablisher {
    struct Session: Sendable {
        let envelope: HermesRealtimeRelayControlSealKeyEnvelope
        let key: SymmetricKey
        let controllerPeerNodeId: String
    }

    /// Establish when (and only when) the default-off RC flag is on AND the
    /// Mac advertised `control_seal_v1` in its heartbeat reply. Returns nil —
    /// the legacy plaintext-at-app-layer lane — otherwise, or when wrap
    /// preparation fails: sealing is defense-in-depth on top of the iroh
    /// transport seal, and a phone that cannot establish must not lose remote
    /// control. `macRelayPublicKeyBase64` is the Mac's HPKE relay key (the
    /// same recipient key the chat lane seals to, from the paired connection
    /// record — never from the stream itself).
    static func establishIfNegotiated(
        uid: String,
        connectionID: String,
        controllerPeerNodeId: String,
        macCapabilities: [String],
        macRelayPublicKeyBase64: String?
    ) async -> Session? {
        guard MobileComputerUseRemoteConfig.controlSealEnabled(),
              ControlFrameSealNegotiation.resolveSealingEnabled(
                  localSupports: true,
                  remoteSupports: macCapabilities.contains(ControlFrameSealNegotiation.capability)
              ),
              let recipientKey = macRelayPublicKeyBase64?.trimmingCharacters(in: .whitespacesAndNewlines),
              recipientKey.isEmpty == false else {
            return nil
        }
        do {
            let senderKeypair = try HermesGatewayRelayKeypair.loadOrCreate()
            let senderDeviceID = MobileDeviceIdentity.loadOrCreateDeviceId()
            let keyID = MobileHermesAuthenticatedRelayRequestSealer.relaySenderKeyID(
                publicKeyBase64: senderKeypair.relayPublicKeyBase64
            )
            // The Mac resolves the pinned sender key through the SAME
            // relay_sender_keys + escrow-trust path as the chat lane, so the
            // identity must be published (and fresh) exactly like the sealer
            // publishes it.
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
                keyID: "control-seal.\(keyID)"
            )
            let (envelope, key) = try ControlFrameSealSession.establish(
                uid: uid,
                connectionID: connectionID,
                peerNodeId: controllerPeerNodeId,
                senderDeviceID: senderDeviceID,
                senderPeerNodeID: senderDeviceID,
                senderKeyID: keyID,
                senderCounter: counter,
                recipientPublicKeyBase64: recipientKey,
                senderPrivateKey: senderKeypair.privateKey
            )
            return Session(envelope: envelope, key: key, controllerPeerNodeId: controllerPeerNodeId)
        } catch {
            return nil
        }
    }

    /// Wrap a `PhoneControlSender` frame sink so every outgoing control
    /// payload is replaced by its sealed shell (`streamClass` +
    /// `sealedFrameBase64` only) before it reaches the stream.
    nonisolated static func sealingFrameSink(
        _ base: @escaping PhoneControlSender.FrameSink,
        session: Session
    ) -> PhoneControlSender.FrameSink {
        { frame in
            var frame = frame
            if let control = frame.control {
                frame.control = try ControlFrameSealSession.sealPayload(
                    control,
                    key: session.key,
                    peerNodeId: session.controllerPeerNodeId,
                    frameType: frame.type.rawValue
                )
            }
            try await base(frame)
        }
    }
}
#endif
