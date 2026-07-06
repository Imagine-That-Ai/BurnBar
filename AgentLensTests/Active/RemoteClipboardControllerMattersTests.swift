#if canImport(AppKit) && !DISTRIBUTION_MAS
import CryptoKit
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// Remote Unlock certification is recorded against the HPKE recipient key material
/// (`credentialRecipientKeyId` / `credentialRecipientPublicKeyBase64`). The read/create of
/// that material used to be a `try?` that silently swallowed keychain faults — which would
/// either skip certification with no signal or, worse, risk recording a half-formed
/// certification. These tests pin the security-correct behavior of the replacement helper:
/// on a key-material fault we fail closed (return nil → no certification recorded) and the
/// loss is observable, while a healthy store still yields the material to certify with.
@MainActor
final class RemoteClipboardControllerMattersTests: XCTestCase {
    private let phoneSigner = ComputerUsePhoneControlSigner()
    private var temporaryFiles: [URL] = []
    private var temporaryDefaultsSuites: [String] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        for suite in temporaryDefaultsSuites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        temporaryFiles.removeAll()
        temporaryDefaultsSuites.removeAll()
        super.tearDown()
    }

    // MARK: - Fakes

    private struct FaultingKeyStore: RemoteUnlockCredentialKeyProviding {
        struct Boom: Error {}

        func copyPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
            throw Boom()
        }

        func copyOrCreateKeyMaterial() throws -> RemoteUnlockCredentialKeyMaterial {
            throw Boom()
        }
    }

    private struct HealthyKeyStore: RemoteUnlockCredentialKeyProviding {
        let material: RemoteUnlockCredentialKeyMaterial

        func copyPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
            material.privateKey
        }

        func copyOrCreateKeyMaterial() throws -> RemoteUnlockCredentialKeyMaterial {
            material
        }
    }

    private func makeMaterial() -> RemoteUnlockCredentialKeyMaterial {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let keyId = SHA256.hash(data: publicKeyData)
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return RemoteUnlockCredentialKeyMaterial(
            keyId: "hpke-\(keyId)",
            publicKeyBase64: publicKeyData.base64EncodedString(),
            privateKey: privateKey
        )
    }

    // MARK: - Tests

    /// A keychain / key-material fault must fail closed: the helper returns nil so the caller
    /// skips `recordCertification` entirely rather than advertising a missing/empty recipient
    /// key (which would silently break later credential opens). The previous `try?` made this
    /// failure indistinguishable from "no key material" and unobservable.
    func testKeyMaterialFaultFailsClosedAndDoesNotCertify() {
        let controller = RemoteUnlockCredentialController(
            keyStore: FaultingKeyStore()
        )

        let material = controller.certificationKeyMaterial(requestId: "req-fault")

        XCTAssertNil(
            material,
            "A key-material fault must fail closed (nil) so no half-formed certification is recorded."
        )
    }

    /// A healthy key store must still surface fully-formed recipient key material so the caller
    /// can record a real certification — the fix must not regress the happy path.
    func testHealthyKeyStoreYieldsFullyFormedMaterial() throws {
        let expected = makeMaterial()
        let controller = RemoteUnlockCredentialController(
            keyStore: HealthyKeyStore(material: expected)
        )

        let material = try XCTUnwrap(
            controller.certificationKeyMaterial(requestId: "req-ok"),
            "A healthy key store must yield certification material."
        )

        XCTAssertEqual(material.keyId, expected.keyId)
        XCTAssertEqual(material.publicKeyBase64, expected.publicKeyBase64)
        XCTAssertFalse(
            material.keyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Recipient key id must be non-empty so recordCertification does not fail closed downstream."
        )
        XCTAssertFalse(
            material.publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Recipient public key must be non-empty so recordCertification does not fail closed downstream."
        )
    }

    /// The default (production) construction path must keep compiling against the real
    /// `RemoteUnlockCredentialKeyStore` seam — guards the injectable-init signature.
    func testDefaultControllerConstructs_smokeNoCrash() {
        // Smoke test by intent: construction wires private framework-backed
        // clipboard dependencies and only exposes success by not trapping.
        _ = RemoteUnlockCredentialController()
    }

    func testRemoteUnlockCredentialRequiresActiveSessionAttestationBeforeDecrypting() async throws {
        let now = Date()
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        XCTAssertTrue(validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey))
        let readiness = makeRemoteUnlockReadinessService()
        readiness.recordRemoteUnlockSession(
            remoteUnlockSession(
                sessionId: "remote-unlock-session",
                peerNodeId: "peer-1",
                viewerDeviceId: "iphone-1",
                attestationHashBlake3: "session-attestation",
                now: now
            ),
            now: now
        )
        let credential = try signedRemoteUnlockCredential(
            privateKey: privateKey,
            attestationHashBlake3: "wrong-attestation",
            now: now
        )
        let controller = RemoteUnlockCredentialController(keyStore: FaultingKeyStore())

        let response = await controller.handle(
            credential: credential,
            context: RemoteUnlockCredentialController.RuntimeContext(
                validator: validator,
                activeSessionId: ComputerUseSessionID("computer-use-session"),
                state: makeSessionState(phoneViewerNodeId: "peer-1", now: now),
                isDirectPhoneControl: true,
                authorizedPeerNodeId: "peer-1",
                attestation: .none,
                readiness: readiness
            )
        )

        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(response.detail, "attestation_mismatch")
    }

    func testRemoteUnlockCredentialPreservesStrictUnboundHostRejection() async throws {
        let now = Date()
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = makeValidator()
        XCTAssertTrue(validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey))
        let readiness = makeRemoteUnlockReadinessService()
        readiness.recordRemoteUnlockSession(
            remoteUnlockSession(
                sessionId: "remote-unlock-session",
                peerNodeId: "peer-1",
                viewerDeviceId: "iphone-1",
                attestationHashBlake3: "session-attestation",
                now: now
            ),
            now: now
        )
        let credential = try signedRemoteUnlockCredential(
            privateKey: privateKey,
            attestationHashBlake3: "session-attestation",
            now: now
        )
        let controller = RemoteUnlockCredentialController(keyStore: FaultingKeyStore())

        let response = await controller.handle(
            credential: credential,
            context: RemoteUnlockCredentialController.RuntimeContext(
                validator: validator,
                activeSessionId: ComputerUseSessionID("computer-use-session"),
                state: makeSessionState(phoneViewerNodeId: "peer-1", now: now),
                isDirectPhoneControl: true,
                authorizedPeerNodeId: "peer-1",
                attestation: .rejectUnboundHost,
                readiness: readiness
            )
        )

        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(response.detail, "mac_attestation_unbound")
    }

    // MARK: - Helpers

    private func temporaryFileURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-\(name)-\(UUID().uuidString).json")
        temporaryFiles.append(url)
        return url
    }

    private func makeValidator() -> PhoneControlAuthorityValidator {
        PhoneControlAuthorityValidator(
            controllerPinStore: nil,
            replayCounterStore: PhoneControlReplayCounterStore(fileURL: temporaryFileURL("remote-unlock-replay")),
            consumedProofStore: PhoneControlConsumedProofStore(fileURL: temporaryFileURL("remote-unlock-proofs"))
        )
    }

    private func makeRemoteUnlockReadinessService() -> MacRemoteUnlockReadinessService {
        let defaultsSuite = "RemoteClipboardControllerMattersTests-\(UUID().uuidString)"
        temporaryDefaultsSuites.append(defaultsSuite)
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        let material = makeMaterial()
        return MacRemoteUnlockReadinessService(
            defaults: defaults,
            snapshotProvider: {
                RemoteUnlockReadinessSnapshot(
                    featureFlagEnabled: true,
                    directDownloadBuild: true,
                    daemonInstalled: true,
                    systemScreenSharingAvailable: true,
                    loopbackOnlyFirewallActive: true,
                    generatedCredentialInSystemKeychain: true,
                    remoteDesktopPermissionGranted: true,
                    virtualHIDDriverInstalled: true,
                    virtualHIDDriverActive: true,
                    backendCertificationFresh: true,
                    currentOSBuild: "test-os-build",
                    certifiedOSBuild: "test-os-build",
                    certifiedAt: Date(),
                    fileVaultEnabled: false,
                    fileVaultSSHSupported: false,
                    lastLockScreenProbeSucceeded: true,
                    lastCredentialInputProbeSucceeded: true,
                    lastUnlockProbeSucceeded: true,
                    credentialRecipientKeyId: "recipient-key",
                    credentialRecipientPublicKeyBase64: material.publicKeyBase64
                )
            },
            revokesPublishedTrustOnClearAll: false,
            credentialKeyMaterialProvider: { material },
            issuerTrustPublisher: {},
            publishedTrustRevoker: {},
            lockStateProvider: { .loginWindow }
        )
    }

    private func makeSessionState(
        phoneViewerNodeId: String,
        now: Date
    ) -> ComputerUseSessionState {
        let sessionId = ComputerUseSessionID("computer-use-session")
        let manifest = ComputerUseSessionManifest(
            sessionId: sessionId,
            mode: .system,
            trustMode: .manual,
            startedAt: now,
            userId: "uid-remote-unlock",
            macHostNodeId: "mac-1",
            phoneViewerNodeId: phoneViewerNodeId,
            entitlementProductId: "hosted_computer_use_sync",
            actionCap: 10,
            sessionTimeoutSeconds: 300
        )
        return ComputerUseSessionState(
            sessionId: sessionId,
            manifest: manifest,
            liveTrustMode: .manual
        )
    }

    private func remoteUnlockSession(
        sessionId: String,
        peerNodeId: String,
        viewerDeviceId: String,
        attestationHashBlake3: String,
        now: Date
    ) -> HermesRealtimeRelayRemoteUnlockSession {
        HermesRealtimeRelayRemoteUnlockSession(
            requestId: "remote-unlock-request",
            sessionId: sessionId,
            intent: .request,
            requesterDisplayName: "Alberto's iPhone",
            viewerDeviceId: viewerDeviceId,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(RemoteUnlockPolicy.default.sessionTTLSeconds),
            localAuthenticationSatisfied: true,
            requestedBackend: .openBurnBarVirtualHID,
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: peerNodeId,
                counter: 1,
                timestamp: now,
                intentHashBlake3: "session-hash",
                signatureEd25519: "session-signature",
                attestationHashBlake3: attestationHashBlake3
            )
        )
    }

    private func signedRemoteUnlockCredential(
        privateKey: Curve25519.Signing.PrivateKey,
        attestationHashBlake3: String,
        now: Date
    ) throws -> HermesRealtimeRelayRemoteUnlockCredentialEnvelope {
        var credential = HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
            requestId: "credential-request",
            sessionId: "remote-unlock-session",
            clientIntentId: "credential-intent",
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
                attestationHashBlake3: attestationHashBlake3
            )
        )
        let signed = try phoneSigner.sign(
            remoteUnlockCredential: credential,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: now,
            privateKey: privateKey
        )
        credential.authority.intentHashBlake3 = signed.intentHashHex
        credential.authority.signatureEd25519 = signed.signatureBase64
        return credential
    }
}
#endif
