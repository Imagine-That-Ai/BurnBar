import CryptoKit
import Darwin
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
@testable import OpenBurnBarDaemon
import XCTest

/// T-DMN-04 — the daemon's INDEPENDENT local-auth-proof verifier is WIRED into
/// the high-risk computer-use RPC path (`computerUseSessionStart` /
/// `computerUseInvoke`) and fails CLOSED.
///
/// These exercise the production dispatch (real Unix socket → `responseData` →
/// `handleComputerUseRPC` → `enforceLocalAuthProof`). They assert the gate's
/// behavior, not the downstream session machinery: a request that survives the
/// gate is distinguished from one the gate refuses by the absence of the
/// proof-specific `unauthorized` error.
final class BurnBarDaemonComputerUseLocalAuthProofWiringTests: XCTestCase {
    private let deviceId = "device-abc"
    private let intentHash = String(repeating: "a", count: 64)

    // MARK: - Helpers

    private func makeSocketPath(name: String) -> String {
        "/tmp/openburnbar-daemon-tests-cu-proof-\(name)-\(UUID().uuidString).sock"
    }

    private func makeProof(
        privateKey: Curve25519.Signing.PrivateKey,
        proofId: String = UUID().uuidString,
        deviceId: String,
        intentHash: String,
        authenticatedAt: Date,
        expiresAt: Date
    ) throws -> HermesRealtimeRelayAgentGrantLocalAuthProof {
        try ComputerUsePhoneControlSigner().signLocalAuthProof(
            proofId: proofId,
            deviceId: deviceId,
            signedIntentHash: intentHash,
            authenticatedAt: authenticatedAt,
            expiresAt: expiresAt,
            privateKey: privateKey
        )
    }

