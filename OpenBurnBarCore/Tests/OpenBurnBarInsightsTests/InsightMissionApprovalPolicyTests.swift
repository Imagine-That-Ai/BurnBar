import XCTest
@testable import OpenBurnBarInsights

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

    // MARK: - M1 characterization (split-brain remediation, Phase 2)
    //
    // Full verdict table for the SHARED approval policy both mission
    // authorities depend on (GUI listener today; daemon
    // `daemon.mission.authorizeRemote` in M2). This pins CURRENT behavior so
    // later routing changes (M3 shadow mode, M4 enforcement) are provably
    // behavior-preserving. A row change here is a policy change, not a test
    // update.
    func testCharacterization_M1_FullApprovalVerdictTable() {
        struct Row {
            let mode: String?
            let commands: Bool
            let fileEdits: Bool
            let expected: Bool
            let note: String
        }

        var rows: [Row] = []

        // Risky execution (commands and/or file edits) ALWAYS requires
        // approval, for every mode — known, unknown, nil, empty, whitespace.
        let riskyCombos: [(Bool, Bool)] = [(true, false), (false, true), (true, true)]
        let everyMode: [String?] = [
            "manual_all", "risky_only", "existing_policy", "read_only",
            nil, "", "   ", "surprise", "MANUAL_ALL", " Risky_Only "
        ]
        for mode in everyMode {
            for (commands, fileEdits) in riskyCombos {
                rows.append(Row(
                    mode: mode,
                    commands: commands,
                    fileEdits: fileEdits,
                    expected: true,
                    note: "risky execution must always require approval (mode=\(mode ?? "nil"))"
                ))
            }
        }

        // Non-risky verdicts are mode-driven.
        rows += [
            Row(mode: "manual_all", commands: false, fileEdits: false, expected: true,
                note: "manual_all pauses even read-only missions"),
            Row(mode: "risky_only", commands: false, fileEdits: false, expected: false,
                note: "risky_only lets read-only missions run"),
            Row(mode: "existing_policy", commands: false, fileEdits: false, expected: false,
                note: "existing_policy lets read-only missions run"),
            Row(mode: "read_only", commands: false, fileEdits: false, expected: false,
                note: "read_only mode without execution capabilities does not pause"),
            Row(mode: nil, commands: false, fileEdits: false, expected: false,
                note: "absent mode defaults open for read-only missions"),
            Row(mode: "", commands: false, fileEdits: false, expected: false,
                note: "empty mode is treated as absent"),
            Row(mode: "   \n ", commands: false, fileEdits: false, expected: false,
                note: "whitespace-only mode trims to absent"),
            // Normalization: the policy trims + lowercases before matching.
            Row(mode: " MANUAL_ALL ", commands: false, fileEdits: false, expected: true,
                note: "mode matching is case-insensitive and trimmed"),
            Row(mode: "Read_Only", commands: false, fileEdits: false, expected: false,
                note: "mode matching is case-insensitive"),
            // Unknown modes fail CLOSED even without risky execution (A4).
            Row(mode: "auto_approve", commands: false, fileEdits: false, expected: true,
                note: "unknown mode fails closed"),
            Row(mode: "manual", commands: false, fileEdits: false, expected: true,
                note: "near-miss of a known mode fails closed"),
            Row(mode: "manual_all2", commands: false, fileEdits: false, expected: true,
                note: "suffixed known mode fails closed")
        ]

        for row in rows {
            XCTAssertEqual(
                InsightMissionApprovalPolicy.requiresPreDispatchApproval(
                    approvalMode: row.mode,
                    commandsAllowed: row.commands,
                    fileEditsAllowed: row.fileEdits
                ),
                row.expected,
                "mode=\(row.mode ?? "nil") commands=\(row.commands) fileEdits=\(row.fileEdits): \(row.note)"
            )
        }
    }
}
