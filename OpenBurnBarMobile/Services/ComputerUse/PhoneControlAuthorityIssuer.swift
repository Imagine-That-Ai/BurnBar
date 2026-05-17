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
public final class PhoneControlAuthorityIssuer {
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

    /// Build an envelope around a Codable intent (`HermesRealtimeRelayInputIntent`).
    /// Counter advances + persists on every successful sign.
    public func issue(
        intent: HermesRealtimeRelayInputIntent,
        timestamp: Date = Date()
    ) throws -> HermesRealtimeRelayAuthorityEnvelope {
        guard let key = privateKey() else { throw IssuerError.signingKeyMissing }
        let counter = nextCounter()
        let signed = try signer.sign(
            intent: intent,
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: timestamp,
            privateKey: key
        )
        return HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        )
    }

    private func nextCounter() -> UInt64 {
        let key = counterKey()
        let raw = userDefaults.object(forKey: key) as? Int ?? 0
        let next = UInt64(max(raw, 0)) &+ 1
        userDefaults.set(Int(min(next, UInt64(Int.max))), forKey: key)
        return next
    }

    private func counterKey() -> String {
        "openburnbar.phoneControl.counter.\(peerNodeId)"
    }
}
#endif
