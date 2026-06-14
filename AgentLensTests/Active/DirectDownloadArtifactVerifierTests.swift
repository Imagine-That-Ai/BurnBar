import CryptoKit
import Foundation
import XCTest
@testable import OpenBurnBar

/// Verifies the in-app update artifact verification: SHA-256 digest plus
/// Ed25519 signature over the downloaded bytes against the pinned
/// `SUPublicEDKey`. The keypair is generated with CryptoKit inside each test —
/// the same primitive (`Curve25519.Signing`) Sparkle's `sign_update` uses, so
/// a signature produced here is byte-compatible with the release pipeline's.
final class DirectDownloadArtifactVerifierTests: XCTestCase {

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Fixture {
        let payload: Data
        let signatureBase64: String
        let signingKey: Curve25519.Signing.PrivateKey
        let verifier: DirectDownloadArtifactVerifier
    }

    private func makeFixture(payload: Data = Data("OpenBurnBar update DMG payload".utf8)) throws -> Fixture {
        let signingKey = Curve25519.Signing.PrivateKey()
        let signature = try signingKey.signature(for: payload)
        let verifier = DirectDownloadArtifactVerifier(
            publicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString()
        )
        return Fixture(
            payload: payload,
            signatureBase64: signature.base64EncodedString(),
            signingKey: signingKey,
            verifier: verifier
        )
    }

    // MARK: - Success path

    func testValidSignatureAndDigestPasses() throws {
        let fixture = try makeFixture()
        XCTAssertNoThrow(
            try fixture.verifier.verify(
                data: fixture.payload,
                expectedLength: fixture.payload.count,
                expectedSHA256: Self.sha256Hex(fixture.payload),
                edSignatureBase64: fixture.signatureBase64
            )
        )
    }

    func testUppercaseSHA256IsAccepted() throws {
        let fixture = try makeFixture()
        XCTAssertNoThrow(
            try fixture.verifier.verify(
                data: fixture.payload,
                expectedLength: fixture.payload.count,
                expectedSHA256: Self.sha256Hex(fixture.payload).uppercased(),
                edSignatureBase64: fixture.signatureBase64
            )
        )
    }

    func testVerifyFileAtURLPassesForValidArtifact() throws {
        let fixture = try makeFixture()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectDownloadArtifactVerifierTests-\(UUID().uuidString).dmg")
        try fixture.payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertNoThrow(
            try fixture.verifier.verify(
                fileAt: fileURL,
                expectedLength: fixture.payload.count,
                expectedSHA256: Self.sha256Hex(fixture.payload),
                edSignatureBase64: fixture.signatureBase64
            )
        )
    }

    // MARK: - Tampering

    func testTamperedBytesFailSignatureEvenWhenFeedDigestMatchesTamperedBytes() throws {
        // Threat model: an attacker who controls the feed swaps the DMG and
        // recomputes sha256/length to match the swapped bytes — but cannot
        // re-sign without the private key. Verification must fail on the
        // signature, the last line of defense.
        let fixture = try makeFixture()
        let tampered = Data("tampered DMG payload".utf8)

        XCTAssertThrowsError(
            try fixture.verifier.verify(
                data: tampered,
                expectedLength: tampered.count,
                expectedSHA256: Self.sha256Hex(tampered),
                edSignatureBase64: fixture.signatureBase64
            )
        ) { error in
            XCTAssertEqual(error as? DirectDownloadVerificationError, .signatureInvalid)
        }
    }

    func testWrongPublicKeyFailsSignature() throws {
        let fixture = try makeFixture()
        let otherKey = Curve25519.Signing.PrivateKey()
        let wrongKeyVerifier = DirectDownloadArtifactVerifier(
            publicKeyBase64: otherKey.publicKey.rawRepresentation.base64EncodedString()
        )

        XCTAssertThrowsError(
            try wrongKeyVerifier.verify(
                data: fixture.payload,
                expectedLength: fixture.payload.count,
                expectedSHA256: Self.sha256Hex(fixture.payload),
                edSignatureBase64: fixture.signatureBase64
            )
        ) { error in
            XCTAssertEqual(error as? DirectDownloadVerificationError, .signatureInvalid)
        }
    }

    func testSHA256MismatchFailsBeforeSignatureCheck() throws {
        let fixture = try makeFixture()
        let wrongDigest = String(repeating: "0", count: 64)

        XCTAssertThrowsError(
            try fixture.verifier.verify(
                data: fixture.payload,
                expectedLength: fixture.payload.count,
                expectedSHA256: wrongDigest,
                edSignatureBase64: fixture.signatureBase64
            )
        ) { error in
            guard case .sha256Mismatch(let expected, let actual)? = error as? DirectDownloadVerificationError else {
                return XCTFail("Expected sha256Mismatch, got \(error)")
            }
            XCTAssertEqual(expected, wrongDigest)
            XCTAssertEqual(actual, Self.sha256Hex(fixture.payload))
        }
    }

