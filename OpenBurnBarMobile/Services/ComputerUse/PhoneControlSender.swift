#if canImport(UIKit)
import Foundation
import CryptoKit
import LocalAuthentication
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
        case attestationRequired
    }

    public typealias FrameSink = @Sendable (HermesRealtimeRelayFrame) async throws -> Void

    public let peerNodeId: String
    private let signer: ComputerUsePhoneControlSigner
    /// F2: key-kind-aware signing identity (legacy software Ed25519 or a
    /// biometry-gated Secure Enclave P-256 key). Every envelope-producing
    /// path signs through this, so key custody is a property of the stored
    /// identity rather than of each call site.
    private let signingIdentityProvider: @Sendable () -> PhoneControlAuthoritySigningKey?
    private let userDefaults: UserDefaults
    private let frameSink: FrameSink
    private let uid: String
    private let connectionId: String
    private let sendSequencer = PhoneControlSendSequencer()
    private static let counterLock = NSLock()

    public init(
        peerNodeId: String,
        uid: String,
        connectionId: String,
        signingIdentityProvider: @escaping @Sendable () -> PhoneControlAuthoritySigningKey?,
        userDefaults: UserDefaults = .standard,
        signer: ComputerUsePhoneControlSigner = ComputerUsePhoneControlSigner(),
        frameSink: @escaping FrameSink
    ) {
        self.peerNodeId = peerNodeId
        self.uid = uid
        self.connectionId = connectionId
        self.signingIdentityProvider = signingIdentityProvider
        self.userDefaults = userDefaults
        self.signer = signer
        self.frameSink = frameSink
    }

    /// Pre-F2 convenience: wraps a legacy software Ed25519 key as the signing
    /// identity. Wire output is byte-identical to the pre-F2 sender.
    public convenience init(
        peerNodeId: String,
        uid: String,
        connectionId: String,
        signingKeyProvider: @escaping @Sendable () -> Curve25519SigningKey?,
        userDefaults: UserDefaults = .standard,
        signer: ComputerUsePhoneControlSigner = ComputerUsePhoneControlSigner(),
        frameSink: @escaping FrameSink
    ) {
        self.init(
            peerNodeId: peerNodeId,
            uid: uid,
            connectionId: connectionId,
            signingIdentityProvider: { signingKeyProvider().map { .ed25519($0.privateKey) } },
            userDefaults: userDefaults,
            signer: signer,
            frameSink: frameSink
        )
    }

    /// Sign and write a `PhoneControlIntent`. Returns the signed
    /// authority envelope so the UI can mirror the counter / timestamp
    /// in the local timeline.
    @discardableResult
    public func send(intent rawIntent: HermesRealtimeRelayInputIntent) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        try await sendSequencer.enqueue { [self] in
            try await sendInputIntent(rawIntent)
        }
    }

    private func sendInputIntent(_ rawIntent: HermesRealtimeRelayInputIntent) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        try await ensureAttestationIfRequired()
        guard let identity = signingIdentityProvider() else {
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
            signed = try signer.signAuthority(
                intentHashHex: signer.canonicalInputIntentHashHex(intent: intent),
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: timestamp,
                key: identity
            )
        } catch {
            throw SendError.signingFailed(error.localizedDescription)
        }

        let attestationDigest = await MobileAppCheckAttestationReader.currentAttestationDigestForEnvelope()
        let authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            attestationHashBlake3: attestationDigest,
            keyKind: identity.wireKeyKind
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
        try await sendSequencer.enqueue { [self] in
            try await sendAgentGrant(request)
        }
    }

    private func sendAgentGrant(_ request: AgentCapabilityGrantRequest) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        try await ensureAttestationIfRequired()
        guard let identity = signingIdentityProvider() else {
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
            signed = try signer.signAuthority(
                intentHashHex: signer.canonicalAgentGrantRequestHashHex(request: unsignedWire),
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: timestamp,
                key: identity
            )
        } catch {
            throw SendError.signingFailed(error.localizedDescription)
        }

        let attestationDigest = await MobileAppCheckAttestationReader.currentAttestationDigestForEnvelope()
        let authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            attestationHashBlake3: attestationDigest,
            keyKind: identity.wireKeyKind
        )
        var signedRequest = request
        if request.localAuthenticationSatisfied {
            signedRequest.localAuthProof = try signer.signLocalAuthProof(
                deviceId: request.sourceDeviceID,
                signedIntentHash: signed.intentHashHex,
                authenticatedAt: signed.timestamp,
                expiresAt: request.expiresAt,
                key: identity
            )
        }
        let frame = HermesRealtimeRelayFrame(
            type: .controlAgentGrantRequest,
            uid: uid,
            connectionId: connectionId,
            payload: nil,
            media: nil,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.agent.grant",
                agentGrantRequest: signedRequest.wire(authority: authority)
            )
        )
        try await frameSink(frame)
        return authority
    }

    /// Sign and write a phone-issued approval decision. The response binds the
    /// pending approval request hash so a relay-visible approve/reject frame
    /// cannot be replayed onto a different action.
    @discardableResult
    public func send(
        approvalResponse response: HermesRealtimeRelayApprovalResponse,
        approvalRequest request: HermesRealtimeRelayApprovalRequest
    ) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        try await sendSequencer.enqueue { [self] in
            try await sendApprovalResponse(response, approvalRequest: request)
        }
    }

    private func sendApprovalResponse(
        _ response: HermesRealtimeRelayApprovalResponse,
        approvalRequest request: HermesRealtimeRelayApprovalRequest
    ) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        try await ensureAttestationIfRequired()
        guard let identity = signingIdentityProvider() else {
            throw SendError.signingFailed("no signing key")
        }
        var response = response
        response.requestHashBlake3 = try signer.canonicalApprovalRequestHashHex(request: request)
        let counter = nextCounter()
        let timestamp = Date()
        let signed: ComputerUsePhoneControlSigner.SignedAuthority
        do {
            signed = try signer.signAuthority(
                intentHashHex: signer.canonicalApprovalResponseHashHex(response: response),
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: timestamp,
                key: identity
            )
        } catch {
            throw SendError.signingFailed(error.localizedDescription)
        }
        let attestationDigest = await MobileAppCheckAttestationReader.currentAttestationDigestForEnvelope()
        response.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            attestationHashBlake3: attestationDigest,
            keyKind: identity.wireKeyKind
        )
        let frame = HermesRealtimeRelayFrame(
            type: .controlApprovalResponse,
            uid: uid,
            connectionId: connectionId,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.approval",
                sessionId: request.sessionId,
                approvalResponse: response
            )
        )
        try await frameSink(frame)
        return response.authority ?? HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            attestationHashBlake3: attestationDigest,
            keyKind: identity.wireKeyKind
        )
    }

    /// Sign and write an explicit remote-clipboard request. Clipboard
    /// requests share the same counter namespace as input intents and
    /// agent grants so replay protection remains one monotonic stream per
    /// phone-control peer.
    @discardableResult
    public func send(clipboardRequest rawRequest: HermesRealtimeRelayClipboardRequest) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        try await sendSequencer.enqueue { [self] in
            try await sendClipboardRequest(rawRequest)
        }
    }

    private func sendClipboardRequest(_ rawRequest: HermesRealtimeRelayClipboardRequest) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        guard let identity = signingIdentityProvider() else {
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
            signed = try signer.signAuthority(
                intentHashHex: signer.canonicalClipboardRequestHashHex(request: unsignedRequest),
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: timestamp,
                key: identity
            )
        } catch {
            throw SendError.signingFailed(error.localizedDescription)
        }

        let attestationDigest = await MobileAppCheckAttestationReader.currentAttestationDigestForEnvelope()
        let authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            attestationHashBlake3: attestationDigest,
            keyKind: identity.wireKeyKind
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
        guard let identity = signingIdentityProvider() else {
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
            signed = try signer.signAuthority(
                intentHashHex: signer.canonicalRemoteUnlockSessionHashHex(session: unsignedSession),
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: timestamp,
                key: identity
            )
        } catch {
            throw SendError.signingFailed(error.localizedDescription)
        }
        unsignedSession.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            attestationHashBlake3: MobileAppCheckAttestationReader.cachedAttestationDigestForEnvelope(),
            keyKind: identity.wireKeyKind
        )
        return unsignedSession
    }

    @discardableResult
    public func send(
        remoteUnlockCredential rawCredential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope
    ) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        try await sendSequencer.enqueue { [self] in
            try await sendRemoteUnlockCredential(rawCredential)
        }
    }

    private func sendRemoteUnlockCredential(
        _ rawCredential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope
    ) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        guard let identity = signingIdentityProvider() else {
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
            signed = try signer.signAuthority(
                intentHashHex: signer.canonicalRemoteUnlockCredentialHashHex(credential: unsignedCredential),
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: timestamp,
                key: identity
            )
        } catch {
            throw SendError.signingFailed(error.localizedDescription)
        }
        let attestationDigest = await MobileAppCheckAttestationReader.currentAttestationDigestForEnvelope()
        let authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            attestationHashBlake3: attestationDigest,
            keyKind: identity.wireKeyKind
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
        try await sendSequencer.enqueue { [self] in
            try await sendSystemPermissionRequest(rawRequest)
        }
    }

    private func sendSystemPermissionRequest(
        _ rawRequest: HermesRealtimeRelaySystemPermissionRequest
    ) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        guard let identity = signingIdentityProvider() else {
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
            signed = try signer.signAuthority(
                intentHashHex: signer.canonicalSystemPermissionRequestHashHex(request: signableRequest),
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: timestamp,
                key: identity
            )
        } catch {
            throw SendError.signingFailed(error.localizedDescription)
        }

        let attestationDigest = await MobileAppCheckAttestationReader.currentAttestationDigestForEnvelope()
        let authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            attestationHashBlake3: attestationDigest,
            keyKind: identity.wireKeyKind
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
        try await sendSequencer.enqueue { [self] in
            try await sendContextTarget(rawTarget)
        }
    }

    private func sendContextTarget(_ rawTarget: HermesRealtimeRelayAgentContextTarget) async throws -> HermesRealtimeRelayAuthorityEnvelope {
        guard let identity = signingIdentityProvider() else {
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
            signed = try signer.signAuthority(
                intentHashHex: signer.canonicalAgentContextTargetHashHex(target: target),
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: timestamp,
                key: identity
            )
        } catch {
            throw SendError.signingFailed(error.localizedDescription)
        }

        let attestationDigest = await MobileAppCheckAttestationReader.currentAttestationDigestForEnvelope()
        let authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            attestationHashBlake3: attestationDigest,
            keyKind: identity.wireKeyKind
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


    private func ensureAttestationIfRequired() async throws {
        guard MobileComputerUseRemoteConfig.phoneControlAttestationRequired() else { return }
        if await MobileAppCheckAttestationReader.currentAttestationDigestForEnvelope() != nil {
            return
        }
        do {
            try await ComputerUseSecurityCallableClient.bindAppCheckAttestation()
        } catch {
            throw SendError.attestationRequired
        }
        if await MobileAppCheckAttestationReader.currentAttestationDigestForEnvelope() == nil {
            throw SendError.attestationRequired
        }
    }

    private func nextCounter() -> UInt64 {
        Self.nextCounter(peerNodeId: peerNodeId, userDefaults: userDefaults)
    }

    public static func nextCounter(peerNodeId: String, userDefaults: UserDefaults = .standard) -> UInt64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        let key = "openburnbar.phoneControl.counter.\(peerNodeId)"
        let raw = userDefaults.object(forKey: key) as? Int ?? 0
        let next = UInt64(max(raw, 0)) &+ 1
        // `Int` clamp keeps Int64 max in range on 64-bit platforms.
        userDefaults.set(Int(min(next, UInt64(Int.max))), forKey: key)
        return next
    }
}

