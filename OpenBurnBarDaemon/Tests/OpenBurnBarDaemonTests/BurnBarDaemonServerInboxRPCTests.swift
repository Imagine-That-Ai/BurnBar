import Darwin
import Foundation
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// AI Inbox RPCs exercised end to end through the production dispatch:
/// real Unix socket, `responseData` routing, `handleInboxRPC`, and the
/// lazily bootstrapped inbox service bound to the configured index database.
final class BurnBarDaemonServerInboxRPCTests: XCTestCase {
    private let authToken = "inbox-rpc-test-token"

    func test_allSixInboxRPCsDispatchThroughTheServerSocket() async throws {
        let rootURL = try makeTemporaryRoot(name: "inbox-rpc")
        let databasePath = rootURL.appendingPathComponent("openburnbar.sqlite").path

        // The index database must exist BEFORE the daemon bootstraps the inbox,
        // exactly as production requires. Seed one item and one run so every
        // read RPC has something real to return.
        let store = try BurnBarAIInboxStore(
            databasePath: databasePath,
            logger: BurnBarDaemonLogger(category: "test")
        )
        let now = Date()
        let seeded = try store.upsertItem(
            AIInboxFixtures.itemWrite(
                fingerprint: "ci_waste:rpc-seed",
                title: "95% of ci runs are wasted"
            ),
            now: now
        )
        let seedTelemetry = BurnBarInboxRunTelemetry(
            tickID: "tick_rpc_seed",
            startedAt: now,
            finishedAt: now,
            gateResult: .forced,
            egressMode: .off
        )
        try store.beginRun(seedTelemetry, gateSignature: "seed-signature")
        try store.finishRun(seedTelemetry)

        let socketPath = makeSocketPath(name: "inbox-full")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: databasePath)
        try await server.start()
        addTeardownBlock { await server.stop() }

