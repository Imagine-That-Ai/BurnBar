import CryptoKit
import Foundation
import XCTest
import OpenBurnBarComputerUseCore

/// F10 — cross-language known-answer test (KAT) for `ControlFrameSeal`.
///
/// Swift is the emitter and one opener; Kotlin
/// (`android/app/src/test/java/com/openburnbar/data/computeruse/ControlFrameSealVectorTest.kt`)
/// opens the SAME frozen fixture, proving the §3 wire invariant is
/// byte-identical across both languages:
///
///     envelope = "OBCFS1"(6) ‖ 0x01 ‖ AES-256-GCM combined (nonce12 ‖ ct ‖ tag16)
///     AAD      = "OpenBurnBar-ControlFrameSeal-v1|" ‖ peerNodeId ‖ 0x7C ‖ frameType
///     key      = HKDF-SHA256(hpkeSessionKey, salt, info "OpenBurnBar-ControlFrameSeal-v1", 32)
///
/// Pattern: `Fixtures/BurnBarHpkeV3Vector.json` — one language seals once,
/// every language must open the frozen bytes. All fixture inputs are
/// deterministic constants; only the AES-GCM nonce inside each envelope is
/// drawn at emission time and then frozen with the fixture.
///
/// Regenerate + re-vendor the Android copy:
///
///     BURNBAR_EMIT_AEAD_VECTORS=1 swift test --package-path OpenBurnBarCore \
///       --filter ControlFrameSealVectorTests
///     cp OpenBurnBarCore/Tests/OpenBurnBarComputerUseCoreTests/Fixtures/ControlFrameSealVector.json \
///        android/app/src/test/resources/control-seal/ControlFrameSealVector.json
final class ControlFrameSealVectorTests: XCTestCase {
    private let seal = ControlFrameSeal()

    // MARK: - Frozen contract

