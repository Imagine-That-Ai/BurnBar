#if canImport(AppKit)
import XCTest
import CryptoKit
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
@testable import OpenBurnBar

final class PhoneControlAuthorityValidatorAttestationTests: XCTestCase {
    private let phoneSigner = ComputerUsePhoneControlSigner()
    private var replayCounterStoreURLs: [URL] = []

    override func tearDown() {
        for url in replayCounterStoreURLs {
            try? FileManager.default.removeItem(at: url)
        }
        replayCounterStoreURLs.removeAll()
        super.tearDown()
    }

    // MARK: - F1 controller-key pin enforcement

    /// A controller key that differs from the Mac-pinned key is refused — the
    /// relay/Firestore control-plane key-swap MITM this remediation closes.
    func test_registerPeerRefusesSwappedControllerKey() {
        let pinStore = ControllerKeyPinStore(backing: InMemoryControllerKeyPinBacking())
        let validator = makeValidator(controllerPinStore: pinStore)
        let real = Curve25519.Signing.PrivateKey().publicKey
        let attacker = Curve25519.Signing.PrivateKey().publicKey

        guard case .pendingConfirmation = validator.registerPeerDetailed(
            nodeId: "ios-phone-aabb",
            publicKey: real,
            uid: "u1"
        ) else {
            return XCTFail("First contact must wait for Mac safety-code confirmation.")
        }
        XCTAssertTrue(validator.confirmPeerPin(nodeId: "ios-phone-aabb", publicKey: real, uid: "u1"))
        XCTAssertTrue(validator.registerPeer(nodeId: "ios-phone-aabb", publicKey: real, uid: "u1"))
        // A swapped key for the same peer is refused — always, regardless of the gate.
        XCTAssertFalse(validator.registerPeer(nodeId: "ios-phone-aabb", publicKey: attacker, uid: "u1"))
        // The genuine key still validates.
        XCTAssertTrue(validator.registerPeer(nodeId: "ios-phone-aabb", publicKey: real, uid: "u1"))
    }

    /// Without a uid (signature-only / legacy callers) pin enforcement is skipped,
    /// preserving backward compatibility.
    func test_registerPeerWithoutUidSkipsPinEnforcement() {
        let pinStore = ControllerKeyPinStore(backing: InMemoryControllerKeyPinBacking())
        let validator = makeValidator(controllerPinStore: pinStore)
        let a = Curve25519.Signing.PrivateKey().publicKey
        let b = Curve25519.Signing.PrivateKey().publicKey
        XCTAssertTrue(validator.registerPeer(nodeId: "p", publicKey: a))
        XCTAssertTrue(validator.registerPeer(nodeId: "p", publicKey: b))
    }

