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

    static func frameSealKey(
        for request: HermesRealtimeRelayMirrorRequest,
        frame: HermesRealtimeRelayFrame
    ) async -> SymmetricKey? {
        guard let envelope = request.mediaSealKey else { return nil }
        do {
            let recipientKey = try HermesRelayKeyStore().privateKey()
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
            let pinnedSenderKey = try await FirestoreHermesRelaySenderTrustResolver.shared
                .pinnedRelaySenderPublicKeyBase64(for: context)
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
