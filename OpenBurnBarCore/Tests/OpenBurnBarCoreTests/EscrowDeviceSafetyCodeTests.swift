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
}
