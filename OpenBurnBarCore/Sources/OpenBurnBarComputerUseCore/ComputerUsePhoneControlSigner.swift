import Foundation
import CryptoKit
import OpenBurnBarCore

/// Pure Ed25519 signer / verifier for `PhoneControlAuthority`
/// envelopes. Phase 12. Lives in `OpenBurnBarComputerUseCore` so iOS
/// and Mac share the same canonical signing path AND the test target
/// can prove sig + counter + freshness + intent-hash semantics
/// independent of any device-specific keystore.
///
/// Wire layout of the bytes signed by the issuer (and verified by the
/// receiver):
///
/// ```
/// signature = Ed25519.sign(privKey,
///                          UTF-8(intentHashHex) ‖ u64BE(counter) ‖ i64BE(timestampMs))
/// ```
///
/// `intentHashHex` is the SHA-256 hex digest of the canonical-JSON
/// encoding of the intent. The plan labels the field "blake3" — see
/// `ComputerUseAuditHasher` for the algorithm note.
public struct ComputerUsePhoneControlSigner: Sendable {
    public init() {}

    private static func canonicalRelayDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Canonical signing payload — exposed for cross-implementation
    /// compatibility tests.
    public func signablePayload(
        intentHashHex: String,
        counter: UInt64,
        timestamp: Date
    ) -> Data {
        var payload = Data()
        payload.append(contentsOf: intentHashHex.utf8)
        var beCounter = counter.bigEndian
        withUnsafeBytes(of: &beCounter) { payload.append(contentsOf: $0) }
        let timestampMs = Int64((timestamp.timeIntervalSince1970 * 1000).rounded())
        var beTs = timestampMs.bigEndian
        withUnsafeBytes(of: &beTs) { payload.append(contentsOf: $0) }
        return payload
    }

