import CryptoKit
import Darwin
import Foundation
import OpenBurnBarEngine
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

    // MARK: - Helpers

    private func makeSocketPath(name: String) -> String {
        let boundedName = String(name.prefix(24))
        let nonce = String(UUID().uuidString.prefix(8))
        return "/tmp/obb-cu-\(boundedName)-\(nonce).sock"
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

    private func makeGrantBinding(
        requestId: String = "grant-request-abc",
        sourceDeviceId: String? = nil,
        localAuthenticationSatisfied: Bool = true,
        clientIntentId: String? = nil
    ) throws -> ComputerUseLocalAuthGrantBinding {
        let now = Date()
        return ComputerUseLocalAuthGrantBinding(
            requestId: requestId,
            runtime: "codex",
            threadId: "thread-abc",
            preset: "desktop",
            capabilities: ["desktop_system_input", "desktop_screenshot"],
            trustMode: "manual",
            deliveryMode: "live_then_queued",
            requestedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(299),
            grantDurationSeconds: 1_800,
            sourceDeviceId: sourceDeviceId ?? deviceId,
            clientIntentId: try clientIntentId ?? ComputerUsePhoneControlSigner()
                .canonicalComputerUseSessionIntentID(request: baseSessionStartRequest()),
            localAuthenticationSatisfied: localAuthenticationSatisfied
        )
    }

    private func baseSessionStartRequest() -> ComputerUseSessionStartRequest {
        ComputerUseSessionStartRequest(
            mode: ComputerUseMode.system.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            clientID: BurnBarClientID(rawValue: "test-client")
        )
    }

    private func intentHash(for binding: ComputerUseLocalAuthGrantBinding) throws -> String {
        try ComputerUsePhoneControlSigner().canonicalAgentGrantRequestHashHex(binding: binding)
    }

    private func makeServer(
        socketPath: String,
        verifier: DaemonLocalAuthProofVerifier?,
        pinStore: DaemonPhoneKeyPinStore? = nil,
        authorizationRegistry: ComputerUseAuthorizationRegistry? = nil
    ) -> BurnBarDaemonServer {
        BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "cu-proof-wiring-tests"),
            computerUseAuthorizationRegistry: authorizationRegistry,
            localAuthProofVerifier: verifier,
            phoneControlPinStore: pinStore
        )
    }

    private func sessionStartRequest(
        proof: HermesRealtimeRelayAgentGrantLocalAuthProof?,
        sourceDeviceId: String?,
        intentHashHex: String?,
        grantBinding: ComputerUseLocalAuthGrantBinding? = nil,
        id: String
    ) -> BurnBarRPCRequestEnvelopeWithParams<ComputerUseSessionStartRequest> {
        BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: .computerUseSessionStart,
            authToken: "test-token",
            params: ComputerUseSessionStartRequest(
                mode: ComputerUseMode.system.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                clientID: BurnBarClientID(rawValue: "test-client"),
                localAuthProof: proof,
                sourceDeviceId: sourceDeviceId,
                intentHashHex: intentHashHex,
                localAuthGrantBinding: grantBinding
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
        peerNodeId: String? = nil,
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
                peerNodeId: peerNodeId,
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

    private final class RacingDuplicatePinBacking: DaemonPhoneKeyPinBacking, @unchecked Sendable {
        private let duplicateRecord: DaemonPhoneKeyPinRecord
        private let lock = NSLock()
        private var loadCount = 0
        private(set) var saveCount = 0

        init(duplicateRecord: DaemonPhoneKeyPinRecord) {
            self.duplicateRecord = duplicateRecord
        }

        func load(deviceId: String) -> DaemonPhoneKeyPinLoad {
            lock.lock()
            defer { lock.unlock() }
            loadCount += 1
            return loadCount == 1 ? .absent : .found(duplicateRecord)
        }

        @discardableResult
        func save(_ record: DaemonPhoneKeyPinRecord) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            saveCount += 1
            return -25299
        }

        func delete(deviceId: String) {}
    }

    private final class NonAtomicFailingAliasPinBacking: DaemonPhoneKeyPinBacking, @unchecked Sendable {
        private let lock = NSLock()
        private var records: [String: DaemonPhoneKeyPinRecord] = [:]
        private var saves = 0
        private var deletes = 0

        func load(deviceId: String) -> DaemonPhoneKeyPinLoad {
            lock.lock()
            defer { lock.unlock() }
            return records[deviceId].map(DaemonPhoneKeyPinLoad.found) ?? .absent
        }

        @discardableResult
        func save(_ record: DaemonPhoneKeyPinRecord) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            saves += 1
            guard saves != 2 else { return -34_018 }
            records[record.deviceId] = record
            return 0
        }

        func delete(deviceId: String) {
            lock.lock()
            defer { lock.unlock() }
            deletes += 1
            // Adversarial backing: rollback deletes would fail to remove trust.
        }

        func operationCounts() -> (saves: Int, deletes: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (saves, deletes)
        }
    }

