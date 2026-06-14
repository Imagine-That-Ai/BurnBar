import XCTest
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

/// Focused coverage for the two error-swallowing sites that previously hid a
/// security/correctness decision behind `try?` in `UsageSyncService.swift`:
///
///   1. `projectKeyHash` derived the keyed group-by trapdoor under the per-user
///      search key and `try?`-swallowed any crypto/derivation fault, conflating
///      it with the benign "name too short" `nil`. A failed derivation must now
///      FAIL CLOSED on the write path (`projectKeyHashOrThrow` throws) so a usage
///      row is never silently uploaded missing its trapdoor.
///
///   2. `openSealedProjectName` opened a sealed project-name envelope and
///      `try?`-swallowed the open failure. The open result drives a privacy
///      decision: on failure the function must NEVER leak the legacy plaintext.
///      The new do/catch keeps that fail-closed `nil` for BOTH a wrong-key /
///      tampered AEAD failure and a structurally invalid envelope, while making
///      the loss observable instead of silent.
///
/// All assertions exercise the exact public `CloudVaultCrypto` primitives the
/// service uses, so the contract is proven without a live Firestore.
final class UsageSyncServiceMattersTests: XCTestCase {
    private let vaultKey = Data(repeating: 0x42, count: 32)
    private let otherKey = Data(repeating: 0x37, count: 32)
    private let shortKey = Data(repeating: 0x42, count: 16) // not 32 bytes → invalidKeyLength

    // MARK: - Site 1: projectKeyHash derivation must fail closed on a crypto fault

    /// Valid key + a normalizable name yields a stable 32-hex trapdoor, and the
    /// throwing primitive is byte-identical to the legacy non-throwing call. This
    /// guards against any behavioral regression for the happy path.
    func test_projectKeyHashOrThrow_validKey_matchesNonThrowingResult() throws {
        let name = "Mercury Media"
        let viaThrowing = try CloudVaultCrypto.projectKeyHashOrThrow(for: name, keyData: vaultKey)
        let viaLegacy = CloudVaultCrypto.projectKeyHash(for: name, keyData: vaultKey)

        let hash = try XCTUnwrap(viaThrowing)
        XCTAssertEqual(hash.count, 32)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(viaThrowing, viaLegacy)
    }

    /// The ONLY `nil` the throwing primitive may return is the expected
    /// "normalizes to fewer than two characters" case — and it must NOT throw.
    func test_projectKeyHashOrThrow_tooShortName_returnsNilWithoutThrowing() throws {
        XCTAssertNil(try CloudVaultCrypto.projectKeyHashOrThrow(for: "", keyData: vaultKey))
        XCTAssertNil(try CloudVaultCrypto.projectKeyHashOrThrow(for: "   ", keyData: vaultKey))
        XCTAssertNil(try CloudVaultCrypto.projectKeyHashOrThrow(for: "a", keyData: vaultKey))
        // A non-empty name that normalizes away entirely (no [a-z0-9]) is also the
        // benign short-case, not a crypto fault.
        XCTAssertNil(try CloudVaultCrypto.projectKeyHashOrThrow(for: "！！", keyData: vaultKey))
    }

    /// FAIL CLOSED: a real crypto/derivation fault (here a bad-length key surfacing
    /// from `searchKey`) propagates instead of being coalesced into the short-name
    /// `nil`. Previously `try?` swallowed this and the row would upload missing its
    /// group-by trapdoor.
    func test_projectKeyHashOrThrow_badKeyLength_throws() {
        XCTAssertThrowsError(
            try CloudVaultCrypto.projectKeyHashOrThrow(for: "Real Project", keyData: shortKey)
        ) { error in
            XCTAssertTrue(
                error is CloudVaultCryptoError,
                "Expected CloudVaultCryptoError, got \(type(of: error))"
            )
        }
    }

    /// The retained non-throwing convenience (used by best-effort budget / policy
    /// sealing) still degrades to `nil` on a crypto fault — but now via a logged
    /// catch, not a silent `try?`. The observable contract is: same `nil`, no throw.
    func test_projectKeyHash_nonThrowing_badKeyLength_returnsNil() {
        XCTAssertNil(CloudVaultCrypto.projectKeyHash(for: "Real Project", keyData: shortKey))
    }

    // MARK: - Site 2: openSealedProjectName must never leak on an open failure

    /// Happy path: the matching key opens the sealed envelope.
    func test_openSealedProjectName_matchingKey_returnsPlaintext() throws {
        let doc = try sealedDoc(name: "Top Secret Project", key: vaultKey)
        XCTAssertEqual(
            CloudVaultCrypto.openSealedProjectName(from: doc, keyData: vaultKey),
            "Top Secret Project"
        )
    }

