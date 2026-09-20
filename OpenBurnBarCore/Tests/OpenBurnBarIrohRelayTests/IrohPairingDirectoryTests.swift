import XCTest
@testable import OpenBurnBarIrohRelay

final class IrohPairingDirectoryTests: XCTestCase {
    private func makeGuard() -> IrohPairingReplayGuard {
        IrohPairingReplayGuard(
            persistence: IrohPairingReplayFileStore(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("iroh-dir-\(UUID().uuidString).json")
            )
        )
    }

    func testPublishAndFetchAndVerifyRoundTrip() async throws {
        let directory = InMemoryIrohPairingDirectory()
        let publisher = IrohPairingPublisher(directory: directory)
        let macKeypair = IrohPairingKeypair()
        let now = Date(timeIntervalSince1970: 1_715_000_000)

        let record = try await publisher.publish(
            uid: "u-1",
            connectionId: "c-1",
            nodeId: "node-abc",
            relayURL: "https://relay.example./",
            directAddresses: ["127.0.0.1:1234"],
            publishedAt: now,
            with: macKeypair
        )
        XCTAssertEqual(record.nodeId, "node-abc")
        XCTAssertEqual(record.relayURL, "https://relay.example./")
        XCTAssertEqual(record.directAddresses, ["127.0.0.1:1234"])
        XCTAssertEqual(record.publishedAtMillis, Int64(now.timeIntervalSince1970 * 1000))

        let verified = try await publisher.fetchAndVerify(
            uid: "u-1",
            connectionId: "c-1",
            publicKey: macKeypair.publicKeyRaw,
            now: now.addingTimeInterval(60),
            replayGuard: makeGuard()
        )
        XCTAssertEqual(verified, IrohDialTarget(
            nodeId: "node-abc",
            relayURL: "https://relay.example./",
            directAddresses: ["127.0.0.1:1234"]
        ))
    }

    func testFetchAndVerifyRejectsExpiredRecord() async throws {
        let directory = InMemoryIrohPairingDirectory()
        let publisher = IrohPairingPublisher(directory: directory)
        let macKeypair = IrohPairingKeypair()
        let signedAt = Date(timeIntervalSince1970: 1_715_000_000)
        _ = try await publisher.publish(
            uid: "u-2",
            connectionId: "c-2",
            nodeId: "node-stale",
            publishedAt: signedAt,
            with: macKeypair
        )
        let later = signedAt.addingTimeInterval(25 * 60 * 60)
        await XCTAssertThrowsErrorAsync({
            _ = try await publisher.fetchAndVerify(
                uid: "u-2",
                connectionId: "c-2",
                publicKey: macKeypair.publicKeyRaw,
                now: later,
                replayGuard: makeGuard()
            )
        }, expected: IrohPairingError.expired)
    }

    func testMissingRecordSurfacesAsRecordNotFound() async throws {
        let directory = InMemoryIrohPairingDirectory()
        let publisher = IrohPairingPublisher(directory: directory)
        await XCTAssertThrowsErrorAsync({
            _ = try await publisher.fetchAndVerify(
                uid: "u-x",
                connectionId: "c-x",
                publicKey: Data(repeating: 0xAA, count: 32),
                now: Date(),
                replayGuard: makeGuard()
            )
        }, expected: IrohPairingDirectoryError.recordNotFound)
    }

    func testFetchAndVerifyAllowsSameSessionReconnect() async throws {
        // Re-dials legitimately re-read the SAME record: the Mac only
        // republishes every ~60s while a reconnecting client retries every
        // few seconds. Same-process consume of a key this guard already
        // accepted is allowed; a new guard on the same store is not.
        let directory = InMemoryIrohPairingDirectory()
        let publisher = IrohPairingPublisher(directory: directory)
        let macKeypair = IrohPairingKeypair()
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let replayGuard = makeGuard()
        _ = try await publisher.publish(
            uid: "u-4",
            connectionId: "c-4",
            nodeId: "node-replay",
            publishedAt: now,
            with: macKeypair
        )
        _ = try await publisher.fetchAndVerify(
            uid: "u-4",
            connectionId: "c-4",
            publicKey: macKeypair.publicKeyRaw,
            now: now.addingTimeInterval(30),
            replayGuard: replayGuard
        )
        let replayTarget = try await publisher.fetchAndVerify(
            uid: "u-4",
            connectionId: "c-4",
            publicKey: macKeypair.publicKeyRaw,
            now: now.addingTimeInterval(60),
            replayGuard: replayGuard
        )
        XCTAssertEqual(replayTarget.nodeId, "node-replay")
    }