        // 1. daemon.inbox.config.get returns the conservative defaults.
        let defaults: BurnBarRPCResponseEnvelope<BurnBarInboxConfig> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "config-get", method: .inboxConfigGet, authToken: authToken),
            socketPath: socketPath
        )
        XCTAssertNil(defaults.error)
        let defaultConfig = try XCTUnwrap(defaults.result)
        XCTAssertFalse(defaultConfig.enabled)
        XCTAssertEqual(defaultConfig.egressMode, .off)
        XCTAssertEqual(defaultConfig.tickSeconds, BurnBarInboxConfig.defaultTickSeconds)

        // 2. daemon.inbox.config.update returns the clamped, stored values.
        let update: BurnBarRPCResponseEnvelope<BurnBarInboxConfig> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "config-update",
                method: .inboxConfigUpdate,
                authToken: authToken,
                params: BurnBarInboxConfig(
                    enabled: false,
                    egressMode: .local,
                    tickSeconds: 1,
                    remotePhaseEveryNTicks: 0,
                    dailyBudgetUSD: -3
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(update.error)
        let storedConfig = try XCTUnwrap(update.result)
        XCTAssertEqual(storedConfig.egressMode, .local)
        XCTAssertEqual(
            storedConfig.tickSeconds,
            BurnBarInboxConfig.minimumTickSeconds,
            "An RPC caller cannot persist a 1-second cadence"
        )
        XCTAssertEqual(storedConfig.remotePhaseEveryNTicks, 1)
        XCTAssertEqual(storedConfig.dailyBudgetUSD, 0, "A negative budget clamps to zero")

        // 3. daemon.inbox.list returns the seeded item.
        let list: BurnBarRPCResponseEnvelope<BurnBarInboxListResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "list",
                method: .inboxList,
                authToken: authToken,
                params: BurnBarInboxListRequest()
            ),
            socketPath: socketPath
        )
        XCTAssertNil(list.error)
        let listResult = try XCTUnwrap(list.result)
        XCTAssertEqual(listResult.openCount, 1)
        XCTAssertEqual(listResult.items.first?.id, seeded.id)
        XCTAssertEqual(listResult.items.first?.kind, .ciWaste)

        // 4. daemon.inbox.get returns the full detail, and nil for unknown ids.
        let detail: BurnBarRPCResponseEnvelope<BurnBarInboxGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "get",
                method: .inboxGet,
                authToken: authToken,
                params: BurnBarInboxGetRequest(id: seeded.id)
            ),
            socketPath: socketPath
        )
        XCTAssertNil(detail.error)
        let fetched = try XCTUnwrap(detail.result?.item)
        XCTAssertEqual(fetched.summary.title, "95% of ci runs are wasted")
        XCTAssertEqual(fetched.tickID, "tick_test")

        let missing: BurnBarRPCResponseEnvelope<BurnBarInboxGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "get-missing",
                method: .inboxGet,
                authToken: authToken,
                params: BurnBarInboxGetRequest(id: "inb_does_not_exist")
            ),
            socketPath: socketPath
        )
        XCTAssertNil(missing.error)
        XCTAssertNil(missing.result?.item, "An unknown id is an empty result, not an error")

        // 5. daemon.inbox.runs.recent returns the seeded telemetry plus the
        // budget the config update just persisted.
        let runs: BurnBarRPCResponseEnvelope<BurnBarInboxRunsResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "runs",
                method: .inboxRunsRecent,
                authToken: authToken,
                params: BurnBarInboxRunsRequest(limit: 10)
            ),
            socketPath: socketPath
        )
        XCTAssertNil(runs.error)
        let runsResult = try XCTUnwrap(runs.result)
        XCTAssertEqual(runsResult.runs.first?.tickID, "tick_rpc_seed")
        XCTAssertEqual(runsResult.runs.first?.gateResult, .forced)
        XCTAssertEqual(runsResult.dailyBudgetUSD, 0, "The stored (clamped) budget is reported")

        // 6. daemon.inbox.run_now is rejected while the inbox is disabled.
        let runNow: BurnBarRPCResponseEnvelope<BurnBarInboxRunNowResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "run-now",
                method: .inboxRunNow,
                authToken: authToken,
                params: BurnBarInboxRunNowRequest(force: false)
            ),
            socketPath: socketPath
        )
        XCTAssertNil(runNow.error)
        let runNowResult = try XCTUnwrap(runNow.result)
        XCTAssertFalse(runNowResult.accepted)
        XCTAssertNil(runNowResult.tickID)
        XCTAssertEqual(runNowResult.reason, "The AI Inbox is turned off.")
    }

    /// The Founder Lens surface end to end through the production socket:
    /// thread read/reply, the plan ledger lifecycle (accept → update →
    /// grade), and the approved-memory export. Same discipline as the
    /// six-RPC test — real dispatch, real SQLite, no service shortcuts.
    func test_founderLensRPCsDispatchThroughTheServerSocket() async throws {
        let rootURL = try makeTemporaryRoot(name: "inbox-lens-rpc")
        let databasePath = rootURL.appendingPathComponent("openburnbar.sqlite").path
        _ = try BurnBarAIInboxStore(
            databasePath: databasePath,
            logger: BurnBarDaemonLogger(category: "test")
        )

        let socketPath = makeSocketPath(name: "inbox-lens")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: databasePath)
        try await server.start()
        addTeardownBlock { await server.stop() }

        // 1. thread.get for an unknown fingerprint is an empty result, not an error.
        let emptyThread: BurnBarRPCResponseEnvelope<BurnBarInboxThreadGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "thread-get",
                method: .inboxThreadGet,
                authToken: authToken,
                params: BurnBarInboxThreadGetRequest(fingerprint: "ci_waste:none")
            ),
            socketPath: socketPath
        )
        XCTAssertNil(emptyThread.error)
        XCTAssertNil(emptyThread.result?.thread)

        // 2. reply is REFUSED (inbox disabled by default) with a stated reason,
        // delivered as a result — refusals are answers, not transport errors.
        let refusedReply: BurnBarRPCResponseEnvelope<BurnBarInboxReplyResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "reply",
                method: .inboxReply,
                authToken: authToken,
                params: BurnBarInboxReplyRequest(fingerprint: "ci_waste:none", bodyMarkdown: "why?")
            ),
            socketPath: socketPath
        )
        XCTAssertNil(refusedReply.error)
        let replyResult = try XCTUnwrap(refusedReply.result)
        XCTAssertNil(replyResult.message)
        XCTAssertEqual(replyResult.refusalReason, "The AI Inbox is turned off.")

        // 3. plans.accept creates an active plan with an accepted step.
        let accept: BurnBarRPCResponseEnvelope<BurnBarInboxPlanAcceptResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "plan-accept",
                method: .inboxPlansAccept,
                authToken: authToken,
                params: BurnBarInboxPlanAcceptRequest(
                    candidate: BurnBarInboxPlanCandidate(
                        title: "Kill the CI waste loop",
                        bodyMarkdown: "Land the compile gate.",
                        horizon: .week
                    ),
                    pack: "engOps"
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(accept.error)
        let accepted = try XCTUnwrap(accept.result)
        XCTAssertEqual(accepted.plan.status, .active)
        XCTAssertEqual(accepted.step.status, .accepted)

        // An unknown pack is rejected, not stored as free text.
        let badPack: BurnBarRPCResponseEnvelope<BurnBarInboxPlanAcceptResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "plan-accept-bad",
                method: .inboxPlansAccept,
                authToken: authToken,
                params: BurnBarInboxPlanAcceptRequest(
                    candidate: BurnBarInboxPlanCandidate(title: "X", bodyMarkdown: "y"),
                    pack: "notAPack"
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(badPack.result)
        XCTAssertNotNil(badPack.error)

        // 4. plans.list and plans.get surface the accepted plan.
        let plans: BurnBarRPCResponseEnvelope<BurnBarInboxPlansListResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "plans-list",
                method: .inboxPlansList,
                authToken: authToken,
                params: BurnBarInboxPlansListRequest()
            ),
            socketPath: socketPath
        )
        XCTAssertNil(plans.error)
        XCTAssertEqual(plans.result?.plans.first?.id, accepted.plan.id)

        let plan: BurnBarRPCResponseEnvelope<BurnBarInboxPlanGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "plan-get",
                method: .inboxPlansGet,
                authToken: authToken,
                params: BurnBarInboxPlanGetRequest(id: accepted.plan.id)
            ),
            socketPath: socketPath
        )
        XCTAssertNil(plan.error)
        XCTAssertEqual(plan.result?.plan?.steps.count, 1)

        // 5. plans.update_step binds a mission and lands the step (auto-seeded
        // grade), then plans.grade overrides with the human verdict.
        let landed: BurnBarRPCResponseEnvelope<BurnBarInboxPlanUpdateStepResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "step-update",
                method: .inboxPlansUpdateStep,
                authToken: authToken,
                params: BurnBarInboxPlanUpdateStepRequest(
                    stepID: accepted.step.id,
                    status: .landed,
                    missionID: "mission_rpc"
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(landed.error)
        XCTAssertEqual(landed.result?.step.status, .landed)
        XCTAssertEqual(landed.result?.step.missionID, "mission_rpc")
        XCTAssertEqual(landed.result?.step.grade, 85, "Landing auto-seeds the grade")

        let graded: BurnBarRPCResponseEnvelope<BurnBarInboxPlanGradeResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "step-grade",
                method: .inboxPlansGrade,
                authToken: authToken,
                params: BurnBarInboxPlanGradeRequest(
                    stepID: accepted.step.id,
                    grade: 95,
                    noteMarkdown: "Shipped clean."
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(graded.error)
        XCTAssertEqual(graded.result?.step.grade, 95)
        XCTAssertEqual(graded.result?.planGradeAverage ?? 0, 95, accuracy: 0.01)

        // 6. memory.export replaces the daemon's approved-snippet set.
        let export: BurnBarRPCResponseEnvelope<BurnBarInboxMemoryExportResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "memory-export",
                method: .inboxMemoryExport,
                authToken: authToken,
                params: BurnBarInboxMemoryExportRequest(
                    entries: [
                        BurnBarInboxMemoryExportEntry(
                            memoryID: "mem_rpc",
                            provenance: "ai-inbox:plan:\(accepted.plan.id)",
                            snippetMarkdown: "Trunk must compile before merges.",
                            approvedAt: Date()
                        )
                    ]
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(export.error)
        XCTAssertEqual(export.result?.stored, 1)
    }

    func test_daemonAuthoritativeMemoryAndFollowupRPCsAreIdempotentThroughServerSocket() async throws {
        let rootURL = try makeTemporaryRoot(name: "inbox-authority-rpc")
        let databasePath = rootURL.appendingPathComponent("openburnbar.sqlite").path
        let projectURL = rootURL.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let inboxStore = try BurnBarAIInboxStore(
            databasePath: databasePath,
            logger: BurnBarDaemonLogger(category: "test")
        )
        let approvedCandidate = BurnBarInboxMemoryCandidate(
            id: "candidate-safe",
            text: "Linux parity requires the exact candidate to pass its native package smoke test.",
            kind: "decision",
            confidence: 0.95,
            citationConversationIDs: ["conversation-safe"]
        )
        let safeItem = try inboxStore.upsertItem(
            AIInboxFixtures.itemWrite(
                fingerprint: "parity:authority-safe",
                title: "Remember the exact-candidate rule",
                payload: BurnBarInboxItemPayload(memoryCandidates: [approvedCandidate])
            ),
            now: Date()
        )
        let secretCandidate = BurnBarInboxMemoryCandidate(
            id: "candidate-secret",
            text: "generic api_key=abcdefghijklmnopqrstuvwxyz123456",
            kind: "gotcha",
            confidence: 0.9,
            citationConversationIDs: []
        )
        let secretItem = try inboxStore.upsertItem(
            AIInboxFixtures.itemWrite(
                fingerprint: "parity:authority-secret",
                title: "Never remember credentials",
                payload: BurnBarInboxItemPayload(memoryCandidates: [secretCandidate])
            ),
            now: Date()
        )

        let missionStore = BurnBarMissionControlStore(
            eventsFileURL: rootURL.appendingPathComponent("controller-events.jsonl"),
            projectionFileURL: rootURL.appendingPathComponent("controller-projection.json"),
            logger: BurnBarDaemonLogger(category: "inbox-authority-rpc-tests")
        )
        let missionService = BurnBarMissionControlService(
            store: missionStore,
            logger: BurnBarDaemonLogger(category: "inbox-authority-rpc-tests"),
            activitySnapshotURL: nil,
            reviewRunLauncher: nil,
            runSnapshotLookup: nil,
            usageLedgerURL: rootURL.appendingPathComponent("usage-events.jsonl")
        )
        _ = try await missionService.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: makeMissionControlProject(slug: "burnbar"))
        )

        let socketPath = makeSocketPath(name: "inbox-authority")
        let server = makeServer(
            rootURL: rootURL,
            socketPath: socketPath,
            indexDatabasePath: databasePath,
            missionControlService: missionService
        )
        try await server.start()
        addTeardownBlock { await server.stop() }

        let staleFingerprint: BurnBarRPCResponseEnvelope<BurnBarInboxMemoryApprovalResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "memory-stale-fingerprint",
                method: .inboxMemoryCandidateApprove,
                authToken: authToken,
                params: BurnBarInboxMemoryCandidateApproveRequest(
                    itemID: safeItem.id,
                    fingerprint: "parity:stale",
                    candidateID: approvedCandidate.id,
                    projectPath: projectURL.path
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(staleFingerprint.result)
        XCTAssertEqual(staleFingerprint.error?.code, BurnBarRPCErrorCode.invalidParams)

        let approvalRequest = BurnBarInboxMemoryCandidateApproveRequest(
            itemID: safeItem.id,
            fingerprint: "parity:authority-safe",
            candidateID: approvedCandidate.id,
            projectPath: projectURL.path
        )
        let approval: BurnBarRPCResponseEnvelope<BurnBarInboxMemoryApprovalResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "memory-approve",
                method: .inboxMemoryCandidateApprove,
                authToken: authToken,
                params: approvalRequest
            ),
            socketPath: socketPath
        )
        XCTAssertNil(approval.error)
        let approvedMemory = try XCTUnwrap(approval.result)
        XCTAssertNotNil(approvedMemory.quarantineAuditHash)
        XCTAssertFalse(approvedMemory.approvalAuditHash.isEmpty)

        let approvalRetry: BurnBarRPCResponseEnvelope<BurnBarInboxMemoryApprovalResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "memory-approve-retry",
                method: .inboxMemoryCandidateApprove,
                authToken: authToken,
                params: approvalRequest
            ),
            socketPath: socketPath
        )
        XCTAssertNil(approvalRetry.error)
        XCTAssertEqual(approvalRetry.result?.memoryID, approvedMemory.memoryID)
        XCTAssertNil(
            approvalRetry.result?.quarantineAuditHash,
            "An already-approved deterministic memory must not be quarantined again"
        )
        XCTAssertEqual(approvalRetry.result?.approvalAuditHash, approvedMemory.approvalAuditHash)

        let secret: BurnBarRPCResponseEnvelope<BurnBarInboxMemoryApprovalResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "memory-secret",
                method: .inboxMemoryCandidateApprove,
                authToken: authToken,
                params: BurnBarInboxMemoryCandidateApproveRequest(
                    itemID: secretItem.id,
                    fingerprint: "parity:authority-secret",
                    candidateID: secretCandidate.id,
                    projectPath: projectURL.path
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(secret.result)
        XCTAssertEqual(secret.error?.code, BurnBarRPCErrorCode.invalidParams)
        XCTAssertTrue(secret.error?.message.localizedCaseInsensitiveContains("secret") == true)

        let accepted: BurnBarRPCResponseEnvelope<BurnBarInboxPlanAcceptResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "authority-plan-accept",
                method: .inboxPlansAccept,
                authToken: authToken,
                params: BurnBarInboxPlanAcceptRequest(
                    candidate: BurnBarInboxPlanCandidate(
                        title: "Finish Linux parity",
                        bodyMarkdown: "Build, install, and verify the exact candidate.",
                        horizon: .week
                    ),
                    pack: "engOps"
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(accepted.error)
        let acceptedStep = try XCTUnwrap(accepted.result?.step)

        let rememberRequest = BurnBarInboxPlanRememberStepRequest(
            stepID: acceptedStep.id,
            projectPath: projectURL.path
        )
        let remembered: BurnBarRPCResponseEnvelope<BurnBarInboxPlanRememberStepResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "authority-plan-remember",
                method: .inboxPlansRememberStep,
                authToken: authToken,
                params: rememberRequest
            ),
            socketPath: socketPath
        )
        XCTAssertNil(remembered.error)
        let rememberedResult = try XCTUnwrap(remembered.result)
        XCTAssertEqual(rememberedResult.step.memoryID, rememberedResult.memory.memoryID)

        let rememberedRetry: BurnBarRPCResponseEnvelope<BurnBarInboxPlanRememberStepResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "authority-plan-remember-retry",
                method: .inboxPlansRememberStep,
                authToken: authToken,
                params: rememberRequest
            ),
            socketPath: socketPath
        )
        XCTAssertNil(rememberedRetry.error)
        XCTAssertEqual(rememberedRetry.result?.memory.memoryID, rememberedResult.memory.memoryID)
        XCTAssertEqual(rememberedRetry.result?.step.memoryID, rememberedResult.memory.memoryID)

        let dueAt = Date(timeIntervalSince1970: 1_786_500_000)
        let followupRequest = BurnBarInboxPlanCreateFollowupRequest(
            stepID: acceptedStep.id,
            projectSlug: "burnbar",
            dueAt: dueAt
        )
        let followup: BurnBarRPCResponseEnvelope<BurnBarInboxPlanCreateFollowupResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "authority-plan-followup",
                method: .inboxPlansCreateFollowup,
                authToken: authToken,
                params: followupRequest
            ),
            socketPath: socketPath
        )
        XCTAssertNil(followup.error)
        let followupResult = try XCTUnwrap(followup.result)
        XCTAssertEqual(followupResult.step.followupID, followupResult.followupID)
        XCTAssertEqual(followupResult.dueAt, dueAt)

        let followupRetry: BurnBarRPCResponseEnvelope<BurnBarInboxPlanCreateFollowupResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "authority-plan-followup-retry",
                method: .inboxPlansCreateFollowup,
                authToken: authToken,
                params: followupRequest
            ),
            socketPath: socketPath
        )
        XCTAssertNil(followupRetry.error)
        XCTAssertEqual(followupRetry.result?.followupID, followupResult.followupID)
        XCTAssertEqual(followupRetry.result?.dueAt, dueAt)

        let storedFollowups = try await missionService.followupsList(
            BurnBarFollowupsListRequest(
                projectSlug: "burnbar",
                statuses: BurnBarFollowupStatus.allCases,
                limit: 10
            )
        )
        XCTAssertEqual(storedFollowups.followups.map(\.id.rawValue), [followupResult.followupID])
    }

    func test_presentationStateRPCsDispatchAndReturnPersistedDaemonTruth() async throws {
        let rootURL = try makeTemporaryRoot(name: "inbox-presentation-rpc")
        let databasePath = rootURL.appendingPathComponent("openburnbar.sqlite").path
        let store = try BurnBarAIInboxStore(
            databasePath: databasePath,
            logger: BurnBarDaemonLogger(category: "test")
        )
        let now = Date()
        let first = try store.upsertItem(
            AIInboxFixtures.itemWrite(
                fingerprint: "presentation:socket:first",
                title: "First presentation row"
            ),
            now: now
        )
        let second = try store.upsertItem(
            AIInboxFixtures.itemWrite(
                fingerprint: "presentation:socket:second",
                title: "Second presentation row"
            ),
            now: now.addingTimeInterval(1)
        )

        let socketPath = makeSocketPath(name: "inbox-presentation")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: databasePath)
        try await server.start()
        addTeardownBlock { await server.stop() }

        // 1. list returns full item detail joined to current presentation state.
        let list: BurnBarRPCResponseEnvelope<BurnBarInboxPresentationListResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "presentation-list",
                method: .inboxPresentationList,
                authToken: authToken,
                params: BurnBarInboxPresentationListRequest()
            ),
            socketPath: socketPath
        )
        XCTAssertNil(list.error)
        let listed = try XCTUnwrap(list.result)
        XCTAssertEqual(Set(listed.rows.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(listed.openCount, 2)
        XCTAssertEqual(listed.activeUnreadCount, 2)
        XCTAssertEqual(listed.rows.first(where: { $0.id == first.id })?.item.tickID, "tick_test")

        // 2. get returns one joined row and nil for an unknown id.
        let get: BurnBarRPCResponseEnvelope<BurnBarInboxPresentationGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "presentation-get",
                method: .inboxPresentationGet,
                authToken: authToken,
                params: BurnBarInboxPresentationGetRequest(id: first.id)
            ),
            socketPath: socketPath
        )
        XCTAssertNil(get.error)
        XCTAssertEqual(get.result?.row?.item.summary.title, "First presentation row")
        XCTAssertNil(get.result?.row?.presentation.readAt)

        let missing: BurnBarRPCResponseEnvelope<BurnBarInboxPresentationGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "presentation-get-missing",
                method: .inboxPresentationGet,
                authToken: authToken,
                params: BurnBarInboxPresentationGetRequest(id: "inb_missing")
            ),
            socketPath: socketPath
        )
        XCTAssertNil(missing.error)
        XCTAssertNil(missing.result?.row)

        // 3. mutate applies a closed-set human action and returns the stored row.
        let archived: BurnBarRPCResponseEnvelope<BurnBarInboxPresentationMutationResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "presentation-mutate",
                method: .inboxPresentationMutate,
                authToken: authToken,
                params: BurnBarInboxPresentationMutationRequest(itemID: first.id, action: .archive)
            ),
            socketPath: socketPath
        )
        XCTAssertNil(archived.error)
        XCTAssertNotNil(archived.result?.row.presentation.archivedAt)
        XCTAssertNotNil(archived.result?.row.presentation.readAt, "Archive must imply read")

        let archivedList: BurnBarRPCResponseEnvelope<BurnBarInboxPresentationListResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "presentation-list-archived",
                method: .inboxPresentationList,
                authToken: authToken,
                params: BurnBarInboxPresentationListRequest(isArchived: true)
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(archivedList.result?.rows.map(\.id), [first.id])
        XCTAssertEqual(archivedList.result?.activeUnreadCount, 1)

        let invalid: BurnBarRPCResponseEnvelope<BurnBarInboxPresentationMutationResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "presentation-mutate-invalid",
                method: .inboxPresentationMutate,
                authToken: authToken,
                params: BurnBarInboxPresentationMutationRequest(itemID: second.id, action: .setFeedback)
            ),
            socketPath: socketPath
        )
        XCTAssertNil(invalid.result)
        XCTAssertEqual(invalid.error?.code, BurnBarRPCErrorCode.invalidParams)

        let unknownAction: BurnBarRPCResponseEnvelope<BurnBarInboxPresentationMutationResponse> =
            try sendPayload(
                Data(
                    """
                    {"id":"presentation-unknown-action","method":"daemon.inbox.presentation.mutate",\
                    "authToken":"\(authToken)","params":{"itemID":"\(second.id)","action":"execute_sql"}}
                    """.utf8
                ),
                socketPath: socketPath
            )
        XCTAssertNil(unknownAction.result)
        XCTAssertEqual(unknownAction.error?.code, BurnBarRPCErrorCode.invalidParams)

        let unknownFeedback: BurnBarRPCResponseEnvelope<BurnBarInboxPresentationMutationResponse> =
            try sendPayload(
                Data(
                    """
                    {"id":"presentation-unknown-feedback","method":"daemon.inbox.presentation.mutate",\
                    "authToken":"\(authToken)","params":{"itemID":"\(second.id)","action":"set_feedback",\
                    "feedback":"thumbs_up"}}
                    """.utf8
                ),
                socketPath: socketPath
            )
        XCTAssertNil(unknownFeedback.result)
        XCTAssertEqual(unknownFeedback.error?.code, BurnBarRPCErrorCode.invalidParams)

        // 4. mark_all_read touches the remaining lifecycle-open unread item.
        let markAll: BurnBarRPCResponseEnvelope<BurnBarInboxPresentationMarkAllReadResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "presentation-mark-all-read",
                method: .inboxPresentationMarkAllRead,
                authToken: authToken,
                params: BurnBarInboxPresentationMarkAllReadRequest()
            ),
            socketPath: socketPath
        )
        XCTAssertNil(markAll.error)
        XCTAssertEqual(markAll.result?.updatedCount, 1)
        XCTAssertEqual(markAll.result?.activeUnreadCount, 0)

        let secondAfter: BurnBarRPCResponseEnvelope<BurnBarInboxPresentationGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "presentation-get-after-mark-all",
                method: .inboxPresentationGet,
                authToken: authToken,
                params: BurnBarInboxPresentationGetRequest(id: second.id)
            ),
            socketPath: socketPath
        )
        XCTAssertNotNil(secondAfter.result?.row?.presentation.readAt)
    }

    func test_inboxRPCsFailClosedWhenNoIndexDatabaseIsConfigured() async throws {
        let rootURL = try makeTemporaryRoot(name: "inbox-rpc-nil")
        let socketPath = makeSocketPath(name: "inbox-nil")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: nil)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let response: BurnBarRPCResponseEnvelope<BurnBarInboxConfig> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "config-get", method: .inboxConfigGet, authToken: authToken),
            socketPath: socketPath
        )

        XCTAssertNil(response.result)
        let error = try XCTUnwrap(response.error)
        XCTAssertEqual(error.code, BurnBarRPCErrorCode.internalError)
        XCTAssertTrue(
            error.message.contains("AI Inbox is not available"),
            "The error must tell the operator how to fix it: \(error.message)"
        )
    }

    // MARK: - Server construction

    private func makeServer(
        rootURL: URL,
        socketPath: String,
        indexDatabasePath: String?,
        missionControlService: (any BurnBarMissionControlServing)? = nil
    ) -> BurnBarDaemonServer {
        BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: authToken,
                indexDatabasePath: indexDatabasePath,
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "inbox-rpc-tests"),
            configStore: BurnBarConfigStore(
                fileURL: rootURL.appendingPathComponent("provider-config.json"),
                secretStore: BurnBarInMemorySecretStore(),
                logger: BurnBarDaemonLogger(category: "inbox-rpc-tests")
            ),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: rootURL.appendingPathComponent("usage-events.jsonl")
            ),
            missionControlService: missionControlService
        )
    }

    private func makeMissionControlProject(slug: String) -> BurnBarReviewProjectSnapshot {
        BurnBarReviewProjectSnapshot(
            id: "project-\(slug)",
            projectSlug: slug,
            displayName: slug.capitalized,
            summary: "OpenBurnBar Linux parity socket test project.",
            status: .healthy,
            preferredCadence: .daily,
            freshness: .provisional,
            pendingQuestionCount: 0,
            openFollowupCount: 0,
            activeMissionCount: 0,
            needsOperatorAttention: false
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
        return rootURL
    }

    private func makeSocketPath(name: String) -> String {
        "/tmp/obb-inbox-\(name)-\(String(UUID().uuidString.prefix(8))).sock"
    }

    // MARK: - Socket transport

    private func sendEnvelope<Envelope: Encodable, Response: Decodable>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        try sendPayload(try JSONEncoder().encode(envelope), socketPath: socketPath)
    }

    private func sendPayload<Response: Decodable>(
        _ payload: Data,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertNotEqual(fileDescriptor, -1)

        var noSigPipe: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = try socketAddress(for: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connectResult == 0 else {
            let code = errno
            close(fileDescriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        let framedPayload = payload + Data([0x0A])
        framedPayload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let bytesWritten = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                XCTAssertGreaterThan(bytesWritten, 0)
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 { break }
            XCTAssertGreaterThan(bytesRead, 0)
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A { break }
        }
        while response.last == 0x0A || response.last == 0x0D { response.removeLast() }

        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
    }

    private func socketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { rawBuffer[index] = byte }
        }
        return address
    }
}