    private func canonicalJSONNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value.rounded(.towardZero) == value {
            return String(Int64(value))
        }
        var rendered = String(format: "%.12f", locale: Locale(identifier: "en_US_POSIX"), value)
        while rendered.last == "0" { rendered.removeLast() }
        if rendered.last == "." { rendered.removeLast() }
        return rendered
    }

    /// Domain-separated local-auth proof payload for high-risk queued agent grants.
    /// This signs the canonical grant intent hash after the device has completed
    /// user-presence authentication. The server consumes each proof once.
    public func localAuthProofSignablePayload(
        proofId: String,
        deviceId: String,
        signedIntentHash: String,
        authenticatedAt: Date,
        expiresAt: Date
    ) -> Data {
        let canonical = [
            "OpenBurnBar.AgentGrantLocalAuthProof.v1",
            proofId,
            deviceId,
            signedIntentHash.lowercased(),
            canonicalJSONNumber(authenticatedAt.timeIntervalSinceReferenceDate),
            canonicalJSONNumber(expiresAt.timeIntervalSinceReferenceDate)
        ].joined(separator: "\n")
        return Data(canonical.utf8)
    }

    public func signLocalAuthProof(
        proofId: String = UUID().uuidString,
        deviceId: String,
        signedIntentHash: String,
        authenticatedAt: Date,
        expiresAt: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> HermesRealtimeRelayAgentGrantLocalAuthProof {
        let payload = localAuthProofSignablePayload(
            proofId: proofId,
            deviceId: deviceId,
            signedIntentHash: signedIntentHash,
            authenticatedAt: authenticatedAt,
            expiresAt: expiresAt
        )
        let signature = try privateKey.signature(for: payload)
        return HermesRealtimeRelayAgentGrantLocalAuthProof(
            proofId: proofId,
            deviceId: deviceId,
            signedIntentHash: signedIntentHash.lowercased(),
            authenticatedAt: authenticatedAt,
            expiresAt: expiresAt,
            signatureEd25519: signature.base64EncodedString()
        )
    }

    /// Hex-encoded SHA-256 of canonical-JSON encoding of `intent`.
    /// The signer hashes the intent the receiver will replay,
    /// guaranteeing both sides agree on the bytes that authorize the
    /// action.
    public func canonicalIntentHashHex<Intent: Encodable>(intent: Intent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(intent)
        return SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Canonical hash for the Phase 12 wire intent. The authority
    /// envelope is intentionally excluded because it is the signature
    /// carrier and is mutated after signing. Including it would make
    /// a valid sender sign placeholder bytes and make the Mac receiver
    /// hash final bytes, causing every real `control.input` intent to
    /// fail `intentHashMismatch`.
    public func canonicalInputIntentHashHex(intent: HermesRealtimeRelayInputIntent) throws -> String {
        struct SignableInputIntent: Encodable {
            let kind: HermesRealtimeRelayInputIntent.Kind
            let displayId: String?
            let normalizedX: Double?
            let normalizedY: Double?
            let normalizedX2: Double?
            let normalizedY2: Double?
            let text: String?
            let key: String?
            let modifiers: [String]?
            let mouseButton: Int?
            let clientIntentId: String?
        }
        return try canonicalIntentHashHex(intent: SignableInputIntent(
            kind: intent.kind,
            displayId: intent.displayId,
            normalizedX: intent.normalizedX,
            normalizedY: intent.normalizedY,
            normalizedX2: intent.normalizedX2,
            normalizedY2: intent.normalizedY2,
            text: intent.text,
            key: intent.key,
            modifiers: intent.modifiers,
            mouseButton: intent.mouseButton,
            clientIntentId: intent.clientIntentId
        ))
    }

    /// Canonical hash for signed mobile grant requests. The authority
    /// envelope is intentionally excluded because it is attached after
    /// signing, matching the `control.input` intent flow.
    public func canonicalAgentGrantRequestHashHex(request: HermesRealtimeRelayAgentGrantRequest) throws -> String {
        struct SignableAgentGrantRequest: Encodable {
            let requestId: String
            let runtime: String
            let threadId: String
            let preset: String
            let capabilities: [String]
            let trustMode: String
            let deliveryMode: String
            let requestedAt: Date
            let expiresAt: Date
            let grantDurationSeconds: Double
            let sourceDeviceId: String
            let clientIntentId: String
            let localAuthenticationSatisfied: Bool
        }
        return try canonicalIntentHashHex(intent: SignableAgentGrantRequest(
            requestId: request.requestId,
            runtime: request.runtime,
            threadId: request.threadId,
            preset: request.preset,
            capabilities: request.capabilities.sorted(),
            trustMode: request.trustMode,
            deliveryMode: request.deliveryMode,
            requestedAt: request.requestedAt,
            expiresAt: request.expiresAt,
            grantDurationSeconds: request.grantDurationSeconds,
            sourceDeviceId: request.sourceDeviceId,
            clientIntentId: request.clientIntentId,
            localAuthenticationSatisfied: request.localAuthenticationSatisfied
        ))
    }

    public func canonicalApprovalRequestHashHex(request: HermesRealtimeRelayApprovalRequest) throws -> String {
        struct SignableApprovalRequest: Encodable {
            let approvalId: String
            let runId: String
            let sessionId: String
            let toolKind: String
            let title: String
            let message: String
            let beforeScreenshotBlake3: String?
            let beforeScreenshotMimeType: String?
            let beforeScreenshotSizeBytes: Int?
            let actionSummary: String
            let requestedAt: Date
            let trustMode: String?
        }
        return try canonicalIntentHashHex(intent: SignableApprovalRequest(
            approvalId: request.approvalId,
            runId: request.runId,
            sessionId: request.sessionId,
            toolKind: request.toolKind,
            title: request.title,
            message: request.message,
            beforeScreenshotBlake3: request.beforeScreenshotBlake3,
            beforeScreenshotMimeType: request.beforeScreenshotMimeType,
            beforeScreenshotSizeBytes: request.beforeScreenshotSizeBytes,
            actionSummary: request.actionSummary,
            requestedAt: request.requestedAt,
            trustMode: request.trustMode
        ))
    }

    public func canonicalApprovalResponseHashHex(response: HermesRealtimeRelayApprovalResponse) throws -> String {
        struct SignableApprovalResponse: Encodable {
            let approvalId: String
            let decision: HermesRealtimeRelayApprovalResponse.Decision
            let respondedBy: String
            let respondedAt: Date
            let note: String?
            let requestHashBlake3: String?
        }
        return try canonicalIntentHashHex(intent: SignableApprovalResponse(
            approvalId: response.approvalId,
            decision: response.decision,
            respondedBy: response.respondedBy,
            respondedAt: response.respondedAt,
            note: response.note,
            requestHashBlake3: response.requestHashBlake3
        ))
    }

    /// Canonical hash for signed remote clipboard requests. The
    /// authority envelope is excluded because the phone attaches it only
    /// after signing, matching input intents and agent grants. Clipboard
    /// content is hashed for tamper detection, but callers must not log
    /// the request body or audit descriptor.
    public func canonicalClipboardRequestHashHex(request: HermesRealtimeRelayClipboardRequest) throws -> String {
        struct SignableClipboardRequest: Encodable {
            let requestId: String
            let action: HermesRealtimeRelayClipboardAction
            let contentType: String
            let text: String?
            let maxBytes: Int
            let clientIntentId: String
        }
        return try canonicalIntentHashHex(intent: SignableClipboardRequest(
            requestId: request.requestId,
            action: request.action,
            contentType: request.contentType,
            text: request.text,
            maxBytes: request.maxBytes,
            clientIntentId: request.clientIntentId
        ))
    }

    public func canonicalRemoteUnlockSessionHashHex(session: HermesRealtimeRelayRemoteUnlockSession) throws -> String {
        struct SignableRemoteUnlockSession: Encodable {
            let requestId: String
            let sessionId: String?
            let intent: HermesRealtimeRelayRemoteUnlockSession.Intent
            let requesterDisplayName: String
            let viewerDeviceId: String?
            let requestedAt: String
            let expiresAt: String
            let localAuthenticationSatisfied: Bool
            let requestedLockState: HermesRealtimeRelayMacLockState?
            let requestedBackend: HermesRealtimeRelayRemoteUnlockBackend?
        }
        return try canonicalIntentHashHex(intent: SignableRemoteUnlockSession(
            requestId: session.requestId,
            sessionId: session.sessionId,
            intent: session.intent,
            requesterDisplayName: session.requesterDisplayName,
            viewerDeviceId: session.viewerDeviceId,
            requestedAt: Self.canonicalRelayDateString(session.requestedAt),
            expiresAt: Self.canonicalRelayDateString(session.expiresAt),
            localAuthenticationSatisfied: session.localAuthenticationSatisfied,
            requestedLockState: session.requestedLockState,
            requestedBackend: session.requestedBackend
        ))
    }

    public func canonicalRemoteUnlockCredentialHashHex(
        credential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope
    ) throws -> String {
        struct SignableRemoteUnlockCredential: Encodable {
            let requestId: String
            let sessionId: String
            let clientIntentId: String
            let credentialKind: HermesRealtimeRelayRemoteUnlockCredentialEnvelope.CredentialKind
            let recipientKeyId: String
            let algorithm: String
            let ciphertextBase64: String
            let aadBase64: String
            let redactedByteCount: Int
            let requestedAt: String
            let expiresAt: String
        }
        return try canonicalIntentHashHex(intent: SignableRemoteUnlockCredential(
            requestId: credential.requestId,
            sessionId: credential.sessionId,
            clientIntentId: credential.clientIntentId,
            credentialKind: credential.credentialKind,
            recipientKeyId: credential.recipientKeyId,
            algorithm: credential.algorithm,
            ciphertextBase64: credential.ciphertextBase64,
            aadBase64: credential.aadBase64,
            redactedByteCount: credential.redactedByteCount,
            requestedAt: Self.canonicalRelayDateString(credential.requestedAt),
            expiresAt: Self.canonicalRelayDateString(credential.expiresAt)
        ))
    }

    /// Canonical hash for signed system permission requests. The authority
    /// envelope is omitted from the canonical form because the phone
    /// attaches it after signing, matching every other Phase 12+ wire
    /// request.
    public func canonicalSystemPermissionRequestHashHex(request: HermesRealtimeRelaySystemPermissionRequest) throws -> String {
        struct SignableSystemPermissionRequest: Encodable {
            let requestId: String
            let clientIntentId: String
            let kind: HermesRealtimeRelaySystemPermissionKind
            let bundleId: String?
            let originatingToolCallId: String?
            let originatingToolName: String?
            let action: HermesRealtimeRelaySystemPermissionAction
            let requestedAt: Date
        }
        return try canonicalIntentHashHex(intent: SignableSystemPermissionRequest(
            requestId: request.requestId,
            clientIntentId: request.clientIntentId,
            kind: request.kind,
            bundleId: request.bundleId,
            originatingToolCallId: request.originatingToolCallId,
            originatingToolName: request.originatingToolName,
            action: request.action,
            requestedAt: request.requestedAt
        ))
    }

    public func canonicalAgentContextTargetHashHex(target: HermesRealtimeRelayAgentContextTarget) throws -> String {
        struct SignableAgentContextTarget: Encodable {
            let requestId: String
            let sessionId: String?
            let runtime: String
            let threadId: String?
            let displayId: String?
            let normalizedX: Double
            let normalizedY: Double
            let normalizedRect: HermesRealtimeRelayNormalizedRect?
            let instruction: String
            let focusContext: HermesRealtimeRelayFocusContext?
            let clientIntentId: String
            let requestedAt: Date
        }
        return try canonicalIntentHashHex(intent: SignableAgentContextTarget(
            requestId: target.requestId,
            sessionId: target.sessionId,
            runtime: target.runtime,
            threadId: target.threadId,
            displayId: target.displayId,
            normalizedX: target.normalizedX,
            normalizedY: target.normalizedY,
            normalizedRect: target.normalizedRect,
            instruction: target.instruction,
            focusContext: target.focusContext,
            clientIntentId: target.clientIntentId,
            requestedAt: target.requestedAt
        ))
    }


    public func sign<Intent: Encodable>(
        intent: Intent,
        peerNodeId: String,
        counter: UInt64,
        timestamp: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedAuthority {
        let intentHashHex = try canonicalIntentHashHex(intent: intent)
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        let signature = try privateKey.signature(for: payload)
        return SignedAuthority(
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: timestamp,
            intentHashHex: intentHashHex,
            signatureBase64: signature.base64EncodedString()
        )
    }

    public func sign(
        intent: HermesRealtimeRelayInputIntent,
        peerNodeId: String,
        counter: UInt64,
        timestamp: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedAuthority {
        let intentHashHex = try canonicalInputIntentHashHex(intent: intent)
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        let signature = try privateKey.signature(for: payload)
        return SignedAuthority(
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: timestamp,
            intentHashHex: intentHashHex,
            signatureBase64: signature.base64EncodedString()
        )
    }

    public func sign(
        request: HermesRealtimeRelayAgentGrantRequest,
        peerNodeId: String,
        counter: UInt64,
        timestamp: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedAuthority {
        let intentHashHex = try canonicalAgentGrantRequestHashHex(request: request)
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        let signature = try privateKey.signature(for: payload)
        return SignedAuthority(
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: timestamp,
            intentHashHex: intentHashHex,
            signatureBase64: signature.base64EncodedString()
        )
    }

    public func sign(
        approvalResponse response: HermesRealtimeRelayApprovalResponse,
        peerNodeId: String,
        counter: UInt64,
        timestamp: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedAuthority {
        let intentHashHex = try canonicalApprovalResponseHashHex(response: response)
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        let signature = try privateKey.signature(for: payload)
        return SignedAuthority(
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: timestamp,
            intentHashHex: intentHashHex,
            signatureBase64: signature.base64EncodedString()
        )
    }

    public func sign(
        clipboardRequest request: HermesRealtimeRelayClipboardRequest,
        peerNodeId: String,
        counter: UInt64,
        timestamp: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedAuthority {
        let intentHashHex = try canonicalClipboardRequestHashHex(request: request)
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        let signature = try privateKey.signature(for: payload)
        return SignedAuthority(
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: timestamp,
            intentHashHex: intentHashHex,
            signatureBase64: signature.base64EncodedString()
        )
    }

    public func sign(
        remoteUnlockSession session: HermesRealtimeRelayRemoteUnlockSession,
        peerNodeId: String,
        counter: UInt64,
        timestamp: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedAuthority {
        let intentHashHex = try canonicalRemoteUnlockSessionHashHex(session: session)
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        let signature = try privateKey.signature(for: payload)
        return SignedAuthority(
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: timestamp,
            intentHashHex: intentHashHex,
            signatureBase64: signature.base64EncodedString()
        )
    }

    public func sign(
        remoteUnlockCredential credential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope,
        peerNodeId: String,
        counter: UInt64,
        timestamp: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedAuthority {
        let intentHashHex = try canonicalRemoteUnlockCredentialHashHex(credential: credential)
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        let signature = try privateKey.signature(for: payload)
        return SignedAuthority(
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: timestamp,
            intentHashHex: intentHashHex,
            signatureBase64: signature.base64EncodedString()
        )
    }

    public func sign(
        target: HermesRealtimeRelayAgentContextTarget,
        peerNodeId: String,
        counter: UInt64,
        timestamp: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedAuthority {
        let intentHashHex = try canonicalAgentContextTargetHashHex(target: target)
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        let signature = try privateKey.signature(for: payload)
        return SignedAuthority(
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: timestamp,
            intentHashHex: intentHashHex,
            signatureBase64: signature.base64EncodedString()
        )
    }

    public func sign(
        systemPermissionRequest request: HermesRealtimeRelaySystemPermissionRequest,
        peerNodeId: String,
        counter: UInt64,
        timestamp: Date,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> SignedAuthority {
        let intentHashHex = try canonicalSystemPermissionRequestHashHex(request: request)
        let payload = signablePayload(intentHashHex: intentHashHex, counter: counter, timestamp: timestamp)
        let signature = try privateKey.signature(for: payload)
        return SignedAuthority(
            peerNodeId: peerNodeId,
            counter: counter,
            timestamp: timestamp,
            intentHashHex: intentHashHex,
            signatureBase64: signature.base64EncodedString()
        )
    }


    public struct SignedAuthority: Codable, Hashable, Sendable {
        public let peerNodeId: String
        public let counter: UInt64
        public let timestamp: Date
        public let intentHashHex: String
        public let signatureBase64: String
    }

    public enum VerifyError: Error, Sendable, Equatable {
        case invalidBase64Signature
        case signatureFailed
        case intentHashMismatch
        case staleTimestamp(skewSeconds: Double)
        case counterReplay(lastSeen: UInt64, attempted: UInt64)
    }

    /// Pure verify. Counter check is delegated to the caller (it
    /// owns the per-peer last-seen state); freshness window is
    /// `freshnessSeconds` from `now`.
    public func verify<Intent: Encodable>(
        intent: Intent,
        authority: SignedAuthority,
        peerPublicKey: Curve25519.Signing.PublicKey,
        lastSeenCounter: UInt64,
        now: Date,
        freshnessSeconds: TimeInterval = 5.0
    ) throws {
        let skew = abs(now.timeIntervalSince(authority.timestamp))
        guard skew <= freshnessSeconds else {
            throw VerifyError.staleTimestamp(skewSeconds: skew)
        }
        guard authority.counter > lastSeenCounter else {
            throw VerifyError.counterReplay(lastSeen: lastSeenCounter, attempted: authority.counter)
        }
        let observedHex = try canonicalIntentHashHex(intent: intent)
        guard observedHex == authority.intentHashHex else {
            throw VerifyError.intentHashMismatch
        }
        guard let signatureData = Data(base64Encoded: authority.signatureBase64) else {
            throw VerifyError.invalidBase64Signature
        }
        let payload = signablePayload(
            intentHashHex: authority.intentHashHex,
            counter: authority.counter,
            timestamp: authority.timestamp
        )
        guard peerPublicKey.isValidSignature(signatureData, for: payload) else {
            throw VerifyError.signatureFailed
        }
    }

    public func verify(
        intent: HermesRealtimeRelayInputIntent,
        authority: SignedAuthority,
        peerPublicKey: Curve25519.Signing.PublicKey,
        lastSeenCounter: UInt64,
        now: Date,
        freshnessSeconds: TimeInterval = 5.0
    ) throws {
        let skew = abs(now.timeIntervalSince(authority.timestamp))
        guard skew <= freshnessSeconds else {
            throw VerifyError.staleTimestamp(skewSeconds: skew)
        }
        guard authority.counter > lastSeenCounter else {
            throw VerifyError.counterReplay(lastSeen: lastSeenCounter, attempted: authority.counter)
        }
        let observedHex = try canonicalInputIntentHashHex(intent: intent)
        guard observedHex == authority.intentHashHex else {
            throw VerifyError.intentHashMismatch
        }
        guard let signatureData = Data(base64Encoded: authority.signatureBase64) else {
            throw VerifyError.invalidBase64Signature
        }
        let payload = signablePayload(
            intentHashHex: authority.intentHashHex,
            counter: authority.counter,
            timestamp: authority.timestamp
        )
        guard peerPublicKey.isValidSignature(signatureData, for: payload) else {
            throw VerifyError.signatureFailed
        }
    }

    public func verify(
        request: HermesRealtimeRelayAgentGrantRequest,
        authority: SignedAuthority,
        peerPublicKey: Curve25519.Signing.PublicKey,
        lastSeenCounter: UInt64,
        now: Date,
        freshnessSeconds: TimeInterval = 5.0
    ) throws {
        let skew = abs(now.timeIntervalSince(authority.timestamp))
        guard skew <= freshnessSeconds else {
            throw VerifyError.staleTimestamp(skewSeconds: skew)
        }
        guard authority.counter > lastSeenCounter else {
            throw VerifyError.counterReplay(lastSeen: lastSeenCounter, attempted: authority.counter)
        }
        let observedHex = try canonicalAgentGrantRequestHashHex(request: request)
        guard observedHex == authority.intentHashHex else {
            throw VerifyError.intentHashMismatch
        }
        guard let signatureData = Data(base64Encoded: authority.signatureBase64) else {
            throw VerifyError.invalidBase64Signature
        }
        let payload = signablePayload(
            intentHashHex: authority.intentHashHex,
            counter: authority.counter,
            timestamp: authority.timestamp
        )
        guard peerPublicKey.isValidSignature(signatureData, for: payload) else {
            throw VerifyError.signatureFailed
        }
    }

    public func verify(
        target: HermesRealtimeRelayAgentContextTarget,
        authority: SignedAuthority,
        peerPublicKey: Curve25519.Signing.PublicKey,
        lastSeenCounter: UInt64,
        now: Date,
        freshnessSeconds: TimeInterval = 5.0
    ) throws {
        let skew = abs(now.timeIntervalSince(authority.timestamp))
        guard skew <= freshnessSeconds else {
            throw VerifyError.staleTimestamp(skewSeconds: skew)
        }
        guard authority.counter > lastSeenCounter else {
            throw VerifyError.counterReplay(lastSeen: lastSeenCounter, attempted: authority.counter)
        }
        let observedHex = try canonicalAgentContextTargetHashHex(target: target)
        guard observedHex == authority.intentHashHex else {
            throw VerifyError.intentHashMismatch
        }
        guard let signatureData = Data(base64Encoded: authority.signatureBase64) else {
            throw VerifyError.invalidBase64Signature
        }
        let payload = signablePayload(
            intentHashHex: authority.intentHashHex,
            counter: authority.counter,
            timestamp: authority.timestamp
        )
        guard peerPublicKey.isValidSignature(signatureData, for: payload) else {
            throw VerifyError.signatureFailed
        }
    }

    public func verify(
        clipboardRequest request: HermesRealtimeRelayClipboardRequest,
        authority: SignedAuthority,
        peerPublicKey: Curve25519.Signing.PublicKey,
        lastSeenCounter: UInt64,
        now: Date,
        freshnessSeconds: TimeInterval = 5.0
    ) throws {
        let skew = abs(now.timeIntervalSince(authority.timestamp))
        guard skew <= freshnessSeconds else {
            throw VerifyError.staleTimestamp(skewSeconds: skew)
        }
        guard authority.counter > lastSeenCounter else {
            throw VerifyError.counterReplay(lastSeen: lastSeenCounter, attempted: authority.counter)
        }
        let observedHex = try canonicalClipboardRequestHashHex(request: request)
        guard observedHex == authority.intentHashHex else {
            throw VerifyError.intentHashMismatch
        }
        guard let signatureData = Data(base64Encoded: authority.signatureBase64) else {
            throw VerifyError.invalidBase64Signature
        }
        let payload = signablePayload(
            intentHashHex: authority.intentHashHex,
            counter: authority.counter,
            timestamp: authority.timestamp
        )
        guard peerPublicKey.isValidSignature(signatureData, for: payload) else {
            throw VerifyError.signatureFailed
        }
    }

    public func verify(
        systemPermissionRequest request: HermesRealtimeRelaySystemPermissionRequest,
        authority: SignedAuthority,
        peerPublicKey: Curve25519.Signing.PublicKey,
        lastSeenCounter: UInt64,
        now: Date,
        freshnessSeconds: TimeInterval = 5.0
    ) throws {
        let skew = abs(now.timeIntervalSince(authority.timestamp))
        guard skew <= freshnessSeconds else {
            throw VerifyError.staleTimestamp(skewSeconds: skew)
        }
        guard authority.counter > lastSeenCounter else {
            throw VerifyError.counterReplay(lastSeen: lastSeenCounter, attempted: authority.counter)
        }
        let observedHex = try canonicalSystemPermissionRequestHashHex(request: request)
        guard observedHex == authority.intentHashHex else {
            throw VerifyError.intentHashMismatch
        }
        guard let signatureData = Data(base64Encoded: authority.signatureBase64) else {
            throw VerifyError.invalidBase64Signature
        }
        let payload = signablePayload(
            intentHashHex: authority.intentHashHex,
            counter: authority.counter,
            timestamp: authority.timestamp
        )
        guard peerPublicKey.isValidSignature(signatureData, for: payload) else {
            throw VerifyError.signatureFailed
        }
    }

    public func verify(
        remoteUnlockCredential credential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope,
        authority: SignedAuthority,
        peerPublicKey: Curve25519.Signing.PublicKey,
        lastSeenCounter: UInt64,
        now: Date,
        freshnessSeconds: TimeInterval = 5.0
    ) throws {
        let skew = abs(now.timeIntervalSince(authority.timestamp))
        guard skew <= freshnessSeconds else {
            throw VerifyError.staleTimestamp(skewSeconds: skew)
        }
        guard authority.counter > lastSeenCounter else {
            throw VerifyError.counterReplay(lastSeen: lastSeenCounter, attempted: authority.counter)
        }
        let observedHex = try canonicalRemoteUnlockCredentialHashHex(credential: credential)
        guard observedHex == authority.intentHashHex else {
            throw VerifyError.intentHashMismatch
        }
        guard let signatureData = Data(base64Encoded: authority.signatureBase64) else {
            throw VerifyError.invalidBase64Signature
        }
        let payload = signablePayload(
            intentHashHex: authority.intentHashHex,
            counter: authority.counter,
            timestamp: authority.timestamp
        )
        guard peerPublicKey.isValidSignature(signatureData, for: payload) else {
            throw VerifyError.signatureFailed
        }
    }
}
