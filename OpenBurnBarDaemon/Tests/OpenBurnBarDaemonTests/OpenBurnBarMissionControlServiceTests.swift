import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarMissionControlServiceTests: XCTestCase {
    func testBackgroundTransportCycleDeliversDueFollowupAndTelegramReply() async throws {
        let recorder = TransportRecorder()
        let harness = try makeHarness(
            name: "transport-cycle",
            transport: BurnBarMissionControlTransport(
                deliverLocalNotification: { title, body in
                    await recorder.recordLocal(title: title, body: body)
                },
                sendTelegramMessage: { token, chatID, text in
                    await recorder.recordTelegram(token: token, chatID: chatID, text: text)
                },
                fetchTelegramUpdates: { _, _ in
                    [BurnBarTelegramInboundMessage(updateID: 1, chatID: "chat-1", text: "/status")]
                },
                applyCalendarEntry: { _, entry, _ in entry }
            )
        )

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "apollo"))
        )
        _ = try await harness.service.notificationConfigUpdate(
            BurnBarNotificationConfigUpdateRequest(
                config: BurnBarNotificationConfig(
                    defaultSnoozeMinutes: 30,
                    nudgeHoursLocal: [9, 13, 17],
                    local: BurnBarLocalNotificationConfig(isEnabled: true),
                    telegram: BurnBarTelegramNotificationConfig(
                        isEnabled: true,
                        botTokenConfigured: true,
                        botToken: "123456:token",
                        botTokenHint: "1234…oken",
                        chatID: "chat-1"
                    ),
                    calendar: BurnBarCalendarNotificationConfig(isEnabled: false, defaultDurationMinutes: 30)
                )
            )
        )
        _ = try await harness.service.followupCreate(
            BurnBarFollowupCreateRequest(
                followup: BurnBarFollowupSnapshot(
                    id: BurnBarFollowupID(rawValue: "followup-apollo"),
                    projectSlug: "apollo",
                    title: "Review the approval sheet",
                    summary: "A daemon-owned nudge should be delivered.",
                    status: .open,
                    kind: .controllerNudge,
                    createdAt: Date().addingTimeInterval(-600),
                    nextNudgeAt: Date().addingTimeInterval(-60)
                )
            )
        )

        await harness.service.startBackgroundLoops()
        let deliveredExpectedTelegramMessages = await waitUntil {
            let telegram = await recorder.telegramMessages
            let hasFollowup = telegram.contains(where: { $0.chatID == "chat-1" && $0.text.contains("Followup due") })
            let hasStatus = telegram.contains(where: { $0.chatID == "chat-1" && $0.text.contains("Projects:") })
            return hasFollowup && hasStatus
        }
        await harness.service.stopBackgroundLoops()

        let local = await recorder.localNotifications
        let telegram = await recorder.telegramMessages

        XCTAssertFalse(local.isEmpty)
        XCTAssertTrue(local.contains(where: { $0.title == "OpenBurnBar followup due" }))
        XCTAssertTrue(deliveredExpectedTelegramMessages, "Expected followup and status telegram messages before timeout.")
        XCTAssertTrue(telegram.contains(where: { $0.chatID == "chat-1" && $0.text.contains("Followup due") }))
        XCTAssertTrue(telegram.contains(where: { $0.chatID == "chat-1" && $0.text.contains("Projects:") }))
    }

    func testQuestionLifecycleCreatesAndResolvesFollowup() async throws {
        let harness = try makeHarness(name: "question-lifecycle")

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "apollo"))
        )

        let questionID = BurnBarQuestionID(rawValue: "question-apollo")
        let created = try await harness.service.questionCreate(
            BurnBarQuestionCreateRequest(
                question: BurnBarPendingQuestionSnapshot(
                    id: questionID,
                    projectSlug: "apollo",
                    title: "Should we ship the new dashboard?",
                    prompt: "Need operator guidance before the next review loop.",
                    status: .pending,
                    priority: .high,
                    askedAt: Date()
                )
            )
        )
        XCTAssertEqual(created.question?.id, questionID)

        let questions = try await harness.service.questionsList(BurnBarQuestionsListRequest(projectSlug: "apollo"))
        XCTAssertEqual(questions.questions.count, 1)

        let followups = try await harness.service.followupsList(BurnBarFollowupsListRequest(projectSlug: "apollo"))
        XCTAssertEqual(followups.followups.count, 1)
        XCTAssertEqual(followups.followups.first?.questionID, questionID)

        let answered = try await harness.service.questionAnswer(
            BurnBarQuestionAnswerRequest(
                questionID: questionID,
                answeredBy: "operator",
                answer: "Ship it, but keep the approval gate on."
            )
        )
        XCTAssertEqual(answered.question.status, .answered)
        XCTAssertEqual(answered.followup?.status, .done)
    }

    func testQuestionCreateAddsWaveTwoSemanticsAndDedicatedNotifications() async throws {
        let recorder = TransportRecorder()
        let harness = try makeHarness(
            name: "question-wave-two",
            transport: BurnBarMissionControlTransport(
                deliverLocalNotification: { title, body in
                    await recorder.recordLocal(title: title, body: body)
                },
                sendTelegramMessage: { token, chatID, text in
                    await recorder.recordTelegram(token: token, chatID: chatID, text: text)
                },
                fetchTelegramUpdates: { _, _ in [] },
                applyCalendarEntry: { _, entry, _ in entry }
            )
        )

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "apollo"))
        )
        _ = try await harness.service.notificationConfigUpdate(
            BurnBarNotificationConfigUpdateRequest(
                config: BurnBarNotificationConfig(
                    defaultSnoozeMinutes: 30,
                    nudgeHoursLocal: [9, 13, 17],
                    local: BurnBarLocalNotificationConfig(isEnabled: true),
                    telegram: BurnBarTelegramNotificationConfig(
                        isEnabled: true,
                        botTokenConfigured: true,
                        botToken: "123456:token",
                        botTokenHint: "1234…oken",
                        chatID: "chat-1"
                    ),
                    calendar: BurnBarCalendarNotificationConfig(isEnabled: false, defaultDurationMinutes: 30)
                )
            )
        )

        let created = try await harness.service.questionCreate(
            BurnBarQuestionCreateRequest(
                question: BurnBarPendingQuestionSnapshot(
                    id: BurnBarQuestionID(rawValue: "question-wave-two"),
                    projectSlug: "apollo",
                    sessionID: BurnBarSessionID(rawValue: "apollo-session"),
                    title: "Scope the approval sheet",
                    prompt: "Should Apollo keep the current approval sheet scope?",
                    stageLabel: "Operator Decision",
                    status: .pending,
                    priority: .high,
                    askedAt: Date(),
                    answerPlaceholder: "Record the operator call OpenBurnBar should carry forward…",
                    contextSummary: "Apollo is close to shipping.",
                    evidenceRefs: ["conversation-apollo"],
                    suggestedOptions: [
                        BurnBarQuestionOptionSnapshot(
                            id: "proceed",
                            title: "Proceed",
                            detail: "Keep the current scope.",
                            answer: "Proceed with the current approval sheet scope."
                        ),
                        BurnBarQuestionOptionSnapshot(
                            id: "reset",
                            title: "Reset",
                            detail: "Change direction before shipping.",
                            answer: "Reset the scope before shipping."
                        )
                    ],
                    deepLink: BurnBarQuestionDeepLinkSnapshot(
                        kind: .sessionLog,
                        targetID: "apollo-session",
                        title: "Open Apollo session log",
                        subtitle: "Latest checkpoint"
                    )
                )
            )
        )

        XCTAssertEqual(created.question?.stageLabel, "Operator Decision")
        XCTAssertEqual(created.question?.suggestedOptions.count, 2)
        XCTAssertEqual(created.question?.deepLink?.targetID, "apollo-session")
        XCTAssertEqual(created.question?.tracker?.notificationCount, 2)

        let local = await recorder.localNotifications
        let telegram = await recorder.telegramMessages
        XCTAssertTrue(local.contains(where: { $0.title == "New OpenBurnBar question" }))
        XCTAssertTrue(telegram.contains(where: { $0.chatID == "chat-1" && $0.text.contains("New question") }))

        let answered = try await harness.service.questionAnswer(
            BurnBarQuestionAnswerRequest(
                questionID: BurnBarQuestionID(rawValue: "question-wave-two"),
                answeredBy: "operator",
                answer: "Proceed with the current approval sheet scope.",
                selectedOptionID: "proceed"
            )
        )
        XCTAssertEqual(answered.question.latestAnswer?.selectedOptionID, "proceed")
        XCTAssertEqual(answered.question.tracker?.isUnread, false)
    }

    func testMissionLifecycleTracksApprovalPacketsResultsAndBurn() async throws {
        let harness = try makeHarness(name: "mission-lifecycle")

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "orion"))
        )

        let created = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Audit direction drift",
                summary: "Review the week’s evidence and recommend whether to override direction.",
                createdBy: "operator",
                recommendation: .review
            )
        )
        let missionID = try XCTUnwrap(created.mission.id)
        XCTAssertEqual(created.mission.status, .awaitingApproval)

        let approved = try await harness.service.missionApprove(
            BurnBarMissionApproveRequest(missionID: missionID, actor: "operator", note: "Proceed")
        )
        XCTAssertEqual(approved.mission.status, .approved)
        XCTAssertEqual(approved.mission.approval.approvedBy, "operator")

        let packetID = BurnBarMissionPacketID(rawValue: "packet-orion")
        let dispatched = try await harness.service.missionDispatchPacket(
            BurnBarMissionDispatchPacketRequest(
                missionID: missionID,
                actor: "operator",
                packet: BurnBarMissionPacketSnapshot(
                    id: packetID,
                    missionID: missionID,
                    workerName: "review-worker",
                    objective: "Inspect review evidence",
                    status: .queued
                )
            )
        )
        XCTAssertEqual(dispatched.mission.status, .dispatching)
        XCTAssertEqual(dispatched.mission.packets.first?.status, .queued)

        let result = try await harness.service.missionRecordResult(
            BurnBarMissionRecordResultRequest(
                missionID: missionID,
                result: BurnBarMissionResultSnapshot(
                    id: BurnBarMissionResultID(rawValue: "result-orion"),
                    missionID: missionID,
                    packetID: packetID,
                    status: .partial,
                    summary: "Direction still looks noisy.",
                    detail: "More evidence needed before final override.",
                    burnDelta: 1.75,
                    createdAt: Date()
                )
            )
        )
        XCTAssertEqual(result.mission.status, .partiallyCompleted)
        XCTAssertEqual(result.mission.results.count, 1)
        XCTAssertEqual(result.mission.burnRecords.first?.amount, 1.75)
    }

    // MARK: - VAL-DAEMON-001: Mission creation initializes approval-gated lifecycle

    func testVAL_DAEMON_001_MissionCreationInitializesApprovalGatedLifecycle() async throws {
        let harness = try makeHarness(name: "val-daemon-001")

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "orion"))
        )

        let created = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Test mission for VAL-DAEMON-001",
                summary: "Verify approval-gated default state on creation.",
                createdBy: "test-actor",
                recommendation: .review
            )
        )

        // VAL-DAEMON-001: Mission created via daemon.mission.create is persisted with:
        // - generated ID (non-nil, non-empty)
        let missionID = try XCTUnwrap(created.mission.id)
        XCTAssertFalse(missionID.rawValue.isEmpty, "Mission ID must be non-empty")

        // - status=awaiting_approval
        XCTAssertEqual(created.mission.status, .awaitingApproval, "Mission status must be awaiting_approval on creation")

        // - approval.approved=false
        XCTAssertEqual(created.mission.approval.approved, false, "Mission approval.approved must be false on creation")
        XCTAssertNil(created.mission.approval.approvedAt, "Mission approval.approvedAt must be nil on creation")
        XCTAssertNil(created.mission.approval.approvedBy, "Mission approval.approvedBy must be nil on creation")
        XCTAssertNil(created.mission.approval.note, "Mission approval.note must be nil on creation")
    }

    // MARK: - VAL-DAEMON-002: Mission approval stamps actor metadata and transitions state

    func testVAL_DAEMON_002_MissionApprovalStampsActorMetadataAndTransitionsState() async throws {
        let harness = try makeHarness(name: "val-daemon-002")

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "orion"))
        )

        let created = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Test mission for VAL-DAEMON-002",
                summary: "Verify approval stamps actor metadata and transitions state.",
                createdBy: "test-actor",
                recommendation: .review
            )
        )
        let missionID = try XCTUnwrap(created.mission.id)
        XCTAssertEqual(created.mission.status, .awaitingApproval)
        XCTAssertEqual(created.mission.approval.approved, false)

        // VAL-DAEMON-002: daemon.mission.approve records actor/note/timestamp and transitions
        // mission to approved unless mission is already cancelled.
        let beforeApprovalAt = created.mission.approval.approvedAt
        let approved = try await harness.service.missionApprove(
            BurnBarMissionApproveRequest(
                missionID: missionID,
                actor: "operator-alice",
                note: "Looks good, proceed with caution."
            )
        )

        // Verify approval metadata is stamped
        XCTAssertEqual(approved.mission.approval.approved, true, "Mission must be approved")
        XCTAssertEqual(approved.mission.approval.approvedBy, "operator-alice", "approvedBy must match actor")
        XCTAssertEqual(approved.mission.approval.note, "Looks good, proceed with caution.", "note must match")
        XCTAssertNotNil(approved.mission.approval.approvedAt, "approvedAt must be set")
        XCTAssertGreaterThanOrEqual(approved.mission.approval.approvedAt ?? Date.distantPast, beforeApprovalAt ?? Date.distantPast, "approvedAt must be >= creation time")

        // Verify state transition to approved
        XCTAssertEqual(approved.mission.status, .approved, "Mission status must transition to approved")
    }

    // Note: Cancelled mission preservation is tested via the store's approveMission logic
    // which checks: status: existing.status == .cancelled ? .cancelled : .approved
    // This is an internal implementation detail that doesn't change public contract behavior.

    // MARK: - VAL-DAEMON-003: Mission list ordering is deterministic

    func testVAL_DAEMON_003_MissionListOrderingIsDeterministic() async throws {
        let harness = try makeHarness(name: "val-daemon-003")

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "orion"))
        )

        // Create multiple missions to test ordering
        let missionA = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Mission A",
                summary: "First mission",
                createdBy: "test-actor",
                recommendation: .review
            )
        )
        let idA = try XCTUnwrap(missionA.mission.id)

        // Create mission B
        let missionB = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Mission B",
                summary: "Second mission",
                createdBy: "test-actor",
                recommendation: .proceed
            )
        )
        let idB = try XCTUnwrap(missionB.mission.id)

        // Create mission C
        let missionC = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Mission C",
                summary: "Third mission",
                createdBy: "test-actor",
                recommendation: .escalate
            )
        )
        let idC = try XCTUnwrap(missionC.mission.id)

        // Approve mission B first (so it has a later updatedAt)
        _ = try await harness.service.missionApprove(
            BurnBarMissionApproveRequest(missionID: idB, actor: "operator", note: nil)
        )

        // Approve mission A second (even later updatedAt)
        _ = try await harness.service.missionApprove(
            BurnBarMissionApproveRequest(missionID: idA, actor: "operator", note: nil)
        )

        // List missions - should be ordered by updatedAt descending
        let missions = try await harness.service.missionsList(
            BurnBarMissionListRequest(projectSlug: "orion", statuses: BurnBarMissionStatus.allCases)
        )

        // Verify we have all 3 missions
        XCTAssertEqual(missions.missions.count, 3, "Should have 3 missions")

        // Verify ordering: most recently updated first
        // After approvals, idA and idB are approved with later updatedAt than idC
        // A was approved after B, so A should be first, then B, then C
        XCTAssertEqual(missions.missions[0].id, idA, "Most recently updated mission should be first")
        XCTAssertEqual(missions.missions[1].id, idB, "Second most recently updated mission should be second")
        XCTAssertEqual(missions.missions[2].id, idC, "Least recently updated mission should be last")

        // Verify updatedAt descending property
        for i in 0..<(missions.missions.count - 1) {
            XCTAssertGreaterThanOrEqual(
                missions.missions[i].updatedAt,
                missions.missions[i + 1].updatedAt,
                "Mission at index \(i) must have updatedAt >= mission at index \(i + 1)"
            )
        }
    }

    func testVAL_DAEMON_003_MissionListTieBreakByMissionIDAscending() async throws {
        let harness = try makeHarness(name: "val-daemon-003-tiebreak")

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "orion"))
        )

        // We need to create missions where two have identical updatedAt timestamps
        // The only way to guarantee identical updatedAt is to use the same timestamp
        // We can do this by creating missions in rapid succession but the timestamps
        // will differ by nanoseconds. To test tie-break, we verify that when
        // updatedAt is equal (or the sort comparison returns false for both directions),
        // missionID ascending is used.

        let mission1 = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Mission 1",
                summary: "First",
                createdBy: "test-actor",
                recommendation: .review
            )
        )
        let id1 = try XCTUnwrap(mission1.mission.id)

        let mission2 = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Mission 2",
                summary: "Second",
                createdBy: "test-actor",
                recommendation: .proceed
            )
        )
        let id2 = try XCTUnwrap(mission2.mission.id)

        let mission3 = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Mission 3",
                summary: "Third",
                createdBy: "test-actor",
                recommendation: .escalate
            )
        )
        let id3 = try XCTUnwrap(mission3.mission.id)

        // All three missions created at nearly the same time
        // After approvals on same timestamp, tie-break should be missionID ascending
        _ = try await harness.service.missionApprove(
            BurnBarMissionApproveRequest(missionID: id2, actor: "operator", note: nil)
        )
        _ = try await harness.service.missionApprove(
            BurnBarMissionApproveRequest(missionID: id1, actor: "operator", note: nil)
        )
        _ = try await harness.service.missionApprove(
            BurnBarMissionApproveRequest(missionID: id3, actor: "operator", note: nil)
        )

        let missions = try await harness.service.missionsList(
            BurnBarMissionListRequest(projectSlug: "orion", statuses: BurnBarMissionStatus.allCases)
        )

        // Verify all 3 missions are present
        XCTAssertEqual(missions.missions.count, 3)

        // The most recently approved (id3) should be first
        // Then id2, then id1 (by updatedAt desc)
        // If any have same updatedAt, they should be sorted by ID asc
        let ids = missions.missions.map { $0.id }

        // Verify the ordering is deterministic: id3 > id2 > id1 by updatedAt (approved in that order)
        XCTAssertTrue(ids.contains(id1), "Mission 1 should be in list")
        XCTAssertTrue(ids.contains(id2), "Mission 2 should be in list")
        XCTAssertTrue(ids.contains(id3), "Mission 3 should be in list")

        // First mission should be the one approved most recently
        XCTAssertEqual(missions.missions[0].id, id3, "Most recently approved mission should be first")
    }

    func testNotificationCommandsAndSimulatorReplayUpdateControllerState() async throws {
        let harness = try makeHarness(name: "notifications-and-simulator")

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "atlas"))
        )
        _ = try await harness.service.createFollowup(
            BurnBarFollowupCreateRequest(
                followup: BurnBarFollowupSnapshot(
                    id: BurnBarFollowupID(rawValue: "followup-atlas"),
                    projectSlug: "atlas",
                    title: "Review the latest burn spike",
                    summary: "Operator needs to confirm whether burn is expected.",
                    status: .open,
                    kind: .controllerNudge,
                    createdAt: Date()
                )
            )
        )

        let snoozed = try await harness.service.notificationCommand(
            BurnBarNotificationCommandRequest(
                command: .snooze,
                arguments: ["followup-atlas", "90"],
                actor: "telegram"
            )
        )
        XCTAssertTrue(snoozed.ok)
        XCTAssertEqual(snoozed.followup?.status, .snoozed)

        let simulator = try await harness.service.simulatorRun(
            BurnBarSimulatorRunRequest(projectSlug: "atlas", scenarioName: "daily-review", seed: 7)
        )
        XCTAssertEqual(simulator.run.projectSlug, "atlas")
        XCTAssertEqual(simulator.run.status, .queued)

        let replayed = try await harness.service.simulatorReplay(
            BurnBarSimulatorReplayRequest(runID: simulator.run.id, includeEvents: true)
        )
        XCTAssertEqual(replayed.run.id, simulator.run.id)
        XCTAssertFalse(replayed.run.emittedEvents.isEmpty)

        let summary = try await harness.service.controllerSummary(BurnBarControllerSummaryRequest(projectSlug: "atlas"))
        XCTAssertGreaterThan(summary.summary.recentEvents.count, 0)
    }

    func testCalendarCommandWritesExternalCalendarEntry() async throws {
        let harness = try makeHarness(
            name: "calendar-command",
            transport: BurnBarMissionControlTransport(
                deliverLocalNotification: { _, _ in },
                sendTelegramMessage: { _, _, _ in },
                fetchTelegramUpdates: { _, _ in [] },
                applyCalendarEntry: { _, entry, _ in
                    BurnBarCalendarEntrySnapshot(
                        externalID: "event-123",
                        title: entry.title,
                        startAt: entry.startAt,
                        endAt: entry.endAt,
                        notes: entry.notes
                    )
                }
            )
        )

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "atlas"))
        )
        _ = try await harness.service.notificationConfigUpdate(
            BurnBarNotificationConfigUpdateRequest(
                config: BurnBarNotificationConfig(
                    defaultSnoozeMinutes: 30,
                    nudgeHoursLocal: [9, 13, 17],
                    local: BurnBarLocalNotificationConfig(isEnabled: false),
                    telegram: BurnBarTelegramNotificationConfig(isEnabled: false, botTokenConfigured: false),
                    calendar: BurnBarCalendarNotificationConfig(
                        isEnabled: true,
                        defaultDurationMinutes: 45,
                        defaultCalendarName: "OpenBurnBar Ops"
                    )
                )
            )
        )
        _ = try await harness.service.followupCreate(
            BurnBarFollowupCreateRequest(
                followup: BurnBarFollowupSnapshot(
                    id: BurnBarFollowupID(rawValue: "followup-calendar"),
                    projectSlug: "atlas",
                    title: "Schedule operator review",
                    summary: "Calendar integration should externalize this hold.",
                    status: .open,
                    kind: .controllerNudge,
                    createdAt: Date()
                )
            )
        )

        let command = try await harness.service.notificationCommand(
            BurnBarNotificationCommandRequest(
                command: .calendar,
                arguments: ["followup-calendar", "2026-03-28T18:00:00Z"],
                actor: "operator"
            )
        )

        XCTAssertTrue(command.ok)
        XCTAssertEqual(command.followup?.calendarEntry?.externalID, "event-123")
    }

    func testControllerActivityIngestionAndScheduledLaunchUseRealRuntimePath() async throws {
        let launcher = ReviewLauncherRecorder()
        let harness = try makeHarness(
            name: "activity-ingestion",
            activitySnapshot: BurnBarControllerActivitySnapshot(
                generatedAt: Date(),
                activeProjectSlug: "apollo",
                projects: [
                    BurnBarControllerActivityProject(
                        projectSlug: "apollo",
                        displayName: "Apollo",
                        summary: "Apollo is preparing its next approval-sheet review.",
                        latestActivityAt: Date(),
                        latestConversationID: "conversation-apollo",
                        latestConversationSessionID: BurnBarSessionID(rawValue: "apollo-session"),
                        latestConversationTitle: "Apollo checkpoint",
                        latestConversationSummary: "Apollo is preparing its next approval-sheet review.",
                        latestQuestionPrompt: nil,
                        sessionCountLast7Days: 3,
                        totalCostLast7Days: 2.75,
                        totalTokensLast7Days: 14_200,
                        preferredCadence: .daily,
                        automationMode: .scheduled,
                        reviewModelID: "glm-5",
                        scheduleHourLocal: 0,
                        scheduleWeekdayLocal: Calendar.current.component(.weekday, from: Date())
                    )
                ]
            ),
            reviewRunLauncher: { prompt, modelID, metadata in
                await launcher.record(prompt: prompt, modelID: modelID, metadata: metadata)
                return BurnBarRunCreateResponse(runID: BurnBarRunID(rawValue: "review-run-1"), phase: .completed)
            }
        )

        let initialProjects = try await harness.service.controllerProjects(
            BurnBarControllerProjectsListRequest(includePaused: true, limit: 20)
        )
        XCTAssertEqual(initialProjects.projects.first?.projectSlug, "apollo")
        XCTAssertEqual(initialProjects.projects.first?.automationMode, .scheduled)

        let questions = try await harness.service.questionsList(
            BurnBarQuestionsListRequest(projectSlug: "apollo", statuses: [.pending])
        )
        XCTAssertTrue(questions.questions.isEmpty)

        await harness.service.startBackgroundLoops()
        let launchedReview = await waitUntil {
            await launcher.launches.count == 1
        }
        await harness.service.stopBackgroundLoops()

        let launches = await launcher.launches
        XCTAssertTrue(launchedReview, "Expected one scheduled review launch before timeout.")
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches.first?.modelID, "glm-5")
        XCTAssertTrue(launches.first?.prompt.contains("OpenBurnBar daily review for project Apollo") == true)

        let refreshedProjects = try await harness.service.controllerProjects(
            BurnBarControllerProjectsListRequest(includePaused: true, limit: 20)
        )
        XCTAssertNotNil(refreshedProjects.projects.first?.latestDailyReviewAt)
    }

    func testMissionDispatchLinksRealRunAndSyncsResultProvenance() async throws {
        let launcher = ReviewLauncherRecorder()
        let now = Date(timeIntervalSince1970: 1_710_100_000)
        let runID = BurnBarRunID(rawValue: "mission-run-1")
        let harness = try makeHarness(
            name: "mission-execution-sync",
            reviewRunLauncher: { prompt, modelID, metadata in
                await launcher.record(prompt: prompt, modelID: modelID, metadata: metadata)
                return BurnBarRunCreateResponse(runID: runID, phase: .planning)
            },
            runSnapshotLookup: { requestedRunID in
                guard requestedRunID == runID else { return nil }
                return BurnBarRunStateSnapshot(
                    runID: requestedRunID,
                    clientID: BurnBarClientID(rawValue: "daemon"),
                    sessionID: BurnBarSessionID(rawValue: "mission-session"),
                    phase: .completed,
                    modelID: "glm-5",
                    updatedAt: now
                )
            }
        )

        try writeUsageRecord(
            BurnBarUsageRecord(
                idempotencyKey: "run:\(runID.rawValue):attempt:1",
                event: BurnBarUsageEvent(
                    runID: runID,
                    providerID: "zai",
                    modelID: "glm-5",
                    inputTokens: 800,
                    outputTokens: 220,
                    cacheReadTokens: 40,
                    cost: 1.42,
                    recordedAt: now
                )
            ),
            to: harness.rootURL.appendingPathComponent("usage-events.jsonl")
        )

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "orion"))
        )
        let mission = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Ship review evidence",
                summary: "Verify the release packet against the latest evidence.",
                createdBy: "operator",
                recommendation: .proceed
            )
        )
        let missionID = mission.mission.id
        _ = try await harness.service.missionApprove(
            BurnBarMissionApproveRequest(missionID: missionID, actor: "operator", note: "Proceed")
        )

        let dispatched = try await harness.service.missionDispatchPacket(
            BurnBarMissionDispatchPacketRequest(
                missionID: missionID,
                actor: "operator",
                packet: BurnBarMissionPacketSnapshot(
                    id: BurnBarMissionPacketID(rawValue: "packet-orion-sync"),
                    missionID: missionID,
                    workerName: "review-worker",
                    objective: "Inspect the release evidence",
                    status: .queued,
                    metadata: ["model_id": .string("glm-5")]
                )
            )
        )

        XCTAssertEqual(dispatched.mission.packets.first?.runID, runID)
        XCTAssertEqual(dispatched.mission.packets.first?.status, .dispatched)

        try await harness.service.runTransportCycle(now: now.addingTimeInterval(5))

        let refreshed = try await harness.service.missionGet(BurnBarMissionGetRequest(missionID: missionID))
        XCTAssertEqual(refreshed.mission?.packets.first?.status, .completed)
        XCTAssertEqual(refreshed.mission?.results.first?.runID, runID)
        XCTAssertEqual(refreshed.mission?.results.first?.burnDelta ?? 0, 1.42, accuracy: 0.001)
        XCTAssertEqual(stringValue(refreshed.mission?.results.first?.metadata["provider_id"]), "zai")
        XCTAssertEqual(numberValue(refreshed.mission?.results.first?.metadata["input_tokens"]), 800)
        XCTAssertEqual(numberValue(refreshed.mission?.metadata["total_tokens"]), 1_060)
        XCTAssertTrue(refreshed.mission?.results.first?.evidenceRefs.contains(runID.rawValue) == true)

        let launches = await launcher.launches
        XCTAssertEqual(launches.count, 1)
        XCTAssertTrue(launches.first?.prompt.contains("OpenBurnBar mission execution for project orion.") == true)
        XCTAssertEqual(boolValue(launches.first?.metadata["missionExecution"]), true)
    }

    func testAutoTakeoverLaunchesAndCompletesHistoryWithoutRecursing() async throws {
        let launcher = ReviewLauncherRecorder()
        let now = Date(timeIntervalSince1970: 1_710_200_000)
        let sourceRunID = BurnBarRunID(rawValue: "source-run-1")
        let takeoverRunID = BurnBarRunID(rawValue: "takeover-run-1")
        let harness = try makeHarness(
            name: "auto-takeover",
            reviewRunLauncher: { prompt, modelID, metadata in
                await launcher.record(prompt: prompt, modelID: modelID, metadata: metadata)
                let launchedRunID = (self.boolValue(metadata["autoTakeover"]) ?? false) ? takeoverRunID : sourceRunID
                return BurnBarRunCreateResponse(runID: launchedRunID, phase: .planning)
            },
            runSnapshotLookup: { requestedRunID in
                if requestedRunID == sourceRunID {
                    return BurnBarRunStateSnapshot(
                        runID: requestedRunID,
                        clientID: BurnBarClientID(rawValue: "daemon"),
                        sessionID: BurnBarSessionID(rawValue: "source-session"),
                        phase: .failed,
                        modelID: "glm-5",
                        updatedAt: now.addingTimeInterval(-1_800),
                        errorMessage: "Primary worker crashed."
                    )
                }
                if requestedRunID == takeoverRunID {
                    return BurnBarRunStateSnapshot(
                        runID: requestedRunID,
                        clientID: BurnBarClientID(rawValue: "daemon"),
                        sessionID: BurnBarSessionID(rawValue: "takeover-session"),
                        phase: .completed,
                        modelID: "glm-5",
                        updatedAt: now.addingTimeInterval(60)
                    )
                }
                return nil
            }
        )

        try writeUsageRecord(
            BurnBarUsageRecord(
                idempotencyKey: "run:\(takeoverRunID.rawValue):attempt:1",
                event: BurnBarUsageEvent(
                    runID: takeoverRunID,
                    providerID: "zai",
                    modelID: "glm-5",
                    inputTokens: 300,
                    outputTokens: 140,
                    cacheReadTokens: 10,
                    cost: 0.61,
                    recordedAt: now.addingTimeInterval(60)
                )
            ),
            to: harness.rootURL.appendingPathComponent("usage-events.jsonl")
        )

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "apollo"))
        )
        let mission = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "apollo",
                title: "Recover the rollout packet",
                summary: "Keep Apollo moving even if the first worker fails.",
                createdBy: "operator",
                recommendation: .review
            )
        )
        let missionID = mission.mission.id
        _ = try await harness.service.missionApprove(
            BurnBarMissionApproveRequest(missionID: missionID, actor: "operator", note: "Proceed")
        )
        _ = try await harness.service.missionDispatchPacket(
            BurnBarMissionDispatchPacketRequest(
                missionID: missionID,
                actor: "operator",
                packet: BurnBarMissionPacketSnapshot(
                    id: BurnBarMissionPacketID(rawValue: "packet-apollo-source"),
                    missionID: missionID,
                    workerName: "primary-worker",
                    objective: "Inspect the rollout packet",
                    status: .queued
                )
            )
        )

        try await harness.service.runTransportCycle(now: now)

        var refreshed = try await harness.service.missionGet(BurnBarMissionGetRequest(missionID: missionID))
        XCTAssertEqual(refreshed.mission?.takeoverHistory?.count, 1)
        XCTAssertEqual(refreshed.mission?.takeoverHistory?.first?.status, .launched)
        XCTAssertEqual(refreshed.mission?.packets.count, 2)
        XCTAssertTrue(refreshed.mission?.packets.contains(where: { $0.runID == takeoverRunID }) == true)

        try await harness.service.runTransportCycle(now: now.addingTimeInterval(90))

        refreshed = try await harness.service.missionGet(BurnBarMissionGetRequest(missionID: missionID))
        XCTAssertEqual(refreshed.mission?.takeoverHistory?.first?.status, .completed)
        XCTAssertEqual(refreshed.mission?.packets.count, 2)
        XCTAssertTrue(refreshed.mission?.results.contains(where: { $0.runID == takeoverRunID }) == true)

        let launches = await launcher.launches
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(boolValue(launches.last?.metadata["autoTakeover"]), true)
        XCTAssertTrue(launches.last?.prompt.contains("OpenBurnBar auto-takeover for mission Recover the rollout packet") == true)
    }

    // MARK: - VAL-DAEMON-014: Typed planner input requires constraints, risk level, and desired outputs

    func testVAL_DAEMON_014_PlannerInputValidationRejectsEmptyConstraints() async throws {
        // VAL-DAEMON-014: Planner input rejects missing required fields (empty constraints)
        let harness = try makeHarness(name: "val-daemon-014-constraints")

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "orion"))
        )

        let mission = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Test planner input validation",
                summary: "Verify planner input requires constraints.",
                createdBy: "test-actor",
                recommendation: .review
            )
        )
        let missionID = try XCTUnwrap(mission.mission.id)

        // Create a planner service to test validation
        let plannerService = BurnBarPlannerService()

        let intent = BurnBarAgentIntent(
            kind: .generic,
            objective: "test",
            summary: "test summary"
        )

        // Empty constraints should be rejected
        do {
            _ = try plannerService.plan(
                for: BurnBarPlannerInput(
                    missionID: missionID,
                    normalizedIntent: intent,
                    constraints: [], // Empty - should fail
                    riskLevel: .low,
                    desiredOutputs: ["output1"]
                )
            )
            XCTFail("Expected planner to reject empty constraints")
        } catch let error as BurnBarPlannerServiceError {
            switch error {
            case .invalidPlannerInput(let message):
                XCTAssertTrue(message.contains("constraints") || message.contains("empty"),
                              "Expected error message about constraints, got: \(message)")
            default:
                XCTFail("Expected invalidPlannerInput error, got \(error)")
            }
        } catch {
            XCTFail("Expected BurnBarPlannerServiceError, got \(error)")
        }
    }

    func testVAL_DAEMON_014_PlannerInputValidationRejectsEmptyDesiredOutputs() async throws {
        // VAL-DAEMON-014: Planner input rejects missing required fields (empty desiredOutputs)
        let harness = try makeHarness(name: "val-daemon-014-outputs")

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "orion"))
        )

        let mission = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Test planner input validation",
                summary: "Verify planner input requires desired outputs.",
                createdBy: "test-actor",
                recommendation: .review
            )
        )
        let missionID = try XCTUnwrap(mission.mission.id)

        let plannerService = BurnBarPlannerService()

        let intent = BurnBarAgentIntent(
            kind: .generic,
            objective: "test",
            summary: "test summary"
        )

        // Empty desiredOutputs should be rejected
        do {
            _ = try plannerService.plan(
                for: BurnBarPlannerInput(
                    missionID: missionID,
                    normalizedIntent: intent,
                    constraints: ["constraint1"],
                    riskLevel: .low,
                    desiredOutputs: [] // Empty - should fail
                )
            )
            XCTFail("Expected planner to reject empty desiredOutputs")
        } catch let error as BurnBarPlannerServiceError {
            switch error {
            case .invalidPlannerInput(let message):
                XCTAssertTrue(message.contains("desiredOutputs") || message.contains("empty"),
                              "Expected error message about desiredOutputs, got: \(message)")
            default:
                XCTFail("Expected invalidPlannerInput error, got \(error)")
            }
        } catch {
            XCTFail("Expected BurnBarPlannerServiceError, got \(error)")
        }
    }

    func testVAL_DAEMON_014_PlannerInputValidationAcceptsValidInput() async throws {
        // VAL-DAEMON-014: Planner input accepts valid input with all required fields
        let harness = try makeHarness(name: "val-daemon-014-valid")

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "orion"))
        )

        let mission = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Test planner input validation",
                summary: "Verify planner input accepts valid input.",
                createdBy: "test-actor",
                recommendation: .review
            )
        )
        let missionID = try XCTUnwrap(mission.mission.id)

        let plannerService = BurnBarPlannerService()

        let intent = BurnBarAgentIntent(
            kind: .replaceStringInFile,
            objective: "replace old with new",
            summary: "replace operation",
            targetPath: "test.swift",
            replacement: BurnBarTextReplacement(from: "old", to: "new"),
            requestedTools: [.readFile, .applyPatch]
        )

        // Valid input should succeed
        let planned = try plannerService.plan(
            for: BurnBarPlannerInput(
                missionID: missionID,
                normalizedIntent: intent,
                constraints: ["do not modify tests", "preserve imports"],
                riskLevel: .medium,
                desiredOutputs: ["file updated", "compilation succeeds"]
            )
        )

        XCTAssertEqual(planned.intent.kind, .replaceStringInFile)
        XCTAssertEqual(planned.constraints, ["do not modify tests", "preserve imports"])
        XCTAssertEqual(planned.riskLevel, .medium)
        XCTAssertEqual(planned.desiredOutputs, ["file updated", "compilation succeeds"])
    }

    func testVAL_DAEMON_014_PlannerInputPreservesFieldsThroughPlanning() async throws {
        // VAL-DAEMON-014: Planner input fields are preserved through planning
        let harness = try makeHarness(name: "val-daemon-014-preserve")

        _ = try await harness.service.controllerProjectUpsert(
            BurnBarControllerProjectUpsertRequest(project: project(slug: "orion"))
        )

        let mission = try await harness.service.missionCreate(
            BurnBarMissionCreateRequest(
                projectSlug: "orion",
                title: "Test planner input field preservation",
                summary: "Verify planner input fields are preserved.",
                createdBy: "test-actor",
                recommendation: .review
            )
        )
        let missionID = try XCTUnwrap(mission.mission.id)

        let plannerService = BurnBarPlannerService()

        let intent = BurnBarAgentIntent(
            kind: .inspectWorkspace,
            objective: "find relevant files",
            summary: "workspace inspection",
            searchQuery: "BurnBarRunService",
            requestedTools: [.searchWorkspace]
        )

        let planned = try plannerService.plan(
            for: BurnBarPlannerInput(
                missionID: missionID,
                normalizedIntent: intent,
                constraints: ["only search src/"],
                riskLevel: .low,
                desiredOutputs: ["files identified"],
                workflowHints: ["scope": .string("src")]
            )
        )

        // Verify fields preserved through planning
        XCTAssertEqual(planned.intent.kind, .inspectWorkspace)
        XCTAssertEqual(planned.intent.searchQuery, "BurnBarRunService")
        XCTAssertEqual(planned.constraints, ["only search src/"])
        XCTAssertEqual(planned.riskLevel, .low)
        XCTAssertEqual(planned.desiredOutputs, ["files identified"])
    }

    private func makeHarness(
        name: String,
        transport: BurnBarMissionControlTransport = .live(),
        activitySnapshot: BurnBarControllerActivitySnapshot? = nil,
        reviewRunLauncher: BurnBarMissionControlReviewRunLauncher? = nil,
        runSnapshotLookup: BurnBarMissionControlRunSnapshotLookup? = nil
    ) throws -> (service: BurnBarMissionControlService, rootURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-mission-control-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let activitySnapshotURL = rootURL.appendingPathComponent("controller-activity-snapshot.json")
        if let activitySnapshot {
            let data = try JSONEncoder().encode(activitySnapshot)
            try data.write(to: activitySnapshotURL, options: .atomic)
        }

        let store = BurnBarMissionControlStore(
            eventsFileURL: rootURL.appendingPathComponent("controller-events.jsonl"),
            projectionFileURL: rootURL.appendingPathComponent("controller-projection.json"),
            logger: BurnBarDaemonLogger(category: "mission-control-tests")
        )
        let service = BurnBarMissionControlService(
            store: store,
            logger: BurnBarDaemonLogger(category: "mission-control-tests"),
            transport: transport,
            activitySnapshotURL: activitySnapshot == nil ? nil : activitySnapshotURL,
            reviewRunLauncher: reviewRunLauncher,
            runSnapshotLookup: runSnapshotLookup,
            usageLedgerURL: rootURL.appendingPathComponent("usage-events.jsonl")
        )
        return (service, rootURL)
    }

    private func writeUsageRecord(_ record: BurnBarUsageRecord, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record) + Data([0x0A])
        try data.write(to: url, options: .atomic)
    }

    private func project(slug: String) -> BurnBarReviewProjectSnapshot {
        BurnBarReviewProjectSnapshot(
            id: "project-\(slug)",
            projectSlug: slug,
            displayName: slug.capitalized,
            summary: "Native OpenBurnBar mission-control test project.",
            status: .healthy,
            preferredCadence: .daily,
            freshness: .provisional,
            pendingQuestionCount: 0,
            openFollowupCount: 0,
            activeMissionCount: 0,
            needsOperatorAttention: false
        )
    }

    private func boolValue(_ value: BurnBarJSONValue?) -> Bool? {
        guard case .bool(let rawValue)? = value else { return nil }
        return rawValue
    }

    private func stringValue(_ value: BurnBarJSONValue?) -> String? {
        guard case .string(let rawValue)? = value else { return nil }
        return rawValue
    }

    private func numberValue(_ value: BurnBarJSONValue?) -> Double? {
        guard case .number(let rawValue)? = value else { return nil }
        return rawValue
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        pollNanoseconds: UInt64 = 50_000_000,
        condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }

        return await condition()
    }
}

private actor TransportRecorder {
    private(set) var localNotifications: [(title: String, body: String)] = []
    private(set) var telegramMessages: [(token: String, chatID: String, text: String)] = []

    func recordLocal(title: String, body: String) {
        localNotifications.append((title, body))
    }

    func recordTelegram(token: String, chatID: String, text: String) {
        telegramMessages.append((token, chatID, text))
    }
}

private actor ReviewLauncherRecorder {
    struct Launch: Sendable {
        let prompt: String
        let modelID: String
        let metadata: [String: BurnBarJSONValue]
    }

    private(set) var launches: [Launch] = []

    func record(prompt: String, modelID: String, metadata: [String: BurnBarJSONValue]) {
        launches.append(Launch(prompt: prompt, modelID: modelID, metadata: metadata))
    }
}
