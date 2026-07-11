import XCTest
@testable import OpenBurnBarIrohRelay

final class IrohPairingDirectoryTests: XCTestCase {
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
            now: now.addingTimeInterval(60)
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
                now: later
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
                now: Date()
            )
        }, expected: IrohPairingDirectoryError.recordNotFound)
    }

    func testFetchAndVerifyToleratesInWindowReplay() async throws {
        // Re-dials legitimately re-read the SAME record: the Mac only
        // republishes every ~60s while a reconnecting client retries every
        // few seconds. The implementation intentionally swallows
        // IrohPairingError.replayed within the freshness window so retries
        // succeed (observed live 2026-07-03). This test verifies that
        // behaviour: a second fetch within the signature freshness window
        // returns the dial target instead of throwing.
        let directory = InMemoryIrohPairingDirectory()
        let publisher = IrohPairingPublisher(directory: directory)
        let macKeypair = IrohPairingKeypair()
        let now = Date(timeIntervalSince1970: 1_715_000_000)
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
            now: now.addingTimeInterval(30)
        )
        // Second fetch within the freshness window should succeed (not throw).
        let replayTarget = try await publisher.fetchAndVerify(
            uid: "u-4",
            connectionId: "c-4",
            publicKey: macKeypair.publicKeyRaw,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(replayTarget.nodeId, "node-replay")
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
                now: now
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
