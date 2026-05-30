import XCTest
import CryptoKit
import OpenBurnBarCore
@testable import OpenBurnBarComputerUseCore

final class RemoteUnlockPolicyTests: XCTestCase {
    func test_screenSharingProbeRequiresLiveLoopbackListener() {
        let probe = RemoteUnlockSystemScreenSharingProbe(
            applicationPaths: ["/System/Applications/Utilities/Screen Sharing.app"],
            fileExists: { $0 == "/System/Applications/Utilities/Screen Sharing.app" },
            canConnectLoopback: { _, _ in false }
        )

        let status = probe.status()

        XCTAssertTrue(status.applicationAvailable)
        XCTAssertFalse(status.loopbackListenerAvailable)
        XCTAssertFalse(status.isAvailable)
    }

    func test_screenSharingProbeAcceptsCurrentAppPathAndLiveLoopbackListener() {
        let probe = RemoteUnlockSystemScreenSharingProbe(
            applicationPaths: ["/System/Applications/Utilities/Screen Sharing.app"],
            fileExists: { $0 == "/System/Applications/Utilities/Screen Sharing.app" },
            canConnectLoopback: { port, timeout in
                XCTAssertEqual(port, RemoteUnlockSystemScreenSharingProbe.defaultLoopbackPort)
                XCTAssertGreaterThan(timeout, 0)
                return true
            }
        )

        let status = probe.status()

        XCTAssertTrue(status.applicationAvailable)
        XCTAssertTrue(status.loopbackListenerAvailable)
        XCTAssertTrue(status.isAvailable)
    }

    func test_capabilitiesAllowFirstHardwareProofWhenRuntimeLaneIsReady() {
        let policy = RemoteUnlockPolicy.default
        let snapshot = RemoteUnlockReadinessSnapshot(
            featureFlagEnabled: true,
            directDownloadBuild: true,
            daemonInstalled: true,
            systemScreenSharingAvailable: true,
            loopbackOnlyFirewallActive: false,
            generatedCredentialInSystemKeychain: true,
            backendCertificationFresh: true,
            currentOSBuild: "23G93",
            certifiedOSBuild: "23G93",
            certifiedAt: Date(timeIntervalSince1970: 1_774_000_000),
            fileVaultEnabled: true,
            fileVaultSSHSupported: false,
            lastLockScreenProbeSucceeded: true,
            lastCredentialInputProbeSucceeded: true,
            lastUnlockProbeSucceeded: true,
            credentialRecipientKeyId: "mac-remote-unlock-key",
            credentialRecipientPublicKeyBase64: "cHVibGljLWtleQ=="
        )

        let capabilities = policy.capabilities(for: snapshot)

        XCTAssertTrue(capabilities.enabled)
        XCTAssertEqual(capabilities.activeBackend, .appleScreenSharingLoopback)
        XCTAssertEqual(capabilities.certificationStatus, .failed)
        XCTAssertTrue(capabilities.blockers.isEmpty)
        XCTAssertTrue(capabilities.allowsCredentialPaste)
        XCTAssertTrue(capabilities.allowsSavedCredentialUnlock)
        XCTAssertEqual(capabilities.credentialRecipientKeyId, "mac-remote-unlock-key")
        XCTAssertEqual(capabilities.credentialRecipientPublicKeyBase64, "cHVibGljLWtleQ==")
        XCTAssertEqual(capabilities.credentialEnvelopeAlgorithm, RemoteUnlockPolicy.credentialEnvelopeAlgorithm)
        XCTAssertFalse(capabilities.fileVaultSSHSupported)
    }

    func test_runtimeReadyWithoutHardwareProofIsNotCertified() {
        let policy = RemoteUnlockPolicy.default
        let snapshot = RemoteUnlockReadinessSnapshot(
            featureFlagEnabled: true,
            directDownloadBuild: true,
            daemonInstalled: true,
            systemScreenSharingAvailable: true,
            loopbackOnlyFirewallActive: false,
            generatedCredentialInSystemKeychain: true,
            backendCertificationFresh: false,
            currentOSBuild: "23G93",
            certifiedOSBuild: nil,
            certifiedAt: nil,
            fileVaultEnabled: true,
            fileVaultSSHSupported: false,
            lastLockScreenProbeSucceeded: false,
            lastCredentialInputProbeSucceeded: false,
            lastUnlockProbeSucceeded: false,
            credentialRecipientKeyId: "mac-remote-unlock-key",
            credentialRecipientPublicKeyBase64: "cHVibGljLWtleQ=="
        )

        let capabilities = policy.capabilities(for: snapshot)

        XCTAssertTrue(capabilities.enabled)
        XCTAssertEqual(capabilities.activeBackend, .appleScreenSharingLoopback)
        XCTAssertEqual(capabilities.certificationStatus, .uncertified)
        XCTAssertTrue(capabilities.allowsCredentialPaste)
        XCTAssertEqual(capabilities.credentialRecipientKeyId, "mac-remote-unlock-key")
    }

