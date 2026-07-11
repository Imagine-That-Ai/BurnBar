#if os(Linux)
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia

public protocol MercuryLinuxMediaSealKeyOpening: Sendable {
    func openMediaFrameSealKey(
        for request: HermesRealtimeRelayMirrorRequest,
        frame: HermesRealtimeRelayFrame
    ) async throws -> PlatformSymmetricKey
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
}
#endif
