import CryptoKit
import Foundation
import OpenBurnBarCore
import XCTest

/// Verifies the fixed Hermes relay wire vector pinned at
/// `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/HermesRelayWireVector.json`.
///
/// The Android suite (`HermesRelayWireVectorTest`) replays the same JSON
/// through the Kotlin implementation. A mismatch on either side
/// signals a wire-protocol drift between iOS / macOS and Android.
///
/// Set `OPENBURNBAR_REGENERATE_HERMES_VECTORS=1` to intentionally rewrite the
/// Swift fixtures after a contract revision bump. Normal test runs must be
/// read-only: AES-GCM nonces and the wrapping key are intentionally random.
final class HermesRelayCrossPlatformVectorTests: XCTestCase {
    /// Whenever this string changes, Android must regenerate its vendored copy
    /// by running this suite with `OPENBURNBAR_REGENERATE_HERMES_VECTORS=1`.
    private static let vectorRevision = "v1"

    /// Revision of the *gateway* wire vector (`HermesGatewayWireVector.json`).
    /// Bump whenever any gateway AAD label / envelope shape changes so the
    /// vendored Python fixture (`tests/gateway/fixtures/`) must be regenerated
    /// and the cross-language gateway test re-pins it.
    private static let gatewayVectorRevision = "v1"

    private static let fixtureURL: URL = {
        let base = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        return base.appendingPathComponent("HermesRelayWireVector.json")
    }()

    private static let gatewayFixtureURL: URL = {
        let base = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        return base.appendingPathComponent("HermesGatewayWireVector.json")
    }()

    func test_defaultHostedRelayURLString_isEmptyAfterWSSRetirement() {
        XCTAssertTrue(HermesRealtimeRelayProtocol.defaultHostedRelayURLString.isEmpty)
    }

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