#if canImport(Security)
    private final class FakePhoneKeyKeychainDataStore: DaemonPhoneKeyKeychainDataStore, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        private var adds = 0
        private var updates = 0
        private var deletes = 0
        var forcedAddError: Int32?
        var forcedUpdateError: Int32?
        var forcedDeleteError: Int32?

        func load(service: String, account: String) -> (status: Int32, data: Data?) {
            lock.lock()
            defer { lock.unlock() }
            guard let data = items[key(service: service, account: account)] else {
                return (-25_300, nil)
            }
            return (0, data)
        }

        func add(service: String, account: String, data: Data) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            adds += 1
            if let forcedAddError { return forcedAddError }
            let itemKey = key(service: service, account: account)
            guard items[itemKey] == nil else { return -25_299 }
            items[itemKey] = data
            return 0
        }

        func update(service: String, account: String, data: Data) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            updates += 1
            if let forcedUpdateError { return forcedUpdateError }
            let itemKey = key(service: service, account: account)
            guard items[itemKey] != nil else { return -25_300 }
            items[itemKey] = data
            return 0
        }

        func delete(service: String, account: String) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            deletes += 1
            if let forcedDeleteError { return forcedDeleteError }
            items.removeValue(forKey: key(service: service, account: account))
            return 0
        }

        func operationCounts() -> (adds: Int, updates: Int, deletes: Int, items: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (adds, updates, deletes, items.count)
        }

        private func key(service: String, account: String) -> String {
            "\(service)\u{0}\(account)"
        }
    }
