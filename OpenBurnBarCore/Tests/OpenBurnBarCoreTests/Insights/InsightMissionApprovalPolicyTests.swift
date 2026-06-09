import XCTest
@testable import OpenBurnBarCore

final class InsightMissionApprovalPolicyTests: XCTestCase {
    func testManualAllAlwaysRequiresApproval() {
        XCTAssertTrue(InsightMissionApprovalPolicy.requiresPreDispatchApproval(
            approvalMode: "manual_all",
            commandsAllowed: false,
            fileEditsAllowed: false
        ))
    }

    func testExistingPolicyRequiresApprovalForRiskyExecution() {
        XCTAssertTrue(InsightMissionApprovalPolicy.requiresPreDispatchApproval(
            approvalMode: "existing_policy",
            commandsAllowed: true,
            fileEditsAllowed: false
        ))
        XCTAssertTrue(InsightMissionApprovalPolicy.requiresPreDispatchApproval(
            approvalMode: "risky_only",
            commandsAllowed: false,
            fileEditsAllowed: true
        ))
    }

    func testReadOnlyRequiresApprovalWhenExecutionCapabilitiesRequested() {
        XCTAssertTrue(InsightMissionApprovalPolicy.requiresPreDispatchApproval(
            approvalMode: "read_only",
            commandsAllowed: true,
            fileEditsAllowed: true
        ))
    }

    func testReadOnlyWithoutExecutionCapabilitiesDoesNotPauseMission() {
        XCTAssertFalse(InsightMissionApprovalPolicy.requiresPreDispatchApproval(
            approvalMode: "read_only",
            commandsAllowed: false,
            fileEditsAllowed: false
        ))
    }

    func testSafeExistingPolicyDoesNotPauseMission() {
        XCTAssertFalse(InsightMissionApprovalPolicy.requiresPreDispatchApproval(
            approvalMode: "existing_policy",
            commandsAllowed: false,
            fileEditsAllowed: false
        ))
    }

    func testUnknownApprovalModeFailsClosed() {
        // A4: an unrecognized / spoofed approvalMode must require approval, not
        // silently dispatch — even when no risky execution is flagged.
        for mode in ["surprise", "MANUAL", "yolo", "auto_approve", "  weird  "] {
            XCTAssertTrue(
                InsightMissionApprovalPolicy.requiresPreDispatchApproval(
                    approvalMode: mode,
                    commandsAllowed: false,
                    fileEditsAllowed: false
                ),
                "approvalMode \(mode) should fail closed"
            )
        }
    }

    func testNilAndEmptyModeRemainNonBlockingWhenNotRisky() {
        // The documented default (no mode / empty) is non-blocking for a
        // read-only mission; only truly unknown strings fail closed.
        XCTAssertFalse(InsightMissionApprovalPolicy.requiresPreDispatchApproval(
            approvalMode: nil, commandsAllowed: false, fileEditsAllowed: false
        ))
        XCTAssertFalse(InsightMissionApprovalPolicy.requiresPreDispatchApproval(
            approvalMode: "", commandsAllowed: false, fileEditsAllowed: false
        ))
    }
}
