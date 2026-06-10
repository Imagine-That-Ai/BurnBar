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

    func test_writeSnapshot_overwriteKeepsOwnerOnlyPermissions() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-heartbeat-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let snapshot = BurnBarDaemonHeartbeatSnapshot(
            pid: 99,
            daemonVersion: "phase0",
            protocolVersion: BurnBarProtocolVersion.current,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        // chmod runs only on first create; the atomic overwrite must keep 0o600.
        try BurnBarDaemonHeartbeat.writeSnapshot(snapshot, to: fileURL)
        try BurnBarDaemonHeartbeat.writeSnapshot(snapshot, to: fileURL)

        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue, 0o600)
    }

    func test_defaultInterval_staysWithinHalfTheStaleThreshold() {
        // A beat can land a full interval late and readers must still see a
        // fresh file; anything above threshold/2 breaks that guarantee.
        XCTAssertLessThanOrEqual(
            BurnBarDaemonHeartbeat.defaultInterval * 2,
            BurnBarDaemonHeartbeat.defaultStaleThreshold
        )
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
