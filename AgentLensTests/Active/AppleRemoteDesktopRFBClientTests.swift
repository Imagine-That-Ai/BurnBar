import XCTest
@testable import OpenBurnBar

final class AppleRemoteDesktopRFBClientTests: XCTestCase {
    func testRemoteUnlockRFBRefusesUntrustedLoopbackBeforeConnecting() async {
        let client = AppleRemoteDesktopRFBClient(
            host: "127.0.0.1",
            port: 1,
            timeoutSeconds: 1,
            loopbackTrustValidator: { _, _ in false }
        )

        do {
            try await client.typeCredential(.init(username: "user", password: "secret"))
            XCTFail("Untrusted loopback listeners must be denied before any credential socket is opened.")
        } catch let failure as AppleRemoteDesktopRFBClient.Failure {
            XCTAssertEqual(failure, .untrustedLoopbackServer)
        } catch {
            XCTFail("Expected untrustedLoopbackServer, got \(error)")
        }
    }

    func testRemoteUnlockRFBTrustPolicyParsesLsofRecords() {
        let output = """
        p88
        claunchd
        u0
        nTCP 127.0.0.1:5900 (LISTEN)
        p901
        cpython
        u501
        nTCP 127.0.0.1:5900 (LISTEN)
        """

        let records = AppleRemoteDesktopRFBServerTrustPolicy.parseLsofListenerRecords(output)

        XCTAssertEqual(
            records,
            [
                .init(pid: 88, command: "launchd", uid: "0", name: "TCP 127.0.0.1:5900 (LISTEN)"),
                .init(pid: 901, command: "python", uid: "501", name: "TCP 127.0.0.1:5900 (LISTEN)")
            ]
        )
    }

    func testRemoteUnlockRFBTrustPolicyAcceptsRootOwnedAppleListener() {
        let record = AppleRemoteDesktopRFBServerTrustPolicy.LsofListenerRecord(
            pid: 88,
            command: "ARDAgent",
            uid: "root",
            name: "TCP 127.0.0.1:5900 (LISTEN)"
        )

        XCTAssertTrue(
            AppleRemoteDesktopRFBServerTrustPolicy.isTrustedListener(
                record,
                executablePath: "/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/MacOS/ARDAgent"
            )
        )
    }

    func testRemoteUnlockRFBTrustPolicyRejectsUserOwnedLookalikeListener() {
        let record = AppleRemoteDesktopRFBServerTrustPolicy.LsofListenerRecord(
            pid: 901,
            command: "ARDAgent",
            uid: "501",
            name: "TCP 127.0.0.1:5900 (LISTEN)"
        )

        XCTAssertFalse(
            AppleRemoteDesktopRFBServerTrustPolicy.isTrustedListener(
                record,
                executablePath: "/tmp/ARDAgent"
            )
        )
    }

    func testRemoteUnlockRFBTrustPolicyRejectsUnexpectedRootProcess() {
        let record = AppleRemoteDesktopRFBServerTrustPolicy.LsofListenerRecord(
            pid: 902,
            command: "python",
            uid: "0",
            name: "TCP 127.0.0.1:5900 (LISTEN)"
        )

        XCTAssertFalse(
            AppleRemoteDesktopRFBServerTrustPolicy.isTrustedListener(
                record,
                executablePath: "/usr/bin/python3"
            )
        )
    }

    func testRemoteUnlockRFBTrustPolicyRejectsMissingExecutablePath() {
        let record = AppleRemoteDesktopRFBServerTrustPolicy.LsofListenerRecord(
            pid: 88,
            command: "ARDAgent",
            uid: "0",
            name: "TCP 127.0.0.1:5900 (LISTEN)"
        )

        XCTAssertFalse(
            AppleRemoteDesktopRFBServerTrustPolicy.isTrustedListener(
                record,
                executablePath: nil
            )
        )
    }

    func testRemoteUnlockRFBTrustPolicyRejectsNonDefaultEndpointWithoutShellingOut() async {
        let trusted = await AppleRemoteDesktopRFBServerTrustPolicy.validate(
            host: "192.0.2.10",
            port: 5900
        )

        XCTAssertFalse(trusted)
    }

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