    func test_rejectsAttestationMismatchWhenRequired() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)

        var intent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            displayId: nil,
            normalizedX: 0.5,
            normalizedY: 0.5,
            normalizedX2: nil,
            normalizedY2: nil,
            text: nil,
            key: nil,
            modifiers: nil,
            mouseButton: nil,
            clientIntentId: "intent-1",
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: 1,
                timestamp: Date(),
                intentHashBlake3: "",
                signatureEd25519: "",
                attestationHashBlake3: "observed-hash"
            )
        )
        let signed = try phoneSigner.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: intent.authority.timestamp,
            privateKey: privateKey
        )
        intent.authority.intentHashBlake3 = signed.intentHashHex
        intent.authority.signatureEd25519 = signed.signatureBase64

        XCTAssertThrowsError(
            try validator.validate(
                envelope: intent.authority,
                intent: intent,
                requiredAttestationHashBlake3: "required-hash"
            )
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.attestationMismatch = error else {
                return XCTFail("Expected attestationMismatch, got \(error)")
            }
        }
    }

    func test_requirePresent_rejectsMissingEnvelopeAttestation() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let intent = try signedTapIntent(privateKey: privateKey, attestationDigest: nil)

        XCTAssertThrowsError(
            try validator.validate(
                envelope: intent.authority,
                intent: intent,
                attestation: .requirePresent
            )
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.missingAttestation = error else {
                return XCTFail("Expected missingAttestation, got \(error)")
            }
        }
    }

    func test_requirePresent_acceptsNonEmptyAttestation() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let intent = try signedTapIntent(privateKey: privateKey, attestationDigest: "phone-digest")

        XCTAssertNoThrow(
            try validator.validate(
                envelope: intent.authority,
                intent: intent,
                attestation: .requirePresent
            )
        )
    }

    func test_clipboardValidationRequiresAttestationWhenPolicyRequiresIt() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let request = try signedClipboardRequest(privateKey: privateKey, attestationDigest: nil)

        XCTAssertThrowsError(
            try validator.validate(
                envelope: request.authority,
                clipboardRequest: request,
                attestation: .requirePresent
            )
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.missingAttestation = error else {
                return XCTFail("Expected missingAttestation, got \(error)")
            }
        }
    }

    func test_remoteUnlockCredentialValidationRequiresAttestationWhenPolicyRequiresIt() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let credential = try signedRemoteUnlockCredential(privateKey: privateKey, attestationDigest: nil)

        XCTAssertThrowsError(
            try validator.validate(
                envelope: credential.authority,
                remoteUnlockCredential: credential,
                attestation: .requirePresent
            )
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.missingAttestation = error else {
                return XCTFail("Expected missingAttestation, got \(error)")
            }
        }
    }

    func test_strictMode_rejectsMacUnbound() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let intent = try signedTapIntent(privateKey: privateKey, attestationDigest: "any")

        XCTAssertThrowsError(
            try validator.validate(
                envelope: intent.authority,
                intent: intent,
                attestation: .rejectUnboundHost
            )
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.macAttestationUnbound = error else {
                return XCTFail("Expected macAttestationUnbound, got \(error)")
            }
        }
    }

    func test_strictMode_acceptsMatchingDigest() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let digest = AppCheckAttestationBinding.digestHex(
            appId: "1:123:ios:abc",
            boundAtMillis: 1_700_000_000_000
        )
        let intent = try signedTapIntent(privateKey: privateKey, attestationDigest: digest)

        XCTAssertNoThrow(
            try validator.validate(
                envelope: intent.authority,
                intent: intent,
                attestation: .required(digest: digest)
            )
        )
    }

    func test_revokedPeerRejected() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        validator.revokePeer(nodeId: "peer-1")

        var intent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            displayId: nil,
            normalizedX: 0.5,
            normalizedY: 0.5,
            normalizedX2: nil,
            normalizedY2: nil,
            text: nil,
            key: nil,
            modifiers: nil,
            mouseButton: nil,
            clientIntentId: "intent-2",
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: 1,
                timestamp: Date(),
                intentHashBlake3: "",
                signatureEd25519: ""
            )
        )
        let signed = try phoneSigner.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: intent.authority.timestamp,
            privateKey: privateKey
        )
        intent.authority.intentHashBlake3 = signed.intentHashHex
        intent.authority.signatureEd25519 = signed.signatureBase64

        XCTAssertThrowsError(try validator.validate(envelope: intent.authority, intent: intent)) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.peerRevoked = error else {
                return XCTFail("Expected peerRevoked, got \(error)")
            }
        }
    }

    func test_registerPeerRefusesRevokedPeerAndFailsClosed() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        // Revoke BEFORE any (re)registration — simulates a revoked device
        // reconnecting and trying to re-admit its pubkey via controlClassify.
        validator.revokePeer(nodeId: "peer-1")
        XCTAssertTrue(validator.isPeerRevoked(nodeId: "peer-1"))

        let registered = validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        XCTAssertFalse(registered, "A revoked peer must NOT be re-registrable.")
        XCTAssertFalse(validator.hasPeer(nodeId: "peer-1"), "The revoked peer's pubkey must not be stored.")

        var intent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            displayId: nil,
            normalizedX: 0.5,
            normalizedY: 0.5,
            normalizedX2: nil,
            normalizedY2: nil,
            text: nil,
            key: nil,
            modifiers: nil,
            mouseButton: nil,
            clientIntentId: "intent-reconnect",
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: 1,
                timestamp: Date(),
                intentHashBlake3: "",
                signatureEd25519: ""
            )
        )
        let signed = try phoneSigner.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: intent.authority.timestamp,
            privateKey: privateKey
        )
        intent.authority.intentHashBlake3 = signed.intentHashHex
        intent.authority.signatureEd25519 = signed.signatureBase64

        XCTAssertThrowsError(
            try validator.validate(envelope: intent.authority, intent: intent),
            "A reconnecting revoked peer must fail closed."
        ) { error in
            switch error {
            case PhoneControlAuthorityValidator.ValidationError.peerRevoked,
                 PhoneControlAuthorityValidator.ValidationError.missingPeerPubKey:
                break
            default:
                XCTFail("Expected peerRevoked or missingPeerPubKey, got \(error)")
            }
        }
    }

    func test_escrowDeviceRevokedRejectsGrantRequest() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        validator.revokeEscrowDevice(deviceId: "escrow-device-1")
        XCTAssertTrue(validator.isEscrowDeviceRevoked(deviceId: "escrow-device-1"))

        let now = Date()
        var request = HermesRealtimeRelayAgentGrantRequest(
            requestId: UUID().uuidString,
            runtime: "claude",
            threadId: "thread-1",
            preset: "default",
            capabilities: ["chat"],
            trustMode: "manual",
            deliveryMode: "push",
            requestedAt: now,
            expiresAt: now.addingTimeInterval(60),
            grantDurationSeconds: 60,
            sourceDeviceId: "escrow-device-1",
            clientIntentId: UUID().uuidString,
            localAuthenticationSatisfied: true,
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: 1,
                timestamp: now,
                intentHashBlake3: "",
                signatureEd25519: ""
            )
        )
        let signed = try phoneSigner.sign(
            request: request,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: now,
            privateKey: privateKey
        )
        request.authority.intentHashBlake3 = signed.intentHashHex
        request.authority.signatureEd25519 = signed.signatureBase64

        XCTAssertThrowsError(
            try validator.validate(envelope: request.authority, grantRequest: request)
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.escrowDeviceRevoked(let deviceId) = error else {
                return XCTFail("Expected escrowDeviceRevoked, got \(error)")
            }
            XCTAssertEqual(deviceId, "escrow-device-1")
        }
    }

    func test_revocationQueryHelpersReflectState() {
        let validator = makeValidator()
        XCTAssertFalse(validator.isPeerRevoked(nodeId: "peer-9"))
        XCTAssertFalse(validator.isEscrowDeviceRevoked(deviceId: "device-9"))
        validator.revokePeer(nodeId: "peer-9")
        validator.revokeEscrowDevice(deviceId: "device-9")
        XCTAssertTrue(validator.isPeerRevoked(nodeId: "peer-9"))
        XCTAssertTrue(validator.isEscrowDeviceRevoked(deviceId: "device-9"))
        validator.clearRevocations()
        XCTAssertFalse(validator.isPeerRevoked(nodeId: "peer-9"))
        XCTAssertFalse(validator.isEscrowDeviceRevoked(deviceId: "device-9"))
    }

    func test_signedApprovalResponseValidatesAndBindsPendingRequestHash() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let request = approvalRequest(toolKind: "desktop.click")
        let requestHash = try phoneSigner.canonicalApprovalRequestHashHex(request: request)
        var response = HermesRealtimeRelayApprovalResponse(
            approvalId: request.approvalId,
            decision: .approve,
            respondedBy: "phone",
            respondedAt: Date(),
            note: nil,
            requestHashBlake3: requestHash
        )
        let signed = try phoneSigner.sign(
            approvalResponse: response,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: response.respondedAt,
            privateKey: privateKey
        )
        response.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        )

        let result = try validator.validate(
            envelope: response.authority!,
            approvalResponse: response,
            expectedRequestHashBlake3: requestHash,
            now: response.respondedAt
        )

        XCTAssertEqual(result.peerNodeId, "peer-1")
    }

    func test_signedApprovalResponseRejectsWrongPendingRequestHash() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let request = approvalRequest(toolKind: "desktop.click")
        let otherRequestHash = try phoneSigner.canonicalApprovalRequestHashHex(
            request: approvalRequest(toolKind: "desktop.type")
        )
        var response = HermesRealtimeRelayApprovalResponse(
            approvalId: request.approvalId,
            decision: .approve,
            respondedBy: "phone",
            respondedAt: Date(),
            note: nil,
            requestHashBlake3: otherRequestHash
        )
        let signed = try phoneSigner.sign(
            approvalResponse: response,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: response.respondedAt,
            privateKey: privateKey
        )
        response.authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        )

        XCTAssertThrowsError(try validator.validate(
            envelope: response.authority!,
            approvalResponse: response,
            expectedRequestHashBlake3: try phoneSigner.canonicalApprovalRequestHashHex(request: request),
            now: response.respondedAt
        )) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.intentHashMismatch = error else {
                return XCTFail("Expected intentHashMismatch, got \(error)")
            }
        }
    }

    func test_replayCounterStoreRejectsCapturedEnvelopeAfterValidatorRestart() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-phone-replay-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let privateKey = Curve25519.Signing.PrivateKey()
        let firstStore = PhoneControlReplayCounterStore(fileURL: fileURL)
        let firstValidator = PhoneControlAuthorityValidator(
            controllerPinStore: nil,
            replayCounterStore: firstStore
        )
        firstValidator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let intent = try signedTapIntent(privateKey: privateKey, attestationDigest: nil, counter: 9)

        XCTAssertEqual(
            try firstValidator.validate(envelope: intent.authority, intent: intent).counter,
            9
        )
        XCTAssertEqual(firstStore.load()["peer-1"], 9)

        let restartedValidator = PhoneControlAuthorityValidator(
            controllerPinStore: nil,
            replayCounterStore: PhoneControlReplayCounterStore(fileURL: fileURL)
        )
        restartedValidator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)

        XCTAssertThrowsError(
            try restartedValidator.validate(envelope: intent.authority, intent: intent)
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.counterReplay(let lastSeen, let attempted) = error else {
                return XCTFail("Expected counterReplay, got \(error)")
            }
            XCTAssertEqual(lastSeen, 9)
            XCTAssertEqual(attempted, 9)
        }
    }

    func test_replayCounterStoreMergeByMaxDoesNotDowngradeCounters() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-phone-replay-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = PhoneControlReplayCounterStore(fileURL: fileURL)

        try store.persist(["peer-1": 12])
        try store.persist(["peer-1": 7, "peer-2": 3])

        XCTAssertEqual(store.load()["peer-1"], 12)
        XCTAssertEqual(store.load()["peer-2"], 3)
    }

    // MARK: - F2 key-kind (Secure-Enclave P-256) validation

    /// An SE-P256-signed envelope (raw r‖s ECDSA, `keyKind: "se-p256"`)
    /// validates against a registered SE verifying key.
    func test_seP256SignedIntentValidates() throws {
        let validator = makeValidator()
        let identity = PhoneControlAuthoritySigningKey.secureEnclaveP256(P256.Signing.PrivateKey())
        XCTAssertTrue(validator.registerPeer(nodeId: "peer-1", verifyingKey: identity.verifyingKey))

        let intent = try seSignedTapIntent(identity: identity)
        let result = try validator.validate(envelope: intent.authority, intent: intent)
        XCTAssertEqual(result.peerNodeId, "peer-1")
        XCTAssertEqual(result.counter, 1)
    }

    /// An envelope that claims legacy `ed25519` against an SE-registered key
    /// (the downgrade an attacker would attempt) fails closed — and so does the
    /// reverse mismatch.
    func test_envelopeKeyKindMismatchFailsClosed() throws {
        let validator = makeValidator()
        let identity = PhoneControlAuthoritySigningKey.secureEnclaveP256(P256.Signing.PrivateKey())
        XCTAssertTrue(validator.registerPeer(nodeId: "peer-1", verifyingKey: identity.verifyingKey))

        var downgraded = try seSignedTapIntent(identity: identity)
        downgraded.authority.keyKind = nil // claim pre-F2 legacy ed25519
        XCTAssertThrowsError(
            try validator.validate(envelope: downgraded.authority, intent: downgraded)
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.signatureFailed = error else {
                return XCTFail("Expected signatureFailed, got \(error)")
            }
        }

        let legacyValidator = makeValidator()
        let legacyKey = Curve25519.Signing.PrivateKey()
        legacyValidator.registerPeer(nodeId: "peer-1", publicKey: legacyKey.publicKey)
        var escalated = try signedTapIntent(privateKey: legacyKey, attestationDigest: nil)
        escalated.authority.keyKind = .secureEnclaveP256
        XCTAssertThrowsError(
            try legacyValidator.validate(envelope: escalated.authority, intent: escalated)
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.signatureFailed = error else {
                return XCTFail("Expected signatureFailed, got \(error)")
            }
        }
    }

    /// F2 step-up: a sensitive grant (shell) signed by a biometry-gated SE key
    /// needs no explicit local-auth proof — the signature is the user-presence
    /// proof. The same grant signed by a legacy software key still demands one.
    func test_stepUpEvidencePerKeyKindOnSensitiveGrant() throws {
        let now = Date()
        func grant(authority: HermesRealtimeRelayAuthorityEnvelope) -> HermesRealtimeRelayAgentGrantRequest {
            HermesRealtimeRelayAgentGrantRequest(
                requestId: UUID().uuidString,
                runtime: "claude",
                threadId: "thread-1",
                preset: "default",
                capabilities: [AgentDesktopCapability.shell.rawValue],
                trustMode: ComputerUseTrustMode.manual.rawValue,
                deliveryMode: "push",
                requestedAt: now,
                expiresAt: now.addingTimeInterval(60),
                grantDurationSeconds: 60,
                sourceDeviceId: "escrow-device-1",
                clientIntentId: UUID().uuidString,
                localAuthenticationSatisfied: false,
                authority: authority
            )
        }

        // SE key: validates without any proof attached.
        let seValidator = makeValidator()
        let identity = PhoneControlAuthoritySigningKey.secureEnclaveP256(P256.Signing.PrivateKey())
        XCTAssertTrue(seValidator.registerPeer(nodeId: "peer-1", verifyingKey: identity.verifyingKey))
        var seRequest = grant(authority: HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: now,
            intentHashBlake3: "",
            signatureEd25519: "",
            keyKind: .secureEnclaveP256
        ))
        let seHash = try phoneSigner.canonicalAgentGrantRequestHashHex(request: seRequest)
        let seSigned = try phoneSigner.signAuthority(
            intentHashHex: seHash,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: now,
            key: identity
        )
        seRequest.authority.intentHashBlake3 = seSigned.intentHashHex
        seRequest.authority.signatureEd25519 = seSigned.signatureBase64
        XCTAssertNoThrow(try seValidator.validate(envelope: seRequest.authority, grantRequest: seRequest, now: now))

        // Legacy key: the identical grant fails for want of the explicit proof.
        let legacyValidator = makeValidator()
        let legacyKey = Curve25519.Signing.PrivateKey()
        legacyValidator.registerPeer(nodeId: "peer-1", publicKey: legacyKey.publicKey)
        var legacyRequest = grant(authority: HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: now,
            intentHashBlake3: "",
            signatureEd25519: ""
        ))
        let legacySigned = try phoneSigner.sign(
            request: legacyRequest,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: now,
            privateKey: legacyKey
        )
        legacyRequest.authority.intentHashBlake3 = legacySigned.intentHashHex
        legacyRequest.authority.signatureEd25519 = legacySigned.signatureBase64
        XCTAssertThrowsError(
            try legacyValidator.validate(envelope: legacyRequest.authority, grantRequest: legacyRequest, now: now)
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.localAuthProofRequired = error else {
                return XCTFail("Expected localAuthProofRequired, got \(error)")
            }
        }
    }

    private func seSignedTapIntent(
        identity: PhoneControlAuthoritySigningKey,
        counter: UInt64 = 1,
        timestamp: Date = Date()
    ) throws -> HermesRealtimeRelayInputIntent {
        var intent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            displayId: nil,
            normalizedX: 0.5,
            normalizedY: 0.5,
            normalizedX2: nil,
            normalizedY2: nil,
            text: nil,
            key: nil,
            modifiers: nil,
            mouseButton: nil,
            clientIntentId: UUID().uuidString,
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: counter,
                timestamp: timestamp,
                intentHashBlake3: "",
                signatureEd25519: "",
                keyKind: .secureEnclaveP256
            )
        )
        let hashHex = try phoneSigner.canonicalInputIntentHashHex(intent: intent)
        let signed = try phoneSigner.signAuthority(
            intentHashHex: hashHex,
            peerNodeId: "peer-1",
            counter: counter,
            timestamp: timestamp,
            key: identity
        )
        intent.authority.intentHashBlake3 = signed.intentHashHex
        intent.authority.signatureEd25519 = signed.signatureBase64
        return intent
    }

    private func makeValidator(
        freshnessWindow: TimeInterval = 5.0,
        authorityMaxLifetime: TimeInterval = 300.0,
        controllerPinStore: ControllerKeyPinStore? = nil,
        pinEnforcement: @escaping @Sendable () -> Bool = { ControllerKeyPinEnforcementFlag.isEnabled() }
    ) -> PhoneControlAuthorityValidator {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-phone-replay-test-\(UUID().uuidString).json")
        replayCounterStoreURLs.append(fileURL)
        return PhoneControlAuthorityValidator(
            freshnessWindow: freshnessWindow,
            authorityMaxLifetime: authorityMaxLifetime,
            controllerPinStore: controllerPinStore,
            pinEnforcement: pinEnforcement,
            replayCounterStore: PhoneControlReplayCounterStore(fileURL: fileURL)
        )
    }

    private func approvalRequest(toolKind: String) -> HermesRealtimeRelayApprovalRequest {
        HermesRealtimeRelayApprovalRequest(
            approvalId: "approval-1",
            runId: "run-1",
            sessionId: "session-1",
            toolKind: toolKind,
            title: "Approve action",
            message: "Approve \(toolKind)",
            beforeScreenshotBlake3: "screenshot-hash",
            actionSummary: "Approve \(toolKind)",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            trustMode: "manual"
        )
    }

    private func signedTapIntent(
        privateKey: Curve25519.Signing.PrivateKey,
        attestationDigest: String?,
        counter: UInt64 = 1,
        timestamp: Date = Date()
    ) throws -> HermesRealtimeRelayInputIntent {
        var intent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            displayId: nil,
            normalizedX: 0.5,
            normalizedY: 0.5,
            normalizedX2: nil,
            normalizedY2: nil,
            text: nil,
            key: nil,
            modifiers: nil,
            mouseButton: nil,
            clientIntentId: UUID().uuidString,
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: counter,
                timestamp: timestamp,
                intentHashBlake3: "",
                signatureEd25519: "",
                attestationHashBlake3: attestationDigest
            )
        )
        let signed = try phoneSigner.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: counter,
            timestamp: timestamp,
            privateKey: privateKey
        )
        intent.authority.intentHashBlake3 = signed.intentHashHex
        intent.authority.signatureEd25519 = signed.signatureBase64
        return intent
    }

    private func signedClipboardRequest(
        privateKey: Curve25519.Signing.PrivateKey,
        attestationDigest: String?
    ) throws -> HermesRealtimeRelayClipboardRequest {
        var request = HermesRealtimeRelayClipboardRequest(
            requestId: UUID().uuidString,
            action: .pasteToMac,
            contentType: "text/plain",
            text: "hello",
            maxBytes: 65_536,
            clientIntentId: UUID().uuidString,
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: 1,
                timestamp: Date(),
                intentHashBlake3: "",
                signatureEd25519: "",
                attestationHashBlake3: attestationDigest
            )
        )
        let signed = try phoneSigner.sign(
            clipboardRequest: request,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: request.authority.timestamp,
            privateKey: privateKey
        )
        request.authority.intentHashBlake3 = signed.intentHashHex
        request.authority.signatureEd25519 = signed.signatureBase64
        return request
    }

    private func signedRemoteUnlockCredential(
        privateKey: Curve25519.Signing.PrivateKey,
        attestationDigest: String?
    ) throws -> HermesRealtimeRelayRemoteUnlockCredentialEnvelope {
        let now = Date()
        var credential = HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
            requestId: UUID().uuidString,
            sessionId: "remote-unlock-session",
            clientIntentId: UUID().uuidString,
            credentialKind: .typedPassword,
            recipientKeyId: "recipient-key",
            algorithm: "X25519-XSalsa20Poly1305",
            ciphertextBase64: Data("ciphertext".utf8).base64EncodedString(),
            aadBase64: Data("aad".utf8).base64EncodedString(),
            redactedByteCount: 12,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(60),
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: 1,
                timestamp: now,
                intentHashBlake3: "",
                signatureEd25519: "",
                attestationHashBlake3: attestationDigest
            )
        )
        let signed = try phoneSigner.sign(
            remoteUnlockCredential: credential,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: credential.authority.timestamp,
            privateKey: privateKey
        )
        credential.authority.intentHashBlake3 = signed.intentHashHex
        credential.authority.signatureEd25519 = signed.signatureBase64
        return credential
    }
}
#endif
