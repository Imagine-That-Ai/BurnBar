import XCTest
@testable import OpenBurnBarIrohRelay

final class KeepAwakeToggleCommandTests: XCTestCase {
    func testSignAndVerifyRoundTrip() throws {
        let keypair = IrohPairingKeypair()
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let command = try KeepAwakeToggleCommand.sign(
            deviceId: "iphone-1",
            enabled: true,
            issuedAt: now,
            with: keypair.signingKey
        )
        try KeepAwakeToggleCommand.verify(
            command,
            publicKey: keypair.publicKeyRaw,
            now: now.addingTimeInterval(30)
        )
        XCTAssertTrue(command.enabled)
        XCTAssertEqual(
            KeepAwakeToggleCommand.parsePresenceCapability(command.presenceCapability),
            command
        )
    }

    func testExpiredToggleRejected() throws {
        let keypair = IrohPairingKeypair()
        let issuedAt = Date(timeIntervalSince1970: 1_715_000_000)
        let command = try KeepAwakeToggleCommand.sign(
            deviceId: "iphone-1",
            enabled: false,
            issuedAt: issuedAt,
            with: keypair.signingKey
        )
        XCTAssertThrowsError(
            try KeepAwakeToggleCommand.verify(
                command,
                publicKey: keypair.publicKeyRaw,
                now: issuedAt.addingTimeInterval(KeepAwakeToggleCommand.maximumAgeSeconds + 1)
            )
        ) { error in
            XCTAssertEqual(error as? KeepAwakeToggleError, .expired)
        }
    }

    func testWrongKeyAndReplayRejected() throws {
        let keypair = IrohPairingKeypair()
        let attacker = IrohPairingKeypair()
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let command = try KeepAwakeToggleCommand.sign(
            deviceId: "iphone-1",
            enabled: true,
            issuedAt: now,
            with: keypair.signingKey
        )
        XCTAssertThrowsError(
            try KeepAwakeToggleCommand.verify(
                command,
                publicKey: attacker.publicKeyRaw,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? KeepAwakeToggleError, .invalidSignature)
        }

        var guardbox = KeepAwakeToggleReplayGuard()
        try guardbox.consume(command)
        XCTAssertThrowsError(try guardbox.consume(command)) { error in
            XCTAssertEqual(error as? KeepAwakeToggleError, .replayed)
        }
    }
}
