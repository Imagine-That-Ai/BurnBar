import XCTest
@testable import OpenBurnBar

final class AppleRemoteDesktopRFBClientTests: XCTestCase {
    func testRemoteUnlockBigUIntModularExponentMatchesKnownVectors() {
        XCTAssertEqual(
            RemoteUnlockBigUInt.powMod(
                base: RemoteUnlockBigUInt(5),
                exponent: RemoteUnlockBigUInt(117),
                modulus: RemoteUnlockBigUInt(19)
            ),
            RemoteUnlockBigUInt(1)
        )
        XCTAssertEqual(
            RemoteUnlockBigUInt.powMod(
                base: RemoteUnlockBigUInt(65_537),
                exponent: RemoteUnlockBigUInt(12_345),
                modulus: RemoteUnlockBigUInt(99_991)
            ),
            RemoteUnlockBigUInt(2_604)
        )
    }

    func testRFBKeyEventWireFormatUsesBigEndianKeysyms() {
        XCTAssertEqual(
            AppleRemoteDesktopRFBClient.makeKeyEventMessage(keysym: 0xff0d, down: true),
            Data([4, 1, 0, 0, 0, 0, 0xff, 0x0d])
        )
        XCTAssertEqual(
            AppleRemoteDesktopRFBClient.makeKeyEventMessage(keysym: UInt32(UInt8(ascii: "A")), down: false),
            Data([4, 0, 0, 0, 0, 0, 0, 0x41])
        )
    }

    func testRFBPointerClickWireFormatUsesButtonMaskAndBigEndianCoordinates() {
        XCTAssertEqual(
            AppleRemoteDesktopRFBClient.makePointerEventMessage(buttonMask: 1, x: 514, y: 2658),
            Data([5, 1, 0x02, 0x02, 0x0a, 0x62])
        )
    }
}
