import XCTest
@testable import OpenBurnBarCore

final class HermesRelayAuthenticatedRequestOpenerTests: XCTestCase {
    func testOpenV3RequestSucceedsWithPinnedSenderAndVerifiedSignalIdentity() async throws {
        let recipient = HermesRelayCrypto.generatePrivateKey()
        let sender = HermesRelayCrypto.generatePrivateKey()
        let payload = try makePayload(recipient: recipient, sender: sender, requestID: "request-1", counter: 1)
        let opener = makeOpener(pinnedSenderPublicKey: sender.publicKeyBase64)

        let opened = try await opener.open(
            payload: payload,
            uid: "uid-1",
            connectionID: "connection-1",
            requestID: "request-1",
            operation: .cliAgentChat,
            recipientPrivateKey: recipient
        )

        XCTAssertEqual(opened.encryptedPayload.body, #"{"prompt":"hello"}"#)
        XCTAssertEqual(opened.sender.deviceID, "phone-1")
        XCTAssertEqual(opened.sender.counter, 1)
    }

    func testRejectsLegacyRelayKeyVersionsBeforeOpen() async throws {
        let recipient = HermesRelayCrypto.generatePrivateKey()
        let sender = HermesRelayCrypto.generatePrivateKey()
        let opener = makeOpener(pinnedSenderPublicKey: sender.publicKeyBase64)

        for version in [HermesRelayCrypto.keyVersion, HermesRelayCrypto.gatewayRelayKeyVersion] {
            var payload = try makePayload(recipient: recipient, sender: sender, requestID: "legacy-\(version)", counter: Int64(version))
            payload.relayKeyVersion = version
            payload.relayEncryption = HermesRelayCrypto.algorithm

            try await assertRelayRejects(
                opener: opener,
                payload: payload,
                recipient: recipient,
                requestID: "legacy-\(version)",
                reason: .senderAuthRequired
            )
        }
    }

    func testRejectsMissingEnc() async throws {
        let recipient = HermesRelayCrypto.generatePrivateKey()
        let sender = HermesRelayCrypto.generatePrivateKey()
        var payload = try makePayload(recipient: recipient, sender: sender, requestID: "missing-enc", counter: 1)
        payload.enc = nil

        try await assertRelayRejects(
            opener: makeOpener(pinnedSenderPublicKey: sender.publicKeyBase64),
            payload: payload,
            recipient: recipient,
            requestID: "missing-enc",
            reason: .senderAuthRequired
        )
    }

    func testRejectsWrongPinnedSender() async throws {
        let recipient = HermesRelayCrypto.generatePrivateKey()
        let realSender = HermesRelayCrypto.generatePrivateKey()
        let wrongSender = HermesRelayCrypto.generatePrivateKey()
        let payload = try makePayload(recipient: recipient, sender: realSender, requestID: "wrong-sender", counter: 1)

        try await assertRelayRejects(
            opener: makeOpener(pinnedSenderPublicKey: wrongSender.publicKeyBase64),
            payload: payload,
            recipient: recipient,
            requestID: "wrong-sender",
            reason: .senderKeyUntrusted
        )
    }

    func testRejectsTamperedAuthenticatedAAD() async throws {
        let recipient = HermesRelayCrypto.generatePrivateKey()
        let sender = HermesRelayCrypto.generatePrivateKey()
        var payload = try makePayload(recipient: recipient, sender: sender, requestID: "tamper-aad", counter: 1)
        payload.operation = .chatCompletions
        let opener = makeOpener(pinnedSenderPublicKey: sender.publicKeyBase64)

        do {
            _ = try await opener.open(
                payload: payload,
                uid: "uid-1",
                connectionID: "connection-1",
                requestID: "tamper-aad",
                operation: .chatCompletions,
                recipientPrivateKey: recipient
            )
            XCTFail("Expected tampered AAD to fail HPKE open.")
        } catch HermesRelayAuthenticatedRequestError.rejected {
            XCTFail("AAD tamper should fail cryptographic authentication, not policy validation.")
        } catch {
            // Expected: CryptoKit HPKE open normalizes to invalidCiphertext.
        }
    }

    func testRejectsReplayedCounterAndDuplicateRequestID() async throws {
        let recipient = HermesRelayCrypto.generatePrivateKey()
        let sender = HermesRelayCrypto.generatePrivateKey()
        let opener = makeOpener(pinnedSenderPublicKey: sender.publicKeyBase64)
        let first = try makePayload(recipient: recipient, sender: sender, requestID: "request-1", counter: 1)
        _ = try await opener.open(
            payload: first,
            uid: "uid-1",
            connectionID: "connection-1",
            requestID: "request-1",
            operation: .cliAgentChat,
            recipientPrivateKey: recipient
        )

        try await assertRelayRejects(
            opener: opener,
            payload: first,
            recipient: recipient,
            requestID: "request-1",
            reason: .senderReplay
        )

        let duplicateID = try makePayload(recipient: recipient, sender: sender, requestID: "request-1", counter: 2)
        try await assertRelayRejects(
            opener: opener,
            payload: duplicateID,
            recipient: recipient,
            requestID: "request-1",
            reason: .senderReplay
        )

        let staleCounter = try makePayload(recipient: recipient, sender: sender, requestID: "request-2", counter: 1)
        try await assertRelayRejects(
            opener: opener,
            payload: staleCounter,
            recipient: recipient,
            requestID: "request-2",
            reason: .senderReplay
        )
    }

    func testRejectsUnverifiedSignalIdentity() async throws {
        let recipient = HermesRelayCrypto.generatePrivateKey()
        let sender = HermesRelayCrypto.generatePrivateKey()
        let payload = try makePayload(recipient: recipient, sender: sender, requestID: "signal-missing", counter: 1)

        try await assertRelayRejects(
            opener: makeOpener(pinnedSenderPublicKey: sender.publicKeyBase64, signalVerified: false),
            payload: payload,
            recipient: recipient,
            requestID: "signal-missing",
            reason: .signalIdentityUnverified
        )
    }

    // MARK: - T-CRY-03: replay high-water-mark survives file deletion

    func testReplayHighWaterMarkSurvivesFileDeletionViaKeychainAnchor() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-replay-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let anchor = InMemoryHermesReplayCounterAnchorBacking()
        let sender = HermesRelayAuthenticatedSender(
            publicKeyBase64: "pub",
            deviceID: "phone-1",
            peerNodeID: "node-1",
            counter: 7,
            keyID: "relay-sender-key-1"
        )

        // 1. Record a fresh request at counter 7 through the file-backed cache.
        let cache = HermesRelayReplayCache(persistenceURL: fileURL, counterAnchor: anchor)
        try await cache.recordFresh(
            uid: "uid-1",
            connectionID: "connection-1",
            requestID: "request-7",
            sender: sender
        )

        // 2. Simulate an attacker deleting the plaintext JSON high-water-mark file.
        try FileManager.default.removeItem(at: fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        // 3. A fresh cache rebuilt from the (now missing) file but the SAME anchor
        //    must still refuse a replay of counter 7 — the anchor preserved the mark.
        let rebuilt = HermesRelayReplayCache(persistenceURL: fileURL, counterAnchor: anchor)
        await assertReplayRejected {
            try await rebuilt.recordFresh(
                uid: "uid-1",
                connectionID: "connection-1",
                requestID: "request-7-replay",
                sender: sender
            )
        }
        // A stale counter (< anchor) is likewise refused.
        await assertReplayRejected {
            try await rebuilt.recordFresh(
                uid: "uid-1",
                connectionID: "connection-1",
                requestID: "request-3",
                sender: HermesRelayAuthenticatedSender(
                    publicKeyBase64: "pub",
                    deviceID: "phone-1",
                    peerNodeID: "node-1",
                    counter: 3,
                    keyID: "relay-sender-key-1"
                )
            )
        }
        // A genuinely newer counter still advances past the anchored mark.
        try await rebuilt.recordFresh(
            uid: "uid-1",
            connectionID: "connection-1",
            requestID: "request-8",
            sender: HermesRelayAuthenticatedSender(
                publicKeyBase64: "pub",
                deviceID: "phone-1",
                peerNodeID: "node-1",
                counter: 8,
                keyID: "relay-sender-key-1"
            )
        )
    }

    func testReplayCacheWithoutAnchorRegressesAfterFileDeletion() async throws {
        // Control: without the anchor seam, deleting the file DOES reset the mark —
        // this is exactly the regression the Keychain anchor closes.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-replay-noanchor-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let sender = HermesRelayAuthenticatedSender(
            publicKeyBase64: "pub",
            deviceID: "phone-1",
            peerNodeID: "node-1",
            counter: 7,
            keyID: "relay-sender-key-1"
        )
        let cache = HermesRelayReplayCache(persistenceURL: fileURL, counterAnchor: nil)
        try await cache.recordFresh(
            uid: "uid-1",
            connectionID: "connection-1",
            requestID: "request-7",
            sender: sender
        )
        try FileManager.default.removeItem(at: fileURL)

        let rebuilt = HermesRelayReplayCache(persistenceURL: fileURL, counterAnchor: nil)
        // Without the anchor the replayed counter is (wrongly) re-admitted.
        try await rebuilt.recordFresh(
            uid: "uid-1",
            connectionID: "connection-1",
            requestID: "request-7-replay",
            sender: sender
        )
    }

