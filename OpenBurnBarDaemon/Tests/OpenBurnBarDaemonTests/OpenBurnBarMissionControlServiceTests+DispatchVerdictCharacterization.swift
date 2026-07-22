import XCTest
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon

// M1 characterization (split-brain remediation, Phase 2 —
// docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md).
//
// One table-driven suite pinning the daemon mission authority's CURRENT
// dispatch verdict matrix — approval gate, terminal gate, fail-closed
// execution-readiness gate, and the enterprise packet-fingerprint stamp —
// so the M2 authorization RPC and the M3/M4 routing changes are provably
// behavior-preserving. Individual VAL-DAEMON-009/011 and VAL-CROSS-012
// tests in the main suite cover side-effect details (launcher never called,
// persisted block metadata); this table pins the verdict surface itself.
//
// Lives in its own file as an extension of the same XCTestCase because the
// main suite file sits at the SwiftLint file_length ratchet.
extension BurnBarMissionControlServiceTests {

    // MARK: - Fixtures

    fileprivate enum DispatchOutcome: Equatable {
        case dispatched
        case missionNotApproved
        case missionTerminal(BurnBarMissionStatus)
        case readinessFailed(BurnBarExecutionReadinessCode)
        case enterpriseBlocked(BurnBarEnterprisePolicyReasonCode)
        case otherError(String)
    }

    fileprivate struct DispatchScenario {
        let name: String
        /// Approve the mission before dispatch.
        var approve = true
        /// Cancel the mission (after any approval) so it is terminal.
        var cancel = false
        /// nil = no gate configured (must fail closed); .some(nil-returning) = pass;
        /// .some(failure-returning) = explicit failure.
        var readinessGate: BurnBarExecutionReadinessGate?
        /// Project-level enterprise approval mode metadata, if any.
        var enterpriseApprovalMode: String?
        /// Re-approve AFTER the first blocked dispatch so the daemon stamps the
        /// blocked packet's fingerprint, then dispatch again.
        var stampBlockedPacketThenRetry = false
        /// Mutate the packet contents between the daemon stamp and the retry
        /// (fingerprint mismatch).
        var tamperPacketAfterStamp = false
        let expected: DispatchOutcome
    }

    fileprivate func characterizationProject(
        slug: String,
        enterpriseApprovalMode: String?
    ) -> BurnBarReviewProjectSnapshot {
        var metadata: BurnBarMetadata = [:]
        if let enterpriseApprovalMode {
            metadata["enterprise_approval_mode"] = .string(enterpriseApprovalMode)
        }
        return BurnBarReviewProjectSnapshot(
            id: "project-\(slug)",
            projectSlug: slug,
            displayName: slug.capitalized,
            summary: "Dispatch verdict characterization fixture.",
            status: .healthy,
            preferredCadence: .daily,
            freshness: .provisional,
            pendingQuestionCount: 0,
            openFollowupCount: 0,
            activeMissionCount: 0,
            needsOperatorAttention: false,
            metadata: metadata
        )
    }

