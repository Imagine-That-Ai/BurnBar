#if os(Linux)
import Foundation
import OpenBurnBarEngine
import OpenBurnBarMedia

public protocol MercuryLinuxMediaSealKeyOpening: Sendable {
    func openMediaFrameSealKey(
        for request: HermesRealtimeRelayMirrorRequest,
        frame: HermesRealtimeRelayFrame
    ) async throws -> PlatformSymmetricKey

    /// Opens the call-bound media seal. Call senders bind the same envelope
    /// to the invite request id as the media-session viewer id; keeping this
    /// overload separate prevents a mirror envelope being replayed as a call.
    func openMediaFrameSealKey(
        for invite: HermesRealtimeRelayCallInvite,
        frame: HermesRealtimeRelayFrame
    ) async throws -> PlatformSymmetricKey
}

public extension MercuryLinuxMediaSealKeyOpening {
    func openMediaFrameSealKey(
        for invite: HermesRealtimeRelayCallInvite,
        frame: HermesRealtimeRelayFrame
    ) async throws -> PlatformSymmetricKey {
        _ = invite
        _ = frame
        throw MercuryLinuxMediaSealKeyOpenError.missingSealKey
    }
}

public enum MercuryLinuxMediaSealKeyOpenError: Error, LocalizedError, Equatable {
    case missingSealKey
    case missingSenderPeerNodeID
    case providerUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingSealKey:
            return "Mirror request did not include a media frame seal key."
        case .missingSenderPeerNodeID:
            return "Mirror request media seal key did not include a sender peer node id."
        case .providerUnavailable:
            return "Linux media seal key providers are not configured."
        }
    }
}

public struct MercuryLinuxMediaSealKeyOpener: MercuryLinuxMediaSealKeyOpening, Sendable {
    public typealias RecipientPrivateKeyProvider = @Sendable () throws -> HermesRelayPrivateKey
    public typealias PinnedSenderPublicKeyProvider =
        @Sendable (_ uid: String, _ connectionID: String, _ envelope: HermesRealtimeRelayControlSealKeyEnvelope) async throws -> String

    private let recipientPrivateKeyProvider: RecipientPrivateKeyProvider?
    private let pinnedSenderPublicKeyProvider: PinnedSenderPublicKeyProvider?

    public init(
        recipientPrivateKeyProvider: RecipientPrivateKeyProvider? = nil,
        pinnedSenderPublicKeyProvider: PinnedSenderPublicKeyProvider? = nil
    ) {
        self.recipientPrivateKeyProvider = recipientPrivateKeyProvider
        self.pinnedSenderPublicKeyProvider = pinnedSenderPublicKeyProvider
    }

    public func openMediaFrameSealKey(
        for request: HermesRealtimeRelayMirrorRequest,
        frame: HermesRealtimeRelayFrame
    ) async throws -> PlatformSymmetricKey {
        guard let envelope = request.mediaSealKey else {
            throw MercuryLinuxMediaSealKeyOpenError.missingSealKey
        }
        guard envelope.senderPeerNodeId != nil else {
            throw MercuryLinuxMediaSealKeyOpenError.missingSenderPeerNodeID
        }
        guard let recipientPrivateKeyProvider,
              let pinnedSenderPublicKeyProvider else {
            throw MercuryLinuxMediaSealKeyOpenError.providerUnavailable
        }
        let recipientPrivateKey = try recipientPrivateKeyProvider()
        let pinnedSenderPublicKey = try await pinnedSenderPublicKeyProvider(
            frame.uid,
            frame.connectionId,
            envelope
        )
        return try MediaFrameSealSession.open(
            envelope: envelope,
            uid: frame.uid,
            connectionID: frame.connectionId,
            viewerId: request.viewerId ?? "",
            recipientPrivateKey: recipientPrivateKey,
            pinnedSenderPublicKeyBase64: pinnedSenderPublicKey
        )
    }

    public func openMediaFrameSealKey(
        for invite: HermesRealtimeRelayCallInvite,
        frame: HermesRealtimeRelayFrame
    ) async throws -> PlatformSymmetricKey {
        guard let envelope = invite.mediaSealKey else {
            throw MercuryLinuxMediaSealKeyOpenError.missingSealKey
        }
        guard envelope.senderPeerNodeId != nil else {
            throw MercuryLinuxMediaSealKeyOpenError.missingSenderPeerNodeID
        }
        guard let recipientPrivateKeyProvider,
              let pinnedSenderPublicKeyProvider else {
            throw MercuryLinuxMediaSealKeyOpenError.providerUnavailable
        }
        let recipientPrivateKey = try recipientPrivateKeyProvider()
        let pinnedSenderPublicKey = try await pinnedSenderPublicKeyProvider(
            frame.uid,
            frame.connectionId,
            envelope
        )
        // Calls bind the seal to the invite request id. The sender and
        // receiver must use this exact stable value; no peer-provided display
        // name or mutable session id participates in the AAD.
        return try MediaFrameSealSession.open(
            envelope: envelope,
            uid: frame.uid,
            connectionID: frame.connectionId,
            viewerId: invite.requestId,
            recipientPrivateKey: recipientPrivateKey,
            pinnedSenderPublicKeyBase64: pinnedSenderPublicKey
        )
    }
}
#endif
