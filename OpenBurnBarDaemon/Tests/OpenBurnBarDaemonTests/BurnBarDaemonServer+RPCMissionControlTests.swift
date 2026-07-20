import XCTest
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon

/// Handler-level coverage for `BurnBarDaemonServer+RPCMissionControl`'s
/// aggregated controller-runtime snapshot plumbing (perf finding macos-007,
/// docs/architecture/macos-performance.md §16), beyond the end-to-end
/// socket pinning in `BurnBarDaemonControllerRuntimeSnapshotTests`:
///   * the EXACT per-list request shapes `makeControllerRuntimeSnapshotPayload`
///     issues (they must stay byte-equivalent to the app's legacy six RPCs),
///   * the empty-state snapshot,
///   * the fail path: a broken list RPC fails the aggregated snapshot,
///   * best-effort mutation embeds: question-answer and followup
///     snooze/calendar mutations carry the refreshed runtime, and a
///     snapshot failure must NOT fail a mutation that already committed.
final class BurnBarDaemonServerRPCMissionControlTests: XCTestCase {

    // MARK: - Stub mission control service

    /// Closure-driven `BurnBarMissionControlServing` so each test pins the
    /// daemon handler behavior without touching shared Mission Control
    /// storage.
    private final class StubMissionControlService: BurnBarMissionControlServing, @unchecked Sendable {
        struct StubError: Error, Equatable {
            let label: String
        }

        private let lock = NSLock()
        private var recordedCalls: [String] = []

        var calls: [String] {
            lock.withLock { recordedCalls }
        }

        private func record(_ call: String) {
            lock.withLock { recordedCalls.append(call) }
        }

        // Fixture state served by the list RPCs.
        var summary: BurnBarControllerSummary
        var questions: [BurnBarPendingQuestionSnapshot] = []
        var followups: [BurnBarFollowupSnapshot] = []
        var missions: [BurnBarMissionSnapshot] = []
        var missionHealthResult: BurnBarMissionHealthResponse?
        var notificationHealthSnapshot: BurnBarNotificationHealthSnapshot
        var simulatorRuns: [BurnBarSimulatorRunSnapshot] = []

        // Failure injection.
        var questionsListError: Error?
        var simulatorListError: Error?

        // Mutation fixtures.
        var questionAnswerResult: BurnBarQuestionAnswerResponse?
        var followupMutationResult: BurnBarFollowupMutationResponse?
        // M1 characterization fixtures: mission approve/dispatch verdicts.
        var missionMutationResult: BurnBarMissionMutationResponse?
        var missionApproveError: Error?
        var missionDispatchError: Error?

        // Captured request shapes.
        private(set) var lastQuestionsListRequest: BurnBarQuestionsListRequest?
        private(set) var lastFollowupsListRequest: BurnBarFollowupsListRequest?
        private(set) var lastSnoozeRequest: BurnBarFollowupSnoozeRequest?
        private(set) var lastCalendarRequest: BurnBarFollowupCalendarRequest?

        init(now: Date) {
            summary = BurnBarControllerSummary(
                updatedAt: now,
                counts: BurnBarControllerCounts(
                    projectCount: 0,
                    pendingQuestionCount: 0,
                    openFollowupCount: 0,
                    activeMissionCount: 0,
                    staleProjectCount: 0
                ),
                freshness: .fresh
            )
            notificationHealthSnapshot = BurnBarNotificationHealthSnapshot(checkedAt: now, channels: [])
        }

        func startBackgroundLoops() async {}
        func stopBackgroundLoops() async {}

        func controllerSummary(_ request: BurnBarControllerSummaryRequest) async throws -> BurnBarControllerSummaryResponse {
            record("controllerSummary")
            return BurnBarControllerSummaryResponse(summary: summary)
        }

        func questionsList(_ request: BurnBarQuestionsListRequest) async throws -> BurnBarQuestionsListResponse {
            record("questionsList")
            lastQuestionsListRequest = request
            if let questionsListError {
                throw questionsListError
            }
            return BurnBarQuestionsListResponse(questions: questions)
        }