    fileprivate func dispatchOutcome(
        of scenario: DispatchScenario,
        index: Int
    ) async throws -> DispatchOutcome {
        let harness = try makeHarness(
            name: "m1-dispatch-verdict-\(index)",
            executionReadinessGate: scenario.readinessGate
        )
        let slug = "verdict-\(index)"
        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(
                project: characterizationProject(
                    slug: slug,
                    enterpriseApprovalMode: scenario.enterpriseApprovalMode
                )
            )
        )
        let created = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: slug,
                title: "Verdict table mission",
                summary: scenario.name,
                createdBy: "characterization",
                recommendation: .review
            )
        )
        let missionID = created.mission.id
        if scenario.approve {
            _ = try await harness.service.missionApprove(
                BurnBarMissionApproveRequest(missionID: missionID, actor: "operator", note: "table")
            )
        }
        if scenario.cancel {
            _ = try await harness.service.missionCancel(
                BurnBarMissionCancelRequest(missionID: missionID, actor: "operator", note: "table")
            )
        }

        var packet = BurnBarMissionPacketSnapshot(
            id: BurnBarMissionPacketID(rawValue: "packet-verdict-\(index)"),
            missionID: missionID,
            workerName: "verdict-worker",
            objective: "Characterize the dispatch verdict",
            status: .queued
        )

        func attempt() async -> DispatchOutcome {
            do {
                _ = try await harness.service.missionDispatchPacket(
                    BurnBarMissionDispatchPacketRequest(
                        missionID: missionID,
                        actor: "operator",
                        packet: packet
                    )
                )
                return .dispatched
            } catch let error as BurnBarMissionControlError {
                switch error {
                case .missionNotApproved:
                    return .missionNotApproved
                case .missionTerminal(_, let status):
                    return .missionTerminal(status)
                case .executionReadinessFailed(_, let code, _):
                    return .readinessFailed(code)
                case .enterprisePolicyBlocked(_, let reasonCode, _):
                    return .enterpriseBlocked(reasonCode)
                default:
                    return .otherError("\(error)")
                }
            } catch {
                return .otherError("\(error)")
            }
        }

        var outcome = await attempt()
        if scenario.stampBlockedPacketThenRetry {
            guard case .enterpriseBlocked = outcome else {
                return .otherError("expected an enterprise block before the stamp, got \(outcome)")
            }
            // Re-approval stamps the blocked packet's daemon-computed fingerprint.
            _ = try await harness.service.missionApprove(
                BurnBarMissionApproveRequest(
                    missionID: missionID,
                    actor: "operator",
                    note: "stamp blocked packet"
                )
            )
            if scenario.tamperPacketAfterStamp {
                packet = BurnBarMissionPacketSnapshot(
                    id: packet.id,
                    missionID: missionID,
                    workerName: packet.workerName,
                    objective: "Tampered objective after the daemon stamp",
                    status: packet.status,
                    metadata: packet.metadata
                )
            }
            outcome = await attempt()
        }
        return outcome
    }

    // MARK: - The table

    func testCharacterization_M1_DispatchVerdictTable() async throws {
        let passGate: BurnBarExecutionReadinessGate = { _, _ in nil }
        let missingCredentialGate: BurnBarExecutionReadinessGate = { _, _ in
            BurnBarExecutionReadiness(code: .missingCredential, detail: "no credential")
        }
        let runtimeDownGate: BurnBarExecutionReadinessGate = { _, _ in
            BurnBarExecutionReadiness(code: .runtimeUnavailable, detail: "runtime down")
        }

        let table: [DispatchScenario] = [
            DispatchScenario(
                name: "unapproved mission is refused before any side effect",
                approve: false,
                readinessGate: passGate,
                expected: .missionNotApproved
            ),
            DispatchScenario(
                name: "unapproved wins over a missing readiness gate (approval checked first)",
                approve: false,
                readinessGate: nil,
                expected: .missionNotApproved
            ),
            DispatchScenario(
                name: "terminal (cancelled) mission is refused even when approved",
                cancel: true,
                readinessGate: passGate,
                expected: .missionTerminal(.cancelled)
            ),
            DispatchScenario(
                name: "approved + NO readiness gate configured fails CLOSED",
                readinessGate: nil,
                expected: .readinessFailed(.runtimeUnavailable)
            ),
            DispatchScenario(
                name: "approved + failing readiness gate surfaces the gate's code",
                readinessGate: missingCredentialGate,
                expected: .readinessFailed(.missingCredential)
            ),
            DispatchScenario(
                name: "approved + runtime-unavailable readiness gate surfaces runtimeUnavailable",
                readinessGate: runtimeDownGate,
                expected: .readinessFailed(.runtimeUnavailable)
            ),
            DispatchScenario(
                name: "approved + passing readiness gate dispatches",
                readinessGate: passGate,
                expected: .dispatched
            ),
            DispatchScenario(
                name: "enterprise manual_all without a daemon-stamped packet fingerprint is blocked",
                readinessGate: passGate,
                enterpriseApprovalMode: "manual_all",
                expected: .enterpriseBlocked(.approvalRequiredByMode)
            ),
            DispatchScenario(
                name: "enterprise manual_all with a matching daemon-stamped fingerprint dispatches",
                readinessGate: passGate,
                enterpriseApprovalMode: "manual_all",
                stampBlockedPacketThenRetry: true,
                expected: .dispatched
            ),
            DispatchScenario(
                name: "enterprise manual_all with a MISMATCHED fingerprint (tampered packet) stays blocked",
                readinessGate: passGate,
                enterpriseApprovalMode: "manual_all",
                stampBlockedPacketThenRetry: true,
                tamperPacketAfterStamp: true,
                expected: .enterpriseBlocked(.approvalRequiredByMode)
            ),
            DispatchScenario(
                name: "unknown enterprise approval mode fails CLOSED as configuration-invalid",
                readinessGate: passGate,
                enterpriseApprovalMode: "yolo_mode",
                expected: .enterpriseBlocked(.configurationInvalid)
            )
        ]

        for (index, scenario) in table.enumerated() {
            let outcome = try await dispatchOutcome(of: scenario, index: index)
            XCTAssertEqual(outcome, scenario.expected, "row \(index): \(scenario.name)")
        }
    }
}
