import CryptoKit
import Foundation
import OpenBurnBarCore
import XCTest

/// Cross-language proof for the RFC 9180 **HPKE Auth mode v3** relay key wrap
/// (`HermesRelayCrypto.sealKeyV3` / `openKeyV3`).
///
/// The v3 migration replaces the bespoke v2 2-DH key wrap with standards-shaped
/// RFC 9180 HPKE Auth mode (DHKEM(P-256, HKDF-SHA256) / HKDF-SHA256 /
/// AES-256-GCM). The payload + attachment AES-GCM sealing layers are unchanged;
/// only the content-key wrap moves to HPKE, and the encapsulated key `enc`
/// becomes a distinct envelope field.
///
/// This suite is **self-contained**: `test_hpkeV3_roundTripsEveryVector...`
/// builds every positive + negative vector in memory and proves the Swift seal
/// AND open paths without depending on any committed fixture, so it is the
/// authoritative "Swift unit tests pass" gate.
///
/// `test_emitsHPKEv3Vector_forCrossLanguageHandoff` builds the full vector set
/// and round-trips it, but only **writes** JSON when the dedicated
/// `OPENBURNBAR_EMIT_HPKE_V3_FIXTURE=1` flag is set (NOT the shared vector-regen
/// flag, so a routine v1/v2 regen never emits a stray v3 file). It writes a
/// Swift-sealed re-vendor sample to `Fixtures/BurnBarHpkeV3Vector.swift-emitted.json`
/// by default, redirectable with `OPENBURNBAR_HPKE_V3_FIXTURE_OUT=<path>` (e.g.
/// to `/tmp`). The canonical cross-language fixture `Fixtures/BurnBarHpkeV3Vector.json`
/// is owned by the vector lane and consumed by `BurnBarHpkeV3CrossPlatformVectorTests`;
/// this emitter never overwrites it.
final class HermesRelayHPKEv3VectorTests: XCTestCase {
    /// Revision of the HPKE v3 vector. Bump alongside any change to the v3 wire
    /// contract (suite, `info`, AAD inputs, envelope field names).
    private static let revision = "v3"

    // MARK: - Frozen contract

    func test_hpkeV3_constants_areTheFrozenContract() {
        XCTAssertEqual(HermesRelayCrypto.gatewayRelayKeyVersionV3, 3)
        XCTAssertEqual(
            HermesRelayCrypto.relayEncryptionV3,
            "hpke-auth-p256-hkdfsha256-aes256gcm"
        )
        // The unchanged payload/attachment AES-GCM layer keeps the v2 algorithm tag.
        XCTAssertEqual(HermesRelayCrypto.algorithm, "p256-hkdf-sha256-aesgcm")
        // v3 is a distinct, higher version than the gateway v2 wrap.
        XCTAssertGreaterThan(
            HermesRelayCrypto.gatewayRelayKeyVersionV3,
            HermesRelayCrypto.gatewayRelayKeyVersion
        )
    }

    // MARK: - Core self-contained proof