private actor PhoneControlSendSequencer {
    private var tail: Task<Void, Never> = Task {}

    func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let predecessor = tail
        let priority = Task.currentPriority
        let next = Task<T, Error>(priority: priority) {
            await predecessor.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task {
            _ = try? await next.value
        }
        if Task.isCancelled {
            next.cancel()
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await next.value
        } onCancel: {
            next.cancel()
        }
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
    /// F2: the key-kind-aware identity (Secure Enclave P-256 when the gate is
    /// on and the hardware exists, legacy software Ed25519 otherwise).
    func signingIdentity() throws -> PhoneControlAuthoritySigningKey
    func peerNodeId(for identity: PhoneControlAuthoritySigningKey) -> String
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

    // MARK: - F2 Secure-Enclave identity

    /// The key-kind-aware signing identity, gated by the
    /// `computer_use_phone_control_secure_enclave_key` Remote Config flag.
    public func signingIdentity() throws -> PhoneControlAuthoritySigningKey {
        try signingIdentity(
            secureEnclaveEnabled: MobileComputerUseRemoteConfig.phoneControlSecureEnclaveKeyEnabled()
        )
    }

    /// Resolution order:
    ///  1. An already-minted Secure Enclave key always wins (its peerNodeId is
    ///     the published controller identity — never silently downgrade).
    ///  2. With the gate on and enclave hardware present, mint a
    ///     biometry-gated SE key (`.biometryCurrentSet` + `.privateKeyUsage` —
    ///     the OS refuses to sign without a live biometric match, which is the
    ///     F2 per-action step-up evidence).
    ///  3. Otherwise the legacy software Ed25519 key (wire-identical to pre-F2).
    public func signingIdentity(
        secureEnclaveEnabled: Bool,
        authenticationContext: LAContext? = nil
    ) throws -> PhoneControlAuthoritySigningKey {
        if let blob = try loadSecureEnclaveBlob() {
            return .secureEnclaveP256(try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: blob,
                authenticationContext: authenticationContext
            ))
        }
        if secureEnclaveEnabled, SecureEnclave.isAvailable {
            return .secureEnclaveP256(try mintSecureEnclaveKey(authenticationContext: authenticationContext))
        }
        return .ed25519(try signingKey().privateKey)
    }

    public func peerNodeId(for identity: PhoneControlAuthoritySigningKey) -> String {
        PhoneControlPeerNodeIdDerivation.derive(
            kind: identity.kind,
            platform: .iOS,
            publicKeyRepresentation: identity.publicKeyRepresentation
        )
    }

    private func mintSecureEnclaveKey(
        authenticationContext: LAContext?
    ) throws -> SecureEnclave.P256.Signing.PrivateKey {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &accessError
        ) else {
            throw KeyStoreError.accessControlCreationFailed
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(
            accessControl: access,
            authenticationContext: authenticationContext
        )
        // `dataRepresentation` is the enclave-wrapped blob — useless outside
        // this device's Secure Enclave, so generic-password storage is safe.
        try saveSecureEnclaveBlob(key.dataRepresentation)
        return key
    }

    private var secureEnclaveAccount: String { account + ".se-p256" }

    private func loadSecureEnclaveBlob() throws -> Data? {
        var query = baseQuery()
        query[kSecAttrAccount as String] = secureEnclaveAccount
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeyStoreError.keychainStatus(status)
        }
        return data
    }

    private func saveSecureEnclaveBlob(_ data: Data) throws {
        var query = baseQuery()
        query[kSecAttrAccount as String] = secureEnclaveAccount
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var match = baseQuery()
            match[kSecAttrAccount as String] = secureEnclaveAccount
            let updateStatus = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeyStoreError.keychainStatus(updateStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeyStoreError.keychainStatus(status) }
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
        /// `SecAccessControlCreateWithFlags` refused the biometry-gated flags
        /// (F2 Secure-Enclave mint path).
        case accessControlCreationFailed
    }
}

extension PhoneControlSigningKeyStore: PhoneControlSigningKeyProviding {}
#endif