#endif

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

    func test_macEnforcedDaemonAcceptsLegacyRandomClientIntentID() async throws {
        let socketPath = makeSocketPath(name: "mac-random")
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { [deviceId] in $0 == deviceId ? .ed25519(privateKey.publicKey) : nil },
            consumeProof: { _, _ in true }
        )
        let server = makeServer(socketPath: socketPath, verifier: verifier)
        try await server.start()
        addTeardownBlock { await server.stop() }
        let binding = try makeGrantBinding(clientIntentId: UUID().uuidString)
        let hash = try intentHash(for: binding)
        let now = Date()
        let proof = try makeProof(
            privateKey: privateKey,
            deviceId: deviceId,
            intentHash: hash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )

        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(
                proof: proof,
                sourceDeviceId: deviceId,
                intentHashHex: hash,
                grantBinding: binding,
                id: "mac-random-client-intent"
            ),
            socketPath: socketPath
        )

        XCTAssertFalse(
            isProofRefusal(response.error),
            "macOS must preserve legacy random clientIntentId grants until mobile acquisition signs exact session intents"
        )
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
        let binding = try makeGrantBinding()
        let hash = try intentHash(for: binding)
        let forged = try makeProof(
            privateKey: attackerKey,
            deviceId: deviceId,
            intentHash: hash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(
                proof: forged,
                sourceDeviceId: deviceId,
                intentHashHex: hash,
                grantBinding: binding,
                id: "forged"
            ),
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
        let binding = try makeGrantBinding()
        let hash = try intentHash(for: binding)
        // Proof minted for a DIFFERENT op hash than the one the request declares.
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: String(repeating: "b", count: 64),
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(
                proof: proof,
                sourceDeviceId: deviceId,
                intentHashHex: hash,
                grantBinding: binding,
                id: "wrong-intent"
            ),
            socketPath: socketPath
        )
        XCTAssertNil(response.result)
        XCTAssertTrue(isProofRefusal(response.error), "intent-retargeted proof must fail closed")
    }

    func test_enforcedDaemon_refusesCallerDeclaredHashWithoutMatchingGrantBinding() async throws {
        let socketPath = makeSocketPath(name: "caller-hash")
        let key = Curve25519.Signing.PrivateKey()
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { [deviceId] in $0 == deviceId ? .ed25519(key.publicKey) : nil },
            consumeProof: { _, _ in true }
        )
        let server = makeServer(socketPath: socketPath, verifier: verifier)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let now = Date()
        let signedBinding = try makeGrantBinding(requestId: "signed-grant")
        let requestedBinding = try makeGrantBinding(requestId: "requested-grant")
        let signedHash = try intentHash(for: signedBinding)
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: signedHash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )

        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(
                proof: proof,
                sourceDeviceId: deviceId,
                intentHashHex: signedHash,
                grantBinding: requestedBinding,
                id: "caller-hash"
            ),
            socketPath: socketPath
        )

        XCTAssertNil(response.result)
        XCTAssertTrue(
            isProofRefusal(response.error),
            "daemon must derive the expected hash from the grant binding, not trust the caller-declared hash"
        )
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
        let binding = try makeGrantBinding()
        let hash = try intentHash(for: binding)
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: hash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(
                proof: proof,
                sourceDeviceId: deviceId,
                intentHashHex: hash,
                grantBinding: binding,
                id: "no-pin"
            ),
            socketPath: socketPath
        )
        XCTAssertNil(response.result)
        XCTAssertTrue(isProofRefusal(response.error), "no pinned key must fail closed")
    }

    func test_enforcedDaemon_refusesValidProofWithoutGrantBinding() async throws {
        let socketPath = makeSocketPath(name: "missing-binding")
        let key = Curve25519.Signing.PrivateKey()
        let verifier = DaemonLocalAuthProofVerifier(
            resolvePinnedKey: { [deviceId] in $0 == deviceId ? .ed25519(key.publicKey) : nil },
            consumeProof: { _, _ in true }
        )
        let server = makeServer(socketPath: socketPath, verifier: verifier)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let now = Date()
        let binding = try makeGrantBinding()
        let hash = try intentHash(for: binding)
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: hash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(
                proof: proof,
                sourceDeviceId: deviceId,
                intentHashHex: hash,
                id: "missing-binding"
            ),
            socketPath: socketPath
        )

        XCTAssertNil(response.result)
        XCTAssertTrue(isProofRefusal(response.error), "proof-enforced daemon must require the grant binding")
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
        let binding = try makeGrantBinding()
        let hash = try intentHash(for: binding)
        let proof = try makeProof(
            privateKey: key,
            deviceId: deviceId,
            intentHash: hash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(
                proof: proof,
                sourceDeviceId: deviceId,
                intentHashHex: hash,
                grantBinding: binding,
                id: "valid"
            ),
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
        let authorizationRegistry = ComputerUseAuthorizationRegistry(enforcementEnabled: true)
        let runID = BurnBarRunID(rawValue: "run-invoke-verified-session")
        let sessionID = ComputerUseSessionID("verified-session")
        let clientID = BurnBarClientID(rawValue: "test-client")
        let reserved = await authorizationRegistry.reserve(runID: runID)
        XCTAssertTrue(reserved)
        let bound = await authorizationRegistry.bind(
            sessionID: sessionID,
            runID: runID,
            clientID: clientID
        )
        XCTAssertTrue(bound)
        let server = makeServer(
            socketPath: socketPath,
            verifier: verifier,
            authorizationRegistry: authorizationRegistry
        )
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

    func test_phoneControlPinProvision_persistsDistinctPeerNodeAlias() async throws {
        let socketPath = makeSocketPath(name: "pin-peer-alias")
        let privateKey = Curve25519.Signing.PrivateKey()
        let pinStore = DaemonPhoneKeyPinStore(backing: DaemonPhoneKeyInMemoryPinBacking())
        let server = makeServer(socketPath: socketPath, verifier: nil, pinStore: pinStore)
        try await server.start()
        addTeardownBlock { await server.stop() }
        let peerNodeId = "iroh-peer-node-distinct-from-device"

        let response: BurnBarRPCResponseEnvelope<DaemonPhoneControlPinProvisionResponse> = try sendEnvelope(
            pinProvisionRequest(
                deviceId: deviceId,
                peerNodeId: peerNodeId,
                publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
                id: "pin-peer-alias"
            ),
            socketPath: socketPath
        )

        XCTAssertEqual(response.result?.pinned, true)
        for identifier in [deviceId, peerNodeId] {
            guard case .pinned(let resolved) = pinStore.pinnedKey(deviceId: identifier) else {
                XCTFail("expected key alias to be pinned for \(identifier)")
                continue
            }
            XCTAssertEqual(resolved.publicKeyRepresentation, privateKey.publicKey.rawRepresentation)
        }
    }

    func test_phoneControlPinProvision_deviceConflictDoesNotPersistPeerAlias() async throws {
        let socketPath = makeSocketPath(name: "pin-device-conflict-atomic")
        let originalKey = Curve25519.Signing.PrivateKey()
        let replacementKey = Curve25519.Signing.PrivateKey()
        let pinStore = DaemonPhoneKeyPinStore(backing: DaemonPhoneKeyInMemoryPinBacking())
        let originalVerifier = try PhoneControlVerifyingKey(
            kind: .ed25519,
            publicKeyRepresentation: originalKey.publicKey.rawRepresentation
        )
        guard case .pinned = pinStore.pin(deviceId: deviceId, key: originalVerifier) else {
            XCTFail("expected original device pin")
            return
        }
        let server = makeServer(socketPath: socketPath, verifier: nil, pinStore: pinStore)
        try await server.start()
        addTeardownBlock { await server.stop() }
        let peerNodeId = "atomic-peer-alias"

        let response: BurnBarRPCResponseEnvelope<DaemonPhoneControlPinProvisionResponse> = try sendEnvelope(
            pinProvisionRequest(
                deviceId: deviceId,
                peerNodeId: peerNodeId,
                publicKeyBase64: replacementKey.publicKey.rawRepresentation.base64EncodedString(),
                id: "pin-device-conflict-atomic"
            ),
            socketPath: socketPath
        )

        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.unauthorized)
        guard case .absent = pinStore.pinnedKey(deviceId: peerNodeId) else {
            XCTFail("rejected device conflict must not persist the peer alias")
            return
        }
    }

    func test_phoneControlPinProvision_peerConflictDoesNotPersistDeviceAlias() async throws {
        let socketPath = makeSocketPath(name: "pin-peer-conflict-atomic")
        let originalKey = Curve25519.Signing.PrivateKey()
        let replacementKey = Curve25519.Signing.PrivateKey()
        let pinStore = DaemonPhoneKeyPinStore(backing: DaemonPhoneKeyInMemoryPinBacking())
        let peerNodeId = "existing-peer-alias"
        let originalVerifier = try PhoneControlVerifyingKey(
            kind: .ed25519,
            publicKeyRepresentation: originalKey.publicKey.rawRepresentation
        )
        guard case .pinned = pinStore.pin(deviceId: peerNodeId, key: originalVerifier) else {
            XCTFail("expected original peer pin")
            return
        }
        let server = makeServer(socketPath: socketPath, verifier: nil, pinStore: pinStore)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<DaemonPhoneControlPinProvisionResponse> = try sendEnvelope(
            pinProvisionRequest(
                deviceId: deviceId,
                peerNodeId: peerNodeId,
                publicKeyBase64: replacementKey.publicKey.rawRepresentation.base64EncodedString(),
                id: "pin-peer-conflict-atomic"
            ),
            socketPath: socketPath
        )

        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.unauthorized)
        guard case .absent = pinStore.pinnedKey(deviceId: deviceId) else {
            XCTFail("rejected peer conflict must not persist the device alias")
            return
        }
    }

    func test_phoneControlPinProvision_nonAtomicBackingFailsBeforeWriteEvenIfRollbackDeleteWouldFail() async throws {
        let socketPath = makeSocketPath(name: "pin-alias-store-error-atomic")
        let privateKey = Curve25519.Signing.PrivateKey()
        let backing = NonAtomicFailingAliasPinBacking()
        let pinStore = DaemonPhoneKeyPinStore(backing: backing)
        let server = makeServer(socketPath: socketPath, verifier: nil, pinStore: pinStore)
        try await server.start()
        addTeardownBlock { await server.stop() }
        let peerNodeId = "store-error-peer-alias"

        let response: BurnBarRPCResponseEnvelope<DaemonPhoneControlPinProvisionResponse> = try sendEnvelope(
            pinProvisionRequest(
                deviceId: deviceId,
                peerNodeId: peerNodeId,
                publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
                id: "pin-alias-store-error-atomic"
            ),
            socketPath: socketPath
        )

        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.internalError)
        for identifier in [deviceId, peerNodeId] {
            guard case .absent = pinStore.pinnedKey(deviceId: identifier) else {
                XCTFail("failed alias transaction must leave \(identifier) absent")
                continue
            }
        }
        let operations = backing.operationCounts()
        XCTAssertEqual(operations.saves, 0)
        XCTAssertEqual(operations.deletes, 0)
    }

    func test_phoneControlPinProvision_isIdempotentForSameExistingKey() async throws {
        let socketPath = makeSocketPath(name: "pin-idempotent")
        let privateKey = Curve25519.Signing.PrivateKey()
        let pinStore = DaemonPhoneKeyPinStore(backing: DaemonPhoneKeyInMemoryPinBacking())
        let server = makeServer(socketPath: socketPath, verifier: nil, pinStore: pinStore)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let first: BurnBarRPCResponseEnvelope<DaemonPhoneControlPinProvisionResponse> = try sendEnvelope(
            pinProvisionRequest(
                deviceId: deviceId,
                publicKeyBase64: publicKeyBase64,
                id: "pin-first"
            ),
            socketPath: socketPath
        )
        let retry: BurnBarRPCResponseEnvelope<DaemonPhoneControlPinProvisionResponse> = try sendEnvelope(
            pinProvisionRequest(
                deviceId: deviceId,
                publicKeyBase64: publicKeyBase64,
                id: "pin-retry"
            ),
            socketPath: socketPath
        )

        XCTAssertEqual(first.result?.pinned, true)
        XCTAssertEqual(retry.result?.pinned, true)
        XCTAssertNil(retry.error)
        guard case .pinned(let resolved) = pinStore.pinnedKey(deviceId: deviceId) else {
            XCTFail("expected original key to remain pinned")
            return
        }
        XCTAssertEqual(resolved.publicKeyRepresentation, privateKey.publicKey.rawRepresentation)
    }

    func test_phoneControlPinStore_sameKeyRetryPreservesOriginalPinnedAt() throws {
        let backing = DaemonPhoneKeyInMemoryPinBacking()
        let privateKey = Curve25519.Signing.PrivateKey()
        let originalPinnedAt = 1_789_000_123.25
        let record = DaemonPhoneKeyPinRecord(
            deviceId: deviceId,
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            keyKind: .ed25519,
            pinnedAtEpoch: originalPinnedAt
        )
        XCTAssertEqual(backing.save(record), 0)

        let pinStore = DaemonPhoneKeyPinStore(backing: backing)
        let verifyingKey = try PhoneControlVerifyingKey(
            kind: .ed25519,
            publicKeyRepresentation: privateKey.publicKey.rawRepresentation
        )
        guard case .pinned(let resolved) = pinStore.pin(deviceId: deviceId, key: verifyingKey) else {
            XCTFail("same-key retry should be admitted as idempotent")
            return
        }
        XCTAssertEqual(resolved.publicKeyRepresentation, privateKey.publicKey.rawRepresentation)

        guard case .found(let stored) = backing.load(deviceId: deviceId) else {
            XCTFail("expected original backing record to remain present")
            return
        }
        XCTAssertEqual(stored.pinnedAtEpoch, originalPinnedAt)
    }

    func test_phoneControlPinStore_duplicateSaveReloadsSameKeyAsIdempotent() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let duplicateRecord = DaemonPhoneKeyPinRecord(
            deviceId: deviceId,
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            keyKind: .ed25519
        )
        let backing = RacingDuplicatePinBacking(duplicateRecord: duplicateRecord)
        let pinStore = DaemonPhoneKeyPinStore(backing: backing)
        let verifyingKey = try PhoneControlVerifyingKey(
            kind: .ed25519,
            publicKeyRepresentation: privateKey.publicKey.rawRepresentation
        )

        guard case .pinned(let resolved) = pinStore.pin(deviceId: deviceId, key: verifyingKey) else {
            XCTFail("duplicate insert with the same stored key should reload as idempotent")
            return
        }
        XCTAssertEqual(resolved.publicKeyRepresentation, privateKey.publicKey.rawRepresentation)
        XCTAssertEqual(backing.saveCount, 1)
    }

    func test_phoneControlPinStore_duplicateSaveReloadsDifferentKeyAsConflict() throws {
        let originalKey = Curve25519.Signing.PrivateKey()
        let replacementKey = Curve25519.Signing.PrivateKey()
        let duplicateRecord = DaemonPhoneKeyPinRecord(
            deviceId: deviceId,
            publicKeyBase64: originalKey.publicKey.rawRepresentation.base64EncodedString(),
            keyKind: .ed25519
        )
        let backing = RacingDuplicatePinBacking(duplicateRecord: duplicateRecord)
        let pinStore = DaemonPhoneKeyPinStore(backing: backing)
        let verifyingKey = try PhoneControlVerifyingKey(
            kind: .ed25519,
            publicKeyRepresentation: replacementKey.publicKey.rawRepresentation
        )

        guard case .conflict = pinStore.pin(deviceId: deviceId, key: verifyingKey) else {
            XCTFail("duplicate insert with a different stored key should fail closed as a conflict")
            return
        }
        XCTAssertEqual(backing.saveCount, 1)
    }

    func test_phoneControlPinStore_clearPinAllowsDeliberateLocalRekey() throws {
        let originalKey = Curve25519.Signing.PrivateKey()
        let replacementKey = Curve25519.Signing.PrivateKey()
        let pinStore = DaemonPhoneKeyPinStore(backing: DaemonPhoneKeyInMemoryPinBacking())
        let originalVerifier = try PhoneControlVerifyingKey(
            kind: .ed25519,
            publicKeyRepresentation: originalKey.publicKey.rawRepresentation
        )
        let replacementVerifier = try PhoneControlVerifyingKey(
            kind: .ed25519,
            publicKeyRepresentation: replacementKey.publicKey.rawRepresentation
        )

        guard case .pinned = pinStore.pin(deviceId: deviceId, key: originalVerifier) else {
            XCTFail("expected original key to pin")
            return
        }
        guard case .conflict = pinStore.pin(deviceId: deviceId, key: replacementVerifier) else {
            XCTFail("replacement must not overwrite before a deliberate local clear")
            return
        }

        pinStore.clearPin(deviceId: deviceId)

        guard case .pinned(let resolved) = pinStore.pin(deviceId: deviceId, key: replacementVerifier) else {
            XCTFail("replacement should pin after the local trust reset clears the old row")
            return
        }
        XCTAssertEqual(resolved.publicKeyRepresentation, replacementKey.publicKey.rawRepresentation)
    }

    func test_phoneControlPinStore_atomicAliasWriteFailurePersistsNoAlias() throws {
        let backing = DaemonPhoneKeyInMemoryPinBacking()
        backing.failWrites(with: -34_018)
        let pinStore = DaemonPhoneKeyPinStore(backing: backing)
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = try PhoneControlVerifyingKey(
            kind: .ed25519,
            publicKeyRepresentation: privateKey.publicKey.rawRepresentation
        )

        guard case .storeError(-34_018) = pinStore.pinAliases(
            deviceIds: [deviceId, "atomic-peer"],
            key: verifier
        ) else {
            XCTFail("expected atomic alias write failure")
            return
        }
        for identifier in [deviceId, "atomic-peer"] {
            guard case .absent = pinStore.pinnedKey(deviceId: identifier) else {
                XCTFail("atomic write failure must leave \(identifier) absent")
                continue
            }
        }
    }