    /// Seal every flavour with v3 HPKE Auth, open it back binding the PINNED
    /// sender key (proving the content key + every AES-GCM payload slot), and
    /// prove each negative mutation fails. No committed fixture is read, so this
    /// passes on a clean checkout.
    func test_hpkeV3_roundTripsEveryVector_andRejectsEveryNegative() throws {
        let built = try Self.buildVectorSet()

        // --- positives: open the wrap, then open the payload slot ----------
        for positive in built.fixture.positives {
            let recipientPriv = try HermesRelayPrivateKey(
                rawRepresentation: try XCTUnwrap(Data(base64Encoded: positive.recipientPrivateKey))
            )
            let expectedContentKey = try XCTUnwrap(Data(base64Encoded: positive.contentKey))

            let openedKey = try HermesRelayCrypto.openKeyV3(
                encBase64: positive.enc,
                wrappedKeyBase64: positive.wrappedKey,
                privateKey: recipientPriv,
                pinnedSenderPublicKeyBase64: positive.senderPublicKey,
                aad: Data(positive.keyAAD.utf8)
            )
            XCTAssertEqual(
                openedKey, expectedContentKey,
                "v3 key unwrap mismatch for \(positive.name)"
            )

            let openedPayload = try HermesRelayCrypto.openBase64(
                ciphertext: positive.payloadCiphertext,
                keyData: openedKey,
                aad: Data(positive.payloadAAD.utf8)
            )
            XCTAssertEqual(
                String(data: openedPayload, encoding: .utf8), positive.plaintext,
                "v3 payload open mismatch for \(positive.name)"
            )
            XCTAssertEqual(
                openedPayload.base64EncodedString(), positive.encodedPlaintext,
                "v3 encodedPlaintext mismatch for \(positive.name)"
            )

            // The full HPKE `info` is the prefix concatenated with the key AAD.
            XCTAssertEqual(
                positive.info,
                "OpenBurnBar-HermesRelay-HPKE-v3|" + positive.keyAAD
            )
        }

        // The attachment manifest + body share ONE v3-wrapped body key but open
        // under DISTINCT payload AADs — assert that explicitly.
        let manifest = try XCTUnwrap(built.fixture.positives.first { $0.name == "attachmentManifest" })
        let body = try XCTUnwrap(built.fixture.positives.first { $0.name == "attachmentBodyKey" })
        XCTAssertEqual(manifest.enc, body.enc)
        XCTAssertEqual(manifest.wrappedKey, body.wrappedKey)
        XCTAssertEqual(manifest.contentKey, body.contentKey)
        XCTAssertNotEqual(manifest.payloadAAD, body.payloadAAD)

        // --- negatives: each mutates exactly one authenticated input -------
        for negative in built.fixture.negatives {
            let recipientPriv = try HermesRelayPrivateKey(
                rawRepresentation: try XCTUnwrap(Data(base64Encoded: negative.recipientPrivateKey))
            )
            XCTAssertThrowsError(
                try HermesRelayCrypto.openKeyV3(
                    encBase64: negative.enc,
                    wrappedKeyBase64: negative.wrappedKey,
                    privateKey: recipientPriv,
                    pinnedSenderPublicKeyBase64: negative.pinnedSenderPublicKey,
                    aad: Data(negative.keyAAD.utf8)
                ),
                "negative vector \(negative.name) must fail to open"
            )
        }

        // --- extra adversarial checks not pinned in the fixture ------------
        let event = try XCTUnwrap(built.fixture.positives.first { $0.name == "event" })
        let agentPriv = try HermesRelayPrivateKey(
            rawRepresentation: try XCTUnwrap(Data(base64Encoded: event.recipientPrivateKey))
        )
        let phonePriv = try HermesRelayPrivateKey(
            rawRepresentation: try XCTUnwrap(Data(base64Encoded: built.phoneSenderPrivateKeyBase64))
        )

        // Wrong RECIPIENT key (the phone trying to open an agent-bound wrap) fails.
        XCTAssertThrowsError(
            try HermesRelayCrypto.openKeyV3(
                encBase64: event.enc,
                wrappedKeyBase64: event.wrappedKey,
                privateKey: phonePriv,
                pinnedSenderPublicKeyBase64: event.senderPublicKey,
                aad: Data(event.keyAAD.utf8)
            )
        )

        // Valid-but-WRONG enc: swap in a fresh, on-curve P-256 point. Unlike the
        // fixture's `mutatedEnc` (a single-byte flip, which never lands on a valid
        // P-256 point and so is refused at point validation), this exercises the
        // AUTHENTICATED enc binding: `enc` is folded into the HPKE `kem_context`,
        // so a valid but unrelated encapsulated key derives the wrong shared
        // secret and the open fails the AEAD tag.
        let strangerEnc = P256.KeyAgreement.PrivateKey().publicKey
            .x963Representation.base64EncodedString()
        XCTAssertThrowsError(
            try HermesRelayCrypto.openKeyV3(
                encBase64: strangerEnc,
                wrappedKeyBase64: event.wrappedKey,
                privateKey: agentPriv,
                pinnedSenderPublicKeyBase64: event.senderPublicKey,
                aad: Data(event.keyAAD.utf8)
            )
        )

        // Domain separation: a v3 wrap is NOT a v2 envelope. Feeding the v3
        // `enc ‖ wrappedKey` (concatenated, as v2 lays it out) into the v2
        // authenticated unwrap must fail — the constructions are incompatible.
        let v2Style = (Data(base64Encoded: event.enc)! + Data(base64Encoded: event.wrappedKey)!)
            .base64EncodedString()
        XCTAssertThrowsError(
            try HermesRelayCrypto.unwrapSymmetricKey(
                v2Style,
                privateKey: agentPriv,
                aad: Data(event.keyAAD.utf8),
                senderPublicKeyBase64: event.senderPublicKey
            )
        )
    }

