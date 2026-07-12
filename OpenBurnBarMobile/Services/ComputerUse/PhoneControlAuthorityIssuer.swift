#if canImport(UIKit)
import Foundation
import CryptoKit
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Builds + signs `PhoneControlAuthority` envelopes on the phone.
/// Phase 12.
///
/// Storage: monotonic counter persisted in `UserDefaults` under a
/// per-peer key so a phone-reboot does not reset the counter.
/// Signing key: Curve25519 private key vended by the iOS-side
/// `IrohPairingKeyStore`.
///
/// The actual signing is delegated to `ComputerUsePhoneControlSigner`
/// in `OpenBurnBarComputerUseCore` — that's the canonical
/// implementation the Mac validator also calls into. This class is
/// the iOS-flavored wrapper that adds the counter persistence and the
/// `IrohPairingKeyStore` plumbing.
// AUDIT(@unchecked Sendable): only non-Sendable stored property is UserDefaults
// (thread-safe, not yet Sendable-annotated). sendable-allowlist: foundation-sdk-shim
public final class PhoneControlAuthorityIssuer: @unchecked Sendable {
    public enum IssuerError: Error, Sendable, Equatable {
        case signingKeyMissing
        case intentHashFailed
    }

    public typealias PrivateKeyProvider = @Sendable () -> Curve25519.Signing.PrivateKey?

    public let peerNodeId: String
    private let privateKey: PrivateKeyProvider
    private let userDefaults: UserDefaults
    private let signer: ComputerUsePhoneControlSigner

    public init(
        peerNodeId: String,
        privateKey: @escaping PrivateKeyProvider,
        userDefaults: UserDefaults = .standard,
        signer: ComputerUsePhoneControlSigner = ComputerUsePhoneControlSigner()
    ) {
        self.peerNodeId = peerNodeId
        self.privateKey = privateKey
        self.userDefaults = userDefaults
        self.signer = signer
    }

    /// Signs and writes one intent while holding the process-wide queue for
    /// this authority peer. A counter is never exposed as a bare reservation:
    /// the queue remains held until `write` finishes or fails.
    public func issueAndWrite(
        intent: HermesRealtimeRelayInputIntent,
        timestamp: Date? = nil,
        write: @escaping @Sendable (HermesRealtimeRelayAuthorityEnvelope) async throws -> Void
    ) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        try await PhoneControlSendSequencer.shared.enqueue(peerNodeId: peerNodeId) { [self] in
            guard let key = privateKey() else { throw IssuerError.signingKeyMissing }
            let counter = nextCounter()
            let issuanceTimestamp = timestamp ?? Date()
            let signed = try signer.sign(
                intent: intent,
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: issuanceTimestamp,
                privateKey: key
            )
            let envelope = HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: signed.peerNodeId,
                counter: signed.counter,
                timestamp: signed.timestamp,
                intentHashBlake3: signed.intentHashHex,
                signatureEd25519: signed.signatureBase64
            )
            try await write(envelope)
            return envelope
        }
    }

    private func nextCounter() -> UInt64 {
        PhoneControlSender.nextCounter(peerNodeId: peerNodeId, userDefaults: userDefaults)
    }
}
#endif