    func test_fixtureIsTheFrozenV1Contract() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.primitive, "ControlFrameSeal")
        XCTAssertEqual(fixture.magicHex, hexString(ControlFrameSeal.magic))
        XCTAssertEqual(fixture.magicHex, "4f4243465331", #""OBCFS1" in ASCII"#)
        XCTAssertEqual(fixture.version, Int(ControlFrameSeal.version))
        XCTAssertEqual(fixture.hkdfInfo, "OpenBurnBar-ControlFrameSeal-v1")
        XCTAssertEqual(fixture.aadPrefix, "OpenBurnBar-ControlFrameSeal-v1|")
        XCTAssertEqual(fixture.capability, ControlFrameSealNegotiation.capability)
        XCTAssertEqual(fixture.cases.count, 2)
    }

    /// Swift HKDF re-derives the exact frozen session key for every case, so
    /// Kotlin's HKDF agreement is anchored to bytes Swift provably produces.
    func test_swiftDerivesEveryFrozenSessionKey() throws {
        let fixture = try loadFixture()
        for vector in fixture.cases {
            let key = try sessionKey(for: vector)
            let keyData = key.withUnsafeBytes { Data($0) }
            XCTAssertEqual(hexString(keyData), vector.derivedKeyHex, "\(vector.name): derived key mismatch")
        }
    }

    /// The production AAD builder reproduces the frozen AAD bytes.
    func test_swiftComputesEveryFrozenAADByteForByte() throws {
        let fixture = try loadFixture()
        for vector in fixture.cases {
            let aad = ControlFrameSeal.aad(peerNodeId: vector.peerNodeId, frameType: vector.frameType)
            XCTAssertEqual(hexString(aad), vector.aadHex, "\(vector.name): AAD mismatch")
        }
    }

    /// The frozen Swift-sealed envelopes open back to the exact control JSON.
    func test_swiftOpensEveryFrozenEnvelope() throws {
        let fixture = try loadFixture()
        for vector in fixture.cases {
            let envelope = try dataFromHex(vector.envelopeHex)
            XCTAssertTrue(ControlFrameSeal.isSealedEnvelope(envelope), "\(vector.name): magic sniff failed")
            XCTAssertEqual(
                envelope.prefix(ControlFrameSeal.magic.count + 1),
                ControlFrameSeal.magic + Data([ControlFrameSeal.version]),
                "\(vector.name): header must be magic ‖ version"
            )
            let plaintext = try dataFromHex(vector.plaintextHex)
            XCTAssertNil(envelope.range(of: plaintext), "\(vector.name): control JSON leaked into the envelope")
            let opened = try open(vector, envelope: envelope, key: try sessionKey(for: vector))
            XCTAssertEqual(opened, plaintext, "\(vector.name): opened plaintext mismatch")
        }
    }

    // MARK: - Frozen negatives

    func test_frozenEnvelopeRejectsTamperedCiphertext() throws {
        let fixture = try loadFixture()
        let vector = try XCTUnwrap(fixture.cases.first)
        let key = try sessionKey(for: vector)
        var tampered = try dataFromHex(vector.envelopeHex)
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertThrowsError(try open(vector, envelope: tampered, key: key)) { error in
            XCTAssertEqual(error as? ControlFrameSeal.SealError, .openFailed)
        }
    }

    func test_frozenEnvelopeRejectsWrongPeerTypeOrKey() throws {
        let fixture = try loadFixture()
        let vector = try XCTUnwrap(fixture.cases.first)
        let key = try sessionKey(for: vector)
        let envelope = try dataFromHex(vector.envelopeHex)
        XCTAssertThrowsError(
            try open(vector, envelope: envelope, key: key, peerNodeIdOverride: "ios-se-IMPOSTOR"),
            "a frame replayed across peers must not open"
        )
        XCTAssertThrowsError(
            try open(vector, envelope: envelope, key: key, frameTypeOverride: "control.approval.response"),
            "a re-typed frame must not open"
        )
        let wrongKey = seal.deriveSessionKey(
            hpkeSessionKey: try dataFromHex(vector.hpkeSessionKeyHex),
            salt: Data("a-different-request".utf8)
        )
        XCTAssertThrowsError(try open(vector, envelope: envelope, key: wrongKey))
    }

    func test_frozenEnvelopeRejectsHeaderMutationsFailClosed() throws {
        let fixture = try loadFixture()
        let vector = try XCTUnwrap(fixture.cases.first)
        let key = try sessionKey(for: vector)
        let envelope = try dataFromHex(vector.envelopeHex)

        XCTAssertThrowsError(try open(vector, envelope: envelope.prefix(30), key: key)) { error in
            XCTAssertEqual(error as? ControlFrameSeal.SealError, .envelopeTooShort)
        }
        var wrongMagic = envelope
        wrongMagic[0] ^= 0xFF
        XCTAssertThrowsError(try open(vector, envelope: wrongMagic, key: key)) { error in
            XCTAssertEqual(error as? ControlFrameSeal.SealError, .invalidMagic)
        }
        var wrongVersion = envelope
        wrongVersion[ControlFrameSeal.magic.count] = 2
        XCTAssertThrowsError(try open(vector, envelope: wrongVersion, key: key)) { error in
            XCTAssertEqual(error as? ControlFrameSeal.SealError, .unsupportedVersion(2))
        }
    }

    // MARK: - Open helpers

    private func sessionKey(for vector: ControlSealCase) throws -> SymmetricKey {
        seal.deriveSessionKey(
            hpkeSessionKey: try dataFromHex(vector.hpkeSessionKeyHex),
            salt: try dataFromHex(vector.saltHex)
        )
    }

    private func open(
        _ vector: ControlSealCase,
        envelope: Data,
        key: SymmetricKey,
        peerNodeIdOverride: String? = nil,
        frameTypeOverride: String? = nil
    ) throws -> Data {
        try seal.open(
            envelope: envelope,
            key: key,
            peerNodeId: peerNodeIdOverride ?? vector.peerNodeId,
            frameType: frameTypeOverride ?? vector.frameType
        )
    }

    // MARK: - Fixture plumbing

    /// Gated on a DEDICATED flag so an unrelated vector regen never rewrites
    /// this fixture as a side effect.
    private static var shouldEmitFixture: Bool {
        guard let value = ProcessInfo.processInfo.environment["BURNBAR_EMIT_AEAD_VECTORS"] else {
            return false
        }
        return ["1", "true", "yes"].contains(value.lowercased())
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("ControlFrameSealVector.json")

    private static var didEmit = false

    private func loadFixture() throws -> ControlSealFixture {
        try Self.emitFixtureIfRequested()
        return try JSONDecoder().decode(ControlSealFixture.self, from: Data(contentsOf: Self.fixtureURL))
    }

    /// Deterministic frozen inputs. NEVER derive these from time or randomness:
    /// the emitted fixture is a frozen cross-language constant.
    private struct FrozenInput {
        var name: String
        var hpkeSessionKey: Data
        var salt: Data
        var peerNodeId: String
        var frameType: String
        var plaintext: Data
        var plaintextUtf8: String?
    }

    private static let frozenInputs: [FrozenInput] = [
        FrozenInput(
            name: "clipboard_request",
            hpkeSessionKey: Data((0..<32).map { UInt8(($0 * 5 + 3) % 251) }),
            salt: Data("control-req-0001".utf8),
            peerNodeId: "ios-se-0a1b2c3d4e5f60718293a4b5",
            frameType: "control.clipboard.request",
            plaintext: Data(#"{"clipboardRequest":{"text":"correct horse battery staple — π≈3.14159"}}"#.utf8),
            plaintextUtf8: #"{"clipboardRequest":{"text":"correct horse battery staple — π≈3.14159"}}"#
        ),
        FrozenInput(
            name: "input_intent",
            hpkeSessionKey: Data((0..<32).map { UInt8(($0 * 9 + 7) % 251) }),
            salt: Data((0..<16).map { UInt8(0xA0 + $0) }),
            peerNodeId: "android-phone-00112233445566778899aabb",
            frameType: "control.input.intent",
            plaintext: Data(#"{"inputIntent":{"x":640,"y":360,"button":"left"}}"#.utf8),
            plaintextUtf8: #"{"inputIntent":{"x":640,"y":360,"button":"left"}}"#
        )
    ]

    private static func emitFixtureIfRequested() throws {
        guard shouldEmitFixture, !didEmit else { return }
        let seal = ControlFrameSeal()
        var cases: [ControlSealCase] = []
        for input in frozenInputs {
            let key = seal.deriveSessionKey(hpkeSessionKey: input.hpkeSessionKey, salt: input.salt)
            let keyData = key.withUnsafeBytes { Data($0) }
            let aad = ControlFrameSeal.aad(peerNodeId: input.peerNodeId, frameType: input.frameType)
            let envelope = try seal.seal(
                plaintext: input.plaintext,
                key: key,
                peerNodeId: input.peerNodeId,
                frameType: input.frameType
            )
            // Prove the candidate envelope opens BEFORE freezing it.
            let reopened = try seal.open(
                envelope: envelope,
                key: key,
                peerNodeId: input.peerNodeId,
                frameType: input.frameType
            )
            guard reopened == input.plaintext else {
                throw VectorError.emitVerificationFailed(input.name)
            }
            cases.append(ControlSealCase(
                name: input.name,
                hpkeSessionKeyHex: hexString(input.hpkeSessionKey),
                saltHex: hexString(input.salt),
                derivedKeyHex: hexString(keyData),
                peerNodeId: input.peerNodeId,
                frameType: input.frameType,
                aadHex: hexString(aad),
                plaintextHex: hexString(input.plaintext),
                plaintextUtf8: input.plaintextUtf8,
                envelopeHex: hexString(envelope)
            ))
        }
        let fixture = ControlSealFixture(
            schemaVersion: 1,
            primitive: "ControlFrameSeal",
            magicHex: hexString(ControlFrameSeal.magic),
            version: Int(ControlFrameSeal.version),
            hkdfInfo: "OpenBurnBar-ControlFrameSeal-v1",
            aadPrefix: "OpenBurnBar-ControlFrameSeal-v1|",
            capability: ControlFrameSealNegotiation.capability,
            envelopeLayout: "magic OBCFS1(6) || version 0x01(1) || AES-256-GCM combined: nonce(12) || ciphertext || tag(16)",
            generator: VectorGenerator(
                command: "BURNBAR_EMIT_AEAD_VECTORS=1 swift test --package-path OpenBurnBarCore --filter ControlFrameSealVectorTests",
                language: "swift",
                note: "Sealed by the production Swift CryptoKit ControlFrameSeal. All inputs (HPKE session key, salt, peerNodeId, frameType, plaintext) are deterministic frozen constants; " +
                    "the AES-GCM nonce inside each envelope was drawn once at emission and is frozen with the fixture. " +
                    "Kotlin opens the identical copy at android/app/src/test/resources/control-seal/ControlFrameSealVector.json (ControlFrameSealVectorTest)."
            ),
            cases: cases
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(fixture)
        data.append(0x0A)
        try FileManager.default.createDirectory(
            at: fixtureURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fixtureURL)
        didEmit = true
    }
}

// MARK: - Fixture shapes (camelCase + hex, one sealed envelope per case)

private struct ControlSealFixture: Codable {
    var schemaVersion: Int
    var primitive: String
    var magicHex: String
    var version: Int
    var hkdfInfo: String
    var aadPrefix: String
    var capability: String
    var envelopeLayout: String
    var generator: VectorGenerator
    var cases: [ControlSealCase]
}

private struct VectorGenerator: Codable {
    var command: String
    var language: String
    var note: String
}

private struct ControlSealCase: Codable {
    var name: String
    var hpkeSessionKeyHex: String
    var saltHex: String
    var derivedKeyHex: String
    var peerNodeId: String
    var frameType: String
    var aadHex: String
    var plaintextHex: String
    var plaintextUtf8: String?
    var envelopeHex: String
}

// MARK: - Hex plumbing

private enum VectorError: Error {
    case invalidHex(String)
    case emitVerificationFailed(String)
}

private func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func dataFromHex(_ hex: String) throws -> Data {
    let characters = Array(hex)
    guard characters.count % 2 == 0 else { throw VectorError.invalidHex(hex) }
    var data = Data(capacity: characters.count / 2)
    var index = 0
    while index < characters.count {
        guard let byte = UInt8(String(characters[index...(index + 1)]), radix: 16) else {
            throw VectorError.invalidHex(hex)
        }
        data.append(byte)
        index += 2
    }
    return data
}
