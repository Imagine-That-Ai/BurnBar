import Foundation
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarMissionHealthLinuxTests: XCTestCase {
    func testMissionHealth_readsAuthoritativeProjectionAndSortsHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-mission-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_710_020_000)
        let missionID = BurnBarMissionID(rawValue: "mission-health-linux")
        let packet = BurnBarMissionPacketSnapshot(
            id: BurnBarMissionPacketID(rawValue: "packet-health-linux"),
            missionID: missionID,
            workerName: "worker-a",
            objective: "Run the parity packet",
            status: .running,
            dispatchedAt: now.addingTimeInterval(-20)
        )
        let result = BurnBarMissionResultSnapshot(
            id: BurnBarMissionResultID(rawValue: "result-health-linux"),
            missionID: missionID,
            packetID: packet.id,
            status: .partial,
            summary: "Partial evidence recorded.",
            createdAt: now.addingTimeInterval(-10)
        )
        let mission = BurnBarMissionSnapshot(
            id: missionID,
            projectSlug: "burnbar",
            title: "Linux health",
            summary: "Mission health test",
            status: .inProgress,
            recommendation: .proceed,
            createdAt: now.addingTimeInterval(-30),
            updatedAt: now,
            approval: BurnBarMissionApprovalSnapshot(approved: true),
            packets: [packet],
            results: [result]
        )
        var projection = BurnBarMissionControlProjectionFile.empty(now: now)
        projection.missions[missionID.rawValue] = mission
        try JSONEncoder().encode(projection).write(
            to: root.appendingPathComponent("controller-projection.json"),
            options: .atomic
        )

        let service = BurnBarMissionControlService(
            store: BurnBarMissionControlStore(
                eventsFileURL: root.appendingPathComponent("controller-events.jsonl"),
                projectionFileURL: root.appendingPathComponent("controller-projection.json"),
                logger: BurnBarDaemonLogger(category: "linux-mission-health-tests")
            ),
            logger: BurnBarDaemonLogger(category: "linux-mission-health-tests")
        )

        let response = try await service.missionHealth(BurnBarMissionHealthRequest(missionID: missionID))

        XCTAssertEqual(response.missionID, missionID)
        XCTAssertEqual(response.health.status, .healthy)
        XCTAssertEqual(response.health.activePacketCount, 1)
        XCTAssertEqual(response.history.map(\.kind), ["packet", "result"])
        XCTAssertEqual(response.history.map(\.id), ["packet:packet-health-linux", "result:result-health-linux"])
        XCTAssertEqual(response.health.lastActivityAt, now.addingTimeInterval(-10))
    }

    func testMissionHealth_missingMissionFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-mission-health-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_710_020_100)
        try JSONEncoder().encode(BurnBarMissionControlProjectionFile.empty(now: now)).write(
            to: root.appendingPathComponent("controller-projection.json"),
            options: .atomic
        )
        let service = BurnBarMissionControlService(
            store: BurnBarMissionControlStore(
                eventsFileURL: root.appendingPathComponent("controller-events.jsonl"),
                projectionFileURL: root.appendingPathComponent("controller-projection.json"),
                logger: BurnBarDaemonLogger(category: "linux-mission-health-tests")
            ),
            logger: BurnBarDaemonLogger(category: "linux-mission-health-tests")
        )

        do {
            _ = try await service.missionHealth(
                BurnBarMissionHealthRequest(missionID: BurnBarMissionID(rawValue: "missing"))
            )
            XCTFail("missing missions must not fabricate health")
        } catch let error as BurnBarMissionControlError {
            guard case .missionNotFound = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
        }
    }
}