    func testLengthMismatchFails() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(
            try fixture.verifier.verify(
                data: fixture.payload,
                expectedLength: fixture.payload.count + 1,
                expectedSHA256: Self.sha256Hex(fixture.payload),
                edSignatureBase64: fixture.signatureBase64
            )
        ) { error in
            XCTAssertEqual(
                error as? DirectDownloadVerificationError,
                .lengthMismatch(expected: fixture.payload.count + 1, actual: fixture.payload.count)
            )
        }
    }

    // MARK: - Malformed inputs (fail closed)

    func testMissingSignatureFails() throws {
        let fixture = try makeFixture()
        for missing in [nil, "", "   \n"] as [String?] {
            XCTAssertThrowsError(
                try fixture.verifier.verify(
                    data: fixture.payload,
                    expectedLength: fixture.payload.count,
                    expectedSHA256: Self.sha256Hex(fixture.payload),
                    edSignatureBase64: missing
                )
            ) { error in
                XCTAssertEqual(error as? DirectDownloadVerificationError, .missingSignature)
            }
        }
    }

    func testMalformedSignatureFails() throws {
        let fixture = try makeFixture()
        // Not base64, and base64 of the wrong size, must both be rejected
        // before any curve math happens.
        for malformed in ["%%%not-base64%%%", Data("short".utf8).base64EncodedString()] {
            XCTAssertThrowsError(
                try fixture.verifier.verify(
                    data: fixture.payload,
                    expectedLength: fixture.payload.count,
                    expectedSHA256: Self.sha256Hex(fixture.payload),
                    edSignatureBase64: malformed
                )
            ) { error in
                XCTAssertEqual(error as? DirectDownloadVerificationError, .malformedSignature)
            }
        }
    }

    func testMissingPublicKeyFailsClosed() throws {
        let fixture = try makeFixture()
        let verifier = DirectDownloadArtifactVerifier(publicKeyBase64: "  ")

        XCTAssertThrowsError(
            try verifier.verify(
                data: fixture.payload,
                expectedLength: fixture.payload.count,
                expectedSHA256: Self.sha256Hex(fixture.payload),
                edSignatureBase64: fixture.signatureBase64
            )
        ) { error in
            XCTAssertEqual(error as? DirectDownloadVerificationError, .missingPublicKey)
        }
    }

    func testMalformedPublicKeyFailsClosed() throws {
        let fixture = try makeFixture()
        for malformedKey in ["%%%not-base64%%%", Data("way-too-short".utf8).base64EncodedString()] {
            let verifier = DirectDownloadArtifactVerifier(publicKeyBase64: malformedKey)
            XCTAssertThrowsError(
                try verifier.verify(
                    data: fixture.payload,
                    expectedLength: fixture.payload.count,
                    expectedSHA256: Self.sha256Hex(fixture.payload),
                    edSignatureBase64: fixture.signatureBase64
                )
            ) { error in
                XCTAssertEqual(error as? DirectDownloadVerificationError, .malformedPublicKey)
            }
        }
    }

    func testUnreadableArtifactFails() throws {
        let fixture = try makeFixture()
        let missingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectDownloadArtifactVerifierTests-missing-\(UUID().uuidString).dmg")

        XCTAssertThrowsError(
            try fixture.verifier.verify(
                fileAt: missingFile,
                expectedLength: fixture.payload.count,
                expectedSHA256: Self.sha256Hex(fixture.payload),
                edSignatureBase64: fixture.signatureBase64
            )
        ) { error in
            guard case .unreadableArtifact? = error as? DirectDownloadVerificationError else {
                return XCTFail("Expected unreadableArtifact, got \(error)")
            }
        }
    }

    // MARK: - Bundled key plumbing

    func testBundledPublicKeyReadsSUPublicEDKey() throws {
        // The unit-test host bundles the app's Info.plist, which pins
        // SUPublicEDKey. If this ever goes missing the updater fails closed,
        // so surface it here too.
        guard let key = DirectDownloadArtifactVerifier.bundledPublicKeyBase64() else {
            throw XCTSkip("Test host bundle does not carry SUPublicEDKey; covered by release verification job.")
        }
        let raw = Data(base64Encoded: key)
        XCTAssertEqual(raw?.count, 32, "SUPublicEDKey must be a raw 32-byte Ed25519 public key")
    }
}

extension DirectDownloadArtifactVerifierTests {
    // MARK: - Public-key construction (trust-anchor) fail-closed

