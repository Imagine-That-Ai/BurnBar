import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

extension BurnBarMissionControlServiceTests {
    // MARK: - VAL-CROSS-008: Re-entry next action ordering is deterministic

    func testVAL_CROSS_008_ControllerSummaryNextActionsFollowDeterministicOrderingAndTieBreaks() async throws {
        let harness = try makeHarnessWithStore(name: "val-cross-008-next-actions")
        let now = Date(timeIntervalSince1970: 1_710_900_000)

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "apollo"))
        )

        func mission(
            id: String,
            status: BurnBarMissionStatus,
            recommendation: BurnBarMissionRecommendation,
            updatedAt: Date
        ) -> BurnBarMissionSnapshot {
            BurnBarMissionSnapshot(
                id: BurnBarMissionID(rawValue: id),
                projectSlug: "apollo",
                title: id,
                summary: "Mission \(id)",
                status: status,
                recommendation: recommendation,
                createdAt: now.addingTimeInterval(-3_600),
                updatedAt: updatedAt,
                approval: BurnBarMissionApprovalSnapshot(
                    approved: status != .awaitingApproval,
                    approvedAt: status == .awaitingApproval ? nil : updatedAt,
                    approvedBy: status == .awaitingApproval ? nil : "operator",
                    note: nil
                ),
                packets: [],
                results: [],
                burnRecords: [],
                takeoverHistory: nil,
                metadata: [:]
            )
        }

        let blockedA = mission(
            id: "mission-blocked-a",
            status: .failed,
            recommendation: .review,
            updatedAt: now
        )
        let blockedB = mission(
            id: "mission-blocked-b",
            status: .failed,
            recommendation: .escalate,
            updatedAt: now
        )
        let interrupted = mission(
            id: "mission-interrupted",
            status: .partiallyCompleted,
            recommendation: .pause,
            updatedAt: now.addingTimeInterval(180)
        )
        let completed = mission(
            id: "mission-completed",
            status: .completed,
            recommendation: .proceed,
            updatedAt: now.addingTimeInterval(360)
        )

        try await harness.store.injectMissionsForTieBreakTesting([completed, blockedB, interrupted, blockedA])

        let summary = try await harness.service.controllerSummary(
            BurnBarControllerSummaryRequest(projectSlug: "apollo")
        )
        let actions = try XCTUnwrap(summary.summary.nextActions)

        XCTAssertEqual(actions.map(\.missionID.rawValue), [
            "mission-blocked-a",
            "mission-blocked-b",
            "mission-interrupted",
            "mission-completed"
        ])
        XCTAssertEqual(actions.map(\.bucket), [
            .blockage,
            .blockage,
            .interruption,
            .completion
        ])
        XCTAssertEqual(actions.map(\.status), [
            .failed,
            .failed,
            .partiallyCompleted,
            .completed
        ])

        let summaryAgain = try await harness.service.controllerSummary(
            BurnBarControllerSummaryRequest(projectSlug: "apollo")
        )
        XCTAssertEqual(
            summaryAgain.summary.nextActions?.map(\.id),
            actions.map(\.id),
            "VAL-CROSS-008: Daemon summary next-action ordering should be deterministic across repeated reads"
        )
    }

    func testVAL_CROSS_009_ControllerSummaryNextActionsAreBoundedToDefaultMaximum() async throws {
        let harness = try makeHarnessWithStore(name: "val-cross-009-next-action-bound")
        let now = Date(timeIntervalSince1970: 1_710_900_000)

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "apollo"))
        )

        let missions = (0..<60).map { index in
            let id = "mission-\(String(format: "%02d", index))"
            return BurnBarMissionSnapshot(
                id: BurnBarMissionID(rawValue: id),
                projectSlug: "apollo",
                title: id,
                summary: "Mission \(id)",
                status: .failed,
                recommendation: .review,
                createdAt: now.addingTimeInterval(-3_600),
                updatedAt: now.addingTimeInterval(TimeInterval(index)),
                approval: BurnBarMissionApprovalSnapshot(
                    approved: true,
                    approvedAt: now.addingTimeInterval(TimeInterval(index)),
                    approvedBy: "operator",
                    note: nil
                ),
                packets: [],
                results: [],
                burnRecords: [],
                takeoverHistory: nil,
                metadata: [:]
            )
        }

        try await harness.store.injectMissionsForTieBreakTesting(missions)

        let summary = try await harness.service.controllerSummary(
            BurnBarControllerSummaryRequest(projectSlug: "apollo")
        )
        let actions = try XCTUnwrap(summary.summary.nextActions)

        XCTAssertEqual(actions.count, BurnBarControllerNextActionPlanner.defaultMaximumActionCount)
        XCTAssertEqual(actions.first?.missionID.rawValue, "mission-59")
        XCTAssertEqual(actions.last?.missionID.rawValue, "mission-10")
        XCTAssertFalse(actions.contains { $0.missionID.rawValue == "mission-00" })
    }
}