    // MARK: - Cross-language fixture emission (handoff)

    func test_emitsHPKEv3Vector_forCrossLanguageHandoff() throws {
        let built = try Self.buildVectorSet()

        // Self-consistency: round-trip the freshly built fixture before it could
        // ever be written, so a broken vector is never emitted.
        for positive in built.fixture.positives {
            let recipientPriv = try HermesRelayPrivateKey(
                rawRepresentation: try XCTUnwrap(Data(base64Encoded: positive.recipientPrivateKey))
            )
            let key = try HermesRelayCrypto.openKeyV3(
                encBase64: positive.enc,
                wrappedKeyBase64: positive.wrappedKey,
                privateKey: recipientPriv,
                pinnedSenderPublicKeyBase64: positive.senderPublicKey,
                aad: Data(positive.keyAAD.utf8)
            )
            XCTAssertEqual(key.base64EncodedString(), positive.contentKey)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(built.fixture)

        guard Self.shouldEmitFixture else {
            // Default runs are read-only and write no fixture — the vector lane
            // owns the canonical BurnBarHpkeV3Vector.json. This emitter only
            // produces a Swift-sealed re-vendor sample on explicit request.
            return
        }
        let outURL = Self.fixtureOutputURL
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outURL, options: .atomic)
    }

    // MARK: - Vector construction

    private struct BuiltVectors {
        var fixture: HPKEv3Fixture
        var phoneSenderPrivateKeyBase64: String
    }

