#if canImport(UIKit)
import Foundation
import CryptoKit
import Security
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// iOS side of the Phase 12 `control.input` stream. Wraps the pure
/// `ComputerUsePhoneControlSigner` with the iroh stream-write
/// machinery so a `PhoneControlIntent` from the SwiftUI overlay
/// becomes a signed envelope, then a `HermesRealtimeRelayFrame`, then
/// a write on the open `control.input` bi-stream.
///
/// The actual stream-send closure is injected — this lets the test
/// target drive the sender against an in-memory channel without
/// spinning up iroh.
public final class PhoneControlSender: @unchecked Sendable {
    public enum SendError: Error, Sendable, Equatable {
        case streamClosed
        case signingFailed(String)
        case wireEncodeFailed
    }

    public typealias FrameSink = @Sendable (HermesRealtimeRelayFrame) async throws -> Void

    public let peerNodeId: String
    private let signer: ComputerUsePhoneControlSigner
    private let signingKeyProvider: @Sendable () -> Curve25519SigningKey?
    private let userDefaults: UserDefaults
    private let frameSink: FrameSink
    private let uid: String
    private let connectionId: String

    public init(
        peerNodeId: String,
        uid: String,
        connectionId: String,
        signingKeyProvider: @escaping @Sendable () -> Curve25519SigningKey?,
        userDefaults: UserDefaults = .standard,
        signer: ComputerUsePhoneControlSigner = ComputerUsePhoneControlSigner(),
        frameSink: @escaping FrameSink
    ) {
        self.peerNodeId = peerNodeId
        self.uid = uid
        self.connectionId = connectionId
        self.signingKeyProvider = signingKeyProvider
        self.userDefaults = userDefaults
        self.signer = signer
        self.frameSink = frameSink
    }

    /// Sign and write a `PhoneControlIntent`. Returns the signed
    /// authority envelope so the UI can mirror the counter / timestamp
    /// in the local timeline.
    @discardableResult
    public func send(intent rawIntent: HermesRealtimeRelayInputIntent) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        guard let key = signingKeyProvider()?.privateKey else {
            throw SendError.signingFailed("no signing key")
        }
        var intent = rawIntent
        if intent.clientIntentId?.isEmpty ?? true {
            intent.clientIntentId = UUID().uuidString
        }
        let counter = nextCounter()
        let timestamp = Date()
        let signed: ComputerUsePhoneControlSigner.SignedAuthority
        do {
            signed = try signer.sign(
                intent: intent,
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: timestamp,
                privateKey: key
            )
        } catch {
            throw SendError.signingFailed(error.localizedDescription)
        }

        let authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        )

        var intentWithAuthority = intent
        intentWithAuthority.authority = authority

        let frame = HermesRealtimeRelayFrame(
            type: .controlInputIntent,
            uid: uid,
            connectionId: connectionId,
            requestId: nil,
            payload: nil,
            media: nil,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.input",
                inputIntent: intentWithAuthority
            )
        )
        try await frameSink(frame)
        return authority
    }

    private func nextCounter() -> UInt64 {
        let key = counterKey()
        let raw = userDefaults.object(forKey: key) as? Int ?? 0
        let next = UInt64(max(raw, 0)) &+ 1
        // `Int` clamp keeps Int64 max in range on 64-bit platforms.
        userDefaults.set(Int(min(next, UInt64(Int.max))), forKey: key)
        return next
    }

    private func counterKey() -> String {
        "openburnbar.phoneControl.counter.\(peerNodeId)"
    }
}

/// Opaque wrapper around the Curve25519 private key so the sender
/// doesn't need to import CryptoKit in its public API. The iOS
/// integration injects an instance vended by the existing
/// `IrohPairingKeyStore`.
public struct Curve25519SigningKey: Sendable {
    public let privateKey: Curve25519SigningKey.Wrapped
    public typealias Wrapped = Curve25519.Signing.PrivateKey
    public init(privateKey: Wrapped) { self.privateKey = privateKey }
}

/// Persistent iOS signing identity for Phase 12 phone-control intents.
///
/// The public key is announced on the already-verified Computer Use control
/// stream; the Mac registers it for that stream and then validates every
/// `control.input` intent with monotonic counters.
public final class PhoneControlSigningKeyStore: @unchecked Sendable {
    public static let shared = PhoneControlSigningKeyStore()

    private let service: String
    private let account: String

    public init(
        service: String = "ai.openburnbar.phone-control",
        account: String = "default-signing-key"
    ) {
        self.service = service
        self.account = account
    }

    public func signingKey() throws -> Curve25519SigningKey {
        if let existing = try load() {
            return Curve25519SigningKey(privateKey: existing)
        }
        let created = Curve25519.Signing.PrivateKey()
        try save(created)
        return Curve25519SigningKey(privateKey: created)
    }

    public func peerNodeId(for key: Curve25519SigningKey) -> String {
        "ios-phone-\(Self.hex(Data(key.privateKey.publicKey.rawRepresentation.prefix(12))))"
    }

    private func load() throws -> Curve25519.Signing.PrivateKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeyStoreError.keychainStatus(status)
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    private func save(_ key: Curve25519.Signing.PrivateKey) throws {
        let data = key.rawRepresentation
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeyStoreError.keychainStatus(updateStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeyStoreError.keychainStatus(status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public enum KeyStoreError: Error, Equatable {
        case keychainStatus(OSStatus)
    }
}
#endif
