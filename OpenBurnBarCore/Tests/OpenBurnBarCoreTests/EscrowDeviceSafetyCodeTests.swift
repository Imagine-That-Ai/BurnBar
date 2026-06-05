import CryptoKit
import Foundation
import XCTest
@testable import OpenBurnBarCore

/// Stream 6 — proves the cross-device safety code is identical on both ends and
/// stays fail-closed (no plausible-looking code from junk input). Crypto is
/// unchanged; this only exercises the display formatter + the flag scaffold.
final class EscrowDeviceSafetyCodeTests: XCTestCase {
    /// A realistic fingerprint exactly as `CloudVaultDeviceKeypair`/iOS produce
    /// it: base64 of SHA-256(publicKeyData).
    private func fingerprint(forSeed seed: UInt8) -> String {
        let fakePublicKey = Data(repeating: seed, count: 65) // x9.63 is 65 bytes
        return Data(SHA256.hash(data: fakePublicKey)).base64EncodedString()
    }

    func testFormatProducesEightGroupsOfFourUppercaseHex() throws {
        let code = try XCTUnwrap(EscrowDeviceSafetyCode.format(fingerprint: fingerprint(forSeed: 0x11)))
        let groups = code.split(separator: " ").map(String.init)
        XCTAssertEqual(groups.count, 8)
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEF")
        for group in groups {
            XCTAssertEqual(group.count, 4)
            XCTAssertTrue(group.unicodeScalars.allSatisfy { allowed.contains($0) }, "non-hex in \(group)")
        }
    }

    func testSameStoredFingerprintYieldsIdenticalCodeOnBothEnds() throws {
        // Both Mac and iOS read the SAME stored fingerprint string; formatting it
        // with the SAME routine must give byte-identical output.
        let stored = fingerprint(forSeed: 0x42)
        let macSide = EscrowDeviceSafetyCode.format(fingerprint: stored)
        let phoneSide = EscrowDeviceSafetyCode.format(fingerprint: stored)
        XCTAssertNotNil(macSide)
        XCTAssertEqual(macSide, phoneSide)
    }

    func testFormatIsStableAndKnownForAFixedDigest() {
        // A digest whose first 16 bytes are 0x00,0x01,...,0x0F renders predictably.
        let digest = Data((0..<32).map { UInt8($0) })
        let code = EscrowDeviceSafetyCode.format(fingerprint: digest.base64EncodedString())
        XCTAssertEqual(code, "0001 0203 0405 0607 0809 0A0B 0C0D 0E0F")
    }

    func testDifferentFingerprintsProduceDifferentCodes() throws {
        let a = try XCTUnwrap(EscrowDeviceSafetyCode.format(fingerprint: fingerprint(forSeed: 0x01)))
        let b = try XCTUnwrap(EscrowDeviceSafetyCode.format(fingerprint: fingerprint(forSeed: 0x02)))
        XCTAssertNotEqual(a, b)
    }

    func testToleratesSurroundingWhitespace() {
        let stored = fingerprint(forSeed: 0x77)
        XCTAssertEqual(
            EscrowDeviceSafetyCode.format(fingerprint: "  \(stored)\n"),
            EscrowDeviceSafetyCode.format(fingerprint: stored)
        )
    }

    func testFailsClosedOnMissingOrInvalidFingerprint() {
        XCTAssertNil(EscrowDeviceSafetyCode.format(fingerprint: nil))
        XCTAssertNil(EscrowDeviceSafetyCode.format(fingerprint: ""))
        XCTAssertNil(EscrowDeviceSafetyCode.format(fingerprint: "   "))
        XCTAssertNil(EscrowDeviceSafetyCode.format(fingerprint: "not base64 !!!"))
        // Valid base64 but too few bytes to fill 128 bits.
        XCTAssertNil(EscrowDeviceSafetyCode.format(fingerprint: Data([0x01, 0x02]).base64EncodedString()))
    }

    func testSpelledOutIsScreenReaderFriendly() {
        XCTAssertEqual(
            EscrowDeviceSafetyCode.spelledOut("AB12 CD34"),
            "A B 1 2 ,   C D 3 4"
        )
    }