#if canImport(Security)
    func test_phoneControlKeychainBackingCommitsEveryAliasInOneVersionedItemWrite() throws {
        let dataStore = FakePhoneKeyKeychainDataStore()
        let backing = DaemonPhoneKeyKeychainPinBacking(
            serviceName: "com.openburnbar.tests.phone-pin.\(UUID().uuidString)",
            dataStore: dataStore
        )
        let pinStore = DaemonPhoneKeyPinStore(backing: backing)
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = try PhoneControlVerifyingKey(
            kind: .ed25519,
            publicKeyRepresentation: privateKey.publicKey.rawRepresentation
        )
        let identifiers = [deviceId, "atomic-keychain-peer"]

        guard case .pinned = pinStore.pinAliases(deviceIds: identifiers, key: verifier) else {
            XCTFail("expected one-item Keychain alias commit")
            return
        }

        let operations = dataStore.operationCounts()
        XCTAssertEqual(operations.adds, 1)
        XCTAssertEqual(operations.updates, 0)
        XCTAssertEqual(operations.items, 1)
        for identifier in identifiers {
            guard case .pinned(let resolved) = pinStore.pinnedKey(deviceId: identifier) else {
                XCTFail("expected Keychain alias \(identifier)")
                continue
            }
            XCTAssertEqual(resolved.publicKeyRepresentation, privateKey.publicKey.rawRepresentation)
        }
    }

    func test_phoneControlKeychainBackingUpdateFailurePreservesPriorTrustAndAddsNoAlias() throws {
        let dataStore = FakePhoneKeyKeychainDataStore()
        let backing = DaemonPhoneKeyKeychainPinBacking(
            serviceName: "com.openburnbar.tests.phone-pin.\(UUID().uuidString)",
            dataStore: dataStore
        )
        let pinStore = DaemonPhoneKeyPinStore(backing: backing)
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = try PhoneControlVerifyingKey(
            kind: .ed25519,
            publicKeyRepresentation: privateKey.publicKey.rawRepresentation
        )
        guard case .pinned = pinStore.pin(deviceId: "existing-keychain-alias", key: verifier) else {
            XCTFail("expected initial Keychain pin")
            return
        }
        dataStore.forcedUpdateError = -34_018
        dataStore.forcedDeleteError = -34_019

        guard case .storeError(-34_018) = pinStore.pinAliases(
            deviceIds: [deviceId, "rejected-keychain-peer"],
            key: verifier
        ) else {
            XCTFail("expected atomic Keychain update failure")
            return
        }

        guard case .pinned = pinStore.pinnedKey(deviceId: "existing-keychain-alias") else {
            XCTFail("failed update must preserve prior trust")
            return
        }
        for identifier in [deviceId, "rejected-keychain-peer"] {
            guard case .absent = pinStore.pinnedKey(deviceId: identifier) else {
                XCTFail("failed atomic update must not add \(identifier)")
                continue
            }
        }
        let operations = dataStore.operationCounts()
        XCTAssertEqual(operations.adds, 1)
        XCTAssertEqual(operations.updates, 1)
        XCTAssertEqual(operations.deletes, 0, "atomic failure must never depend on rollback delete")
        XCTAssertEqual(operations.items, 1)
    }