    func test_capabilitiesAdvertiseAppleScreenSharingLoopbackOnlyAfterCertification() {
        let policy = RemoteUnlockPolicy.default
        let snapshot = certifiedSnapshot()

        let capabilities = policy.capabilities(for: snapshot)

        XCTAssertTrue(capabilities.enabled)
        XCTAssertEqual(capabilities.certificationStatus, .certified)
        XCTAssertEqual(capabilities.activeBackend, .appleScreenSharingLoopback)
        XCTAssertEqual(capabilities.supportedBackends, [.appleScreenSharingLoopback])
        XCTAssertTrue(capabilities.supportedLockStates.contains(.loginWindow))
        XCTAssertTrue(capabilities.supportedLockStates.contains(.rebootLoginWindow))
        XCTAssertTrue(capabilities.allowsCredentialPaste)
        XCTAssertTrue(capabilities.allowsSavedCredentialUnlock)
        XCTAssertEqual(capabilities.credentialRecipientKeyId, "mac-remote-unlock-key")
        XCTAssertEqual(capabilities.credentialRecipientPublicKeyBase64, "cHVibGljLWtleQ==")
        XCTAssertEqual(capabilities.credentialEnvelopeAlgorithm, RemoteUnlockPolicy.credentialEnvelopeAlgorithm)
        XCTAssertTrue(capabilities.blockers.isEmpty)
    }

    func test_capabilitiesRequireCredentialRecipientKeyMaterial() {
        let policy = RemoteUnlockPolicy.default
        var snapshot = certifiedSnapshot()
        snapshot.credentialRecipientKeyId = nil
        snapshot.credentialRecipientPublicKeyBase64 = " "

        let capabilities = policy.capabilities(for: snapshot)

        XCTAssertFalse(capabilities.enabled)
        XCTAssertFalse(capabilities.allowsCredentialPaste)
        XCTAssertFalse(capabilities.allowsSavedCredentialUnlock)
        XCTAssertTrue(capabilities.blockers.contains("remote_unlock_recipient_key_missing"))
        XCTAssertNil(capabilities.credentialRecipientKeyId)
        XCTAssertNil(capabilities.credentialRecipientPublicKeyBase64)
    }

    func test_capabilitiesRequireLiveRemoteAccessDaemonForRuntimeLane() {
        let policy = RemoteUnlockPolicy.default
        var snapshot = certifiedSnapshot()
        snapshot.daemonInstalled = false

        let capabilities = policy.capabilities(for: snapshot)

        XCTAssertFalse(capabilities.enabled)
        XCTAssertFalse(capabilities.allowsCredentialPaste)
        XCTAssertFalse(capabilities.allowsSavedCredentialUnlock)
        XCTAssertEqual(capabilities.activeBackend, .unavailable)
        XCTAssertTrue(capabilities.blockers.contains("remote_access_daemon_missing"))
        XCTAssertNil(capabilities.credentialRecipientKeyId)
    }

    func test_osBuildDriftInvalidatesCertification() {
        let policy = RemoteUnlockPolicy.default
        var snapshot = certifiedSnapshot()
        snapshot.currentOSBuild = "24A100"

        let capabilities = policy.capabilities(for: snapshot)

        XCTAssertTrue(capabilities.enabled)
        XCTAssertTrue(capabilities.allowsCredentialPaste)
        XCTAssertEqual(capabilities.certificationStatus, .stale)
        XCTAssertFalse(capabilities.blockers.contains("os_build_changed_recertification_required"))
    }

    func test_sessionRequiresLocalAuthenticationAndSupportedBackend() {
        let policy = RemoteUnlockPolicy.default
        let capabilities = policy.capabilities(for: certifiedSnapshot())
        let now = Date(timeIntervalSince1970: 1_774_000_000)
        let session = remoteUnlockSession(
            localAuthenticationSatisfied: false,
            requestedBackend: .appleScreenSharingLoopback,
            expiresAt: now.addingTimeInterval(60)
        )

        XCTAssertEqual(
            policy.validate(session: session, capabilities: capabilities, now: now),
            .denied("local_auth_required")
        )

        let valid = remoteUnlockSession(
            localAuthenticationSatisfied: true,
            requestedBackend: .appleScreenSharingLoopback,
            expiresAt: now.addingTimeInterval(60)
        )
        XCTAssertEqual(policy.validate(session: valid, capabilities: capabilities, now: now), .allowed)
    }