    func testFlagDefaultsOff() {
        // Use an isolated suite so we never touch standard defaults.
        let suiteName = "EscrowSafetyFlagTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(EscrowDeviceTrustSafetyCheckFlag.isEnabled(defaults: defaults))
    }

    func testFlagUserDefaultsOverrideWins() {
        let suiteName = "EscrowSafetyFlagTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: EscrowDeviceTrustSafetyCheckFlag.userDefaultsKey)
        XCTAssertTrue(EscrowDeviceTrustSafetyCheckFlag.isEnabled(defaults: defaults))

        defaults.set(false, forKey: EscrowDeviceTrustSafetyCheckFlag.userDefaultsKey)
        XCTAssertFalse(EscrowDeviceTrustSafetyCheckFlag.isEnabled(defaults: defaults))
    }

    // MARK: - Stream 6 enablement: key-bound (load-bearing) safety code

    /// A real P-256 x9.63 (65-byte) public key, base64-encoded, exactly as
    /// `EscrowPublicKey.publicKeyData` carries it.
    private func realPublicKeyBase64() -> String {
        P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
    }

    func testRecomputeFingerprintMatchesCanonicalSha256OfKeyBytes() throws {
        let raw = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let base64 = raw.base64EncodedString()
        let expected = Data(SHA256.hash(data: raw)).base64EncodedString()
        XCTAssertEqual(EscrowDeviceSafetyCode.recomputeFingerprint(fromPublicKeyData: base64), expected)
    }

    func testKeyBoundCodeEqualsCodeForLocallyRecomputedFingerprint() throws {
        let key = realPublicKeyBase64()
        let viaKey = try XCTUnwrap(EscrowDeviceSafetyCode.format(publicKeyData: key))
        let fingerprint = try XCTUnwrap(EscrowDeviceSafetyCode.recomputeFingerprint(fromPublicKeyData: key))
        let viaFingerprint = try XCTUnwrap(EscrowDeviceSafetyCode.format(fingerprint: fingerprint))
        XCTAssertEqual(viaKey, viaFingerprint)
        // Shape parity with the legacy formatter.
        XCTAssertEqual(viaKey.split(separator: " ").count, 8)
    }

    func testKeyBoundCodeIsStableForTheSameKeyAndDiffersAcrossKeys() throws {
        let key = realPublicKeyBase64()
        XCTAssertEqual(
            EscrowDeviceSafetyCode.format(publicKeyData: key),
            EscrowDeviceSafetyCode.format(publicKeyData: key)
        )
        let other = realPublicKeyBase64()
        XCTAssertNotEqual(
            EscrowDeviceSafetyCode.format(publicKeyData: key),
            EscrowDeviceSafetyCode.format(publicKeyData: other)
        )
    }

    func testKeyBoundCodeFailsClosedOnAbsentOrInvalidKey() {
        XCTAssertNil(EscrowDeviceSafetyCode.format(publicKeyData: nil))
        XCTAssertNil(EscrowDeviceSafetyCode.recomputeFingerprint(fromPublicKeyData: nil))
        XCTAssertNil(EscrowDeviceSafetyCode.format(publicKeyData: ""))
        XCTAssertNil(EscrowDeviceSafetyCode.format(publicKeyData: "   "))
        XCTAssertNil(EscrowDeviceSafetyCode.format(publicKeyData: "not base64 !!!"))
        // Valid base64 but wrong length (not a 65-byte x9.63 key).
        XCTAssertNil(EscrowDeviceSafetyCode.format(publicKeyData: Data([0x04, 0x01, 0x02]).base64EncodedString()))
        // Correct length, correct 0x04 prefix, but not on the P-256 curve —
        // CryptoKit import must reject it (no plausible code from junk bytes).
        let offCurve = Data([0x04] + Array(repeating: UInt8(0xAB), count: 64))
        XCTAssertEqual(offCurve.count, 65)
        XCTAssertNil(EscrowDeviceSafetyCode.format(publicKeyData: offCurve.base64EncodedString()))
        XCTAssertNil(EscrowDeviceSafetyCode.recomputeFingerprint(fromPublicKeyData: offCurve.base64EncodedString()))
    }