    func testFetchAndVerifyPhoneCannotWidenFirstDialPastIdleBound() async throws {
        let directory = InMemoryIrohPairingDirectory()
        let publisher = IrohPairingPublisher(directory: directory)
        let macKeypair = IrohPairingKeypair()
        let signedAt = Date(timeIntervalSince1970: 1_715_000_000)
        _ = try await publisher.publish(
            uid: "u-live",
            connectionId: "c-live",
            nodeId: "node-live",
            publishedAt: signedAt,
            with: macKeypair
        )
        let justPastIdle = signedAt.addingTimeInterval(IrohPairingFreshness.maximumAgeSeconds + 1)
        await XCTAssertThrowsErrorAsync({
            _ = try await publisher.fetchAndVerify(
                uid: "u-live",
                connectionId: "c-live",
                publicKey: macKeypair.publicKeyRaw,
                now: justPastIdle,
                remoteSessionLive: true,
                replayGuard: makeGuard()
            )
        }, expected: IrohPairingError.expired)
    }

    func testFetchAndVerifyLiveWindowAppliesOnlyAfterThisSessionFirstDial() async throws {
        let directory = InMemoryIrohPairingDirectory()
        let publisher = IrohPairingPublisher(directory: directory)
        let macKeypair = IrohPairingKeypair()
        let signedAt = Date(timeIntervalSince1970: 1_715_000_000)
        let replayGuard = makeGuard()
        _ = try await publisher.publish(
            uid: "u-live2",
            connectionId: "c-live2",
            nodeId: "node-live2",
            publishedAt: signedAt,
            with: macKeypair
        )
        _ = try await publisher.fetchAndVerify(
            uid: "u-live2",
            connectionId: "c-live2",
            publicKey: macKeypair.publicKeyRaw,
            now: signedAt.addingTimeInterval(30),
            replayGuard: replayGuard
        )
        let justPastIdle = signedAt.addingTimeInterval(IrohPairingFreshness.maximumAgeSeconds + 1)
        let liveTarget = try await publisher.fetchAndVerify(
            uid: "u-live2",
            connectionId: "c-live2",
            publicKey: macKeypair.publicKeyRaw,
            now: justPastIdle,
            remoteSessionLive: true,
            replayGuard: replayGuard
        )
        XCTAssertEqual(liveTarget.nodeId, "node-live2")
    }

    func testFetchAndVerifyRelaunchRejectsCapturedRecord() async throws {
        let directory = InMemoryIrohPairingDirectory()
        let publisher = IrohPairingPublisher(directory: directory)
        let macKeypair = IrohPairingKeypair()
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iroh-relaunch-\(UUID().uuidString).json")
        _ = try await publisher.publish(
            uid: "u-relaunch",
            connectionId: "c-relaunch",
            nodeId: "node-relaunch",
            publishedAt: now,
            with: macKeypair
        )
        _ = try await publisher.fetchAndVerify(
            uid: "u-relaunch",
            connectionId: "c-relaunch",
            publicKey: macKeypair.publicKeyRaw,
            now: now.addingTimeInterval(30),
            replayGuard: IrohPairingReplayGuard(persistence: IrohPairingReplayFileStore(url: url))
        )
        await XCTAssertThrowsErrorAsync({
            _ = try await publisher.fetchAndVerify(
                uid: "u-relaunch",
                connectionId: "c-relaunch",
                publicKey: macKeypair.publicKeyRaw,
                now: now.addingTimeInterval(60),
                replayGuard: IrohPairingReplayGuard(persistence: IrohPairingReplayFileStore(url: url))
            )
        }, expected: IrohPairingError.replayed)
    }

    func testRevokeRemovesRecord() async throws {
        let directory = InMemoryIrohPairingDirectory()
        let publisher = IrohPairingPublisher(directory: directory)
        let macKeypair = IrohPairingKeypair()
        let now = Date(timeIntervalSince1970: 1_715_000_000)
        _ = try await publisher.publish(
            uid: "u-3",
            connectionId: "c-3",
            nodeId: "node-revoked",
            publishedAt: now,
            with: macKeypair
        )
        try await directory.revoke(uid: "u-3", connectionId: "c-3")
        await XCTAssertThrowsErrorAsync({
            _ = try await publisher.fetchAndVerify(
                uid: "u-3",
                connectionId: "c-3",
                publicKey: macKeypair.publicKeyRaw,
                now: now,
                replayGuard: makeGuard()
            )
        }, expected: IrohPairingDirectoryError.recordNotFound)
    }
}

// MARK: - Helpers

func XCTAssertThrowsErrorAsync<E: Error & Equatable>(
    _ expression: () async throws -> Void,
    expected: E,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected \(expected), but expression did not throw", file: file, line: line)
    } catch let actual as E {
        XCTAssertEqual(actual, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected); got \(error)", file: file, line: line)
    }
}
