import XCTest
@testable import OpenBurnBarCore

final class BurnBarLinuxPrivacyExportCryptoTests: XCTestCase {
    func testRoundTripAuthenticatesHeaderAndPayload() throws {
        let payload = Data("redacted local privacy export".utf8)
        let bundle = try BurnBarLinuxPrivacyExportCrypto.seal(payload: payload, passphrase: "correct horse battery")

        XCTAssertEqual(try BurnBarLinuxPrivacyExportCrypto.open(bundle: bundle, passphrase: "correct horse battery"), payload)
        XCTAssertThrowsError(try BurnBarLinuxPrivacyExportCrypto.open(bundle: bundle, passphrase: "wrong horse battery")) {
            XCTAssertEqual($0 as? BurnBarLinuxPrivacyExportCrypto.Error, .authenticationFailed)
        }
    }

    func testHeaderTamperingFailsAuthentication() throws {
        let payload = Data("secret".utf8)
        var bundle = try BurnBarLinuxPrivacyExportCrypto.seal(payload: payload, passphrase: "correct horse battery")
        bundle[BurnBarLinuxPrivacyExportCrypto.magic.count + 1] ^= 0x01

        XCTAssertThrowsError(try BurnBarLinuxPrivacyExportCrypto.open(bundle: bundle, passphrase: "correct horse battery")) {
            XCTAssertEqual($0 as? BurnBarLinuxPrivacyExportCrypto.Error, .authenticationFailed)
        }
    }

    func testPassphraseAndPayloadBoundsFailClosed() {
        XCTAssertThrowsError(
            try BurnBarLinuxPrivacyExportCrypto.seal(payload: Data(), passphrase: "short")
        ) { XCTAssertEqual($0 as? BurnBarLinuxPrivacyExportCrypto.Error, .passphraseTooShort) }
        let oversized = Data(repeating: 0x41, count: BurnBarLinuxPrivacyExportCrypto.maximumPayloadByteCount + 1)
        XCTAssertThrowsError(
            try BurnBarLinuxPrivacyExportCrypto.seal(payload: oversized, passphrase: "correct horse battery")
        ) { XCTAssertEqual($0 as? BurnBarLinuxPrivacyExportCrypto.Error, .payloadTooLarge(oversized.count)) }
    }
}