    /// The pinned `SUPublicEDKey` is the trust anchor for the whole signature
    /// check. Constructing the `Curve25519.Signing.PublicKey` from its raw bytes
    /// used to be a `try?` that collapsed any CryptoKit error to `nil` — silently
    /// discarding *why* the key was rejected while (correctly) failing closed.
    /// The conversion to an explicit `do/catch` must keep failing closed:
    /// whenever the 32 bytes do not yield a usable key, verification still throws
    /// `.malformedPublicKey` and never falls open.
    func testPublicKeyConstructionFailureFailsClosed() throws {
        let fixture = try makeFixture()
        // Inputs that decode to *exactly* 32 bytes (so they clear the length
        // guard and reach the construction step) but are adversarial / arbitrary
        // key material rather than the pinned key. Under any CryptoKit behavior
        // — construction throws, or construction succeeds but the key cannot
        // validate the real signature — verification must reject the update.
        let thirtyTwoByteKeys: [Data] = [
            Data(repeating: 0x00, count: 32),
            Data(repeating: 0xFF, count: 32),
            Data((0..<32).map { UInt8($0) })
        ]
        for keyBytes in thirtyTwoByteKeys {
            let verifier = DirectDownloadArtifactVerifier(
                publicKeyBase64: keyBytes.base64EncodedString()
            )
            XCTAssertThrowsError(
                try verifier.verify(
                    data: fixture.payload,
                    expectedLength: fixture.payload.count,
                    expectedSHA256: Self.sha256Hex(fixture.payload),
                    edSignatureBase64: fixture.signatureBase64
                ),
                "A 32-byte non-pinned key must never let a foreign signature verify"
            ) { error in
                let verificationError = error as? DirectDownloadVerificationError
                XCTAssertTrue(
                    verificationError == .malformedPublicKey
                        || verificationError == .signatureInvalid,
                    "Expected fail-closed (.malformedPublicKey or .signatureInvalid), got \(error)"
                )
            }
        }
    }

    /// Regression guard for the exact bug the `try?` masked: a key whose bytes
    /// are well-formed base64 but decode to the wrong length must fail closed
    /// with `.malformedPublicKey` *before* any signature math, never returning a
    /// permissive default. Covers 31 and 33 bytes — the off-by-one neighbours of
    /// a valid raw Ed25519 key — to lock the length gate in place.
    func testNearLengthPublicKeyBytesFailClosed() throws {
        let fixture = try makeFixture()
        for length in [0, 1, 16, 31, 33, 64] {
            let verifier = DirectDownloadArtifactVerifier(
                publicKeyBase64: Data(repeating: 0xAB, count: length).base64EncodedString()
            )
            XCTAssertThrowsError(
                try verifier.verify(
                    data: fixture.payload,
                    expectedLength: fixture.payload.count,
                    expectedSHA256: Self.sha256Hex(fixture.payload),
                    edSignatureBase64: fixture.signatureBase64
                )
            ) { error in
                XCTAssertEqual(
                    error as? DirectDownloadVerificationError,
                    .malformedPublicKey,
                    "A \(length)-byte key must fail closed as .malformedPublicKey"
                )
            }
        }
    }

    /// The previously-pinned key still verifies the real signature after the
    /// construction path changed from `try?` to `do/catch` — proving the fix is
    /// behaviour-preserving on the happy path and did not over-tighten into a
    /// false reject of legitimate updates.
    func testGenuinePinnedKeyStillVerifiesAfterConstructionHardening() throws {
        let fixture = try makeFixture()
        XCTAssertNoThrow(
            try fixture.verifier.verify(
                data: fixture.payload,
                expectedLength: fixture.payload.count,
                expectedSHA256: Self.sha256Hex(fixture.payload),
                edSignatureBase64: fixture.signatureBase64
            )
        )
    }

    /// The error copy is the security-honest UX the update design demands:
    /// every failure names what was being verified and why opening stopped.
    func testEveryVerificationErrorExplainsItselfSpecifically() {
        let cases: [(DirectDownloadVerificationError, String)] = [
            (.missingPublicKey, "SUPublicEDKey"),
            (.malformedPublicKey, "Ed25519"),
            (.missingSignature, "signature"),
            (.malformedSignature, "base64"),
            (.lengthMismatch(expected: 1000, actual: 999), "999"),
            (.sha256Mismatch(expected: "aa", actual: "bb"), "bb"),
            (.signatureInvalid, "does not verify"),
            (.unreadableArtifact("boom"), "boom")
        ]
        for (error, marker) in cases {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(error) must explain itself")
            XCTAssertTrue(
                description.contains(marker),
                "\(error) description must name its specifics (missing: \(marker))"
            )
        }
    }
}
