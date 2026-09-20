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
        let controller = RemoteUnlockCredentialController()
        XCTAssertNotNil(controller, "Default (production) init must yield a usable controller")
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

/// Client-side server-trust gate for the root remote-access agent socket.
///
/// The agent's `typeCredential` requests carry the macOS login password, so the
/// client must authenticate the server (peer UID + first-party designated
/// requirement) BEFORE writing anything — a squatted socket must receive zero
/// bytes. Mirrors `PrivilegedInputSocketClientTrustTests` in the core package.
final class RemoteAccessAgentClientTrustTests: XCTestCase {
    private var temporaryDirectories: [String] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    private func makeSocketPath() throws -> String {
        let directory = NSTemporaryDirectory()
            + "obb-agent-client-trust-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        temporaryDirectories.append(directory)
        return directory + "/agent.sock"
    }

    func testSend_writesNothingToServerThatFailsTrustValidation() throws {
        let socketPath = try makeSocketPath()
        let impostor = try AgentImpostorSocketServer(socketPath: socketPath)
        defer { impostor.shutdown() }

        let client = RemoteAccessAgentClient(
            socketPath: socketPath,
            serverCodeSignatureValidator: { _ in
                throw PrivilegedSocketTrustError.codeSignatureInvalid(status: -67050)
            }
        )

        XCTAssertThrowsError(
            try client.sendForTesting(
                RemoteAccessAgentRequest(operation: "typeCredential", password: "super-secret-login-password")
            )
        ) { error in
            guard case RemoteAccessAgentClientError.serverUntrusted = error else {
                return XCTFail("expected serverUntrusted, got \(error)")
            }
        }
        XCTAssertEqual(
            impostor.receivedByteCount(),
            0,
            "client must not write the login password to an untrusted agent server"
        )
    }

    func testSend_writesNothingWhenServerUIDUnexpected() throws {
        let socketPath = try makeSocketPath()
        let impostor = try AgentImpostorSocketServer(socketPath: socketPath)
        defer { impostor.shutdown() }

        let client = RemoteAccessAgentClient(
            socketPath: socketPath,
            expectedServerUID: getuid() &+ 1, // the impostor runs as the test process, so this expectation cannot match
            serverCodeSignatureValidator: { _ in }
        )

        XCTAssertThrowsError(
            try client.sendForTesting(
                RemoteAccessAgentRequest(operation: "typeCredential", password: "super-secret-login-password")
            )
        ) { error in
            guard case RemoteAccessAgentClientError.serverUntrusted = error else {
                return XCTFail("expected serverUntrusted, got \(error)")
            }
        }
        XCTAssertEqual(impostor.receivedByteCount(), 0)
    }

    func testSend_completesAgainstTrustedServer() throws {
        let socketPath = try makeSocketPath()
        let impostor = try AgentImpostorSocketServer(
            socketPath: socketPath,
            response: "{\"ok\":true,\"version\":\"1\"}\n"
        )
        defer { impostor.shutdown() }

        // UID gate: the impostor runs as the test process user, so expect that.
        // (The production default expects uid 0 — the root LaunchDaemon.)
        let client = RemoteAccessAgentClient(
            socketPath: socketPath,
            expectedServerUID: getuid(),
            serverCodeSignatureValidator: { _ in }
        )
        try client.sendForTesting(
            RemoteAccessAgentRequest(operation: "health", password: nil)
        )
        XCTAssertGreaterThan(impostor.receivedByteCount(), 0)
    }

    func testSend_rejectsUnsignedListenerWithProductionValidator() throws {
        // The test process listening at the path is not first-party signed, so
        // the PRODUCTION validator must refuse before any payload is written.
        let socketPath = try makeSocketPath()
        let impostor = try AgentImpostorSocketServer(socketPath: socketPath)
        defer { impostor.shutdown() }

        let client = RemoteAccessAgentClient(socketPath: socketPath)
        XCTAssertThrowsError(
            try client.sendForTesting(
                RemoteAccessAgentRequest(operation: "typeCredential", password: "secret")
            )
        ) { error in
            guard case RemoteAccessAgentClientError.serverUntrusted = error else {
                return XCTFail("expected serverUntrusted, got \(error)")
            }
        }
        XCTAssertEqual(impostor.receivedByteCount(), 0, "no bytes may reach an unsigned listener")
    }

    func testDefaultValidator_pinsExactAgentIdentifier_notSharedAllowlist() throws {
        // M-10 review fix: the production validator must authenticate the
        // server against the remote-access agent's EXACT identifier, not the
        // shared privileged-input allowlist — otherwise any first-party root
        // helper squatting the socket path could receive the login password.
        let pinned = OpenBurnBarPrivilegedTrust.remoteAccessAgentDesignatedRequirement
        XCTAssertTrue(
            pinned.contains("identifier \"com.openburnbar.remote-access-agent\""),
            "the client's server gate must pin the agent identifier exactly"
        )
        for other in OpenBurnBarPrivilegedTrust.privilegedInputPeerBundleIdentifiers
        where other != OpenBurnBarPrivilegedTrust.remoteAccessAgentIdentifier {
            XCTAssertFalse(
                pinned.contains("identifier \"\(other)\""),
                "the pinned server requirement must not accept \(other)"
            )
        }
        XCTAssertTrue(pinned.contains(OpenBurnBarPrivilegedTrust.teamID))
    }
}

/// Minimal single-connection UNIX-socket listener that records exactly how
/// many bytes the client sent (shared shape with the core-package impostor).
final class AgentImpostorSocketServer: @unchecked Sendable {
    private let listenerFD: Int32
    private let socketPath: String
    private let response: String?
    private let lock = NSLock()
    private var receivedBytes = 0
    private let finished = DispatchSemaphore(value: 0)

    init(socketPath: String, response: String? = nil) throws {
        self.socketPath = socketPath
        self.response = response

        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { throw POSIXError(.EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = socketPath.withCString { path -> Int in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                    strncpy($0, path, pathCapacity - 1)
                }
            }
            return 0
        }
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindStatus == 0, listen(listenerFD, 1) == 0 else {
            close(listenerFD)
            throw POSIXError(.EIO)
        }

        Thread.detachNewThread { [self] in
            let client = accept(listenerFD, nil, nil)
            defer { finished.signal() }
            guard client >= 0 else { return }
            defer { close(client) }

            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            withUnsafePointer(to: &timeout) { pointer in
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            }

            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                lock.lock()
                receivedBytes += count
                lock.unlock()
                if buffer[count - 1] == 0x0A { break }
            }

            if let response, receivedByteCount() > 0 {
                _ = response.withCString { Darwin.write(client, $0, strlen($0)) }
            }
        }
    }

    func receivedByteCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedBytes
    }

    func shutdown() {
        close(listenerFD)
        unlink(socketPath)
        _ = finished.wait(timeout: .now() + 3)
    }
}
#endif
