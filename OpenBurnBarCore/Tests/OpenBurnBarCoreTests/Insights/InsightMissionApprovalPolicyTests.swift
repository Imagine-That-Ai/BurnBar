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

    func testReadOnlyNeverRequiresPreDispatchApproval() {
        XCTAssertFalse(InsightMissionApprovalPolicy.requiresPreDispatchApproval(
            approvalMode: "read_only",
            commandsAllowed: true,
            fileEditsAllowed: true
        ))
    }

    func testSafeExistingPolicyDoesNotPauseMission() {
        XCTAssertFalse(InsightMissionApprovalPolicy.requiresPreDispatchApproval(
            approvalMode: "existing_policy",
            commandsAllowed: false,
            fileEditsAllowed: false
        ))
    }
}