    private static func buildVectorSet() throws -> BuiltVectors {
        let agentPriv = try deterministicPrivateKey(tweak: 0x01)   // recipient of phone→agent
        let phonePriv = try deterministicPrivateKey(tweak: 0x02)   // recipient of agent→phone
        let agentRelayPriv = try HermesRelayPrivateKey(rawRepresentation: agentPriv.rawRepresentation)
        let phoneRelayPriv = try HermesRelayPrivateKey(rawRepresentation: phonePriv.rawRepresentation)
        let agentPubB64 = agentPriv.publicKey.x963Representation.base64EncodedString()
        let phonePubB64 = phonePriv.publicKey.x963Representation.base64EncodedString()

        let uid = "u-gateway"
        let clientId = "c-gateway"
        let eventId = "e-gateway"
        let messageId = "m-gateway"
        let modelSwitchEventId = "e-model-switch"
        let attachmentId = "a-gateway"

        var positives: [HPKEv3Positive] = []

        // --- event: phone → agent -----------------------------------------
        let eventSymKey = deterministicSymmetricKey(tweak: 0x11)
        let eventPlaintext = #"{"text":"open the BurnBar gateway","kind":"chat","destinationId":"burnbar:home","replayCounter":1}"#
        positives.append(try makePositive(
            name: "event", direction: "phone->agent",
            uid: uid, clientId: clientId, id: eventId,
            recipientPriv: agentPriv, recipientPubB64: agentPubB64,
            senderPriv: phoneRelayPriv, senderPubB64: phonePubB64,
            contentKey: eventSymKey,
            keyAAD: HermesRelayCrypto.gatewayEventKeyAAD(uid: uid, clientId: clientId, eventId: eventId),
            payloadAAD: HermesRelayCrypto.gatewayEventAAD(uid: uid, clientId: clientId, eventId: eventId),
            plaintext: eventPlaintext
        ))

        // --- message / reply: agent → phone -------------------------------
        let messageSymKey = deterministicSymmetricKey(tweak: 0x22)
        let messagePlaintext = #"{"text":"Hermes replied over the encrypted gateway.","destinationId":"burnbar:home"}"#
        positives.append(try makePositive(
            name: "message", direction: "agent->phone",
            uid: uid, clientId: clientId, id: messageId,
            recipientPriv: phonePriv, recipientPubB64: phonePubB64,
            senderPriv: agentRelayPriv, senderPubB64: agentPubB64,
            contentKey: messageSymKey,
            keyAAD: HermesRelayCrypto.gatewayMessageKeyAAD(uid: uid, clientId: clientId, messageId: messageId),
            payloadAAD: HermesRelayCrypto.gatewayMessageAAD(uid: uid, clientId: clientId, messageId: messageId),
            plaintext: messagePlaintext
        ))

        // --- model switch: phone → agent (reuses the EVENT AADs) ----------
        let modelSwitchSymKey = deterministicSymmetricKey(tweak: 0x33)
        let modelSwitchPlaintext = #"{"kind":"model_switch","modelId":"claude-opus-4-8","destinationId":"burnbar:home","replayCounter":2}"#
        positives.append(try makePositive(
            name: "modelSwitch", direction: "phone->agent",
            uid: uid, clientId: clientId, id: modelSwitchEventId,
            recipientPriv: agentPriv, recipientPubB64: agentPubB64,
            senderPriv: phoneRelayPriv, senderPubB64: phonePubB64,
            contentKey: modelSwitchSymKey,
            keyAAD: HermesRelayCrypto.gatewayEventKeyAAD(uid: uid, clientId: clientId, eventId: modelSwitchEventId),
            payloadAAD: HermesRelayCrypto.gatewayEventAAD(uid: uid, clientId: clientId, eventId: modelSwitchEventId),
            plaintext: modelSwitchPlaintext
        ))

        // --- attachment: agent → phone ------------------------------------
        // One body key is v3-wrapped ONCE (under the attachment-key AAD) and
        // seals BOTH the manifest and the body under DISTINCT payload AADs. The
        // manifest + body-key positives therefore share enc/wrappedKey/contentKey
        // and differ only in the payload slot they open.
        let attachmentBodyKey = deterministicSymmetricKey(tweak: 0x44)
        let attachmentKeyAAD = HermesRelayCrypto.gatewayAttachmentKeyAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        let attachmentWrap = try HermesRelayCrypto.sealKeyV3(
            attachmentBodyKey,
            recipientPublicKeyBase64: phonePubB64,
            senderPrivateKey: agentRelayPriv,
            aad: attachmentKeyAAD
        )
        let manifestPlaintext = #"{"fileName":"quarterly-report.pdf","contentType":"application/pdf","byteCount":20,"destinationId":"burnbar:home"}"#
        let manifestAAD = HermesRelayCrypto.gatewayAttachmentManifestAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        positives.append(try makePositive(
            name: "attachmentManifest", direction: "agent->phone",
            uid: uid, clientId: clientId, id: attachmentId,
            recipientPubB64: phonePubB64, recipientPriv: phonePriv,
            senderPubB64: agentPubB64,
            contentKey: attachmentBodyKey, wrap: attachmentWrap,
            keyAAD: attachmentKeyAAD,
            payloadAAD: manifestAAD, plaintext: manifestPlaintext
        ))
        let bodyPlaintext = "PDF-BYTES-1234567890"
        let bodyAAD = HermesRelayCrypto.gatewayAttachmentBodyAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        positives.append(try makePositive(
            name: "attachmentBodyKey", direction: "agent->phone",
            uid: uid, clientId: clientId, id: attachmentId,
            recipientPubB64: phonePubB64, recipientPriv: phonePriv,
            senderPubB64: agentPubB64,
            contentKey: attachmentBodyKey, wrap: attachmentWrap,
            keyAAD: attachmentKeyAAD,
            payloadAAD: bodyAAD, plaintext: bodyPlaintext
        ))

        // --- negatives: each mutates exactly one authenticated input -------
        let event = positives[0]
        let negatives: [HPKEv3Negative] = [
            HPKEv3Negative(
                name: "wrongPinnedSender",
                base: "event",
                mutation: "open binds the agent's own key as the pinned sender instead of the phone",
                recipientPrivateKey: event.recipientPrivateKey,
                pinnedSenderPublicKey: agentPubB64,   // WRONG: must be the phone's key
                keyAAD: event.keyAAD,
                enc: event.enc,
                wrappedKey: event.wrappedKey,
                expect: "open-fails"
            ),
            HPKEv3Negative(
                name: "wrongAAD",
                base: "event",
                mutation: "open passes a key_aad for a different eventId (e-tampered)",
                recipientPrivateKey: event.recipientPrivateKey,
                pinnedSenderPublicKey: phonePubB64,
                keyAAD: String(
                    data: HermesRelayCrypto.gatewayEventKeyAAD(uid: uid, clientId: clientId, eventId: "e-tampered"),
                    encoding: .utf8
                )!,
                enc: event.enc,
                wrappedKey: event.wrappedKey,
                expect: "open-fails"
            ),
            HPKEv3Negative(
                name: "mutatedEnc",
                base: "event",
                mutation: "one byte of the HPKE encapsulated key is flipped",
                recipientPrivateKey: event.recipientPrivateKey,
                pinnedSenderPublicKey: phonePubB64,
                keyAAD: event.keyAAD,
                enc: mutatingLastByte(ofBase64: event.enc),
                wrappedKey: event.wrappedKey,
                expect: "open-fails"
            ),
            HPKEv3Negative(
                name: "mutatedWrappedKey",
                base: "event",
                mutation: "one byte of the HPKE ciphertext is flipped",
                recipientPrivateKey: event.recipientPrivateKey,
                pinnedSenderPublicKey: phonePubB64,
                keyAAD: event.keyAAD,
                enc: event.enc,
                wrappedKey: mutatingLastByte(ofBase64: event.wrappedKey),
                expect: "open-fails"
            )
        ]

        let fixture = HPKEv3Fixture(
            revision: revision,
            algorithm: HermesRelayCrypto.algorithm,
            relayEncryption: HermesRelayCrypto.relayEncryptionV3,
            relayKeyVersion: HermesRelayCrypto.gatewayRelayKeyVersionV3,
            suite: "DHKEM(P-256, HKDF-SHA256) / HKDF-SHA256 / AES-256-GCM",
            hpkeMode: "auth",
            infoPrefix: "OpenBurnBar-HermesRelay-HPKE-v3|",
            agentRecipientPrivateKey: agentPriv.rawRepresentation.base64EncodedString(),
            agentRecipientPublicKey: agentPubB64,
            phoneSenderPrivateKey: phonePriv.rawRepresentation.base64EncodedString(),
            phoneSenderPublicKey: phonePubB64,
            positives: positives,
            negatives: negatives
        )
        return BuiltVectors(fixture: fixture, phoneSenderPrivateKeyBase64: phonePriv.rawRepresentation.base64EncodedString())
    }

