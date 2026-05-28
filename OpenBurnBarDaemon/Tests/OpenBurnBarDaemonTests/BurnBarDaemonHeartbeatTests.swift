import Foundation
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBarDaemon

final class BurnBarDaemonHeartbeatTests: XCTestCase {
    func test_writeAndReadSnapshot_roundTrip() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-heartbeat-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let snapshot = BurnBarDaemonHeartbeatSnapshot(
            pid: 99,
            daemonVersion: "phase0",
            protocolVersion: BurnBarProtocolVersion.current,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try BurnBarDaemonHeartbeat.writeSnapshot(snapshot, to: fileURL)
        XCTAssertEqual(BurnBarDaemonHeartbeat.readSnapshot(from: fileURL), snapshot)
    }

    func test_isStale_detectsExpiredHeartbeat() {
        let snapshot = BurnBarDaemonHeartbeatSnapshot(
            pid: 1,
            daemonVersion: "daemon",
            protocolVersion: 1,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(
            BurnBarDaemonHeartbeat.isStale(
                snapshot: snapshot,
                now: Date(timeIntervalSince1970: 60),
                maxAge: 20
            )
        )
    }
}