    /// Wrong vault key: the AEAD open fails (wrong-device / not-yet-keyed). The
    /// function must return `nil` and MUST NOT fall through to a stale legacy value.
    func test_openSealedProjectName_wrongKey_failsClosedAndDoesNotLeakLegacy() throws {
        var doc = try sealedDoc(name: "Sealed Truth", key: vaultKey)
        doc["projectName"] = "STALE PLAINTEXT MUST NOT LEAK"

        let opened = CloudVaultCrypto.openSealedProjectName(from: doc, keyData: otherKey)
        XCTAssertNil(opened, "Wrong-key open must fail closed, never return a legacy value")
    }

    /// No key on this device: sealed text stays opaque and the legacy plaintext is
    /// never surfaced (guard clause before any AEAD work).
    func test_openSealedProjectName_absentKey_failsClosedAndDoesNotLeakLegacy() throws {
        var doc = try sealedDoc(name: "Sealed Truth", key: vaultKey)
        doc["projectName"] = "STALE PLAINTEXT MUST NOT LEAK"

        XCTAssertNil(CloudVaultCrypto.openSealedProjectName(from: doc, keyData: nil))
    }

    /// Tampered ciphertext (valid envelope shape, mutated AEAD payload): the open
    /// throws an authentication failure, which previously vanished into `try?`.
    /// The function returns `nil` (fail closed) and never leaks the legacy value.
    func test_openSealedProjectName_tamperedCiphertext_failsClosedAndDoesNotLeak() throws {
        var doc = try sealedDoc(name: "Sealed Truth", key: vaultKey)
        doc["projectName"] = "STALE PLAINTEXT MUST NOT LEAK"

        let sealed = try XCTUnwrap(doc["sealedProjectName"] as? [String: Any])
        let ciphertext = try XCTUnwrap(sealed["ciphertext"] as? String)
        var mutated = sealed
        mutated["ciphertext"] = flippedBase64(ciphertext)
        doc["sealedProjectName"] = mutated

        // Sanity: the mutation still decodes into a structurally valid envelope, so
        // we are exercising the AEAD-tag path, not the malformed-envelope path.
        XCTAssertNotNil(CloudVaultCrypto.decodeSealedText(from: mutated))

        XCTAssertNil(
            CloudVaultCrypto.openSealedProjectName(from: doc, keyData: vaultKey),
            "Tampered ciphertext must fail closed, never return a legacy value"
        )
    }

    /// Structurally invalid envelope (bad algorithm): the open throws
    /// `CloudVaultCryptoError.invalidEnvelope`. The function returns `nil` and the
    /// legacy plaintext is still suppressed.
    func test_openSealedProjectName_invalidEnvelope_failsClosedAndDoesNotLeak() throws {
        var doc = try sealedDoc(name: "Sealed Truth", key: vaultKey)
        doc["projectName"] = "STALE PLAINTEXT MUST NOT LEAK"

        let sealed = try XCTUnwrap(doc["sealedProjectName"] as? [String: Any])
        var mutated = sealed
        mutated["algorithm"] = "ROT13" // not AES-256-GCM → invalidEnvelope on open
        doc["sealedProjectName"] = mutated

        // The bad algorithm still decodes structurally; the fault is raised inside open().
        XCTAssertNotNil(CloudVaultCrypto.decodeSealedText(from: mutated))

        XCTAssertNil(
            CloudVaultCrypto.openSealedProjectName(from: doc, keyData: vaultKey),
            "Invalid envelope must fail closed, never return a legacy value"
        )
    }

    /// Back-compat preserved: with NO sealed field present, a legacy plaintext doc
    /// still decodes (in-flight / pre-migration docs). The fix did not regress this.
    func test_openSealedProjectName_legacyOnlyDoc_stillDecodes() {
        let legacyDoc: [String: Any] = ["projectName": "Legacy Project"]
        XCTAssertEqual(
            CloudVaultCrypto.openSealedProjectName(from: legacyDoc, keyData: vaultKey),
            "Legacy Project"
        )
        // Even without a key, a doc with no sealed envelope returns the legacy value.
        XCTAssertEqual(
            CloudVaultCrypto.openSealedProjectName(from: legacyDoc, keyData: nil),
            "Legacy Project"
        )
    }

    // MARK: - Helpers

    private func sealedDoc(name: String, key: Data) throws -> [String: Any] {
        var doc: [String: Any] = [:]
        doc["sealedProjectName"] = try CloudVaultCrypto.firestoreDictionary(
            CloudVaultCrypto.sealText(name, keyData: key)
        )
        return doc
    }

    /// Flip the FIRST base64 character so the decoded ciphertext bytes change while
    /// the string stays valid base64 of the same length and padding (the AEAD tag
    /// will not verify). The first character is always a data character, never the
    /// `=` padding, so the result still decodes to bytes of the original length.
    private func flippedBase64(_ value: String) -> String {
        guard let first = value.first else { return value }
        let replacement: Character = (first == "A") ? "B" : "A"
        return String(replacement) + String(value.dropFirst())
    }
}
