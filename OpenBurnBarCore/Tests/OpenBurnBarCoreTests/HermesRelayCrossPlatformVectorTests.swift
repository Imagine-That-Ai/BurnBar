import CryptoKit
import Foundation
import OpenBurnBarCore
import XCTest

/// Generates a fixed Hermes relay wire vector and pins it to
/// `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/HermesRelayWireVector.json`.
///
/// The Android suite (`HermesRelayWireVectorTest`) replays the same JSON
/// through the Kotlin implementation. A mismatch on either side
/// signals a wire-protocol drift between iOS / macOS and Android.
final class HermesRelayCrossPlatformVectorTests: XCTestCase {
    /// Whenever this string changes — bump it — Android must regenerate
    /// the fixture (`swift test --filter HermesRelayCrossPlatformVectorTests`).
    private static let vectorRevision = "v1"

    private static let fixtureURL: URL = {
        let base = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        return base.appendingPathComponent("HermesRelayWireVector.json")
    }()

    func test_emitsDeterministicVector_thatRoundTrips() throws {
        let priv = try makeDeterministicPrivateKey()
        let pub = priv.publicKey
        let symKey = makeDeterministicSymmetricKey()

        let uid = "u-vector"
        let cid = "c-vector"
        let rid = "r-vector"
        let payload = HermesRelayEncryptedRequestPayload(
            path: "/v1/chat/completions",
            sessionId: "s-vector",
            body: "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
        )
        let plaintext = try JSONEncoder().encode(payload)

        let requestAAD = HermesRelayCrypto.requestAAD(uid: uid, connectionID: cid, requestID: rid)
        let keyAAD = HermesRelayCrypto.keyAAD(uid: uid, connectionID: cid, requestID: rid)
        let chunkAAD = HermesRelayCrypto.chunkAAD(
            uid: uid,
            connectionID: cid,
            requestID: rid,
            sequence: 0,
            kind: "sse"
        )

        let payloadCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: plaintext,
            keyData: symKey,
            aad: requestAAD
        )
        let wrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            symKey,
            recipientPublicKeyBase64: pub.x963Representation.base64EncodedString(),
            aad: keyAAD
        )

        let chunkPlaintext = "data: hello mercury"
        let chunkCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: Data(chunkPlaintext.utf8),
            keyData: symKey,
            aad: chunkAAD
        )

        // Self-consistency: round-trip what we just emitted before
        // writing the file. Guards against accidentally pinning a
        // broken fixture.
        let unwrapped = try HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKey,
            privateKey: HermesRelayPrivateKey(rawRepresentation: priv.rawRepresentation),
            aad: keyAAD
        )
        XCTAssertEqual(unwrapped, symKey)
        let openedPlaintext = try HermesRelayCrypto.openBase64(
            ciphertext: payloadCiphertext,
            keyData: symKey,
            aad: requestAAD
        )
        XCTAssertEqual(openedPlaintext, plaintext)
        let openedChunk = try HermesRelayCrypto.openBase64(
            ciphertext: chunkCiphertext,
            keyData: symKey,
            aad: chunkAAD
        )
        XCTAssertEqual(String(data: openedChunk, encoding: .utf8), chunkPlaintext)

        let vector = WireVector(
            revision: Self.vectorRevision,
            algorithm: HermesRelayCrypto.algorithm,
            recipientPrivateKey: priv.rawRepresentation.base64EncodedString(),
            recipientPublicKey: pub.x963Representation.base64EncodedString(),
            symmetricKey: symKey.base64EncodedString(),
            uid: uid,
            connectionId: cid,
            requestId: rid,
            requestAAD: String(data: requestAAD, encoding: .utf8)!,
            keyAAD: String(data: keyAAD, encoding: .utf8)!,
            chunkAAD: String(data: chunkAAD, encoding: .utf8)!,
            chunkSequence: 0,
            chunkKind: "sse",
            plaintextPath: payload.path ?? "",
            plaintextSessionId: payload.sessionId ?? "",
            plaintextBody: payload.body ?? "",
            encodedPlaintext: plaintext.base64EncodedString(),
            payloadCiphertext: payloadCiphertext,
            wrappedKey: wrappedKey,
            chunkPlaintext: chunkPlaintext,
            chunkCiphertext: chunkCiphertext
        )

        try FileManager.default.createDirectory(
            at: Self.fixtureURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(vector)
        try data.write(to: Self.fixtureURL, options: .atomic)
    }

    // MARK: - Deterministic key generation

    private func makeDeterministicPrivateKey() throws -> P256.KeyAgreement.PrivateKey {
        // Compress: pick a fixed 32-byte scalar. P-256 private keys are
        // 1..n-1 where n is the curve order; any 32-byte value with the
        // top bit clear is comfortably in range.
        var seed = Array(repeating: UInt8(0x42), count: 32)
        seed[0] = 0x10
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(seed))
    }

    private func makeDeterministicSymmetricKey() -> Data {
        Data((0..<32).map { UInt8($0 * 7 % 251) })
    }
}

private struct WireVector: Codable {
    var revision: String
    var algorithm: String
    var recipientPrivateKey: String
    var recipientPublicKey: String
    var symmetricKey: String
    var uid: String
    var connectionId: String
    var requestId: String
    var requestAAD: String
    var keyAAD: String
    var chunkAAD: String
    var chunkSequence: Int
    var chunkKind: String
    var plaintextPath: String
    var plaintextSessionId: String
    var plaintextBody: String
    var encodedPlaintext: String
    var payloadCiphertext: String
    var wrappedKey: String
    var chunkPlaintext: String
    var chunkCiphertext: String
}
