import XCTest
@testable import OpenBurnBarIrohRelay

final class IrohPairingReplayGuardTests: XCTestCase {
    func testSameGuardAllowsReconnectOfConsumedRecord() async throws {
        let store = IrohPairingReplayFileStore(url: uniqueReplayURL())
        let replayGuard = IrohPairingReplayGuard(persistence: store)
        let record = try signedRecord(uid: "u-reconnect", at: Date(timeIntervalSince1970: 1_715_000_000))
        try await replayGuard.consume(record: record, now: Date(timeIntervalSince1970: 1_715_000_030))
        try await replayGuard.consume(record: record, now: Date(timeIntervalSince1970: 1_715_000_060))
        let accepted = await replayGuard.hasConsumedInThisSession(record)
        XCTAssertTrue(accepted)
    }

    func testRelaunchRejectsCapturedInWindowRecord() async throws {
        let url = uniqueReplayURL()
        let record = try signedRecord(uid: "u-relaunch", at: Date(timeIntervalSince1970: 1_715_000_000))
        let first = IrohPairingReplayGuard(persistence: IrohPairingReplayFileStore(url: url))
        try await first.consume(record: record, now: Date(timeIntervalSince1970: 1_715_000_030))

        let relaunch = IrohPairingReplayGuard(persistence: IrohPairingReplayFileStore(url: url))
        do {
            try await relaunch.consume(record: record, now: Date(timeIntervalSince1970: 1_715_000_060))
            XCTFail("relaunch must reject a captured in-window record")
        } catch IrohPairingError.replayed {
            // expected
        }
        let accepted = await relaunch.hasConsumedInThisSession(record)
        XCTAssertFalse(accepted, "inherited keys are not this-session consumes")
    }

    func testPruneExpiresInheritedKeys() async throws {
        let url = uniqueReplayURL()
        let signedAt = Date(timeIntervalSince1970: 1_715_000_000)
        let record = try signedRecord(uid: "u-prune", at: signedAt)
        let first = IrohPairingReplayGuard(persistence: IrohPairingReplayFileStore(url: url))
        try await first.consume(record: record, now: signedAt)

        let relaunch = IrohPairingReplayGuard(persistence: IrohPairingReplayFileStore(url: url))
        let later = signedAt.addingTimeInterval(IrohPairingFreshness.maximumAgeSeconds + 5)
        try await relaunch.consume(record: record, now: later, maximumAge: IrohPairingFreshness.maximumAgeSeconds)
        let accepted = await relaunch.hasConsumedInThisSession(record)
        XCTAssertTrue(accepted, "pruned inherited key may be consumed again after expiry")
    }

    func testCorruptStoreFailsClosed() async throws {
        let url = uniqueReplayURL()
        try Data("not-json".utf8).write(to: url)
        let replayGuard = IrohPairingReplayGuard(persistence: IrohPairingReplayFileStore(url: url))
        let record = try signedRecord(uid: "u-corrupt", at: Date(timeIntervalSince1970: 1_715_000_000))
        do {
            try await replayGuard.consume(record: record, now: Date(timeIntervalSince1970: 1_715_000_010))
            XCTFail("corrupt replay store must fail closed")
        } catch IrohPairingError.replayStoreUnavailable {
            // expected
        }
    }

    func testUnavailableStoreFailsClosed() async throws {
        let replayGuard = IrohPairingReplayGuard(persistence: IrohPairingReplayUnavailableStore())
        let record = try signedRecord(uid: "u-unavail", at: Date(timeIntervalSince1970: 1_715_000_000))
        do {
            try await replayGuard.consume(record: record, now: Date(timeIntervalSince1970: 1_715_000_010))
            XCTFail("unavailable store must fail closed")
        } catch IrohPairingError.replayStoreUnavailable {
            // expected
        }
    }
}

private func uniqueReplayURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("iroh-replay-\(UUID().uuidString).json")
}

private func signedRecord(uid: String, at signedAt: Date) throws -> IrohPairingRecord {
    let keypair = IrohPairingKeypair()
    return try IrohPairingSignature.sign(
        uid: uid,
        connectionId: "c-\(uid)",
        nodeId: "node-\(uid)",
        publishedAtMillis: Int64(signedAt.timeIntervalSince1970 * 1000),
        with: keypair.signingKey
    )
}
