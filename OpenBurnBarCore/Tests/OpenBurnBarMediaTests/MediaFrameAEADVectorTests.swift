import CryptoKit
import Foundation
import XCTest
import OpenBurnBarMedia

/// F7 — cross-language known-answer test (KAT) for `MediaFrameAEAD`.
///
/// Swift is the emitter and one opener; Kotlin
/// (`android/app/src/test/java/com/openburnbar/data/media/MediaFrameAeadVectorTest.kt`)
/// opens the SAME frozen fixture, proving the §3 wire invariant is
/// byte-identical across both languages:
///
///     envelope = "OBMFA1"(6) ‖ 0x01 ‖ AES-256-GCM combined (nonce12 ‖ ct ‖ tag16)
///     AAD      = "OpenBurnBar-MediaFrameAEAD-v1|" ‖ streamClass ‖ 0x7C ‖
///                u8(kind) ‖ u32BE(gopID) ‖ u32BE(frameIndex)
///     key      = HKDF-SHA256(sharedSecret, salt, info "OpenBurnBar-MediaFrameAEAD-v1", 32)
///
/// Pattern: `Fixtures/BurnBarHpkeV3Vector.json` — one language seals once,
/// every language must open the frozen bytes. All fixture inputs are
/// deterministic constants; only the AES-GCM nonce inside each envelope is
/// drawn at emission time and then frozen with the fixture.
///
/// Regenerate + re-vendor the Android copy:
///
///     BURNBAR_EMIT_AEAD_VECTORS=1 swift test --package-path OpenBurnBarCore \
///       --filter MediaFrameAEADVectorTests
///     cp OpenBurnBarCore/Tests/OpenBurnBarMediaTests/Fixtures/MediaFrameAEADVector.json \
///        android/app/src/test/resources/media-aead/MediaFrameAEADVector.json
final class MediaFrameAEADVectorTests: XCTestCase {
    private let aead = MediaFrameAEAD()

    // MARK: - Frozen contract