    func test_sessionRejectsOverlongOrFutureDatedRequests() {
        let policy = RemoteUnlockPolicy.default
        let capabilities = policy.capabilities(for: certifiedSnapshot())
        let now = Date(timeIntervalSince1970: 1_774_000_000)

        let overlong = remoteUnlockSession(
            localAuthenticationSatisfied: true,
            requestedBackend: .appleScreenSharingLoopback,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(policy.sessionTTLSeconds + 1)
        )
        XCTAssertEqual(
            policy.validate(session: overlong, capabilities: capabilities, now: now),
            .denied("session_ttl_exceeded")
        )

        let future = remoteUnlockSession(
            localAuthenticationSatisfied: true,
            requestedBackend: .appleScreenSharingLoopback,
            requestedAt: now.addingTimeInterval(31),
            expiresAt: now.addingTimeInterval(90)
        )
        XCTAssertEqual(
            policy.validate(session: future, capabilities: capabilities, now: now),
            .denied("session_requested_at_in_future")
        )
    }

    func test_sessionRequiresSessionIdForCredentialBinding() {
        let policy = RemoteUnlockPolicy.default
        let capabilities = policy.capabilities(for: certifiedSnapshot())
        let now = Date(timeIntervalSince1970: 1_774_000_000)
        let missing = remoteUnlockSession(
            sessionId: nil,
            localAuthenticationSatisfied: true,
            requestedBackend: .appleScreenSharingLoopback,
            expiresAt: now.addingTimeInterval(60)
        )
        let blank = remoteUnlockSession(
            sessionId: " ",
            localAuthenticationSatisfied: true,
            requestedBackend: .appleScreenSharingLoopback,
            expiresAt: now.addingTimeInterval(60)
        )

        XCTAssertEqual(
            policy.validate(session: missing, capabilities: capabilities, now: now),
            .denied("session_id_required")
        )
        XCTAssertEqual(
            policy.validate(session: blank, capabilities: capabilities, now: now),
            .denied("session_id_required")
        )
    }

    func test_credentialEnvelopeRejectsPlainOrExpiredPayloads() {
        let policy = RemoteUnlockPolicy.default
        let now = Date(timeIntervalSince1970: 1_774_000_000)
        let expired = credential(
            algorithm: RemoteUnlockPolicy.credentialEnvelopeAlgorithm,
            redactedByteCount: 12,
            ciphertextBase64: "Y2lwaGVy",
            aadBase64: "YWFk",
            expiresAt: now.addingTimeInterval(-1)
        )

        XCTAssertEqual(
            policy.validate(credential: expired, sessionId: "unlock-session", now: now),
            .denied("credential_expired")
        )

        let unsupported = credential(
            algorithm: "plain-text",
            redactedByteCount: 12,
            ciphertextBase64: "secret",
            aadBase64: "aad",
            expiresAt: now.addingTimeInterval(30)
        )
        XCTAssertEqual(
            policy.validate(credential: unsupported, sessionId: "unlock-session", now: now),
            .denied("unsupported_credential_algorithm")
        )
    }

    func test_credentialEnvelopeRejectsWrongActiveSession() {
        let policy = RemoteUnlockPolicy.default
        let now = Date(timeIntervalSince1970: 1_774_000_000)
        let envelope = credential(
            algorithm: RemoteUnlockPolicy.credentialEnvelopeAlgorithm,
            redactedByteCount: 12,
            ciphertextBase64: "Y2lwaGVy",
            aadBase64: "YWFk",
            expiresAt: now.addingTimeInterval(30)
        )

        XCTAssertEqual(
            policy.validate(credential: envelope, sessionId: "different-session", now: now),
            .denied("session_mismatch")
        )
    }