    /// Build a positive vector by sealing the content key with v3 HPKE Auth and
    /// sealing the payload with the unchanged AES-GCM layer.
    private static func makePositive(
        name: String, direction: String,
        uid: String, clientId: String, id: String,
        recipientPriv: P256.KeyAgreement.PrivateKey, recipientPubB64: String,
        senderPriv: HermesRelayPrivateKey, senderPubB64: String,
        contentKey: Data,
        keyAAD: Data, payloadAAD: Data, plaintext: String
    ) throws -> HPKEv3Positive {
        let wrap = try HermesRelayCrypto.sealKeyV3(
            contentKey,
            recipientPublicKeyBase64: recipientPubB64,
            senderPrivateKey: senderPriv,
            aad: keyAAD
        )
        return try makePositive(
            name: name, direction: direction,
            uid: uid, clientId: clientId, id: id,
            recipientPubB64: recipientPubB64, recipientPriv: recipientPriv,
            senderPubB64: senderPubB64,
            contentKey: contentKey, wrap: wrap,
            keyAAD: keyAAD, payloadAAD: payloadAAD, plaintext: plaintext
        )
    }

    /// Build a positive vector from an already-produced v3 wrap (used when one
    /// wrapped content key seals more than one payload slot, e.g. attachments).
    private static func makePositive(
        name: String, direction: String,
        uid: String, clientId: String, id: String,
        recipientPubB64: String, recipientPriv: P256.KeyAgreement.PrivateKey,
        senderPubB64: String,
        contentKey: Data, wrap: HermesRelayKeyWrapV3,
        keyAAD: Data, payloadAAD: Data, plaintext: String
    ) throws -> HPKEv3Positive {
        let plaintextData = Data(plaintext.utf8)
        let payloadCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: plaintextData, keyData: contentKey, aad: payloadAAD
        )
        return HPKEv3Positive(
            name: name, direction: direction,
            uid: uid, clientId: clientId, id: id,
            recipientPrivateKey: recipientPriv.rawRepresentation.base64EncodedString(),
            recipientPublicKey: recipientPubB64,
            senderPublicKey: senderPubB64,
            contentKey: contentKey.base64EncodedString(),
            keyAAD: String(data: keyAAD, encoding: .utf8)!,
            info: "OpenBurnBar-HermesRelay-HPKE-v3|" + String(data: keyAAD, encoding: .utf8)!,
            enc: wrap.encBase64,
            wrappedKey: wrap.wrappedKeyBase64,
            payloadAAD: String(data: payloadAAD, encoding: .utf8)!,
            plaintext: plaintext,
            encodedPlaintext: plaintextData.base64EncodedString(),
            payloadCiphertext: payloadCiphertext
        )
    }

    // MARK: - Deterministic key material (matches HermesRelayCrossPlatformVectorTests)

    private static func deterministicPrivateKey(tweak: UInt8 = 0) throws -> P256.KeyAgreement.PrivateKey {
        var seed = Array(repeating: UInt8(0x42), count: 32)
        seed[0] = 0x10
        seed[31] = tweak
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(seed))
    }

    private static func deterministicSymmetricKey(tweak: UInt8 = 0) -> Data {
        Data((0..<32).map { UInt8((Int($0) * 7 + Int(tweak)) % 251) })
    }

    private static func mutatingLastByte(ofBase64 base64: String) -> String {
        var bytes = [UInt8](Data(base64Encoded: base64)!)
        bytes[bytes.count - 1] ^= 0xFF
        return Data(bytes).base64EncodedString()
    }

    // MARK: - Fixture output plumbing

    /// Gated on a DEDICATED flag (not the shared `OPENBURNBAR_REGENERATE_HERMES_VECTORS`)
    /// so a routine v1/v2 vector regen never emits an unexpected v3 side artifact.
    private static var shouldEmitFixture: Bool {
        guard let value = ProcessInfo.processInfo.environment["OPENBURNBAR_EMIT_HPKE_V3_FIXTURE"] else {
            return false
        }
        return ["1", "true", "yes"].contains(value.lowercased())
    }

    /// Swift-sealed re-vendor sample path (default), overridable via
    /// `OPENBURNBAR_HPKE_V3_FIXTURE_OUT` so a handoff sample can be emitted (e.g.
    /// to `/tmp`). The `.swift-emitted` infix keeps it from colliding with the
    /// vector lane's canonical `BurnBarHpkeV3Vector.json`, which this never writes.
    private static var fixtureOutputURL: URL {
        if let override = ProcessInfo.processInfo.environment["OPENBURNBAR_HPKE_V3_FIXTURE_OUT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("BurnBarHpkeV3Vector.swift-emitted.json")
    }
}