        func questionAnswer(_ request: BurnBarQuestionAnswerRequest) async throws -> BurnBarQuestionAnswerResponse {
            record("questionAnswer")
            guard let questionAnswerResult else {
                throw StubError(label: "questionAnswer fixture missing")
            }
            return questionAnswerResult
        }

        func followupsList(_ request: BurnBarFollowupsListRequest) async throws -> BurnBarFollowupsListResponse {
            record("followupsList")
            lastFollowupsListRequest = request
            return BurnBarFollowupsListResponse(followups: followups)
        }

        func followupDone(_ request: BurnBarFollowupDoneRequest) async throws -> BurnBarFollowupMutationResponse {
            record("followupDone")
            guard let followupMutationResult else {
                throw StubError(label: "followupDone fixture missing")
            }
            return followupMutationResult
        }

        func followupSnooze(_ request: BurnBarFollowupSnoozeRequest) async throws -> BurnBarFollowupMutationResponse {
            record("followupSnooze")
            lastSnoozeRequest = request
            guard let followupMutationResult else {
                throw StubError(label: "followupSnooze fixture missing")
            }
            return followupMutationResult
        }

        func followupCalendar(_ request: BurnBarFollowupCalendarRequest) async throws -> BurnBarFollowupMutationResponse {
            record("followupCalendar")
            lastCalendarRequest = request
            guard let followupMutationResult else {
                throw StubError(label: "followupCalendar fixture missing")
            }
            return followupMutationResult
        }

        func missionsList(_ request: BurnBarMissionListRequest) async throws -> BurnBarMissionListResponse {
            record("missionsList")
            return BurnBarMissionListResponse(missions: missions)
        }

        func notificationHealth(_ request: BurnBarNotificationHealthRequest) async throws -> BurnBarNotificationHealthResponse {
            record("notificationHealth")
            return BurnBarNotificationHealthResponse(health: notificationHealthSnapshot)
        }

        func simulatorList(_ request: BurnBarSimulatorListRequest) async throws -> BurnBarSimulatorListResponse {
            record("simulatorList")
            if let simulatorListError {
                throw simulatorListError
            }
            return BurnBarSimulatorListResponse(runs: simulatorRuns)
        }

        // MARK: Methods outside this handler's aggregated-snapshot scope.

        func controllerProjects(_ request: BurnBarControllerProjectsListRequest) async throws -> BurnBarControllerProjectsListResponse {
            throw StubError(label: "controllerProjects unexpected")
        }

        func controllerProject(_ request: BurnBarControllerProjectGetRequest) async throws -> BurnBarControllerProjectResponse {
            throw StubError(label: "controllerProject unexpected")
        }

        func controllerProjectUpsert(_ request: BurnBarControllerProjectUpsertRequest) async throws -> BurnBarControllerProjectResponse {
            throw StubError(label: "controllerProjectUpsert unexpected")
        }

        func reviewRunRecord(_ request: BurnBarControllerReviewRunRecordRequest) async throws -> BurnBarControllerReviewRunRecordResponse {
            throw StubError(label: "reviewRunRecord unexpected")
        }

        func questionCreate(_ request: BurnBarQuestionCreateRequest) async throws -> BurnBarQuestionResponse {
            throw StubError(label: "questionCreate unexpected")
        }

        func questionGet(_ request: BurnBarQuestionGetRequest) async throws -> BurnBarQuestionResponse {
            throw StubError(label: "questionGet unexpected")
        }

        func followupCreate(_ request: BurnBarFollowupCreateRequest) async throws -> BurnBarFollowupMutationResponse {
            throw StubError(label: "followupCreate unexpected")
        }

        func missionCreate(_ request: BurnBarMissionCreateRequest) async throws -> BurnBarMissionMutationResponse {
            throw StubError(label: "missionCreate unexpected")
        }

        func missionGet(_ request: BurnBarMissionGetRequest) async throws -> BurnBarMissionResponse {
            throw StubError(label: "missionGet unexpected")
        }

