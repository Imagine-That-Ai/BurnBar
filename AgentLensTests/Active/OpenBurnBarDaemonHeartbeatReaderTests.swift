import XCTest
@testable import OpenBurnBar

final class OpenBurnBarDaemonHeartbeatReaderTests: XCTestCase {
    func test_readSnapshot_decodesWrittenPayload() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartbeat-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let expected = OpenBurnBarDaemonHeartbeatSnapshot(
            pid: 4242,
            daemonVersion: "test-daemon",
            protocolVersion: 1,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(expected).write(to: fileURL)

        let decoded = OpenBurnBarDaemonHeartbeatReader.readSnapshot(from: fileURL)
        XCTAssertEqual(decoded, expected)
    }

    func test_isStale_returnsTrueWhenSnapshotMissing() {
        XCTAssertTrue(OpenBurnBarDaemonHeartbeatReader.isStale(snapshot: nil))
    }

    func test_isStale_returnsTrueWhenHeartbeatIsOlderThanThreshold() {
        let snapshot = OpenBurnBarDaemonHeartbeatSnapshot(
            pid: 1,
            daemonVersion: "daemon",
            protocolVersion: 1,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(
            OpenBurnBarDaemonHeartbeatReader.isStale(
                snapshot: snapshot,
                now: Date(timeIntervalSince1970: 100),
                maxAge: 20
            )
        )
    }
}