    func test_credentialEnvelopeRejectsOverlongMissingOrInvalidBase64Payloads() {
        let policy = RemoteUnlockPolicy.default
        let now = Date(timeIntervalSince1970: 1_774_000_000)

        let overlong = credential(
            algorithm: RemoteUnlockPolicy.credentialEnvelopeAlgorithm,
            redactedByteCount: 12,
            ciphertextBase64: "Y2lwaGVy",
            aadBase64: "YWFk",
            requestedAt: now,
            expiresAt: now.addingTimeInterval(policy.credentialTTLSeconds + 1)
        )
        XCTAssertEqual(
            policy.validate(credential: overlong, sessionId: "unlock-session", now: now),
            .denied("credential_ttl_exceeded")
        )

        let missingKeyId = credential(
            algorithm: RemoteUnlockPolicy.credentialEnvelopeAlgorithm,
            redactedByteCount: 12,
            ciphertextBase64: "Y2lwaGVy",
            aadBase64: "YWFk",
            recipientKeyId: " ",
            expiresAt: now.addingTimeInterval(30)
        )
        XCTAssertEqual(
            policy.validate(credential: missingKeyId, sessionId: "unlock-session", now: now),
            .denied("credential_envelope_incomplete")
        )

        let invalidBase64 = credential(
            algorithm: RemoteUnlockPolicy.credentialEnvelopeAlgorithm,
            redactedByteCount: 12,
            ciphertextBase64: "not-base64!!!",
            aadBase64: "YWFk",
            expiresAt: now.addingTimeInterval(30)
        )
        XCTAssertEqual(
            policy.validate(credential: invalidBase64, sessionId: "unlock-session", now: now),
            .denied("credential_envelope_invalid_base64")
        )

        let valid = credential(
            algorithm: RemoteUnlockPolicy.credentialEnvelopeAlgorithm,
            redactedByteCount: 12,
            ciphertextBase64: "Y2lwaGVy",
            aadBase64: "YWFk",
            expiresAt: now.addingTimeInterval(30)
        )
        XCTAssertEqual(
            policy.validate(credential: valid, sessionId: "unlock-session", now: now),
            .allowed
        )
    }

    func test_credentialEnvelopeCryptoRoundTripsAndBindsMetadata() throws {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientPublicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let requestId = "cred-req"
        let sessionId = "unlock-session"
        let clientIntentId = "client-intent"
        let sealed = try RemoteUnlockCredentialEnvelopeCrypto.seal(
            credential: "correct horse battery staple",
            requestId: requestId,
            sessionId: sessionId,
            clientIntentId: clientIntentId,
            credentialKind: .typedPassword,
            recipientKeyId: "mac-key",
            recipientPublicKeyBase64: recipientPublicKeyBase64
        )
        let envelope = HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
            requestId: requestId,
            sessionId: sessionId,
            clientIntentId: clientIntentId,
            credentialKind: .typedPassword,
            recipientKeyId: "mac-key",
            algorithm: RemoteUnlockCredentialEnvelopeCrypto.algorithm,
            ciphertextBase64: sealed.ciphertextBase64,
            aadBase64: sealed.aadBase64,
            redactedByteCount: sealed.redactedByteCount,
            requestedAt: Date(timeIntervalSince1970: 1_774_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_774_000_030),
            authority: authority()
        )

        XCTAssertEqual(
            try RemoteUnlockCredentialEnvelopeCrypto.open(envelope: envelope, recipientPrivateKey: privateKey),
            "correct horse battery staple"
        )

