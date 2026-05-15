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
            publishedAt: now,
            with: macKeypair
        )
        XCTAssertEqual(record.nodeId, "node-abc")
        XCTAssertEqual(record.publishedAtMillis, Int64(now.timeIntervalSince1970 * 1000))

        let verified = try await publisher.fetchAndVerify(
            uid: "u-1",
            connectionId: "c-1",
            publicKey: macKeypair.publicKeyRaw,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(verified, "node-abc")
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