        try updateOrAssertRelayFixture(vector)
    }

    // MARK: - Gateway wire vector (phone⇄agent E2E)

    /// Emits the cross-language **gateway** wire vector and pins it to
    /// `Fixtures/HermesGatewayWireVector.json`. The Python fork
    /// (`tests/gateway/test_relay_e2ee.py`) vendors this JSON byte-identical and
    /// opens it with the adapter's `_gateway_*_aad` helpers, proving iOS and the
    /// Python agent agree on every gateway AAD label — the regression gate whose
    /// absence let the payload-vs-key-wrap AAD divergence ship green.
    ///
    /// Sealed flavours (all using `HermesRelayCrypto` gateway helpers):
    ///   * phone→agent **event** — payload `gatewayEvent`, key-wrap
    ///     `gatewayEventKey`, opened with the AGENT relay private key.
    ///   * agent→phone **message** — payload `gatewayMessage`, key-wrap
    ///     `gatewayMessageKey`, opened with the PHONE relay private key.
    ///   * phone→agent **model_switch** — reuses the EVENT AADs
    ///     (`gatewayEvent` / `gatewayEventKey`) with `modelId` inside the event
    ///     payload; there is NO separate `gatewayModelSwitch` label.
    func test_emitsDeterministicGatewayVector_thatRoundTrips() throws {
        // Two recipients: the agent opens phone→agent frames; the phone opens
        // agent→phone frames. Distinct deterministic keys keep the directions
        // independent and let Python pick the right private key per flavour.
        let agentPriv = try makeDeterministicPrivateKey(tweak: 0x01)
        let agentPub = agentPriv.publicKey
        let phonePriv = try makeDeterministicPrivateKey(tweak: 0x02)
        let phonePub = phonePriv.publicKey

        let uid = "u-gateway"
        let clientId = "c-gateway"
        let eventId = "e-gateway"
        let messageId = "m-gateway"
        let modelSwitchEventId = "e-model-switch"

        // --- phone→agent EVENT -------------------------------------------------
        let eventSymKey = makeDeterministicSymmetricKey(tweak: 0x11)
        let eventPlaintext = Data(
            #"{"text":"open the BurnBar gateway","kind":"chat"}"#.utf8
        )
        let gatewayEventAAD = HermesRelayCrypto.gatewayEventAAD(
            uid: uid, clientId: clientId, eventId: eventId
        )
        let gatewayEventKeyAAD = HermesRelayCrypto.gatewayEventKeyAAD(
            uid: uid, clientId: clientId, eventId: eventId
        )
        let eventPayloadCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: eventPlaintext,
            keyData: eventSymKey,
            aad: gatewayEventAAD
        )
        let eventWrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            eventSymKey,
            recipientPublicKeyBase64: agentPub.x963Representation.base64EncodedString(),
            aad: gatewayEventKeyAAD
        )

        // --- agent→phone MESSAGE ----------------------------------------------
        let messageSymKey = makeDeterministicSymmetricKey(tweak: 0x22)
        let messagePlaintext = Data(
            #"{"text":"Hermes replied over the encrypted gateway."}"#.utf8
        )
        let gatewayMessageAAD = HermesRelayCrypto.gatewayMessageAAD(
            uid: uid, clientId: clientId, messageId: messageId
        )
        let gatewayMessageKeyAAD = HermesRelayCrypto.gatewayMessageKeyAAD(
            uid: uid, clientId: clientId, messageId: messageId
        )
        let messagePayloadCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: messagePlaintext,
            keyData: messageSymKey,
            aad: gatewayMessageAAD
        )
        let messageWrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            messageSymKey,
            recipientPublicKeyBase64: phonePub.x963Representation.base64EncodedString(),
            aad: gatewayMessageKeyAAD
        )

        // --- phone→agent model_switch (reuses the EVENT AADs) -----------------
        let modelSwitchSymKey = makeDeterministicSymmetricKey(tweak: 0x33)
        let modelSwitchPlaintext = Data(#"{"modelId":"claude-opus-4-8"}"#.utf8)
        let modelSwitchAAD = HermesRelayCrypto.gatewayEventAAD(
            uid: uid, clientId: clientId, eventId: modelSwitchEventId
        )
        let modelSwitchKeyAAD = HermesRelayCrypto.gatewayEventKeyAAD(
            uid: uid, clientId: clientId, eventId: modelSwitchEventId
        )
        let modelSwitchPayloadCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: modelSwitchPlaintext,
            keyData: modelSwitchSymKey,
            aad: modelSwitchAAD
        )
        let modelSwitchWrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            modelSwitchSymKey,
            recipientPublicKeyBase64: agentPub.x963Representation.base64EncodedString(),
            aad: modelSwitchKeyAAD
        )

        // Self-consistency: open everything we just sealed under the SAME
        // payload-vs-key AAD split before pinning the fixture. A future label
        // drift in HermesRelayCrypto fails right here, never reaching the file.
        let unwrappedEventKey = try HermesRelayCrypto.unwrapSymmetricKey(
            eventWrappedKey,
            privateKey: HermesRelayPrivateKey(rawRepresentation: agentPriv.rawRepresentation),
            aad: gatewayEventKeyAAD
        )
        XCTAssertEqual(unwrappedEventKey, eventSymKey)
        XCTAssertEqual(
            try HermesRelayCrypto.openBase64(
                ciphertext: eventPayloadCiphertext,
                keyData: eventSymKey,
                aad: gatewayEventAAD
            ),
            eventPlaintext
        )

        let unwrappedMessageKey = try HermesRelayCrypto.unwrapSymmetricKey(
            messageWrappedKey,
            privateKey: HermesRelayPrivateKey(rawRepresentation: phonePriv.rawRepresentation),
            aad: gatewayMessageKeyAAD
        )
        XCTAssertEqual(unwrappedMessageKey, messageSymKey)
        XCTAssertEqual(
            try HermesRelayCrypto.openBase64(
                ciphertext: messagePayloadCiphertext,
                keyData: messageSymKey,
                aad: gatewayMessageAAD
            ),
            messagePlaintext
        )

        let unwrappedModelSwitchKey = try HermesRelayCrypto.unwrapSymmetricKey(
            modelSwitchWrappedKey,
            privateKey: HermesRelayPrivateKey(rawRepresentation: agentPriv.rawRepresentation),
            aad: modelSwitchKeyAAD
        )
        XCTAssertEqual(unwrappedModelSwitchKey, modelSwitchSymKey)
        XCTAssertEqual(
            try HermesRelayCrypto.openBase64(
                ciphertext: modelSwitchPayloadCiphertext,
                keyData: modelSwitchSymKey,
                aad: modelSwitchAAD
            ),
            modelSwitchPlaintext
        )

        // Guard against the exact bug this gate exists to catch: payload AAD and
        // key-wrap AAD must be DISTINCT byte-strings, and unwrapping the key with
        // the payload AAD (the divergence that shipped) must fail.
        XCTAssertNotEqual(gatewayEventAAD, gatewayEventKeyAAD)
        XCTAssertNotEqual(gatewayMessageAAD, gatewayMessageKeyAAD)
        XCTAssertThrowsError(
            try HermesRelayCrypto.unwrapSymmetricKey(
                eventWrappedKey,
                privateKey: HermesRelayPrivateKey(rawRepresentation: agentPriv.rawRepresentation),
                aad: gatewayEventAAD  // WRONG: payload AAD instead of the key AAD
            )
        )

        let event = GatewayEventVector(
            uid: uid,
            clientId: clientId,
            eventId: eventId,
            recipientPrivateKey: agentPriv.rawRepresentation.base64EncodedString(),
            recipientPublicKey: agentPub.x963Representation.base64EncodedString(),
            symmetricKey: eventSymKey.base64EncodedString(),
            payloadAAD: String(data: gatewayEventAAD, encoding: .utf8)!,
            keyAAD: String(data: gatewayEventKeyAAD, encoding: .utf8)!,
            plaintext: String(data: eventPlaintext, encoding: .utf8)!,
            encodedPlaintext: eventPlaintext.base64EncodedString(),
            payloadCiphertext: eventPayloadCiphertext,
            wrappedKey: eventWrappedKey
        )

        let message = GatewayMessageVector(
            uid: uid,
            clientId: clientId,
            messageId: messageId,
            recipientPrivateKey: phonePriv.rawRepresentation.base64EncodedString(),
            recipientPublicKey: phonePub.x963Representation.base64EncodedString(),
            symmetricKey: messageSymKey.base64EncodedString(),
            payloadAAD: String(data: gatewayMessageAAD, encoding: .utf8)!,
            keyAAD: String(data: gatewayMessageKeyAAD, encoding: .utf8)!,
            plaintext: String(data: messagePlaintext, encoding: .utf8)!,
            encodedPlaintext: messagePlaintext.base64EncodedString(),
            payloadCiphertext: messagePayloadCiphertext,
            wrappedKey: messageWrappedKey
        )

        let modelSwitch = GatewayEventVector(
            uid: uid,
            clientId: clientId,
            eventId: modelSwitchEventId,
            recipientPrivateKey: agentPriv.rawRepresentation.base64EncodedString(),
            recipientPublicKey: agentPub.x963Representation.base64EncodedString(),
            symmetricKey: modelSwitchSymKey.base64EncodedString(),
            payloadAAD: String(data: modelSwitchAAD, encoding: .utf8)!,
            keyAAD: String(data: modelSwitchKeyAAD, encoding: .utf8)!,
            plaintext: String(data: modelSwitchPlaintext, encoding: .utf8)!,
            encodedPlaintext: modelSwitchPlaintext.base64EncodedString(),
            payloadCiphertext: modelSwitchPayloadCiphertext,
            wrappedKey: modelSwitchWrappedKey
        )

        let vector = GatewayWireVector(
            revision: Self.gatewayVectorRevision,
            algorithm: HermesRelayCrypto.algorithm,
            keyVersion: HermesRelayCrypto.keyVersion,
            event: event,
            message: message,
            modelSwitch: modelSwitch
        )

        try updateOrAssertGatewayFixture(vector)
    }

    /// The gateway AAD labels are the cross-language contract: this asserts the
    /// exact byte-strings so a rename in `HermesRelayCrypto` fails here and is
    /// caught before the vendored Python fixture can silently drift.
    func test_gatewayAADLabels_areTheLockedContract() {
        XCTAssertEqual(
            String(data: HermesRelayCrypto.gatewayEventAAD(uid: "u", clientId: "c", eventId: "e"), encoding: .utf8),
            "OpenBurnBar-HermesRelay-v1|gatewayEvent|u|c|e"
        )
        XCTAssertEqual(
            String(data: HermesRelayCrypto.gatewayEventKeyAAD(uid: "u", clientId: "c", eventId: "e"), encoding: .utf8),
            "OpenBurnBar-HermesRelay-v1|gatewayEventKey|u|c|e"
        )
        XCTAssertEqual(
            String(data: HermesRelayCrypto.gatewayMessageAAD(uid: "u", clientId: "c", messageId: "m"), encoding: .utf8),
            "OpenBurnBar-HermesRelay-v1|gatewayMessage|u|c|m"
        )
        XCTAssertEqual(
            String(data: HermesRelayCrypto.gatewayMessageKeyAAD(uid: "u", clientId: "c", messageId: "m"), encoding: .utf8),
            "OpenBurnBar-HermesRelay-v1|gatewayMessageKey|u|c|m"
        )
    }

    // MARK: - Fixture assertion / regeneration

    private static var shouldRegenerateFixtures: Bool {
        guard let value = ProcessInfo.processInfo.environment["OPENBURNBAR_REGENERATE_HERMES_VECTORS"] else {
            return false
        }
        return ["1", "true", "yes"].contains(value.lowercased())
    }

    private func updateOrAssertRelayFixture(_ vector: WireVector) throws {
        let data = try Self.encodeFixture(vector)
        if Self.shouldRegenerateFixtures {
            try Self.writeFixture(data, to: Self.fixtureURL)
            return
        }

        let fixture = try JSONDecoder().decode(WireVector.self, from: Data(contentsOf: Self.fixtureURL))
        assertRelayStableFields(fixture, match: vector)
        try assertRelayVectorRoundTrips(fixture)
    }

    private func updateOrAssertGatewayFixture(_ vector: GatewayWireVector) throws {
        let data = try Self.encodeFixture(vector)
        if Self.shouldRegenerateFixtures {
            try Self.writeFixture(data, to: Self.gatewayFixtureURL)
            return
        }

        let fixture = try JSONDecoder().decode(GatewayWireVector.self, from: Data(contentsOf: Self.gatewayFixtureURL))
        assertGatewayStableFields(fixture, match: vector)
        try assertGatewayVectorRoundTrips(fixture)
    }

    private static func encodeFixture<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private static func writeFixture(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func assertRelayStableFields(_ fixture: WireVector, match expected: WireVector) {
        XCTAssertEqual(fixture.revision, expected.revision)
        XCTAssertEqual(fixture.algorithm, expected.algorithm)
        XCTAssertEqual(fixture.recipientPrivateKey, expected.recipientPrivateKey)
        XCTAssertEqual(fixture.recipientPublicKey, expected.recipientPublicKey)
        XCTAssertEqual(fixture.symmetricKey, expected.symmetricKey)
        XCTAssertEqual(fixture.uid, expected.uid)
        XCTAssertEqual(fixture.connectionId, expected.connectionId)
        XCTAssertEqual(fixture.requestId, expected.requestId)
        XCTAssertEqual(fixture.requestAAD, expected.requestAAD)
        XCTAssertEqual(fixture.keyAAD, expected.keyAAD)
        XCTAssertEqual(fixture.chunkAAD, expected.chunkAAD)
        XCTAssertEqual(fixture.chunkSequence, expected.chunkSequence)
        XCTAssertEqual(fixture.chunkKind, expected.chunkKind)
        XCTAssertEqual(fixture.plaintextPath, expected.plaintextPath)
        XCTAssertEqual(fixture.plaintextSessionId, expected.plaintextSessionId)
        XCTAssertEqual(fixture.plaintextBody, expected.plaintextBody)
        XCTAssertEqual(fixture.chunkPlaintext, expected.chunkPlaintext)
    }

    private func assertRelayVectorRoundTrips(_ vector: WireVector) throws {
        XCTAssertEqual(vector.requestAAD, String(data: HermesRelayCrypto.requestAAD(
            uid: vector.uid,
            connectionID: vector.connectionId,
            requestID: vector.requestId
        ), encoding: .utf8))
        XCTAssertEqual(vector.keyAAD, String(data: HermesRelayCrypto.keyAAD(
            uid: vector.uid,
            connectionID: vector.connectionId,
            requestID: vector.requestId
        ), encoding: .utf8))
        XCTAssertEqual(vector.chunkAAD, String(data: HermesRelayCrypto.chunkAAD(
            uid: vector.uid,
            connectionID: vector.connectionId,
            requestID: vector.requestId,
            sequence: vector.chunkSequence,
            kind: vector.chunkKind
        ), encoding: .utf8))

        let privateKeyData = try XCTUnwrap(Data(base64Encoded: vector.recipientPrivateKey))
        let symmetricKey = try XCTUnwrap(Data(base64Encoded: vector.symmetricKey))
        let unwrapped = try HermesRelayCrypto.unwrapSymmetricKey(
            vector.wrappedKey,
            privateKey: HermesRelayPrivateKey(rawRepresentation: privateKeyData),
            aad: Data(vector.keyAAD.utf8)
        )
        XCTAssertEqual(unwrapped, symmetricKey)

        let openedPlaintext = try HermesRelayCrypto.openBase64(
            ciphertext: vector.payloadCiphertext,
            keyData: symmetricKey,
            aad: Data(vector.requestAAD.utf8)
        )
        XCTAssertEqual(openedPlaintext.base64EncodedString(), vector.encodedPlaintext)
        let payload = try JSONDecoder().decode(HermesRelayEncryptedRequestPayload.self, from: openedPlaintext)
        XCTAssertEqual(payload.path, vector.plaintextPath)
        XCTAssertEqual(payload.sessionId, vector.plaintextSessionId)
        XCTAssertEqual(payload.body, vector.plaintextBody)

        let openedChunk = try HermesRelayCrypto.openBase64(
            ciphertext: vector.chunkCiphertext,
            keyData: symmetricKey,
            aad: Data(vector.chunkAAD.utf8)
        )
        XCTAssertEqual(String(data: openedChunk, encoding: .utf8), vector.chunkPlaintext)
    }

    private func assertGatewayStableFields(_ fixture: GatewayWireVector, match expected: GatewayWireVector) {
        XCTAssertEqual(fixture.revision, expected.revision)
        XCTAssertEqual(fixture.algorithm, expected.algorithm)
        XCTAssertEqual(fixture.keyVersion, expected.keyVersion)
        assertGatewayEventStableFields(fixture.event, match: expected.event)
        assertGatewayMessageStableFields(fixture.message, match: expected.message)
        assertGatewayEventStableFields(fixture.modelSwitch, match: expected.modelSwitch)
    }

    private func assertGatewayEventStableFields(_ fixture: GatewayEventVector, match expected: GatewayEventVector) {
        XCTAssertEqual(fixture.uid, expected.uid)
        XCTAssertEqual(fixture.clientId, expected.clientId)
        XCTAssertEqual(fixture.eventId, expected.eventId)
        XCTAssertEqual(fixture.recipientPrivateKey, expected.recipientPrivateKey)
        XCTAssertEqual(fixture.recipientPublicKey, expected.recipientPublicKey)
        XCTAssertEqual(fixture.symmetricKey, expected.symmetricKey)
        XCTAssertEqual(fixture.payloadAAD, expected.payloadAAD)
        XCTAssertEqual(fixture.keyAAD, expected.keyAAD)
        XCTAssertEqual(fixture.plaintext, expected.plaintext)
        XCTAssertEqual(fixture.encodedPlaintext, expected.encodedPlaintext)
    }

    private func assertGatewayMessageStableFields(_ fixture: GatewayMessageVector, match expected: GatewayMessageVector) {
        XCTAssertEqual(fixture.uid, expected.uid)
        XCTAssertEqual(fixture.clientId, expected.clientId)
        XCTAssertEqual(fixture.messageId, expected.messageId)
        XCTAssertEqual(fixture.recipientPrivateKey, expected.recipientPrivateKey)
        XCTAssertEqual(fixture.recipientPublicKey, expected.recipientPublicKey)
        XCTAssertEqual(fixture.symmetricKey, expected.symmetricKey)
        XCTAssertEqual(fixture.payloadAAD, expected.payloadAAD)
        XCTAssertEqual(fixture.keyAAD, expected.keyAAD)
        XCTAssertEqual(fixture.plaintext, expected.plaintext)
        XCTAssertEqual(fixture.encodedPlaintext, expected.encodedPlaintext)
    }

    private func assertGatewayVectorRoundTrips(_ vector: GatewayWireVector) throws {
        XCTAssertEqual(vector.revision, Self.gatewayVectorRevision)
        XCTAssertEqual(vector.algorithm, HermesRelayCrypto.algorithm)
        XCTAssertEqual(vector.keyVersion, HermesRelayCrypto.keyVersion)

        try assertGatewayEventVectorRoundTrips(
            vector.event,
            expectedPayloadAAD: HermesRelayCrypto.gatewayEventAAD(
                uid: vector.event.uid,
                clientId: vector.event.clientId,
                eventId: vector.event.eventId
            ),
            expectedKeyAAD: HermesRelayCrypto.gatewayEventKeyAAD(
                uid: vector.event.uid,
                clientId: vector.event.clientId,
                eventId: vector.event.eventId
            )
        )
        try assertGatewayMessageVectorRoundTrips(
            vector.message,
            expectedPayloadAAD: HermesRelayCrypto.gatewayMessageAAD(
                uid: vector.message.uid,
                clientId: vector.message.clientId,
                messageId: vector.message.messageId
            ),
            expectedKeyAAD: HermesRelayCrypto.gatewayMessageKeyAAD(
                uid: vector.message.uid,
                clientId: vector.message.clientId,
                messageId: vector.message.messageId
            )
        )
        try assertGatewayEventVectorRoundTrips(
            vector.modelSwitch,
            expectedPayloadAAD: HermesRelayCrypto.gatewayEventAAD(
                uid: vector.modelSwitch.uid,
                clientId: vector.modelSwitch.clientId,
                eventId: vector.modelSwitch.eventId
            ),
            expectedKeyAAD: HermesRelayCrypto.gatewayEventKeyAAD(
                uid: vector.modelSwitch.uid,
                clientId: vector.modelSwitch.clientId,
                eventId: vector.modelSwitch.eventId
            )
        )

        let eventPrivateKeyData = try XCTUnwrap(Data(base64Encoded: vector.event.recipientPrivateKey))
        let eventPrivateKey = try HermesRelayPrivateKey(rawRepresentation: eventPrivateKeyData)
        XCTAssertNotEqual(vector.event.payloadAAD, vector.event.keyAAD)
        XCTAssertNotEqual(vector.message.payloadAAD, vector.message.keyAAD)
        XCTAssertThrowsError(
            try HermesRelayCrypto.unwrapSymmetricKey(
                vector.event.wrappedKey,
                privateKey: eventPrivateKey,
                aad: Data(vector.event.payloadAAD.utf8)
            )
        )
    }

    private func assertGatewayEventVectorRoundTrips(
        _ vector: GatewayEventVector,
        expectedPayloadAAD: Data,
        expectedKeyAAD: Data
    ) throws {
        XCTAssertEqual(vector.payloadAAD, String(data: expectedPayloadAAD, encoding: .utf8))
        XCTAssertEqual(vector.keyAAD, String(data: expectedKeyAAD, encoding: .utf8))

        let privateKeyData = try XCTUnwrap(Data(base64Encoded: vector.recipientPrivateKey))
        let symmetricKey = try XCTUnwrap(Data(base64Encoded: vector.symmetricKey))
        let unwrapped = try HermesRelayCrypto.unwrapSymmetricKey(
            vector.wrappedKey,
            privateKey: HermesRelayPrivateKey(rawRepresentation: privateKeyData),
            aad: expectedKeyAAD
        )
        XCTAssertEqual(unwrapped, symmetricKey)

        let opened = try HermesRelayCrypto.openBase64(
            ciphertext: vector.payloadCiphertext,
            keyData: symmetricKey,
            aad: expectedPayloadAAD
        )
        XCTAssertEqual(opened.base64EncodedString(), vector.encodedPlaintext)
        XCTAssertEqual(String(data: opened, encoding: .utf8), vector.plaintext)
    }

    private func assertGatewayMessageVectorRoundTrips(
        _ vector: GatewayMessageVector,
        expectedPayloadAAD: Data,
        expectedKeyAAD: Data
    ) throws {
        XCTAssertEqual(vector.payloadAAD, String(data: expectedPayloadAAD, encoding: .utf8))
        XCTAssertEqual(vector.keyAAD, String(data: expectedKeyAAD, encoding: .utf8))

        let privateKeyData = try XCTUnwrap(Data(base64Encoded: vector.recipientPrivateKey))
        let symmetricKey = try XCTUnwrap(Data(base64Encoded: vector.symmetricKey))
        let unwrapped = try HermesRelayCrypto.unwrapSymmetricKey(
            vector.wrappedKey,
            privateKey: HermesRelayPrivateKey(rawRepresentation: privateKeyData),
            aad: expectedKeyAAD
        )
        XCTAssertEqual(unwrapped, symmetricKey)

        let opened = try HermesRelayCrypto.openBase64(
            ciphertext: vector.payloadCiphertext,
            keyData: symmetricKey,
            aad: expectedPayloadAAD
        )
        XCTAssertEqual(opened.base64EncodedString(), vector.encodedPlaintext)
        XCTAssertEqual(String(data: opened, encoding: .utf8), vector.plaintext)
    }

    // MARK: - Deterministic key generation

    private func makeDeterministicPrivateKey(tweak: UInt8 = 0) throws -> P256.KeyAgreement.PrivateKey {
        // Compress: pick a fixed 32-byte scalar. P-256 private keys are
        // 1..n-1 where n is the curve order; any 32-byte value with the
        // top bit clear is comfortably in range. ``tweak`` perturbs the low
        // byte so the gateway vector can derive several independent recipients
        // (e.g. the agent key vs the phone key) deterministically.
        var seed = Array(repeating: UInt8(0x42), count: 32)
        seed[0] = 0x10
        seed[31] = tweak
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(seed))
    }

    private func makeDeterministicSymmetricKey(tweak: UInt8 = 0) -> Data {
        Data((0..<32).map { UInt8((Int($0) * 7 + Int(tweak)) % 251) })
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

// MARK: - Gateway wire vector shapes

/// One sealed phone→agent gateway event (or model_switch, which reuses the
/// event AADs). ``recipientPrivateKey`` is the AGENT relay key that unwraps
/// ``wrappedKey``; ``keyAAD`` is the distinct `gatewayEventKey` AAD and
/// ``payloadAAD`` the `gatewayEvent` AAD.
private struct GatewayEventVector: Codable {
    var uid: String
    var clientId: String
    var eventId: String
    var recipientPrivateKey: String
    var recipientPublicKey: String
    var symmetricKey: String
    var payloadAAD: String
    var keyAAD: String
    var plaintext: String
    var encodedPlaintext: String
    var payloadCiphertext: String
    var wrappedKey: String
}

/// One sealed agent→phone gateway message. ``recipientPrivateKey`` is the
/// PHONE relay key that unwraps ``wrappedKey``; ``keyAAD`` is the distinct
/// `gatewayMessageKey` AAD and ``payloadAAD`` the `gatewayMessage` AAD.
private struct GatewayMessageVector: Codable {
    var uid: String
    var clientId: String
    var messageId: String
    var recipientPrivateKey: String
    var recipientPublicKey: String
    var symmetricKey: String
    var payloadAAD: String
    var keyAAD: String
    var plaintext: String
    var encodedPlaintext: String
    var payloadCiphertext: String
    var wrappedKey: String
}

private struct GatewayWireVector: Codable {
    var revision: String
    var algorithm: String
    var keyVersion: Int
    var event: GatewayEventVector
    var message: GatewayMessageVector
    var modelSwitch: GatewayEventVector
}