    func testIsFingerprintBoundToAcceptsTheGenuineServerStoredFingerprint() throws {
        // The server-stored fingerprint that legitimately matches the key bytes
        // must verify. This is the "honest server" / honest-device case.
        let key = realPublicKeyBase64()
        let stored = try XCTUnwrap(EscrowDeviceSafetyCode.recomputeFingerprint(fromPublicKeyData: key))
        XCTAssertTrue(EscrowDeviceSafetyCode.isFingerprint(stored, boundTo: key))
        XCTAssertTrue(EscrowDeviceSafetyCode.isFingerprint("  \(stored)\n", boundTo: key))
    }

    func testIsFingerprintBoundToRejectsAServerSpoofedFingerprint() throws {
        // The attack the binding closes: a server advertises a fingerprint that
        // is valid base64 of a SHA-256 digest but does NOT correspond to the
        // key bytes the device will actually use. The verifier must reject it.
        let key = realPublicKeyBase64()
        let attackerFingerprint = Data(SHA256.hash(data: Data("attacker-supplied-key".utf8))).base64EncodedString()
        XCTAssertFalse(EscrowDeviceSafetyCode.isFingerprint(attackerFingerprint, boundTo: key))
    }

    func testIsFingerprintBoundToFailsClosedOnMissingInputs() throws {
        let key = realPublicKeyBase64()
        let stored = try XCTUnwrap(EscrowDeviceSafetyCode.recomputeFingerprint(fromPublicKeyData: key))
        XCTAssertFalse(EscrowDeviceSafetyCode.isFingerprint(nil, boundTo: key))
        XCTAssertFalse(EscrowDeviceSafetyCode.isFingerprint("", boundTo: key))
        XCTAssertFalse(EscrowDeviceSafetyCode.isFingerprint(stored, boundTo: nil))
        XCTAssertFalse(EscrowDeviceSafetyCode.isFingerprint(stored, boundTo: "not a key"))
        // A truncated digest of the right key must not pass (length mismatch).
        let truncated = Data(Data(base64Encoded: stored)!.prefix(16)).base64EncodedString()
        XCTAssertFalse(EscrowDeviceSafetyCode.isFingerprint(truncated, boundTo: key))
    }

    func testRecomputeFingerprintMatchesServerGoldenVector() throws {
        // Cross-language parity with functions/src/callables/computerUseSecurity.ts
        // `recomputeEscrowFingerprint`. This exact (key, fingerprint) pair was
        // produced by the Node implementation; both sides must agree byte-for-byte
        // so a Mac/iOS reader and the server bind to the same key identity.
        let key = "BF8kD8cxysQZYfK+E5P47VMA2Kyf7qQ8SSJh0QB3RkparBtbyeL7XrAue1wanXNo0KUc5OzpAtUWp6oWSYrKzfM="
        let serverFingerprint = "gpX18YwBJijSAfecJvCp7Fmc5wM+uzmwJxbbGcoGoAw="
        XCTAssertEqual(EscrowDeviceSafetyCode.recomputeFingerprint(fromPublicKeyData: key), serverFingerprint)
        XCTAssertTrue(EscrowDeviceSafetyCode.isFingerprint(serverFingerprint, boundTo: key))
        XCTAssertEqual(
            EscrowDeviceSafetyCode.format(publicKeyData: key),
            EscrowDeviceSafetyCode.format(fingerprint: serverFingerprint)
        )
    }

    func testKeyBoundAndLegacyCodesAgreeOnTheSameDevice() throws {
        // A device whose stored fingerprint is honestly the SHA-256 of its key
        // shows the SAME code whether read off the stored string or recomputed
        // from the key — so enabling the binding does not change the operator's
        // displayed code for honest devices.
        let key = realPublicKeyBase64()
        let stored = try XCTUnwrap(EscrowDeviceSafetyCode.recomputeFingerprint(fromPublicKeyData: key))
        XCTAssertEqual(
            EscrowDeviceSafetyCode.format(fingerprint: stored),
            EscrowDeviceSafetyCode.format(publicKeyData: key)
        )
    }
}
