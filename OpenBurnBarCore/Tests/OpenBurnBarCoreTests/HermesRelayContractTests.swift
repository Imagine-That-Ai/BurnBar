import XCTest
@testable import OpenBurnBarCore

final class HermesRelayContractTests: XCTestCase {
    func testRelayRequestRecordCodableRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_714_200_000)
        let record = HermesRelayRequestRecord(
            id: "relay-request-1",
            connectionId: "relay-mac",
            operation: .chatCompletions,
            status: .streaming,
            method: "POST",
            payloadCiphertext: "ciphertext",
            wrappedKey: "wrapped-key",
            relayEncryption: HermesRelayCrypto.algorithm,
            relayKeyVersion: HermesRelayCrypto.keyVersion,
            chunkCount: 2,
            createdAt: now,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(90)
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(HermesRelayRequestRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.operation.rawValue, "chatCompletions")
        XCTAssertEqual(decoded.status.rawValue, "streaming")
    }

    func testRelayChunkRecordCodableRoundTrip() throws {
        let record = HermesRelayChunkRecord(
            id: "00000001",
            requestId: "relay-request-1",
            sequence: 1,
            kind: .sse,
            ciphertext: "ciphertext"
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(HermesRelayChunkRecord.self, from: data)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.kind.rawValue, "sse")
    }

    func testRelayCryptoRoundTripsRequestAndChunkPayloads() throws {
        let privateKey = HermesRelayCrypto.generatePrivateKey()
        let keyData = try HermesRelayCrypto.generateSymmetricKeyData()
        let uid = "user-1"
        let connectionID = "relay-mac"
        let requestID = "relay-request-1"
        let keyAAD = HermesRelayCrypto.keyAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        let wrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            keyData,
            recipientPublicKeyBase64: privateKey.publicKeyBase64,
            aad: keyAAD
        )
        let unwrappedKey = try HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKey,
            privateKey: privateKey,
            aad: keyAAD
        )
        XCTAssertEqual(unwrappedKey, keyData)

        let requestPayload = HermesRelayEncryptedRequestPayload(
            path: "/v1/chat/completions",
            sessionId: "session-☿",
            body: #"{"stream":true,"messages":[{"role":"user","content":"hi"}]}"#
        )
        let requestPlaintext = try JSONEncoder().encode(requestPayload)
        let requestCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: requestPlaintext,
            keyData: keyData,
            aad: HermesRelayCrypto.requestAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        )
        XCTAssertFalse(requestCiphertext.contains("messages"))

        let openedRequest = try HermesRelayCrypto.openBase64(
            ciphertext: requestCiphertext,
            keyData: unwrappedKey,
            aad: HermesRelayCrypto.requestAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        )
        XCTAssertEqual(try JSONDecoder().decode(HermesRelayEncryptedRequestPayload.self, from: openedRequest), requestPayload)

        let chunkAAD = HermesRelayCrypto.chunkAAD(
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            sequence: 0,
            kind: HermesRelayChunkKind.sse.rawValue
        )
        let chunkCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: Data("data: hello ☿".utf8),
            keyData: keyData,
            aad: chunkAAD
        )
        let openedChunk = try HermesRelayCrypto.openBase64(
            ciphertext: chunkCiphertext,
            keyData: keyData,
            aad: chunkAAD
        )
        XCTAssertEqual(String(data: openedChunk, encoding: .utf8), "data: hello ☿")
    }
}
