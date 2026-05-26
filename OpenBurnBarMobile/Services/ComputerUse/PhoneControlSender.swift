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

    /// Sign and write a mobile-issued agent permission request. This uses
    /// the same Ed25519 authority and monotonic counter as phone-control
    /// input intents so the Mac can reject replay across both channels.
    @discardableResult
    public func send(agentGrant request: AgentCapabilityGrantRequest) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        guard let key = signingKeyProvider()?.privateKey else {
            throw SendError.signingFailed("no signing key")
        }
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: request.requestedAt,
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let unsignedWire = request.wire(authority: placeholder)
        let counter = nextCounter()
        let timestamp = Date()
        let signed: ComputerUsePhoneControlSigner.SignedAuthority
        do {
            signed = try signer.sign(
                request: unsignedWire,
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
        let frame = HermesRealtimeRelayFrame(
            type: .controlAgentGrantRequest,
            uid: uid,
            connectionId: connectionId,
            payload: nil,
            media: nil,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.agent.grant",
                agentGrantRequest: request.wire(authority: authority)
            )
        )
        try await frameSink(frame)
        return authority
    }

    /// Sign and write an explicit remote-clipboard request. Clipboard
    /// requests share the same counter namespace as input intents and
    /// agent grants so replay protection remains one monotonic stream per
    /// phone-control peer.
    @discardableResult
    public func send(clipboardRequest rawRequest: HermesRealtimeRelayClipboardRequest) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        guard let key = signingKeyProvider()?.privateKey else {
            throw SendError.signingFailed("no signing key")
        }
        let requestId = rawRequest.requestId.isEmpty ? UUID().uuidString : rawRequest.requestId
        let clientIntentId = rawRequest.clientIntentId.isEmpty ? UUID().uuidString : rawRequest.clientIntentId
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        var unsignedRequest = rawRequest
        unsignedRequest.requestId = requestId
        unsignedRequest.clientIntentId = clientIntentId
        unsignedRequest.authority = placeholder

        let counter = nextCounter()
        let timestamp = Date()
        let signed: ComputerUsePhoneControlSigner.SignedAuthority
        do {
            signed = try signer.sign(
                clipboardRequest: unsignedRequest,
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

        var signedRequest = unsignedRequest
        signedRequest.authority = authority

        let frame = HermesRealtimeRelayFrame(
            type: .controlClipboardRequest,
            uid: uid,
            connectionId: connectionId,
            requestId: requestId,
            payload: nil,
            media: nil,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.clipboard",
                clipboardRequest: signedRequest
            )
        )
        try await frameSink(frame)
        return authority
    }

    @discardableResult
    public func sign(remoteUnlockSession rawSession: HermesRealtimeRelayRemoteUnlockSession) throws -> HermesRealtimeRelayRemoteUnlockSession {
        guard let key = signingKeyProvider()?.privateKey else {
            throw SendError.signingFailed("no signing key")
        }
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        var unsignedSession = rawSession
        unsignedSession.authority = placeholder
        let counter = nextCounter()
        let timestamp = Date()
        let signed: ComputerUsePhoneControlSigner.SignedAuthority
        do {
            signed = try signer.sign(
                remoteUnlockSession: unsignedSession,
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: timestamp,
                privateKey: key
            )
        } catch {
            throw SendError.signingFailed(error.localizedDescription)
        }
        unsignedSession.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        )
        return unsignedSession
    }

    @discardableResult
    public func send(
        remoteUnlockCredential rawCredential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope
    ) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        guard let key = signingKeyProvider()?.privateKey else {
            throw SendError.signingFailed("no signing key")
        }
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        var unsignedCredential = rawCredential
        unsignedCredential.authority = placeholder
        let counter = nextCounter()
        let timestamp = Date()
        let signed: ComputerUsePhoneControlSigner.SignedAuthority
        do {
            signed = try signer.sign(
                remoteUnlockCredential: unsignedCredential,
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
        unsignedCredential.authority = authority
        let frame = HermesRealtimeRelayFrame(
            type: .remoteUnlockCredential,
            uid: uid,
            connectionId: connectionId,
            requestId: unsignedCredential.requestId,
            payload: nil,
            media: nil,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "remote_unlock",
                sessionId: unsignedCredential.sessionId,
                remoteUnlockCredential: unsignedCredential
            )
        )
        try await frameSink(frame)
        return authority
    }

    /// Sign and write a Phase 14 system-permission request. Used by
    /// `SystemPermissionGrantSender` when the user taps "Grant on this
    /// Mac" in the iOS grant sheet. Shares the same counter namespace
    /// and authority envelope shape as input intents / grants /
    /// clipboard / context targets so a single monotonic stream guards
    /// replay across every control surface.
    @discardableResult
    public func send(systemPermissionRequest rawRequest: HermesRealtimeRelaySystemPermissionRequest) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        guard let key = signingKeyProvider()?.privateKey else {
            throw SendError.signingFailed("no signing key")
        }
        let requestId = rawRequest.requestId.isEmpty ? UUID().uuidString : rawRequest.requestId
        let clientIntentId = rawRequest.clientIntentId.isEmpty ? UUID().uuidString : rawRequest.clientIntentId
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        var unsignedRequest = rawRequest
        unsignedRequest.requestId = requestId
        unsignedRequest.clientIntentId = clientIntentId
        unsignedRequest.authority = placeholder
        // Canonical signing must omit the authority so the rehash on
        // the receiver matches the bytes the phone signed. We restore
        // it after signing.
        var signableRequest = unsignedRequest
        signableRequest.authority = placeholder

        let counter = nextCounter()
        let timestamp = Date()
        let signed: ComputerUsePhoneControlSigner.SignedAuthority
        do {
            signed = try signer.sign(
                systemPermissionRequest: signableRequest,
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
        var signedRequest = unsignedRequest
        signedRequest.authority = authority

        let frame = HermesRealtimeRelayFrame(
            type: .controlSystemPermissionRequest,
            uid: uid,
            connectionId: connectionId,
            requestId: requestId,
            payload: nil,
            media: nil,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.system.permission",
                systemPermissionRequest: signedRequest
            )
        )
        try await frameSink(frame)
        return authority
    }

    @discardableResult
    public func send(contextTarget rawTarget: HermesRealtimeRelayAgentContextTarget) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        guard let key = signingKeyProvider()?.privateKey else {
            throw SendError.signingFailed("no signing key")
        }
        var target = rawTarget
        if target.clientIntentId.isEmpty {
            target.clientIntentId = UUID().uuidString
        }
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: target.requestedAt,
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        target.authority = placeholder
        let counter = nextCounter()
        let timestamp = Date()
        let signed: ComputerUsePhoneControlSigner.SignedAuthority
        do {
            signed = try signer.sign(
                target: target,
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

        var targetWithAuthority = target
        targetWithAuthority.authority = authority

        let frame = HermesRealtimeRelayFrame(
            type: .controlAgentContextTarget,
            uid: uid,
            connectionId: connectionId,
            payload: nil,
            media: nil,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.input",
                agentContextTarget: targetWithAuthority
            )
        )
        try await frameSink(frame)
        return authority
    }


    private func nextCounter() -> UInt64 {
        Self.nextCounter(peerNodeId: peerNodeId, userDefaults: userDefaults)
    }

    public static func nextCounter(peerNodeId: String, userDefaults: UserDefaults = .standard) -> UInt64 {
        let key = "openburnbar.phoneControl.counter.\(peerNodeId)"
        let raw = userDefaults.object(forKey: key) as? Int ?? 0
        let next = UInt64(max(raw, 0)) &+ 1
        // `Int` clamp keeps Int64 max in range on 64-bit platforms.
        userDefaults.set(Int(min(next, UInt64(Int.max))), forKey: key)
        return next
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

protocol PhoneControlSigningKeyProviding: AnyObject {
    func signingKey() throws -> Curve25519SigningKey
    func peerNodeId(for key: Curve25519SigningKey) -> String
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

extension PhoneControlSigningKeyStore: PhoneControlSigningKeyProviding {}
#endif