// MARK: - Fixture shapes (camelCase + base64, mirroring HermesGatewayWireVector.json)

private struct HPKEv3Fixture: Codable {
    var revision: String
    /// Payload/attachment AES-GCM algorithm tag — the UNCHANGED sealing layer.
    var algorithm: String
    var relayEncryption: String
    var relayKeyVersion: Int
    var suite: String
    var hpkeMode: String
    var infoPrefix: String
    var agentRecipientPrivateKey: String
    var agentRecipientPublicKey: String
    var phoneSenderPrivateKey: String
    var phoneSenderPublicKey: String
    var positives: [HPKEv3Positive]
    var negatives: [HPKEv3Negative]
}

/// One v3-wrapped content key plus the AES-GCM payload slot it protects. The
/// recipient opens `enc`/`wrappedKey` binding `senderPublicKey` (pinned), yields
/// `contentKey`, then opens `payloadCiphertext` under `payloadAAD`.
private struct HPKEv3Positive: Codable {
    var name: String
    var direction: String
    var uid: String
    var clientId: String
    var id: String
    var recipientPrivateKey: String
    var recipientPublicKey: String
    /// The PINNED sender static key (X9.63 base64) the recipient authenticates.
    var senderPublicKey: String
    var contentKey: String
    var keyAAD: String
    var info: String
    var enc: String
    var wrappedKey: String
    var payloadAAD: String
    var plaintext: String
    var encodedPlaintext: String
    var payloadCiphertext: String
}

/// One negative vector: exactly one authenticated input is mutated and the v3
/// open MUST fail (`expect == "open-fails"`).
private struct HPKEv3Negative: Codable {
    var name: String
    var base: String
    var mutation: String
    var recipientPrivateKey: String
    var pinnedSenderPublicKey: String
    var keyAAD: String
    var enc: String
    var wrappedKey: String
    var expect: String
}