    private func assertReplayRejected(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected replay to be rejected.", file: file, line: line)
        } catch HermesRelayAuthenticatedRequestError.rejected(let reason) {
            XCTAssertEqual(reason, .senderReplay, file: file, line: line)
        } catch {
            XCTFail("Expected senderReplay rejection, got \(error)", file: file, line: line)
        }
    }

    private func makeOpener(
        pinnedSenderPublicKey: String,
        signalVerified: Bool = true
    ) -> HermesRelayAuthenticatedRequestOpener {
        HermesRelayAuthenticatedRequestOpener(
            replayCache: HermesRelayReplayCache(counterAnchor: InMemoryHermesReplayCounterAnchorBacking()),
            trustResolver: StaticRelaySenderTrustResolver(
                pinnedPublicKey: pinnedSenderPublicKey,
                signalVerified: signalVerified
            )
        )
    }

    private func makePayload(
        recipient: HermesRelayPrivateKey,
        sender: HermesRelayPrivateKey,
        requestID: String,
        counter: Int64
    ) throws -> HermesRealtimeRelayPayload {
        let uid = "uid-1"
        let connectionID = "connection-1"
        let operation = HermesRelayOperation.cliAgentChat
        let senderDeviceID = "phone-1"
        let senderPeerNodeID = "node-1"
        let keyID = "relay-sender-key-1"
        let keyData = try HermesRelayCrypto.generateSymmetricKeyData()
        let keyAAD = HermesRelayCrypto.authenticatedKeyAAD(
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            operation: operation,
            senderDeviceID: senderDeviceID,
            senderPeerNodeID: senderPeerNodeID,
            senderCounter: counter,
            keyID: keyID
        )
        let wrap = try HermesRelayCrypto.sealKeyV3(
            keyData,
            recipientPublicKeyBase64: recipient.publicKeyBase64,
            senderPrivateKey: sender,
            aad: keyAAD
        )
        let body = HermesRelayEncryptedRequestPayload(
            path: "/v1/cli-agent/chat",
            sessionId: "session-1",
            body: #"{"prompt":"hello"}"#
        )
        let payloadCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: JSONEncoder().encode(body),
            keyData: keyData,
            aad: HermesRelayCrypto.authenticatedRequestAAD(
                uid: uid,
                connectionID: connectionID,
                requestID: requestID,
                operation: operation,
                senderDeviceID: senderDeviceID,
                senderPeerNodeID: senderPeerNodeID,
                senderCounter: counter,
                keyID: keyID
            )
        )
        return HermesRealtimeRelayPayload(
            operation: operation,
            method: "POST",
            payloadCiphertext: payloadCiphertext,
            enc: wrap.encBase64,
            wrappedKey: wrap.wrappedKeyBase64,
            relayEncryption: HermesRelayCrypto.relayEncryptionV3,
            relayKeyVersion: HermesRelayCrypto.gatewayRelayKeyVersionV3,
            senderPublicKey: sender.publicKeyBase64,
            senderDeviceId: senderDeviceID,
            senderPeerNodeId: senderPeerNodeID,
            senderCounter: counter,
            keyId: keyID
        )
    }

    private func assertRelayRejects(
        opener: HermesRelayAuthenticatedRequestOpener,
        payload: HermesRealtimeRelayPayload,
        recipient: HermesRelayPrivateKey,
        requestID: String,
        reason: HermesRelayAuthenticatedRequestDenyReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await opener.open(
                payload: payload,
                uid: "uid-1",
                connectionID: "connection-1",
                requestID: requestID,
                operation: .cliAgentChat,
                recipientPrivateKey: recipient
            )
            XCTFail("Expected relay request to reject.", file: file, line: line)
        } catch HermesRelayAuthenticatedRequestError.rejected(let actual) {
            XCTAssertEqual(actual, reason, file: file, line: line)
        }
    }
}

private struct StaticRelaySenderTrustResolver: HermesRelaySenderTrustResolving {
    var pinnedPublicKey: String
    var signalVerified: Bool

    func pinnedRelaySenderPublicKeyBase64(
        for context: HermesRelayAuthenticatedRequestTrustContext
    ) async throws -> String {
        pinnedPublicKey
    }

    func requireVerifiedSignalIdentity(
        for context: HermesRelayAuthenticatedRequestTrustContext
    ) async throws {
        guard signalVerified else {
            throw HermesRelayAuthenticatedRequestError.rejected(.signalIdentityUnverified)
        }
    }
}