        func missionHealth(_ request: BurnBarMissionHealthRequest) async throws -> BurnBarMissionHealthResponse {
            record("missionHealth")
            guard let missionHealthResult else {
                throw StubError(label: "missionHealth unexpected")
            }
            XCTAssertEqual(request.missionID, missionHealthResult.missionID)
            return missionHealthResult
        }

        func missionApprove(_ request: BurnBarMissionApproveRequest) async throws -> BurnBarMissionMutationResponse {
            record("missionApprove")
            if let missionApproveError {
                throw missionApproveError
            }
            guard let missionMutationResult else {
                throw StubError(label: "missionApprove unexpected")
            }
            return missionMutationResult
        }

        func missionCancel(_ request: BurnBarMissionCancelRequest) async throws -> BurnBarMissionMutationResponse {
            throw StubError(label: "missionCancel unexpected")
        }

        func missionDispatchPacket(_ request: BurnBarMissionDispatchPacketRequest) async throws -> BurnBarMissionMutationResponse {
            record("missionDispatchPacket")
            if let missionDispatchError {
                throw missionDispatchError
            }
            guard let missionMutationResult else {
                throw StubError(label: "missionDispatchPacket unexpected")
            }
            return missionMutationResult
        }

        func missionRecordResult(_ request: BurnBarMissionRecordResultRequest) async throws -> BurnBarMissionMutationResponse {
            throw StubError(label: "missionRecordResult unexpected")
        }

        func notificationConfigGet(_ request: BurnBarNotificationConfigGetRequest) async throws -> BurnBarNotificationConfigResponse {
            throw StubError(label: "notificationConfigGet unexpected")
        }

        func notificationConfigUpdate(_ request: BurnBarNotificationConfigUpdateRequest) async throws -> BurnBarNotificationConfigResponse {
            throw StubError(label: "notificationConfigUpdate unexpected")
        }

        func notificationCommand(_ request: BurnBarNotificationCommandRequest) async throws -> BurnBarNotificationCommandResponse {
            throw StubError(label: "notificationCommand unexpected")
        }

        func simulatorRun(_ request: BurnBarSimulatorRunRequest) async throws -> BurnBarSimulatorRunResponse {
            throw StubError(label: "simulatorRun unexpected")
        }

        func simulatorReplay(_ request: BurnBarSimulatorReplayRequest) async throws -> BurnBarSimulatorRunResponse {
            throw StubError(label: "simulatorReplay unexpected")
        }

        func projectionRebuild(_ request: BurnBarProjectionRebuildRequest) async throws -> BurnBarProjectionRebuildResponse {
            throw StubError(label: "projectionRebuild unexpected")
        }
    }

    // MARK: - Harness

