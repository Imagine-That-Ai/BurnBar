import XCTest
@testable import OpenBurnBarCore

final class PiAgentRelayContractTests: XCTestCase {
    func testConnectionAndRelayRecordsCodableRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_778_534_400)
        let connection = PiConnectionRecord(
            id: "relay-mac",
            displayName: "Mac Pi Relay",
            mode: .relayLink,
            status: .online,
            endpointURL: "http://127.0.0.1:8765",
            advertisedModel: "pi-default",
            instanceID: "default",
            redisURL: "redis://127.0.0.1:6379/0",
            relayPublicKey: "public",
            relayKeyVersion: PiAgentRelayCrypto.keyVersion,
            relayEncryption: PiAgentRelayCrypto.algorithm,
            capabilities: ["chat_completions", "remote_relay"],
            instances: [
                PiAgentInstanceRecord(
                    id: "default",
                    displayName: "Default",
                    endpointURL: "http://127.0.0.1:8765",
                    status: .online,
                    modelName: "pi-default",
                    capabilities: ["chat_completions"],
                    lastSeenAt: now
                )
            ],
            models: [
                PiAgentRuntimeModelOption(
                    providerID: "pi",
                    providerName: "Pi",
                    modelID: "pi-default",
                    instanceID: "default"
                )
            ],
            lastSeenAt: now,
            createdAt: now,
            updatedAt: now,
            schemaVersion: 1
        )
        let request = PiAgentRelayRequestRecord(
            id: "req-1",
            connectionId: connection.id,
            operation: .chatCompletions,
            status: .streaming,
            method: "POST",
            payloadCiphertext: "ciphertext",
            wrappedKey: "wrapped",
            chunkCount: 1,
            createdAt: now,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(90)
        )
        let chunk = PiAgentRelayChunkRecord(
            id: "00000000",
            requestId: request.id,
            sequence: 0,
            kind: .sse,
            ciphertext: "chunk"
        )

        let encodedConnection = try JSONEncoder().encode(connection)
        let encodedConnectionJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedConnection) as? [String: Any])
        XCTAssertEqual(encodedConnectionJSON["selectedInstanceID"] as? String, "default")
        XCTAssertNil(encodedConnectionJSON["instanceID"])
        XCTAssertEqual(try roundTrip(connection), connection)
        XCTAssertEqual(try roundTrip(request), request)
        XCTAssertEqual(try roundTrip(chunk), chunk)
        XCTAssertEqual(request.operation.rawValue, "chatCompletions")
        XCTAssertEqual(chunk.kind.rawValue, "sse")
    }

    func testRuntimePreferenceAndDeviceLinkRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_778_534_400)
        let preference = RuntimeConnectionPreferenceDoc(
            deviceID: "iphone-1",
            runtimeKind: .piAgent,
            selectedConnectionID: "relay-mac",
            selectedInstanceID: "default",
            selectedModelID: "pi-default",
            createdAt: now,
            updatedAt: now
        )
        let link = ProviderAccountDeviceLinkDoc(
            accountID: "codex_default",
            deviceID: "iphone-1",
            deviceDisplayName: "iPhone",
            capability: .use,
            status: .active,
            lastObservedAt: now,
            createdAt: now,
            updatedAt: now
        )

        XCTAssertEqual(preference.id, "iphone-1_piAgent")
        XCTAssertEqual(link.id, "codex_default_iphone-1")
        XCTAssertEqual(try roundTrip(preference), preference)
        XCTAssertEqual(try roundTrip(link), link)
    }

    func testPiRelayCryptoRoundTripsAndRejectsHermesAAD() throws {
        let privateKey = PiAgentRelayCrypto.generatePrivateKey()
        let keyData = try PiAgentRelayCrypto.generateSymmetricKeyData()
        let uid = "user-1"
        let connectionID = "relay-mac"
        let requestID = "req-1"
        let keyAAD = PiAgentRelayCrypto.keyAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        let wrappedKey = try PiAgentRelayCrypto.wrapSymmetricKey(
            keyData,
            recipientPublicKeyBase64: privateKey.publicKeyBase64,
            aad: keyAAD
        )
        let unwrappedKey = try PiAgentRelayCrypto.unwrapSymmetricKey(
            wrappedKey,
            privateKey: privateKey,
            aad: keyAAD
        )
        XCTAssertEqual(unwrappedKey, keyData)

        let payload = PiAgentRelayEncryptedRequestPayload(
            path: "/v1/chat/completions",
            sessionId: "pi-session",
            body: #"{"stream":true,"messages":[{"role":"user","content":"hi"}]}"#
        )
        let plaintext = try JSONEncoder().encode(payload)
        let piAAD = PiAgentRelayCrypto.requestAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        let ciphertext = try PiAgentRelayCrypto.sealToBase64(
            plaintext: plaintext,
            keyData: keyData,
            aad: piAAD
        )
        let opened = try PiAgentRelayCrypto.openBase64(
            ciphertext: ciphertext,
            keyData: keyData,
            aad: piAAD
        )
        XCTAssertEqual(try JSONDecoder().decode(PiAgentRelayEncryptedRequestPayload.self, from: opened), payload)

        let hermesAAD = HermesRelayCrypto.requestAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        XCTAssertThrowsError(
            try HermesRelayCrypto.openBase64(
                ciphertext: ciphertext,
                keyData: keyData,
                aad: hermesAAD
            )
        )
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