#endif

    func test_phoneControlPinProvision_rejectsDifferentKeyForExistingDevice() async throws {
        let socketPath = makeSocketPath(name: "pin-conflict")
        let originalKey = Curve25519.Signing.PrivateKey()
        let replacementKey = Curve25519.Signing.PrivateKey()
        let pinStore = DaemonPhoneKeyPinStore(backing: DaemonPhoneKeyInMemoryPinBacking())
        let server = makeServer(socketPath: socketPath, verifier: nil, pinStore: pinStore)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let first: BurnBarRPCResponseEnvelope<DaemonPhoneControlPinProvisionResponse> = try sendEnvelope(
            pinProvisionRequest(
                deviceId: deviceId,
                publicKeyBase64: originalKey.publicKey.rawRepresentation.base64EncodedString(),
                id: "pin-original"
            ),
            socketPath: socketPath
        )
        let replacement: BurnBarRPCResponseEnvelope<DaemonPhoneControlPinProvisionResponse> = try sendEnvelope(
            pinProvisionRequest(
                deviceId: deviceId,
                publicKeyBase64: replacementKey.publicKey.rawRepresentation.base64EncodedString(),
                id: "pin-replacement"
            ),
            socketPath: socketPath
        )

        XCTAssertEqual(first.result?.pinned, true)
        XCTAssertNil(replacement.result)
        XCTAssertEqual(replacement.error?.code, BurnBarRPCErrorCode.unauthorized)
        guard case .pinned(let resolved) = pinStore.pinnedKey(deviceId: deviceId) else {
            XCTFail("expected original key to remain pinned")
            return
        }
        XCTAssertEqual(resolved.publicKeyRepresentation, originalKey.publicKey.rawRepresentation)
        XCTAssertNotEqual(resolved.publicKeyRepresentation, replacementKey.publicKey.rawRepresentation)
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

    func test_phoneControlPinProvision_rejectsEmptyDeviceEvenWithPeerAlias() async throws {
        let socketPath = makeSocketPath(name: "pin-empty-device")
        let privateKey = Curve25519.Signing.PrivateKey()
        let pinStore = DaemonPhoneKeyPinStore(backing: DaemonPhoneKeyInMemoryPinBacking())
        let server = makeServer(socketPath: socketPath, verifier: nil, pinStore: pinStore)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<DaemonPhoneControlPinProvisionResponse> = try sendEnvelope(
            pinProvisionRequest(
                deviceId: "   ",
                peerNodeId: "otherwise-valid-peer",
                publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
                id: "pin-empty-device"
            ),
            socketPath: socketPath
        )

        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.invalidParams)
        guard case .absent = pinStore.pinnedKey(deviceId: "otherwise-valid-peer") else {
            XCTFail("malformed device identity must not persist the peer alias")
            return
        }
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
        let binding = try makeGrantBinding()
        let hash = try intentHash(for: binding)
        let proof = try makeProof(
            privateKey: privateKey,
            deviceId: deviceId,
            intentHash: hash,
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let response: BurnBarRPCResponseEnvelope<ComputerUseSessionStartResponse> = try sendEnvelope(
            sessionStartRequest(
                proof: proof,
                sourceDeviceId: deviceId,
                intentHashHex: hash,
                grantBinding: binding,
                id: "verify"
            ),
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