    private func makeServer(
        socketPath: String,
        verifier: DaemonLocalAuthProofVerifier?,
        pinStore: DaemonPhoneKeyPinStore? = nil
    ) -> BurnBarDaemonServer {
        BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "cu-proof-wiring-tests"),
            localAuthProofVerifier: verifier,
            phoneControlPinStore: pinStore
        )
    }

    private func sessionStartRequest(
        proof: HermesRealtimeRelayAgentGrantLocalAuthProof?,
        sourceDeviceId: String?,
        intentHashHex: String?,
        id: String
    ) -> BurnBarRPCRequestEnvelopeWithParams<ComputerUseSessionStartRequest> {
        BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: .computerUseSessionStart,
            authToken: "test-token",
            params: ComputerUseSessionStartRequest(
                mode: "browser",
                trustMode: "untrusted",
                clientID: BurnBarClientID(rawValue: "test-client"),
                localAuthProof: proof,
                sourceDeviceId: sourceDeviceId,
                intentHashHex: intentHashHex
            )
        )
    }

    private func invokeRequest(
        sessionId: String,
        id: String
    ) -> BurnBarRPCRequestEnvelopeWithParams<ComputerUseInvokeRequest> {
        BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: .computerUseInvoke,
            authToken: "test-token",
            params: ComputerUseInvokeRequest(
                sessionId: sessionId,
                invocation: BurnBarToolInvocation(
                    callID: "call-\(id)",
                    runID: BurnBarRunID(rawValue: "run-\(id)"),
                    tool: .browserScreenshot,
                    arguments: .object([:]),
                    requestedBy: BurnBarClientID(rawValue: "test-client"),
                    requestedAt: Date()
                )
            )
        )
    }

    private func pinProvisionRequest(
        deviceId: String,
        publicKeyBase64: String,
        keyKind: PhoneControlSigningKeyKind = .ed25519,
        id: String
    ) -> BurnBarRPCRequestEnvelopeWithParams<DaemonPhoneControlPinProvisionRequest> {
        BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: .phoneControlPinProvision,
            authToken: "test-token",
            params: DaemonPhoneControlPinProvisionRequest(
                deviceId: deviceId,
                publicKeyBase64: publicKeyBase64,
                keyKind: keyKind
            )
        )
    }

    /// `unauthorized` (-32001) is the code `enforceLocalAuthProof` returns when it
    /// refuses a request. Any OTHER outcome means the request passed the proof gate.
    private func isProofRefusal(_ error: BurnBarRPCError?) -> Bool {
        error?.code == -32001
    }

    // MARK: - Tests

    func test_enforcedDaemon_refusesSessionStartWithNoProof() async throws {
        let socketPath = makeSocketPath(name: "no-proof")
        let key = Curve25519.Signing.PrivateKey()
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { [deviceId] in $0 == deviceId ? .ed25519(key.publicKey) : nil },
            consumeProof: { _, _ in true }
        )
        let server = makeServer(socketPath: socketPath, verifier: verifier)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(proof: nil, sourceDeviceId: nil, intentHashHex: nil, id: "no-proof"),
            socketPath: socketPath
        )
        XCTAssertNil(response.result)
        XCTAssertTrue(isProofRefusal(response.error), "missing proof must fail closed with unauthorized")
    }

    func test_enforcedDaemon_refusesForgedProof_appCompromise() async throws {
        // App compromise: a proof signed by an attacker key, but the daemon pins
        // the REAL phone key. Must fail closed even though the app forwarded it.
        let socketPath = makeSocketPath(name: "forged")
        let realKey = Curve25519.Signing.PrivateKey()
        let attackerKey = Curve25519.Signing.PrivateKey()
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { [deviceId] in $0 == deviceId ? .ed25519(realKey.publicKey) : nil },
            consumeProof: { _, _ in true }
        )
        let server = makeServer(socketPath: socketPath, verifier: verifier)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let now = Date()
        let forged = try makeProof(
            privateKey: attackerKey,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(proof: forged, sourceDeviceId: deviceId, intentHashHex: intentHash, id: "forged"),
            socketPath: socketPath
        )
        XCTAssertNil(response.result)
        XCTAssertTrue(isProofRefusal(response.error), "forged signature must fail closed")
    }

    func test_enforcedDaemon_refusesProofRetargetedToDifferentIntent() async throws {
        let socketPath = makeSocketPath(name: "wrong-intent")
        let key = Curve25519.Signing.PrivateKey()
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { [deviceId] in $0 == deviceId ? .ed25519(key.publicKey) : nil },
            consumeProof: { _, _ in true }
        )
        let server = makeServer(socketPath: socketPath, verifier: verifier)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let now = Date()
        // Proof minted for a DIFFERENT op hash than the one the request declares.
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: String(repeating: "b", count: 64),
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(proof: proof, sourceDeviceId: deviceId, intentHashHex: intentHash, id: "wrong-intent"),
            socketPath: socketPath
        )
        XCTAssertNil(response.result)
        XCTAssertTrue(isProofRefusal(response.error), "intent-retargeted proof must fail closed")
    }

    func test_enforcedDaemon_refusesWhenNoKeyIsPinnedForDevice() async throws {
        let socketPath = makeSocketPath(name: "no-pin")
        let key = Curve25519.Signing.PrivateKey()
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { _ in nil }, // nothing pinned
            consumeProof: { _, _ in true }
        )
        let server = makeServer(socketPath: socketPath, verifier: verifier)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let now = Date()
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(proof: proof, sourceDeviceId: deviceId, intentHashHex: intentHash, id: "no-pin"),
            socketPath: socketPath
        )
        XCTAssertNil(response.result)
        XCTAssertTrue(isProofRefusal(response.error), "no pinned key must fail closed")
    }

    func test_enforcedDaemon_validProofPassesTheProofGate() async throws {
        // A valid, pinned-key-signed, op-bound proof must NOT be refused by the
        // proof gate. (Downstream session start may still fail for unrelated
        // reasons in a headless test env; we assert only that the outcome is NOT
        // the proof-specific unauthorized refusal.)
        let socketPath = makeSocketPath(name: "valid")
        let key = Curve25519.Signing.PrivateKey()
        let ledger = DaemonConsumedLocalAuthProofLedger()
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { [deviceId] in $0 == deviceId ? .ed25519(key.publicKey) : nil },
            consumeProof: { proofId, expiresAt in ledger.consume(proofId: proofId, expiresAt: expiresAt) }
        )
        let server = makeServer(socketPath: socketPath, verifier: verifier)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let now = Date()
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(proof: proof, sourceDeviceId: deviceId, intentHashHex: intentHash, id: "valid"),
            socketPath: socketPath
        )
        XCTAssertFalse(
            isProofRefusal(response.error),
            "a valid pinned-key proof must pass the proof gate (error: \(String(describing: response.error)))"
        )
    }

    func test_enforcedDaemon_refusesInvokeWithoutVerifiedSession() async throws {
        let socketPath = makeSocketPath(name: "invoke-no-session")
        let key = Curve25519.Signing.PrivateKey()
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { [deviceId] in $0 == deviceId ? .ed25519(key.publicKey) : nil },
            consumeProof: { _, _ in true }
        )
        let server = makeServer(socketPath: socketPath, verifier: verifier)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<ComputerUseInvokeResponse> = try sendEnvelope(
            invokeRequest(sessionId: "unverified-session", id: "invoke-no-session"),
            socketPath: socketPath
        )
        XCTAssertNil(response.result)
        XCTAssertTrue(isProofRefusal(response.error), "invoke must fail closed unless session start was proof-verified")
    }

    func test_enforcedDaemon_allowsInvokeForVerifiedSessionWithoutReplayingProof() async throws {
        // The local-auth proof is single-use. A verified session start records a
        // bounded daemon session authorization, and subsequent invokes must not
        // try to replay the same proof for every tool call.
        let socketPath = makeSocketPath(name: "invoke-ok")
        let key = Curve25519.Signing.PrivateKey()
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { [deviceId] in $0 == deviceId ? .ed25519(key.publicKey) : nil },
            consumeProof: { _, _ in true }
        )
        let server = makeServer(socketPath: socketPath, verifier: verifier)
        try await server.start()
        addTeardownBlock { await server.stop() }
        await server.rememberLocalAuthVerifiedSession(
            sessionId: "verified-session",
            requestedTimeoutSeconds: 1800
        )

        let response: BurnBarRPCResponseEnvelope<ComputerUseInvokeResponse> = try sendEnvelope(
            invokeRequest(sessionId: "verified-session", id: "invoke-verified-session"),
            socketPath: socketPath
        )
        XCTAssertFalse(
            isProofRefusal(response.error),
            "a proof-verified session may invoke without replaying the single-use proof (error: \(String(describing: response.error)))"
        )
    }

    func test_phoneControlPinProvision_persistsPinnedKeyForDaemonResolver() async throws {
        let socketPath = makeSocketPath(name: "pin-ok")
        let privateKey = Curve25519.Signing.PrivateKey()
        let pinStore = DaemonPhoneKeyPinStore(backing: DaemonPhoneKeyInMemoryPinBacking())
        let server = makeServer(socketPath: socketPath, verifier: nil, pinStore: pinStore)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<DaemonPhoneControlPinProvisionResponse> = try sendEnvelope(
            pinProvisionRequest(
                deviceId: deviceId,
                publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
                id: "pin-ok"
            ),
            socketPath: socketPath
        )

        XCTAssertEqual(response.result?.pinned, true)
        guard case .pinned(let resolved) = pinStore.pinnedKey(deviceId: deviceId) else {
            XCTFail("expected key to be pinned")
            return
        }
        XCTAssertEqual(resolved.publicKeyRepresentation, privateKey.publicKey.rawRepresentation)
    }

    func test_phoneControlPinProvision_rejectsMalformedPublicKey() async throws {
        let socketPath = makeSocketPath(name: "pin-bad")
        let pinStore = DaemonPhoneKeyPinStore(backing: DaemonPhoneKeyInMemoryPinBacking())
        let server = makeServer(socketPath: socketPath, verifier: nil, pinStore: pinStore)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<DaemonPhoneControlPinProvisionResponse> = try sendEnvelope(
            pinProvisionRequest(
                deviceId: deviceId,
                publicKeyBase64: "not-base64",
                id: "pin-bad"
            ),
            socketPath: socketPath
        )

        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.invalidParams)
    }

    func test_provisionedPin_enablesEndToEndProofVerification() async throws {
        // T-DMN-04 full loop: provision the daemon's pinned phone key via RPC,
        // then send a session-start request carrying a proof signed by that key.
        // The daemon must resolve the pinned key independently and verify the proof.
        let socketPath = makeSocketPath(name: "provision-then-verify")
        let privateKey = Curve25519.Signing.PrivateKey()
        let pinStore = DaemonPhoneKeyPinStore(backing: DaemonPhoneKeyInMemoryPinBacking())
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { requestedDeviceId in
                if case .pinned(let key) = pinStore.pinnedKey(deviceId: requestedDeviceId) {
                    return key
                }
                return nil
            },
            consumeProof: { _, _ in true }
        )
        let server = makeServer(socketPath: socketPath, verifier: verifier, pinStore: pinStore)
        try await server.start()
        addTeardownBlock { await server.stop() }

        // 1. Provision the pinned key.
        let provision: BurnBarRPCResponseEnvelope<DaemonPhoneControlPinProvisionResponse> = try sendEnvelope(
            pinProvisionRequest(
                deviceId: deviceId,
                publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
                id: "provision"
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(provision.result?.pinned, true)

        // 2. Send a proof-bound session-start request.
        let now = Date()
        let proof = try makeProof(
            privateKey: privateKey,
            deviceId: deviceId,
            intentHash: intentHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(proof: proof, sourceDeviceId: deviceId, intentHashHex: intentHash, id: "verify"),
            socketPath: socketPath
        )
        XCTAssertFalse(
            isProofRefusal(response.error),
            "a provisioned pinned key must enable end-to-end proof verification (error: \(String(describing: response.error)))"
        )
    }

    func test_unenforcedDaemon_doesNotRequireProof() async throws {
        // Backward-compatible default: when no verifier is wired, the high-risk
        // method is NOT refused for lacking a proof (it may proceed/fail on its
        // own merits but never on a proof gate).
        let socketPath = makeSocketPath(name: "unenforced")
        let server = makeServer(socketPath: socketPath, verifier: nil)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(proof: nil, sourceDeviceId: nil, intentHashHex: nil, id: "unenforced"),
            socketPath: socketPath
        )
        XCTAssertFalse(isProofRefusal(response.error), "unenforced daemon must not raise the proof gate")
    }

    // MARK: - Socket round-trip (mirrors BurnBarDaemonServerTests)

    private func sendEnvelope<Envelope: Encodable, Response: Decodable>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertNotEqual(fileDescriptor, -1)

        var noSigPipe: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = try socketAddress(for: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connectResult == 0 else {
            let code = errno
            close(fileDescriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        let payload = try JSONEncoder().encode(envelope) + Data([0x0A])
        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let bytesWritten = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                XCTAssertGreaterThan(bytesWritten, 0)
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 { break }
            XCTAssertGreaterThan(bytesRead, 0)
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A { break }
        }
        while response.last == 0x0A || response.last == 0x0D { response.removeLast() }

        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
    }

    private func socketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { rawBuffer[index] = byte }
        }
        return address
    }
}
