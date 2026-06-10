import CryptoKit
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia
import OSLog

/// F7 — opens the phone-wrapped media-seal key carried on a mirror request,
/// using the Mac relay private key and the SAME pinned relay-sender-key trust
/// path the chat opener applies. Returns nil — the legacy plaintext-at-app-
/// layer lane — when the request carries no wrap or when establishment fails:
/// per-frame sealing is defense-in-depth on top of the iroh transport seal,
/// and a mirror must not fail because the seal could not be established.
enum MacMediaSealKeyOpener {
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "Mercury")

    /// F7 test seams — production leaves these nil and resolves the Mac relay
    /// private key from the keychain-backed store and the pinned sender key
    /// from the same Firestore trust resolver the chat opener uses (mirrors
    /// the F10 `ComputerUseSessionCoordinator.controlSeal*Provider` seams).
    static var recipientPrivateKeyProvider: (@Sendable () throws -> HermesRelayPrivateKey)?
    static var pinnedSenderKeyProvider: (@Sendable (_ uid: String, _ connectionId: String, _ envelope: HermesRealtimeRelayControlSealKeyEnvelope) async throws -> String)?

    static func frameSealKey(
        for request: HermesRealtimeRelayMirrorRequest,
        frame: HermesRealtimeRelayFrame
    ) async -> SymmetricKey? {
        guard let envelope = request.mediaSealKey else { return nil }
        do {
            let recipientKey = try recipientPrivateKeyProvider.map { try $0() }
                ?? HermesRelayKeyStore().privateKey()
            // The trust resolver only consults uid + sender identity; the
            // request id/operation exist for the chat lane's AAD and are
            // irrelevant to pinned-key resolution.
            let context = HermesRelayAuthenticatedRequestTrustContext(
                uid: frame.uid,
                connectionID: frame.connectionId,
                requestID: "media-seal-\(envelope.senderCounter)",
                operation: .chatCompletions,
                sender: HermesRelayAuthenticatedSender(
                    publicKeyBase64: "",
                    deviceID: envelope.senderDeviceId,
                    peerNodeID: envelope.senderPeerNodeId,
                    counter: envelope.senderCounter,
                    keyID: envelope.senderKeyId
                )
            )
            let pinnedSenderKey: String
            if let provider = pinnedSenderKeyProvider {
                pinnedSenderKey = try await provider(frame.uid, frame.connectionId, envelope)
            } else {
                pinnedSenderKey = try await FirestoreHermesRelaySenderTrustResolver.shared
                    .pinnedRelaySenderPublicKeyBase64(for: context)
            }
            let key = try MediaFrameSealSession.open(
                envelope: envelope,
                uid: frame.uid,
                connectionID: frame.connectionId,
                viewerId: request.viewerId ?? "",
                recipientPrivateKey: recipientKey,
                pinnedSenderPublicKeyBase64: pinnedSenderKey
            )
            Self.log.info("media_seal_established connectionID=\(frame.connectionId, privacy: .public)")
            return key
        } catch {
            Self.log.error("media_seal_establish_failed connectionID=\(frame.connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