        var tampered = envelope
        tampered.clientIntentId = "different-intent"
        XCTAssertThrowsError(
            try RemoteUnlockCredentialEnvelopeCrypto.open(envelope: tampered, recipientPrivateKey: privateKey)
        )
    }

    func test_certificationReportRequiresFreshMachineBoundHardwareProof() {
        let now = Date(timeIntervalSince1970: 1_774_000_000)
        let publicKey = Data(repeating: 0xA7, count: 32).base64EncodedString()
        var report = RemoteUnlockCertificationReport.certifiedHardware(
            currentOSBuild: "24F74",
            credentialRecipientKeyId: "hpke-0123456789abcdef01234567",
            credentialRecipientPublicKeyBase64: publicKey,
            fileVaultSSHSupported: false,
            generatedAt: now
        )

        XCTAssertEqual(
            report.validationBlockers(
                now: now.addingTimeInterval(60),
                currentOSBuild: "24F74",
                credentialRecipientKeyId: "hpke-0123456789abcdef01234567",
                credentialRecipientPublicKeyBase64: publicKey,
                directDownloadBuild: true,
                daemonInstalled: true,
                systemScreenSharingAvailable: true
            ),
            []
        )

        report.currentOSBuild = "24F75"
        report.evidence.operatorConfirmedHardware = false
        let blockers = report.validationBlockers(
            now: now.addingTimeInterval(60),
            currentOSBuild: "24F74",
            credentialRecipientKeyId: "hpke-0123456789abcdef01234567",
            credentialRecipientPublicKeyBase64: publicKey,
            directDownloadBuild: true,
            daemonInstalled: true,
            systemScreenSharingAvailable: true
        )
        XCTAssertTrue(blockers.contains("os_build_changed_recertification_required"))
        XCTAssertTrue(blockers.contains("hardware_operator_confirmation_missing"))
    }

    func test_certificationReportStoreRoundTripsReadableProofJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-remote-unlock-\(UUID().uuidString)", isDirectory: true)
        let store = RemoteUnlockCertificationReportStore(
            fileURL: directory.appendingPathComponent("proof.json")
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = RemoteUnlockCertificationReport.certifiedHardware(
            currentOSBuild: "24F74",
            credentialRecipientKeyId: "hpke-0123456789abcdef01234567",
            credentialRecipientPublicKeyBase64: Data(repeating: 0x5A, count: 32).base64EncodedString(),
            fileVaultSSHSupported: true,
            generatedAt: Date(timeIntervalSince1970: 1_774_000_000),
            redactedViewerDeviceKind: "ipad",
            notes: "Operator-confirmed smoke."
        )

        try store.save(report)
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"schemaVersion\""))
        XCTAssertTrue(raw.contains("\"operatorConfirmedHardware\""))
        XCTAssertEqual(try store.load(), report)
    }

    private func certifiedSnapshot() -> RemoteUnlockReadinessSnapshot {
        RemoteUnlockReadinessSnapshot(
            featureFlagEnabled: true,
            directDownloadBuild: true,
            daemonInstalled: true,
            systemScreenSharingAvailable: true,
            loopbackOnlyFirewallActive: true,
            generatedCredentialInSystemKeychain: true,
            backendCertificationFresh: true,
            currentOSBuild: "23G93",
            certifiedOSBuild: "23G93",
            certifiedAt: Date(timeIntervalSince1970: 1_774_000_000),
            fileVaultEnabled: true,
            fileVaultSSHSupported: false,
            lastLockScreenProbeSucceeded: true,
            lastCredentialInputProbeSucceeded: true,
            lastUnlockProbeSucceeded: true,
            credentialRecipientKeyId: "mac-remote-unlock-key",
            credentialRecipientPublicKeyBase64: "cHVibGljLWtleQ=="
        )
    }

    private func remoteUnlockSession(
        sessionId: String? = "unlock-session",
        localAuthenticationSatisfied: Bool,
        requestedBackend: HermesRealtimeRelayRemoteUnlockBackend?,
        requestedAt: Date = Date(timeIntervalSince1970: 1_774_000_000),
        expiresAt: Date
    ) -> HermesRealtimeRelayRemoteUnlockSession {
        HermesRealtimeRelayRemoteUnlockSession(
            requestId: "unlock-req",
            sessionId: sessionId,
            intent: .request,
            requesterDisplayName: "iPhone",
            viewerDeviceId: "ios-1",
            requestedAt: requestedAt,
            expiresAt: expiresAt,
            localAuthenticationSatisfied: localAuthenticationSatisfied,
            requestedLockState: .loginWindow,
            requestedBackend: requestedBackend,
            authority: authority()
        )
    }

    private func credential(
        algorithm: String,
        redactedByteCount: Int,
        ciphertextBase64: String,
        aadBase64: String,
        recipientKeyId: String = "mac-key",
        requestedAt: Date = Date(timeIntervalSince1970: 1_774_000_000),
        expiresAt: Date
    ) -> HermesRealtimeRelayRemoteUnlockCredentialEnvelope {
        HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
            requestId: "cred-req",
            sessionId: "unlock-session",
            clientIntentId: "client-intent",
            credentialKind: .clipboardPassword,
            recipientKeyId: recipientKeyId,
            algorithm: algorithm,
            ciphertextBase64: ciphertextBase64,
            aadBase64: aadBase64,
            redactedByteCount: redactedByteCount,
            requestedAt: requestedAt,
            expiresAt: expiresAt,
            authority: authority()
        )
    }

    private func authority() -> HermesRealtimeRelayAuthorityEnvelope {
        HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "ios-node",
            counter: 1,
            timestamp: Date(timeIntervalSince1970: 1_774_000_000),
            intentHashBlake3: "hash",
            signatureEd25519: "signature"
        )
    }
}