    func test_fixtureIsTheFrozenV1Contract() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.primitive, "MediaFrameAEAD")
        XCTAssertEqual(fixture.magicHex, hexString(MediaFrameAEAD.magic))
        XCTAssertEqual(fixture.magicHex, "4f424d464131", #""OBMFA1" in ASCII"#)
        XCTAssertEqual(fixture.version, Int(MediaFrameAEAD.version))
        XCTAssertEqual(fixture.hkdfInfo, "OpenBurnBar-MediaFrameAEAD-v1")
        XCTAssertEqual(fixture.aadPrefix, "OpenBurnBar-MediaFrameAEAD-v1|")
        XCTAssertEqual(fixture.capability, MediaFrameAeadNegotiation.capability)
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

    /// The production AAD builder reproduces the frozen AAD bytes — including
    /// the u32 big-endian gopID/frameIndex lanes the second case probes.
    func test_swiftComputesEveryFrozenAADByteForByte() throws {
        let fixture = try loadFixture()
        for vector in fixture.cases {
            let aad = MediaFrameAEAD.aad(
                streamClass: vector.streamClass,
                kind: vector.kind,
                gopID: vector.gopID,
                frameIndex: vector.frameIndex
            )
            XCTAssertEqual(hexString(aad), vector.aadHex, "\(vector.name): AAD mismatch")
        }
    }

    /// The frozen Swift-sealed envelopes open back to the exact plaintext.
    func test_swiftOpensEveryFrozenEnvelope() throws {
        let fixture = try loadFixture()
        for vector in fixture.cases {
            let envelope = try dataFromHex(vector.envelopeHex)
            XCTAssertTrue(MediaFrameAEAD.isSealedEnvelope(envelope), "\(vector.name): magic sniff failed")
            XCTAssertEqual(
                envelope.prefix(MediaFrameAEAD.magic.count + 1),
                MediaFrameAEAD.magic + Data([MediaFrameAEAD.version]),
                "\(vector.name): header must be magic ‖ version"
            )
            let plaintext = try dataFromHex(vector.plaintextHex)
            XCTAssertNil(envelope.range(of: plaintext), "\(vector.name): plaintext leaked into the envelope")
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
            XCTAssertEqual(error as? MediaFrameAEAD.SealError, .openFailed)
        }
    }

    func test_frozenEnvelopeRejectsWrongPositionStreamOrKey() throws {
        let fixture = try loadFixture()
        let vector = try XCTUnwrap(fixture.cases.first)
        let key = try sessionKey(for: vector)
        let envelope = try dataFromHex(vector.envelopeHex)
        XCTAssertThrowsError(
            try open(vector, envelope: envelope, key: key, frameIndexOverride: vector.frameIndex &+ 1),
            "a frame replayed in a different position must not open"
        )
        XCTAssertThrowsError(
            try open(vector, envelope: envelope, key: key, streamClassOverride: "control.surface.frame"),
            "a frame replayed on another stream must not open"
        )
        let wrongKey = aead.deriveSessionKey(
            sharedSecret: try dataFromHex(vector.sharedSecretHex),
            salt: Data("a-different-session".utf8)
        )
        XCTAssertThrowsError(try open(vector, envelope: envelope, key: wrongKey))
    }

    func test_frozenEnvelopeRejectsHeaderMutationsFailClosed() throws {
        let fixture = try loadFixture()
        let vector = try XCTUnwrap(fixture.cases.first)
        let key = try sessionKey(for: vector)
        let envelope = try dataFromHex(vector.envelopeHex)

        XCTAssertThrowsError(try open(vector, envelope: envelope.prefix(30), key: key)) { error in
            XCTAssertEqual(error as? MediaFrameAEAD.SealError, .envelopeTooShort)
        }
        var wrongMagic = envelope
        wrongMagic[0] ^= 0xFF
        XCTAssertThrowsError(try open(vector, envelope: wrongMagic, key: key)) { error in
            XCTAssertEqual(error as? MediaFrameAEAD.SealError, .invalidMagic)
        }
        var wrongVersion = envelope
        wrongVersion[MediaFrameAEAD.magic.count] = 2
        XCTAssertThrowsError(try open(vector, envelope: wrongVersion, key: key)) { error in
            XCTAssertEqual(error as? MediaFrameAEAD.SealError, .unsupportedVersion(2))
        }
    }

    // MARK: - Open helpers

    private func sessionKey(for vector: MediaAeadCase) throws -> SymmetricKey {
        let key = aead.deriveSessionKey(
            sharedSecret: try dataFromHex(vector.sharedSecretHex),
            salt: try dataFromHex(vector.saltHex)
        )
        return key
    }

    private func open(
        _ vector: MediaAeadCase,
        envelope: Data,
        key: SymmetricKey,
        streamClassOverride: String? = nil,
        frameIndexOverride: UInt32? = nil
    ) throws -> Data {
        try aead.open(
            envelope: envelope,
            key: key,
            streamClass: streamClassOverride ?? vector.streamClass,
            kind: vector.kind,
            gopID: vector.gopID,
            frameIndex: frameIndexOverride ?? vector.frameIndex
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

    private static let fixtureURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("MediaFrameAEADVector.json")

    private static var didEmit = false

    private func loadFixture() throws -> MediaAeadFixture {
        try Self.emitFixtureIfRequested()
        return try JSONDecoder().decode(MediaAeadFixture.self, from: Data(contentsOf: Self.fixtureURL))
    }

    /// Deterministic frozen inputs. NEVER derive these from time or randomness:
    /// the emitted fixture is a frozen cross-language constant.
    private struct FrozenInput {
        var name: String
        var sharedSecret: Data
        var salt: Data
        var streamClass: String
        var kind: UInt8
        var gopID: UInt32
        var frameIndex: UInt32
        var plaintext: Data
        var plaintextUtf8: String?
    }

    private static let frozenInputs: [FrozenInput] = [
        FrozenInput(
            name: "screen_video_key_frame",
            sharedSecret: Data((0..<32).map { UInt8(($0 * 7 + 13) % 251) }),
            salt: Data("mercury-mirror-session-0001".utf8),
            streamClass: "media.screen.video",
            kind: 0x01,
            gopID: 4,
            frameIndex: 9,
            plaintext: Data("OBMF2-encoded H.264 keyframe payload — frozen for the F7 cross-language KAT".utf8),
            plaintextUtf8: "OBMF2-encoded H.264 keyframe payload — frozen for the F7 cross-language KAT"
        ),
        // Probes the u32 big-endian AAD lanes (gopID 0x01020304, frameIndex
        // 0xFFFFFFFE) and a binary (non-UTF-8) plaintext.
        FrozenInput(
            name: "call_audio_u32_endianness_probe",
            sharedSecret: Data((0..<32).map { UInt8(($0 * 11 + 5) % 251) }),
            salt: Data((0..<16).map { UInt8($0) }),
            streamClass: "media.audio.out",
            kind: 0x02,
            gopID: 0x0102_0304,
            frameIndex: 0xFFFF_FFFE,
            plaintext: Data((0..<48).map { UInt8(truncatingIfNeeded: $0 * 3 + 1) }),
            plaintextUtf8: nil
        )
    ]

    private static func emitFixtureIfRequested() throws {
        guard shouldEmitFixture, !didEmit else { return }
        let aead = MediaFrameAEAD()
        var cases: [MediaAeadCase] = []
        for input in frozenInputs {
            let key = aead.deriveSessionKey(sharedSecret: input.sharedSecret, salt: input.salt)
            let keyData = key.withUnsafeBytes { Data($0) }
            let aad = MediaFrameAEAD.aad(
                streamClass: input.streamClass,
                kind: input.kind,
                gopID: input.gopID,
                frameIndex: input.frameIndex
            )
            let envelope = try aead.seal(
                plaintext: input.plaintext,
                key: key,
                streamClass: input.streamClass,
                kind: input.kind,
                gopID: input.gopID,
                frameIndex: input.frameIndex
            )
            // Prove the candidate envelope opens BEFORE freezing it.
            let reopened = try aead.open(
                envelope: envelope,
                key: key,
                streamClass: input.streamClass,
                kind: input.kind,
                gopID: input.gopID,
                frameIndex: input.frameIndex
            )
            guard reopened == input.plaintext else {
                throw VectorError.emitVerificationFailed(input.name)
            }
            cases.append(MediaAeadCase(
                name: input.name,
                sharedSecretHex: hexString(input.sharedSecret),
                saltHex: hexString(input.salt),
                derivedKeyHex: hexString(keyData),
                streamClass: input.streamClass,
                kind: input.kind,
                gopID: input.gopID,
                frameIndex: input.frameIndex,
                aadHex: hexString(aad),
                plaintextHex: hexString(input.plaintext),
                plaintextUtf8: input.plaintextUtf8,
                envelopeHex: hexString(envelope)
            ))
        }
        let fixture = MediaAeadFixture(
            schemaVersion: 1,
            primitive: "MediaFrameAEAD",
            magicHex: hexString(MediaFrameAEAD.magic),
            version: Int(MediaFrameAEAD.version),
            hkdfInfo: "OpenBurnBar-MediaFrameAEAD-v1",
            aadPrefix: "OpenBurnBar-MediaFrameAEAD-v1|",
            capability: MediaFrameAeadNegotiation.capability,
            envelopeLayout: "magic OBMFA1(6) || version 0x01(1) || AES-256-GCM combined: nonce(12) || ciphertext || tag(16)",
            generator: VectorGenerator(
                command: "BURNBAR_EMIT_AEAD_VECTORS=1 swift test --package-path OpenBurnBarCore --filter MediaFrameAEADVectorTests",
                language: "swift",
                note: "Sealed by the production Swift CryptoKit MediaFrameAEAD. All inputs (shared secret, salt, AAD params, plaintext) are deterministic frozen constants; the AES-GCM nonce inside each envelope was drawn once at emission and is frozen with the fixture. Kotlin opens the identical copy at android/app/src/test/resources/media-aead/MediaFrameAEADVector.json (MediaFrameAeadVectorTest)."
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

private struct MediaAeadFixture: Codable {
    var schemaVersion: Int
    var primitive: String
    var magicHex: String
    var version: Int
    var hkdfInfo: String
    var aadPrefix: String
    var capability: String
    var envelopeLayout: String
    var generator: VectorGenerator
    var cases: [MediaAeadCase]
}

private struct VectorGenerator: Codable {
    var command: String
    var language: String
    var note: String
}

private struct MediaAeadCase: Codable {
    var name: String
    var sharedSecretHex: String
    var saltHex: String
    var derivedKeyHex: String
    var streamClass: String
    var kind: UInt8
    var gopID: UInt32
    var frameIndex: UInt32
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