    private func makeServer(service: StubMissionControlService) -> BurnBarDaemonServer {
        BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: "/tmp/openburnbar-daemon-tests-rpc-mc-\(UUID().uuidString).sock",
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            missionControlService: service
        )
    }

    private func invoke<Params: Codable & Sendable, Result: Codable & Sendable>(
        _ server: BurnBarDaemonServer,
        method: BurnBarRPCMethod,
        params: Params,
        id: String = UUID().uuidString
    ) async throws -> BurnBarRPCResponseEnvelope<Result> {
        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: method,
            authToken: "test-token",
            params: params
        )
        let requestData = try JSONEncoder().encode(request)
        let responseData = try await server.handleMissionControlRPC(
            method: method,
            decoder: JSONDecoder(),
            requestData: requestData
        )
        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Result>.self, from: responseData)
    }

    private func makeQuestion(id: String, now: Date) -> BurnBarPendingQuestionSnapshot {
        BurnBarPendingQuestionSnapshot(
            id: BurnBarQuestionID(rawValue: id),
            projectSlug: "apollo",
            title: "Approve \(id)?",
            prompt: "Continue?",
            status: .pending,
            priority: .high,
            askedAt: now
        )
    }

    private func makeFollowup(id: String, status: BurnBarFollowupStatus, now: Date) -> BurnBarFollowupSnapshot {
        BurnBarFollowupSnapshot(
            id: BurnBarFollowupID(rawValue: id),
            projectSlug: "apollo",
            title: "Follow up \(id)",
            summary: "Check on \(id).",
            status: status,
            kind: .controllerNudge,
            createdAt: now
        )
    }

    // MARK: - Aggregated snapshot

    func testMissionHealthRPC_returnsDaemonHealthAndHistory() async throws {
        let now = Date(timeIntervalSince1970: 1_710_010_000)
        let missionID = BurnBarMissionID(rawValue: "mission-health-1")
        let service = StubMissionControlService(now: now)
        service.missionHealthResult = BurnBarMissionHealthResponse(
            missionID: missionID,
            health: BurnBarMissionHealthSnapshot(
                status: .healthy,
                detail: "One packet is active.",
                checkedAt: now,
                lastActivityAt: now.addingTimeInterval(-10),
                activePacketCount: 1,
                failedResultCount: 0
            ),
            history: [
                BurnBarMissionHistoryEntry(
                    id: "packet:packet-health-1",
                    kind: "packet",
                    status: "running",
                    summary: "Worker is running.",
                    occurredAt: now.addingTimeInterval(-10)
                )
            ]
        )
        let server = makeServer(service: service)

        let response: BurnBarRPCResponseEnvelope<BurnBarMissionHealthResponse> = try await invoke(
            server,
            method: .missionHealth,
            params: BurnBarMissionHealthRequest(missionID: missionID),
            id: "mission-health-rpc-1"
        )

        XCTAssertEqual(response.id, "mission-health-rpc-1")
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?.missionID, missionID)
        XCTAssertEqual(response.result?.health.status, .healthy)
        XCTAssertEqual(response.result?.health.activePacketCount, 1)
        XCTAssertEqual(response.result?.history.first?.id, "packet:packet-health-1")
        XCTAssertEqual(service.calls, ["missionHealth"])
    }

    func testControllerRuntimeSnapshot_emptyState_returnsEmptyPayload() async throws {
        let now = Date(timeIntervalSince1970: 1_710_010_000)
        let service = StubMissionControlService(now: now)
        let server = makeServer(service: service)

        let response: BurnBarRPCResponseEnvelope<BurnBarControllerRuntimeSnapshotResponse> = try await invoke(
            server,
            method: .controllerRuntimeSnapshot,
            params: BurnBarControllerRuntimeSnapshotRequest(),
            id: "runtime-snapshot-empty-1"
        )

        XCTAssertEqual(response.id, "runtime-snapshot-empty-1")
        XCTAssertNil(response.error)
        let snapshot = try XCTUnwrap(response.result?.snapshot)
        XCTAssertTrue(snapshot.questions.isEmpty)
        XCTAssertTrue(snapshot.followups.isEmpty)
        XCTAssertTrue(snapshot.missions.isEmpty)
        XCTAssertTrue(snapshot.simulatorRuns.isEmpty)
        XCTAssertEqual(snapshot.summary.counts.pendingQuestionCount, 0)
        XCTAssertEqual(
            service.calls,
            [
                "controllerSummary",
                "questionsList",
                "followupsList",
                "missionsList",
                "notificationHealth",
                "simulatorList"
            ],
            "One aggregated RPC must fan out to exactly the six legacy list calls, in order"
        )
    }

    func testControllerRuntimeSnapshot_usesLegacyEquivalentRequestShapes() async throws {
        let now = Date(timeIntervalSince1970: 1_710_010_100)
        let service = StubMissionControlService(now: now)
        service.questions = [makeQuestion(id: "question-shape-1", now: now)]
        service.followups = [makeFollowup(id: "followup-shape-1", status: .open, now: now)]
        let server = makeServer(service: service)

        let response: BurnBarRPCResponseEnvelope<BurnBarControllerRuntimeSnapshotResponse> = try await invoke(
            server,
            method: .controllerRuntimeSnapshot,
            params: BurnBarControllerRuntimeSnapshotRequest()
        )

        let snapshot = try XCTUnwrap(response.result?.snapshot)
        XCTAssertEqual(snapshot.questions, service.questions)
        XCTAssertEqual(snapshot.followups, service.followups)

        // The aggregated answer must stay byte-equivalent to the app's
        // legacy per-list RPCs: every status, no project filter.
        let questionsRequest = try XCTUnwrap(service.lastQuestionsListRequest)
        XCTAssertNil(questionsRequest.projectSlug)
        XCTAssertEqual(questionsRequest.statuses, BurnBarPendingQuestionStatus.allCases)

        let followupsRequest = try XCTUnwrap(service.lastFollowupsListRequest)
        XCTAssertNil(followupsRequest.projectSlug)
        XCTAssertEqual(followupsRequest.statuses, BurnBarFollowupStatus.allCases)
    }

    func testControllerRuntimeSnapshot_propagatesListFailure() async throws {
        let now = Date(timeIntervalSince1970: 1_710_010_200)
        let service = StubMissionControlService(now: now)
        service.questionsListError = StubMissionControlService.StubError(label: "questions store broken")
        let server = makeServer(service: service)

        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: "runtime-snapshot-broken-1",
            method: BurnBarRPCMethod.controllerRuntimeSnapshot,
            authToken: "test-token",
            params: BurnBarControllerRuntimeSnapshotRequest()
        )
        let requestData = try JSONEncoder().encode(request)

        do {
            _ = try await server.handleMissionControlRPC(
                method: .controllerRuntimeSnapshot,
                decoder: JSONDecoder(),
                requestData: requestData
            )
            XCTFail("A failed list RPC must fail the aggregated snapshot, not fabricate one")
        } catch let error as StubMissionControlService.StubError {
            XCTAssertEqual(error.label, "questions store broken")
        }
        XCTAssertEqual(
            service.calls,
            ["controllerSummary", "questionsList"],
            "Composition must stop at the first failed list call"
        )
    }

    // MARK: - Mutation embeds

    func testQuestionAnswer_embedsPostMutationRuntimeSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_710_010_300)
        let service = StubMissionControlService(now: now)
        let answered = makeQuestion(id: "question-answer-1", now: now)
        service.questionAnswerResult = BurnBarQuestionAnswerResponse(question: answered)
        service.questions = [answered]
        let server = makeServer(service: service)

        let response: BurnBarRPCResponseEnvelope<BurnBarQuestionAnswerResponse> = try await invoke(
            server,
            method: .questionAnswer,
            params: BurnBarQuestionAnswerRequest(
                questionID: answered.id,
                answeredBy: "operator",
                answer: "Proceed."
            )
        )

        let result = try XCTUnwrap(response.result)
        XCTAssertEqual(result.question, answered)
        let embedded = try XCTUnwrap(
            result.runtimeSnapshot,
            "questionAnswer must embed the post-mutation runtime snapshot"
        )
        XCTAssertEqual(embedded.questions, [answered])
        XCTAssertEqual(
            service.calls.first, "questionAnswer",
            "The mutation must commit before the snapshot is composed"
        )
        XCTAssertTrue(service.calls.contains("simulatorList"))
    }

    func testQuestionAnswer_snapshotFailureDoesNotFailCommittedMutation() async throws {
        let now = Date(timeIntervalSince1970: 1_710_010_400)
        let service = StubMissionControlService(now: now)
        let answered = makeQuestion(id: "question-answer-2", now: now)
        service.questionAnswerResult = BurnBarQuestionAnswerResponse(question: answered)
        service.simulatorListError = StubMissionControlService.StubError(label: "simulator store broken")
        let server = makeServer(service: service)

        let response: BurnBarRPCResponseEnvelope<BurnBarQuestionAnswerResponse> = try await invoke(
            server,
            method: .questionAnswer,
            params: BurnBarQuestionAnswerRequest(
                questionID: answered.id,
                answeredBy: "operator",
                answer: "Proceed."
            )
        )

        XCTAssertNil(response.error)
        let result = try XCTUnwrap(
            response.result,
            "A snapshot failure must not fail a mutation that already committed"
        )
        XCTAssertEqual(result.question, answered)
        XCTAssertNil(
            result.runtimeSnapshot,
            "Best-effort embed: the client falls back to its legacy snapshot RPCs"
        )
    }

    func testFollowupSnooze_embedsPostMutationRuntimeSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_710_010_500)
        let service = StubMissionControlService(now: now)
        let snoozed = makeFollowup(id: "followup-snooze-1", status: .snoozed, now: now)
        service.followupMutationResult = BurnBarFollowupMutationResponse(followup: snoozed)
        service.followups = [snoozed]
        let server = makeServer(service: service)

        let until = now.addingTimeInterval(3_600)
        let response: BurnBarRPCResponseEnvelope<BurnBarFollowupMutationResponse> = try await invoke(
            server,
            method: .followupSnooze,
            params: BurnBarFollowupSnoozeRequest(
                followupID: snoozed.id,
                actor: "operator",
                snoozeUntil: until
            )
        )

        let result = try XCTUnwrap(response.result)
        XCTAssertEqual(result.followup, snoozed)
        let embedded = try XCTUnwrap(
            result.runtimeSnapshot,
            "followupSnooze must embed the post-mutation runtime snapshot"
        )
        XCTAssertEqual(embedded.followups, [snoozed])
        XCTAssertEqual(service.lastSnoozeRequest?.snoozeUntil, until)
        XCTAssertEqual(service.calls.first, "followupSnooze")
    }

    func testFollowupCalendar_embedsPostMutationRuntimeSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_710_010_600)
        let service = StubMissionControlService(now: now)
        let scheduled = makeFollowup(id: "followup-calendar-1", status: .open, now: now)
        service.followupMutationResult = BurnBarFollowupMutationResponse(followup: scheduled)
        service.followups = [scheduled]
        let server = makeServer(service: service)

        let start = now.addingTimeInterval(7_200)
        let response: BurnBarRPCResponseEnvelope<BurnBarFollowupMutationResponse> = try await invoke(
            server,
            method: .followupCalendar,
            params: BurnBarFollowupCalendarRequest(
                followupID: scheduled.id,
                actor: "operator",
                action: .create,
                entry: BurnBarCalendarEntrySnapshot(
                    externalID: nil,
                    title: "Check rollout",
                    startAt: start,
                    endAt: start.addingTimeInterval(1_800),
                    notes: "Scheduled from the handler test."
                )
            )
        )

        let result = try XCTUnwrap(response.result)
        XCTAssertEqual(result.followup, scheduled)
        let embedded = try XCTUnwrap(
            result.runtimeSnapshot,
            "followupCalendar must embed the post-mutation runtime snapshot"
        )
        XCTAssertEqual(embedded.followups, [scheduled])
        XCTAssertEqual(service.lastCalendarRequest?.entry.title, "Check rollout")
    }

    func testFollowupSnooze_snapshotFailureDoesNotFailCommittedMutation() async throws {
        let now = Date(timeIntervalSince1970: 1_710_010_700)
        let service = StubMissionControlService(now: now)
        let snoozed = makeFollowup(id: "followup-snooze-2", status: .snoozed, now: now)
        service.followupMutationResult = BurnBarFollowupMutationResponse(followup: snoozed)
        service.simulatorListError = StubMissionControlService.StubError(label: "simulator store broken")
        let server = makeServer(service: service)

        let response: BurnBarRPCResponseEnvelope<BurnBarFollowupMutationResponse> = try await invoke(
            server,
            method: .followupSnooze,
            params: BurnBarFollowupSnoozeRequest(
                followupID: snoozed.id,
                actor: "operator",
                snoozeUntil: now.addingTimeInterval(600)
            )
        )

        XCTAssertNil(response.error)
        let result = try XCTUnwrap(response.result)
        XCTAssertEqual(result.followup, snoozed)
        XCTAssertNil(result.runtimeSnapshot)
    }

    // MARK: - M1 characterization: mission verdict plumbing
    //
    // Split-brain remediation Phase 2 (M1): the handler layer must forward
    // mission approve/dispatch verdicts and verdict ERRORS from the mission
    // control service without rewriting, swallowing, or substituting them —
    // the daemon service is the authority; the RPC layer is plumbing. Pinned
    // before M2 adds `daemon.mission.authorizeRemote` beside these methods.

    private func makeMission(id: String, approved: Bool, now: Date) -> BurnBarMissionSnapshot {
        BurnBarMissionSnapshot(
            id: BurnBarMissionID(rawValue: id),
            projectSlug: "apollo",
            title: "Mission \(id)",
            summary: "Characterize verdict plumbing.",
            status: approved ? .approved : .awaitingApproval,
            recommendation: .review,
            createdAt: now,
            updatedAt: now,
            approval: BurnBarMissionApprovalSnapshot(
                approved: approved,
                approvedAt: approved ? now : nil,
                approvedBy: approved ? "operator" : nil
            )
        )
    }

    func testCharacterization_M1_MissionApproveAndDispatchForwardServiceVerdicts() async throws {
        let now = Date(timeIntervalSince1970: 1_710_011_000)
        let service = StubMissionControlService(now: now)
        let approved = makeMission(id: "mission-verdict-1", approved: true, now: now)
        service.missionMutationResult = BurnBarMissionMutationResponse(mission: approved)
        let server = makeServer(service: service)

        let approveResponse: BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse> = try await invoke(
            server,
            method: .missionApprove,
            params: BurnBarMissionApproveRequest(
                missionID: approved.id,
                actor: "operator",
                note: "table"
            )
        )
        XCTAssertNil(approveResponse.error)
        XCTAssertEqual(approveResponse.result?.mission, approved)

        let dispatchResponse: BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse> = try await invoke(
            server,
            method: .missionDispatchPacket,
            params: BurnBarMissionDispatchPacketRequest(
                missionID: approved.id,
                actor: "operator",
                packet: BurnBarMissionPacketSnapshot(
                    id: BurnBarMissionPacketID(rawValue: "packet-verdict-1"),
                    missionID: approved.id,
                    workerName: "worker",
                    objective: "Forward the verdict",
                    status: .queued
                )
            )
        )
        XCTAssertNil(dispatchResponse.error)
        XCTAssertEqual(dispatchResponse.result?.mission, approved)
        XCTAssertEqual(service.calls, ["missionApprove", "missionDispatchPacket"])
    }

    func testCharacterization_M1_MissionVerdictErrorsPropagateUntouched() async throws {
        // Table: each service-side verdict error must surface from the handler
        // AS the original typed error (responseData converts it later); the
        // handler must not catch, downgrade, or fabricate a success envelope.
        let now = Date(timeIntervalSince1970: 1_710_011_100)
        let missionID = BurnBarMissionID(rawValue: "mission-verdict-err")
        let verdictErrors: [(String, BurnBarMissionControlError)] = [
            ("not approved", .missionNotApproved(missionID)),
            ("terminal", .missionTerminal(missionID, .cancelled)),
            ("readiness fail-closed", .executionReadinessFailed(missionID, .runtimeUnavailable, "no gate")),
            ("enterprise blocked", .enterprisePolicyBlocked(missionID, .approvalRequiredByMode, "needs stamp"))
        ]

        for (label, verdictError) in verdictErrors {
            let service = StubMissionControlService(now: now)
            service.missionDispatchError = verdictError
            let server = makeServer(service: service)

            let request = BurnBarRPCRequestEnvelopeWithParams(
                id: "dispatch-verdict-error",
                method: BurnBarRPCMethod.missionDispatchPacket,
                authToken: "test-token",
                params: BurnBarMissionDispatchPacketRequest(
                    missionID: missionID,
                    actor: "operator",
                    packet: BurnBarMissionPacketSnapshot(
                        id: BurnBarMissionPacketID(rawValue: "packet-verdict-err"),
                        missionID: missionID,
                        workerName: "worker",
                        objective: "Propagate the verdict error",
                        status: .queued
                    )
                )
            )
            let requestData = try JSONEncoder().encode(request)
            do {
                _ = try await server.handleMissionControlRPC(
                    method: .missionDispatchPacket,
                    decoder: JSONDecoder(),
                    requestData: requestData
                )
                XCTFail("\(label): the handler must propagate the service verdict error")
            } catch let error as BurnBarMissionControlError {
                XCTAssertEqual(
                    error.errorDescription,
                    verdictError.errorDescription,
                    "\(label): the verdict error must propagate untouched"
                )
            }
        }
    }

    // MARK: - M2: daemon.mission.authorizeRemote round trip

    func testMissionAuthorizeRemote_roundTripsVerdictsThroughTheHandler() async throws {
        // The new authorization RPC (M2, split-brain remediation) must decode
        // the request envelope, evaluate the pure policy, and answer in the
        // result lane — never the error lane — for every verdict class.
        let now = Date(timeIntervalSince1970: 1_710_011_200)
        let service = StubMissionControlService(now: now)
        let server = makeServer(service: service)

        func request(
            trust: String,
            approvalMode: String?,
            approvalStatus: String?,
            fanOut: Int = 1
        ) -> BurnBarRemoteMissionAuthorizeRequest {
            BurnBarRemoteMissionAuthorizeRequest(
                missionID: "mission-authz-rpc-1",
                originDeviceID: "phone-1",
                originPlatform: "ios",
                executorTrustState: trust,
                promptSummary: "Summarize the failing lane",
                promptSHA256: String(repeating: "cd", count: 32),
                requestedRuntime: "hermes",
                requestedGrant: BurnBarRemoteMissionCapabilityGrantRequest(
                    commandsAllowed: false,
                    fileEditsAllowed: false
                ),
                approvalMode: approvalMode,
                approvalStatus: approvalStatus,
                entitlementTier: "ultra",
                requestedFanOutCount: fanOut
            )
        }

        struct Row {
            let name: String
            let params: BurnBarRemoteMissionAuthorizeRequest
            let expectedVerdict: BurnBarRemoteMissionAuthorizationVerdict
            let expectedReason: BurnBarRemoteMissionDenialReason?
        }
        let rows: [Row] = [
            Row(name: "authorized",
                params: request(trust: "trusted", approvalMode: "existing_policy", approvalStatus: "approved"),
                expectedVerdict: .authorized, expectedReason: nil),
            Row(name: "requires approval",
                params: request(trust: "trusted", approvalMode: "manual_all", approvalStatus: nil),
                expectedVerdict: .requiresApproval, expectedReason: nil),
            Row(name: "denied untrusted",
                params: request(trust: "pending", approvalMode: nil, approvalStatus: "approved"),
                expectedVerdict: .denied, expectedReason: .untrustedDevice),
            Row(name: "denied unknown trust (fail closed)",
                params: request(trust: "who-knows", approvalMode: nil, approvalStatus: "approved"),
                expectedVerdict: .denied, expectedReason: .unknownTrustState),
            Row(name: "denied fan-out",
                params: request(trust: "trusted", approvalMode: nil, approvalStatus: "approved", fanOut: 99),
                expectedVerdict: .denied, expectedReason: .fanOutCapExceeded)
        ]

        for row in rows {
            let response: BurnBarRPCResponseEnvelope<BurnBarRemoteMissionAuthorizeResponse> = try await invoke(
                server,
                method: .missionAuthorizeRemote,
                params: row.params,
                id: "authorize-remote-\(row.name)"
            )
            XCTAssertEqual(response.id, "authorize-remote-\(row.name)")
            XCTAssertNil(response.error, "\(row.name): verdicts ride the result lane")
            let result = try XCTUnwrap(response.result, row.name)
            XCTAssertEqual(result.verdict, row.expectedVerdict, row.name)
            XCTAssertEqual(result.deniedReason, row.expectedReason, row.name)
        }

        // The default protocol implementation is a pure policy evaluation: it
        // must never touch the mission-control store surface.
        XCTAssertEqual(
            service.calls, [],
            "authorizeRemote must not call into mission-control storage RPCs"
        )
    }
}
