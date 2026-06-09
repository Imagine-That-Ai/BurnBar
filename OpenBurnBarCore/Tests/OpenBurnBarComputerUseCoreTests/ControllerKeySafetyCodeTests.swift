import CryptoKit
import XCTest
@testable import OpenBurnBarComputerUseCore

final class ControllerKeySafetyCodeTests: XCTestCase {
    private func keyBase64() -> String {
        Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    }

    func testFormatIsDeterministicAndOrderIndependent() {
        let a = keyBase64()
        let b = keyBase64()
        let code1 = ControllerKeySafetyCode.format(controllerKeyBase64: a, hostKeyBase64: b)
        let code2 = ControllerKeySafetyCode.format(controllerKeyBase64: b, hostKeyBase64: a)
        XCTAssertNotNil(code1)
        XCTAssertEqual(code1, code2, "Mac and phone derive the same code without agreeing on roles")
    }

    func testFormatShapeIsEightGroupsOfFourHex() {
        let code = ControllerKeySafetyCode.format(controllerKeyBase64: keyBase64(), hostKeyBase64: keyBase64())
        let groups = try? XCTUnwrap(code).split(separator: " ")
        XCTAssertEqual(groups?.count, 8)
        for group in groups ?? [] {
            XCTAssertEqual(group.count, 4)
            XCTAssertTrue(group.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isUppercase) })
        }
    }

    func testCodeChangesWhenEitherKeyChanges() {
        let host = keyBase64()
        let controller = keyBase64()
        let base = ControllerKeySafetyCode.format(controllerKeyBase64: controller, hostKeyBase64: host)
        let swapController = ControllerKeySafetyCode.format(controllerKeyBase64: keyBase64(), hostKeyBase64: host)
        let swapHost = ControllerKeySafetyCode.format(controllerKeyBase64: controller, hostKeyBase64: keyBase64())
        XCTAssertNotEqual(base, swapController, "swapping the controller key changes the code")
        XCTAssertNotEqual(base, swapHost, "swapping the host key changes the code")
    }

    func testMalformedKeysFailClosed() {
        let good = keyBase64()
        XCTAssertNil(ControllerKeySafetyCode.format(controllerKeyBase64: "", hostKeyBase64: good))
        XCTAssertNil(ControllerKeySafetyCode.format(controllerKeyBase64: "not-base64!!", hostKeyBase64: good))
        // Right length but not a valid Ed25519 point bytes that CryptoKit accepts? 32 random
        // bytes are almost always a valid Curve25519 key, so use a wrong length instead.
        XCTAssertNil(ControllerKeySafetyCode.format(
            controllerKeyBase64: Data(repeating: 1, count: 16).base64EncodedString(),
            hostKeyBase64: good
        ))
        XCTAssertNil(ControllerKeySafetyCode.format(publicKeysBase64: []))
    }

    func testSpelledOutInsertsSeparators() {
        let spelled = ControllerKeySafetyCode.spelledOut("AB12 CD34")
        XCTAssertEqual(spelled, "A B 1 2 ,   C D 3 4")
    }
}
