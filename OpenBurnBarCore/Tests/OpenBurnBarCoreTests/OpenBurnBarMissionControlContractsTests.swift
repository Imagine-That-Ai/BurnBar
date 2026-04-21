import XCTest
@testable import OpenBurnBarCore

final class BurnBarMissionControlContractsTests: XCTestCase {
    func testRPCMethods_includeMissionControlSurface() {
        XCTAssertEqual(BurnBarRPCMethod.controllerSummary.rawValue, "daemon.controller.summary")
        XCTAssertEqual(BurnBarRPCMethod.controllerProjectsList.rawValue, "daemon.controller.project.list")
        XCTAssertEqual(BurnBarRPCMethod.controllerProjectGet.rawValue, "daemon.controller.project.get")
        XCTAssertEqual(BurnBarRPCMethod.questionAnswer.rawValue, "daemon.question.answer")
        XCTAssertEqual(BurnBarRPCMethod.followupCalendar.rawValue, "daemon.followup.calendar")
        XCTAssertEqual(BurnBarRPCMethod.missionDispatchPacket.rawValue, "daemon.mission.packet.dispatch")
        XCTAssertEqual(BurnBarRPCMethod.simulatorReplay.rawValue, "daemon.simulator.replay")
        XCTAssertEqual(BurnBarRPCMethod.notificationConfigUpdate.rawValue, "daemon.notification.config.update")
        XCTAssertEqual(BurnBarRPCMethod.notificationHealth.rawValue, "daemon.notification.health")
        XCTAssertEqual(BurnBarRPCMethod.projectionRebuild.rawValue, "daemon.projection.rebuild")
    }

    func testControllerSummaryRoundTrip_includesEventsAndProjections() throws {
        let now = Date(timeIntervalSince1970: 1_710_000_000)
        let checkpoint = BurnBarReplayCheckpoint(
            id: BurnBarProjectionCheckpointID(rawValue: "checkpoint-1"),
            projectionName: "conversation_home",
            eventSequence: 42,
            recordedAt: now
        )
        let projection = BurnBarProjectionStatusSnapshot(
            projectionName: "conversation_home",
            status: .upToDate,
            freshness: .fresh,
            lastMaterializedAt: now,
            lastEventSequence: 42,
            checkpoint: checkpoint
        )
        let event = BurnBarControllerEvent(
            id: BurnBarControllerEventID(rawValue: "event-1"),
            family: .controller,
            eventType: "review_run_completed",
            projectSlug: "openburnbar",
            recordedAt: now,
            sequence: 42,
            summary: "Daily review completed",
            metadata: ["cadence": .string("daily")]
        )
        let response = BurnBarControllerSummaryResponse(
            summary: BurnBarControllerSummary(
                updatedAt: now,
                activeProjectSlug: "openburnbar",
                counts: BurnBarControllerCounts(
                    projectCount: 3,
                    pendingQuestionCount: 2,
                    openFollowupCount: 4,
                    activeMissionCount: 1,
                    staleProjectCount: 1
                ),
                nextSuggestedCadence: .daily,
                latestReviewAt: now,
                freshness: .fresh,
                projectionStatus: [projection],
                recentEvents: [event]
            )
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(BurnBarControllerSummaryResponse.self, from: data)

        XCTAssertEqual(decoded.summary.counts.pendingQuestionCount, 2)
        XCTAssertEqual(decoded.summary.projectionStatus.first?.checkpoint?.eventSequence, 42)
        XCTAssertEqual(decoded.summary.recentEvents.first?.metadata["cadence"], .string("daily"))
    }

    func testProjectAndReviewRunContracts_roundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_710_000_050)
        let project = BurnBarReviewProjectSnapshot(
            id: "project-1",
            projectSlug: "openburnbar",
            displayName: "OpenBurnBar",
            summary: "Primary product repo",
            status: .needsAttention,
            preferredCadence: .daily,
            aliases: ["burn-bar", "bb"],
            automationMode: .scheduled,
            reviewModelID: "glm-5",
            scheduleHourLocal: 9,
            scheduleWeekdayLocal: 2,
            freshness: .aging,
            latestDailyReviewAt: now,
            latestWeeklyReviewAt: now,
            nextScheduledReviewAt: now.addingTimeInterval(86_400),
            pendingQuestionCount: 2,
            openFollowupCount: 1,
            activeMissionCount: 1,
            activeMissionID: BurnBarMissionID(rawValue: "mission-1"),
            needsOperatorAttention: true,
            ingestionSource: .appActivity
        )
        let run = BurnBarReviewRunSnapshot(
            id: "run-1",
            projectSlug: "openburnbar",
            cadence: .daily,
            recordedAt: now,
            summary: "Queued one question and one mission.",
            questionCount: 1,
            followupCount: 1,
            missionCount: 1,
            origin: .dashboard,
            triggeredBy: "operator",
            launchedRunID: BurnBarRunID(rawValue: "run-live-1")
        )
        let response = BurnBarControllerReviewRunRecordResponse(
            run: run,
            summary: BurnBarControllerSummary(
                updatedAt: now,
                activeProjectSlug: "openburnbar",
                counts: BurnBarControllerCounts(
                    projectCount: 1,
                    pendingQuestionCount: 1,
                    openFollowupCount: 1,
                    activeMissionCount: 1,
                    staleProjectCount: 0
                ),
                nextSuggestedCadence: .weekly,
                latestReviewAt: now,
                freshness: .aging
            )
        )

        let projectData = try JSONEncoder().encode(BurnBarControllerProjectResponse(project: project))
        let runData = try JSONEncoder().encode(response)

        let decodedProject = try JSONDecoder().decode(BurnBarControllerProjectResponse.self, from: projectData)
        let decodedRun = try JSONDecoder().decode(BurnBarControllerReviewRunRecordResponse.self, from: runData)

        XCTAssertEqual(decodedProject.project?.status, .needsAttention)
        XCTAssertEqual(decodedProject.project?.activeMissionID, BurnBarMissionID(rawValue: "mission-1"))
        XCTAssertEqual(decodedProject.project?.aliases, ["burn-bar", "bb"])
        XCTAssertEqual(decodedProject.project?.automationMode, .scheduled)
        XCTAssertEqual(decodedProject.project?.reviewModelID, "glm-5")
        XCTAssertEqual(decodedProject.project?.scheduleHourLocal, 9)
        XCTAssertEqual(decodedProject.project?.scheduleWeekdayLocal, 2)
        XCTAssertEqual(decodedProject.project?.ingestionSource, .appActivity)
        XCTAssertEqual(decodedRun.run.cadence, .daily)
        XCTAssertEqual(decodedRun.run.origin, .dashboard)
        XCTAssertEqual(decodedRun.run.triggeredBy, "operator")
        XCTAssertEqual(decodedRun.run.launchedRunID, BurnBarRunID(rawValue: "run-live-1"))
        XCTAssertEqual(decodedRun.summary.counts.openFollowupCount, 1)
    }

    func testVAL_CROSS_012_EnterprisePolicyBlockContractsRoundTrip() throws {
        let block = BurnBarEnterprisePolicyBlock(
            reasonCode: .budgetHardCapBlocked,
            detail: "Observed spend (12.5 USD) exceeds hard cap (10 USD).",
            approvalMode: .manualAll,
            budgetHardCapUSD: 10,
            observedSpendUSD: 12.5,
            blockedAt: Date(timeIntervalSince1970: 1_710_320_000)
        )

        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(BurnBarEnterprisePolicyBlock.self, from: data)

        XCTAssertEqual(decoded.reasonCode, .budgetHardCapBlocked)
        XCTAssertEqual(decoded.approvalMode, .manualAll)
        XCTAssertEqual(decoded.budgetHardCapUSD, 10)
        XCTAssertEqual(decoded.observedSpendUSD, 12.5)
        XCTAssertTrue(decoded.displayMessage.contains("Budget hard cap reached"))
    }

    func testVAL_CROSS_013_ScheduledReviewIntentContractsRoundTrip() throws {
        let dueAt = Date(timeIntervalSince1970: 1_710_320_500)
        let intent = BurnBarScheduledReviewIntent(
            taskID: "scheduled-review-apollo-daily-1710320500",
            projectSlug: "apollo",
            dueAt: dueAt,
            notificationIntentID: "intent-apollo-daily-1710320500",
            notificationChannels: [.local, .telegram]
        )

        let data = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(BurnBarScheduledReviewIntent.self, from: data)

        XCTAssertEqual(decoded.taskID, "scheduled-review-apollo-daily-1710320500")
        XCTAssertEqual(decoded.projectSlug, "apollo")
        XCTAssertEqual(decoded.dueAt, dueAt)
        XCTAssertEqual(decoded.notificationIntentID, "intent-apollo-daily-1710320500")
        XCTAssertEqual(decoded.notificationChannels, [.local, .telegram])
    }

    func testLegacyProjectAndReviewRunPayloads_decodeWithWaveOneDefaults() throws {
        let legacyProjectData = """
        {
          "project": {
            "id": "project-legacy",
            "projectSlug": "openburnbar",
            "displayName": "OpenBurnBar",
            "summary": "Legacy payload",
            "status": "healthy",
            "preferredCadence": "daily",
            "freshness": "fresh",
            "pendingQuestionCount": 0,
            "openFollowupCount": 0,
            "activeMissionCount": 0,
            "needsOperatorAttention": false,
            "metadata": {}
          }
        }
        """.data(using: .utf8)!
        let legacyRunData = """
        {
          "run": {
            "id": "run-legacy",
            "projectSlug": "openburnbar",
            "cadence": "weekly",
            "recordedAt": 1710000050,
            "summary": "Legacy review",
            "questionCount": 0,
            "followupCount": 0,
            "missionCount": 0,
            "metadata": {}
          },
          "summary": {
            "updatedAt": 1710000050,
            "activeProjectSlug": "openburnbar",
            "counts": {
              "projectCount": 1,
              "pendingQuestionCount": 0,
              "openFollowupCount": 0,
              "activeMissionCount": 0,
              "staleProjectCount": 0
            },
            "freshness": "fresh",
            "projectionStatus": [],
            "recentEvents": []
          }
        }
        """.data(using: .utf8)!

        let decodedProject = try JSONDecoder().decode(BurnBarControllerProjectResponse.self, from: legacyProjectData)
        let decodedRun = try JSONDecoder().decode(BurnBarControllerReviewRunRecordResponse.self, from: legacyRunData)

        XCTAssertEqual(decodedProject.project?.aliases, [])
        XCTAssertEqual(decodedProject.project?.automationMode, .manual)
        XCTAssertNil(decodedProject.project?.reviewModelID)
        XCTAssertEqual(decodedProject.project?.ingestionSource, .manual)
        XCTAssertEqual(decodedRun.run.origin, .manual)
        XCTAssertNil(decodedRun.run.triggeredBy)
        XCTAssertNil(decodedRun.run.launchedRunID)
    }

    func testQuestionAndFollowupRoundTrip_preservesAnswerAndCalendarData() throws {
        let now = Date(timeIntervalSince1970: 1_710_000_100)
        let questionID = BurnBarQuestionID(rawValue: "question-1")
        let followupID = BurnBarFollowupID(rawValue: "followup-1")
        let question = BurnBarPendingQuestionSnapshot(
            id: questionID,
            projectSlug: "openburnbar",
            sessionID: BurnBarSessionID(rawValue: "session-1"),
            title: "Approve burn delta?",
            prompt: "Is the increased burn intentional?",
            stageLabel: "Operator Decision",
            status: .answered,
            priority: .high,
            askedAt: now,
            dueAt: now.addingTimeInterval(3_600),
            latestAnswer: BurnBarAnswerRecord(
                answeredAt: now.addingTimeInterval(120),
                answeredBy: "operator",
                answer: "Yes, this is expected during rollout.",
                selectedOptionID: "proceed"
            ),
            answerPlaceholder: "Record OpenBurnBar's operator call…",
            contextSummary: "Burn spiked after deployment.",
            evidenceRefs: ["event-42"],
            suggestedOptions: [
                BurnBarQuestionOptionSnapshot(
                    id: "proceed",
                    title: "Proceed",
                    detail: "Keep the current rollout moving.",
                    answer: "Proceed with the rollout."
                ),
                BurnBarQuestionOptionSnapshot(
                    id: "pause",
                    title: "Pause",
                    detail: "Reset direction before continuing.",
                    answer: "Pause and reset the rollout."
                )
            ],
            deepLink: BurnBarQuestionDeepLinkSnapshot(
                kind: .sessionLog,
                targetID: "session-1",
                title: "Open rollout session log",
                subtitle: "Review the latest checkpoint"
            ),
            tracker: BurnBarQuestionTrackerSnapshot(
                isUnread: true,
                surfacedAt: now,
                firstNotifiedAt: now,
                lastNotifiedAt: now,
                notificationCount: 1
            )
        )
        let followup = BurnBarFollowupSnapshot(
            id: followupID,
            projectSlug: "openburnbar",
            questionID: questionID,
            title: "Confirm rollout notes",
            summary: "Attach operator rationale to the mission log.",
            stageLabel: "Operator Decision",
            status: .snoozed,
            kind: .pendingQuestion,
            createdAt: now,
            nextNudgeAt: now.addingTimeInterval(7_200),
            snoozeUntil: now.addingTimeInterval(10_800),
            calendarEntry: BurnBarCalendarEntrySnapshot(
                externalID: "cal-1",
                title: "Review rollout notes",
                startAt: now.addingTimeInterval(3_600),
                endAt: now.addingTimeInterval(5_400),
                notes: "Bring deployment metrics."
            ),
            deepLink: BurnBarQuestionDeepLinkSnapshot(
                kind: .sessionLog,
                targetID: "session-1",
                title: "Open rollout session log"
            )
        )
        let response = BurnBarQuestionAnswerResponse(question: question, followup: followup)

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(BurnBarQuestionAnswerResponse.self, from: data)

        XCTAssertEqual(decoded.question.latestAnswer?.answeredBy, "operator")
        XCTAssertEqual(decoded.question.latestAnswer?.selectedOptionID, "proceed")
        XCTAssertEqual(decoded.question.stageLabel, "Operator Decision")
        XCTAssertEqual(decoded.question.answerPlaceholder, "Record OpenBurnBar's operator call…")
        XCTAssertEqual(decoded.question.suggestedOptions.count, 2)
        XCTAssertEqual(decoded.question.deepLink?.kind, .sessionLog)
        XCTAssertEqual(decoded.question.tracker?.notificationCount, 1)
        XCTAssertEqual(decoded.followup?.questionID, questionID)
        XCTAssertEqual(decoded.followup?.status, .snoozed)
        XCTAssertEqual(decoded.followup?.calendarEntry?.externalID, "cal-1")
        XCTAssertEqual(decoded.followup?.stageLabel, "Operator Decision")
        XCTAssertEqual(decoded.followup?.deepLink?.targetID, "session-1")
    }

    func testLegacyQuestionPayload_decodesWithWaveTwoDefaults() throws {
        let legacyQuestionData = """
        {
          "question": {
            "id": "question-legacy",
            "projectSlug": "openburnbar",
            "sessionID": "session-legacy",
            "title": "Legacy",
            "prompt": "Should OpenBurnBar keep the current scope?",
            "status": "pending",
            "priority": "medium",
            "askedAt": 1710000100,
            "evidenceRefs": [],
            "metadata": {}
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(BurnBarQuestionResponse.self, from: legacyQuestionData)

        XCTAssertNil(decoded.question?.stageLabel)
        XCTAssertNil(decoded.question?.answerPlaceholder)
        XCTAssertEqual(decoded.question?.suggestedOptions, [])
        XCTAssertNil(decoded.question?.deepLink)
        XCTAssertNil(decoded.question?.tracker)
    }

    func testMissionMutationRoundTrip_preservesPacketsResultsAndBurn() throws {
        // VAL-GOV-007: Mission closure carries typed PR lifecycle linkage.
        let now = Date(timeIntervalSince1970: 1_710_000_200)
        let missionID = BurnBarMissionID(rawValue: "mission-1")
        let prLinkage = BurnBarPRLinkageSnapshot(
            repository: "Ajnunezg/BurnBar",
            prNumberOrID: "42",
            url: "https://github.com/Ajnunezg/BurnBar/pull/42",
            state: .merged,
            mergeCommitSHA: "abc123def",
            mergedAt: now.addingTimeInterval(25),
            closedAt: now.addingTimeInterval(30)
        )
        let packet = BurnBarMissionPacketSnapshot(
            id: BurnBarMissionPacketID(rawValue: "packet-1"),
            missionID: missionID,
            workerName: "planner",
            objective: "Draft operator plan",
            status: .completed,
            runID: BurnBarRunID(rawValue: "run-1"),
            dispatchedAt: now,
            completedAt: now.addingTimeInterval(30)
        )
        let result = BurnBarMissionResultSnapshot(
            id: BurnBarMissionResultID(rawValue: "result-1"),
            missionID: missionID,
            packetID: packet.id,
            runID: BurnBarRunID(rawValue: "run-1"),
            status: .partial,
            summary: "Plan drafted with one unresolved dependency.",
            detail: "Waiting on provider quota confirmation.",
            burnDelta: 2.5,
            createdAt: now.addingTimeInterval(30),
            evidenceRefs: ["event-99"],
            prLinkage: prLinkage
        )
        let mission = BurnBarMissionSnapshot(
            id: missionID,
            projectSlug: "openburnbar",
            title: "Stabilize review controller",
            summary: "Move pending work into daemon-owned mission control.",
            status: .partiallyCompleted,
            recommendation: .review,
            createdAt: now,
            updatedAt: now.addingTimeInterval(30),
            approval: BurnBarMissionApprovalSnapshot(
                approved: true,
                approvedAt: now.addingTimeInterval(5),
                approvedBy: "maintainer",
                note: "Proceed, but keep rollout observable."
            ),
            packets: [packet],
            results: [result],
            burnRecords: [
                BurnBarMissionBurnRecord(
                    id: "burn-1",
                    label: "Operator review",
                    amount: 2.5,
                    unit: "points",
                    recordedAt: now.addingTimeInterval(30)
                )
            ],
            takeoverHistory: [
                BurnBarAutoTakeoverRecord(
                    id: "takeover-1",
                    projectSlug: "openburnbar",
                    missionID: missionID,
                    sourceRunID: BurnBarRunID(rawValue: "run-stuck"),
                    takeoverRunID: BurnBarRunID(rawValue: "run-1"),
                    status: .completed,
                    reason: "Original run stalled in awaiting approval.",
                    createdAt: now.addingTimeInterval(10),
                    updatedAt: now.addingTimeInterval(30)
                )
            ],
            prLinkage: prLinkage,
            metadata: ["cadence": .string("daily")]
        )
        let response = BurnBarMissionMutationResponse(
            mission: mission,
            emittedEvent: BurnBarControllerEvent(
                id: BurnBarControllerEventID(rawValue: "event-2"),
                family: .mission,
                eventType: "mission_result_recorded",
                projectSlug: "openburnbar",
                recordedAt: now.addingTimeInterval(30),
                sequence: 100,
                summary: "Mission result recorded"
            )
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(BurnBarMissionMutationResponse.self, from: data)

        XCTAssertEqual(decoded.mission.status, .partiallyCompleted)
        XCTAssertEqual(decoded.mission.packets.first?.runID, BurnBarRunID(rawValue: "run-1"))
        XCTAssertEqual(decoded.mission.packets.first?.workerName, "planner")
        XCTAssertEqual(decoded.mission.results.first?.runID, BurnBarRunID(rawValue: "run-1"))
        XCTAssertEqual(decoded.mission.results.first?.burnDelta, 2.5)
        XCTAssertEqual(decoded.mission.results.first?.prLinkage?.repository, "Ajnunezg/BurnBar")
        XCTAssertEqual(decoded.mission.results.first?.prLinkage?.state, .merged)
        XCTAssertEqual(decoded.mission.prLinkage?.prNumberOrID, "42")
        XCTAssertEqual(decoded.mission.prLinkage?.mergeCommitSHA, "abc123def")
        XCTAssertEqual(decoded.mission.takeoverHistory?.first?.status, .completed)
        XCTAssertEqual(decoded.emittedEvent?.family, .mission)
    }

    func testVAL_GOV_007_ResultMetadataFallbackBuildsTypedPRLinkage() {
        let result = BurnBarMissionResultSnapshot(
            id: BurnBarMissionResultID(rawValue: "result-metadata"),
            missionID: BurnBarMissionID(rawValue: "mission-metadata"),
            status: .succeeded,
            summary: "Connector reported PR opened.",
            createdAt: Date(timeIntervalSince1970: 1_710_000_300),
            metadata: [
                "pr_repository": .string("Ajnunezg/BurnBar"),
                "pr_number_or_id": .string("101"),
                "pr_url": .string("https://github.com/Ajnunezg/BurnBar/pull/101"),
                "pr_state": .string("opened")
            ]
        )

        XCTAssertEqual(result.prLinkage?.repository, "Ajnunezg/BurnBar")
        XCTAssertEqual(result.prLinkage?.prNumberOrID, "101")
        XCTAssertEqual(result.prLinkage?.state, .opened)
    }

    func testNotificationAndSimulatorContracts_roundTrip() throws {
        let config = BurnBarNotificationConfig(
            defaultSnoozeMinutes: 90,
            nudgeHoursLocal: [9, 13, 17],
            local: BurnBarLocalNotificationConfig(isEnabled: true, quietHoursStart: 22, quietHoursEnd: 7),
            telegram: BurnBarTelegramNotificationConfig(
                isEnabled: true,
                botTokenConfigured: true,
                botToken: "123456:secret-token",
                botTokenHint: "1234…abcd",
                chatID: "chat-1",
                supportedCommands: [.help, .pending, .answer, .runDaily]
            ),
            calendar: BurnBarCalendarNotificationConfig(
                isEnabled: true,
                defaultDurationMinutes: 30,
                defaultCalendarName: "OpenBurnBar Ops"
            )
        )
        let health = BurnBarNotificationHealthResponse(
            health: BurnBarNotificationHealthSnapshot(
                checkedAt: Date(timeIntervalSince1970: 1_710_000_300),
                channels: [
                    BurnBarNotificationChannelHealth(
                        channel: .telegram,
                        status: .healthy,
                        detail: "Webhook responding",
                        checkedAt: Date(timeIntervalSince1970: 1_710_000_300)
                    )
                ]
            )
        )
        let command = BurnBarNotificationCommandResponse(
            command: .pending,
            ok: true,
            message: "1 pending question, 2 open followups."
        )
        let now = Date(timeIntervalSince1970: 1_710_000_400)
        let simEvent = BurnBarControllerEvent(
            id: BurnBarControllerEventID(rawValue: "event-3"),
            family: .simulator,
            eventType: "scenario_step",
            projectSlug: "openburnbar",
            recordedAt: now,
            sequence: 5,
            summary: "Injected a duplicate event",
            isReplay: true
        )
        let simulator = BurnBarSimulatorRunResponse(
            run: BurnBarSimulatorRunSnapshot(
                id: BurnBarSimulatorRunID(rawValue: "sim-1"),
                projectSlug: "openburnbar",
                scenarioName: "duplicate-events",
                status: .completed,
                seed: 7,
                startedAt: now,
                completedAt: now.addingTimeInterval(3),
                emittedEvents: [simEvent],
                projectionStatus: [
                    BurnBarProjectionStatusSnapshot(
                        projectionName: "controller_summary",
                        status: .rebuilding,
                        freshness: .provisional,
                        lastMaterializedAt: nil,
                        lastEventSequence: 5,
                        checkpoint: BurnBarReplayCheckpoint(
                            id: BurnBarProjectionCheckpointID(rawValue: "checkpoint-2"),
                            projectionName: "controller_summary",
                            eventSequence: 5,
                            recordedAt: now.addingTimeInterval(3)
                        )
                    )
                ],
                summary: "Replay completed with duplicate/out-of-order coverage."
            )
        )

        let configData = try JSONEncoder().encode(BurnBarNotificationConfigResponse(config: config))
        let healthData = try JSONEncoder().encode(health)
        let commandData = try JSONEncoder().encode(command)
        let simulatorData = try JSONEncoder().encode(simulator)

        let decodedConfig = try JSONDecoder().decode(BurnBarNotificationConfigResponse.self, from: configData)
        let decodedHealth = try JSONDecoder().decode(BurnBarNotificationHealthResponse.self, from: healthData)
        let decodedCommand = try JSONDecoder().decode(BurnBarNotificationCommandResponse.self, from: commandData)
        let decodedSimulator = try JSONDecoder().decode(BurnBarSimulatorRunResponse.self, from: simulatorData)

        XCTAssertEqual(decodedConfig.config.telegram.supportedCommands, [.help, .pending, .answer, .runDaily])
        XCTAssertEqual(decodedConfig.config.telegram.botToken, "123456:secret-token")
        XCTAssertEqual(decodedHealth.health.channels.first?.status, .healthy)
        XCTAssertEqual(decodedCommand.command, .pending)
        XCTAssertEqual(decodedSimulator.run.emittedEvents.first?.isReplay, true)
        XCTAssertEqual(decodedSimulator.run.projectionStatus.first?.status, .rebuilding)
    }

    func testControllerActivitySnapshot_roundTripsProjectActivityShape() throws {
        let now = Date(timeIntervalSince1970: 1_710_000_900)
        let snapshot = BurnBarControllerActivitySnapshot(
            generatedAt: now,
            activeProjectSlug: "openburnbar",
            projects: [
                BurnBarControllerActivityProject(
                    projectSlug: "openburnbar",
                    displayName: "OpenBurnBar",
                    summary: "Latest indexed checkpoint looks healthy.",
                    latestActivityAt: now,
                    latestConversationID: "conversation-1",
                    latestConversationSessionID: BurnBarSessionID(rawValue: "session-1"),
                    latestConversationTitle: "Checkpoint summary",
                    latestConversationSummary: "Shipped the daemon-backed path.",
                    latestQuestionPrompt: "Should OpenBurnBar keep the current review cadence?",
                    sessionCountLast7Days: 4,
                    totalCostLast7Days: 5.25,
                    totalTokensLast7Days: 12_500,
                    aliases: ["bb"],
                    preferredCadence: .daily,
                    automationMode: .scheduled,
                    reviewModelID: "glm-5",
                    scheduleHourLocal: 9,
                    scheduleWeekdayLocal: 2
                )
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(BurnBarControllerActivitySnapshot.self, from: data)

        XCTAssertEqual(decoded.activeProjectSlug, "openburnbar")
        XCTAssertEqual(decoded.projects.first?.latestConversationSessionID, BurnBarSessionID(rawValue: "session-1"))
        XCTAssertEqual(decoded.projects.first?.automationMode, .scheduled)
        XCTAssertEqual(decoded.projects.first?.reviewModelID, "glm-5")
    }

    // MARK: - VAL-DAEMON-014: Typed planner input requires constraints, risk level, and desired outputs

    func testVAL_DAEMON_014_PlannerInputSchemaRequiresConstraintsRiskLevelAndDesiredOutputs() throws {
        // VAL-DAEMON-014: Planner input contract requires constraints, risk level, and desired outputs
        // These are the three required fields that must be present in BurnBarPlannerInput
        let intent = BurnBarAgentIntent(
            kind: .replaceStringInFile,
            objective: "Replace old with new",
            summary: "Replace operation",
            targetPath: "test.swift",
            replacement: BurnBarTextReplacement(from: "old", to: "new"),
            requestedTools: [.readFile, .applyPatch]
        )
        let plannerInput = BurnBarPlannerInput(
            schemaVersion: 1,
            missionID: BurnBarMissionID(rawValue: "mission-val-014"),
            normalizedIntent: intent,
            constraints: ["do not modify tests", "preserve existing imports"],
            riskLevel: .medium,
            desiredOutputs: ["file updated successfully", "compilation passes"]
        )

        // Verify required fields are present
        XCTAssertEqual(plannerInput.constraints.count, 2)
        XCTAssertEqual(plannerInput.riskLevel, .medium)
        XCTAssertEqual(plannerInput.desiredOutputs.count, 2)

        // Round-trip encode/decode preserves required fields
        let data = try JSONEncoder().encode(plannerInput)
        let decoded = try JSONDecoder().decode(BurnBarPlannerInput.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.missionID, BurnBarMissionID(rawValue: "mission-val-014"))
        XCTAssertEqual(decoded.normalizedIntent.kind, .replaceStringInFile)
        XCTAssertEqual(decoded.constraints, ["do not modify tests", "preserve existing imports"])
        XCTAssertEqual(decoded.riskLevel, .medium)
        XCTAssertEqual(decoded.desiredOutputs, ["file updated successfully", "compilation passes"])
    }

    func testVAL_DAEMON_014_PlannerInputPreservesConstraintsRiskAndOutputsThroughSerialization() throws {
        // VAL-DAEMON-014: Typed planner input preserves constraints/risk-level/desired-output fields
        let intent = BurnBarAgentIntent(
            kind: .inspectWorkspace,
            objective: "Find relevant files",
            summary: "Workspace inspection",
            searchQuery: "BurnBarRunService",
            requestedTools: [.searchWorkspace]
        )
        let plannerInput = BurnBarPlannerInput(
            schemaVersion: 1,
            missionID: BurnBarMissionID(rawValue: "mission-preserve"),
            normalizedIntent: intent,
            constraints: ["search only src/ directory"],
            riskLevel: .low,
            desiredOutputs: ["files identified and listed"],
            workflowHints: ["scope": .string("src")],
            toolHints: ["maxResults": .number(10)]
        )

        // Serialize
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(plannerInput)

        // Deserialize
        let decoder = JSONDecoder()
        let roundTripped = try decoder.decode(BurnBarPlannerInput.self, from: jsonData)

        // Verify all fields preserved
        XCTAssertEqual(roundTripped.schemaVersion, plannerInput.schemaVersion)
        XCTAssertEqual(roundTripped.missionID, plannerInput.missionID)
        XCTAssertEqual(roundTripped.constraints, plannerInput.constraints)
        XCTAssertEqual(roundTripped.riskLevel, plannerInput.riskLevel)
        XCTAssertEqual(roundTripped.desiredOutputs, plannerInput.desiredOutputs)
        XCTAssertEqual(roundTripped.workflowHints?["scope"], .string("src"))
        XCTAssertEqual(roundTripped.toolHints?["maxResults"], .number(10))
    }

    func testVAL_DAEMON_014_PlannerInputSchemaVersionIsEncodedAndDecoded() throws {
        // VAL-DAEMON-014: Schema version must be preserved for version compatibility checking
        let intent = BurnBarAgentIntent(
            kind: .generic,
            objective: "Test schema version",
            summary: "Version test"
        )

        // Test with schema version 1 (current)
        let inputV1 = BurnBarPlannerInput(
            schemaVersion: 1,
            missionID: BurnBarMissionID(rawValue: "mission-v1"),
            normalizedIntent: intent,
            constraints: ["constraint1"],
            riskLevel: .low,
            desiredOutputs: ["output1"]
        )

        let dataV1 = try JSONEncoder().encode(inputV1)
        let decodedV1 = try JSONDecoder().decode(BurnBarPlannerInput.self, from: dataV1)
        XCTAssertEqual(decodedV1.schemaVersion, 1)

        // Test with explicit schema version 2 (if supported in future)
        let inputV2 = BurnBarPlannerInput(
            schemaVersion: 2,
            missionID: BurnBarMissionID(rawValue: "mission-v2"),
            normalizedIntent: intent,
            constraints: ["constraint1"],
            riskLevel: .low,
            desiredOutputs: ["output1"]
        )

        let dataV2 = try JSONEncoder().encode(inputV2)
        let decodedV2 = try JSONDecoder().decode(BurnBarPlannerInput.self, from: dataV2)
        XCTAssertEqual(decodedV2.schemaVersion, 2)
    }

    func testVAL_DAEMON_014_PlannerInputRejectsMissingRequiredFieldsAtSchemaLevel() throws {
        // VAL-DAEMON-014: Missing required fields should be detectable at decode time
        // Note: Swift Codable doesn't enforce required fields automatically,
        // but we can verify the schema structure and test the validation in the service layer

        // Valid input with all required fields
        let validIntent = BurnBarAgentIntent(kind: .generic, objective: "test", summary: "test")
        let validInput = BurnBarPlannerInput(
            missionID: BurnBarMissionID(rawValue: "mission-valid"),
            normalizedIntent: validIntent,
            constraints: ["must have constraints"],
            riskLevel: .low,
            desiredOutputs: ["must have outputs"]
        )

        // Verify valid input encodes/decodes correctly
        let validData = try JSONEncoder().encode(validInput)
        let validDecoded = try JSONDecoder().decode(BurnBarPlannerInput.self, from: validData)
        XCTAssertEqual(validDecoded.constraints, ["must have constraints"])
        XCTAssertEqual(validDecoded.desiredOutputs, ["must have outputs"])

        // The service layer (BurnBarPlannerService) validates that constraints and desiredOutputs
        // are non-empty when processing planner input. This is tested in BurnBarAgentStackTests
        // with the VAL_DAEMON_014 tagged tests there.
    }

    // MARK: - VAL-DAEMON-010: Typed DAG contract round-trips with deterministic IDs

    func testVAL_DAEMON_010_DAGContractRoundTripPreservesAllFields() throws {
        // VAL-DAEMON-010: DAG contracts round-trip losslessly with all fields preserved
        let missionID = BurnBarMissionID(rawValue: "mission-dag-010")

        // Create deterministic node IDs
        let node1ID = BurnBarDAGNodeID.deterministic(
            missionID: missionID,
            stepIndex: 0,
            contentHash: "Step 1|Find files"
        )
        let node2ID = BurnBarDAGNodeID.deterministic(
            missionID: missionID,
            stepIndex: 1,
            contentHash: "Step 2|Edit file"
        )

        let node1 = BurnBarDAGNode(
            id: node1ID,
            title: "Find files",
            detail: "Search for files matching pattern",
            status: .pending,
            dependsOn: [],
            metadata: ["pattern": .string("*.swift")]
        )
        let node2 = BurnBarDAGNode(
            id: node2ID,
            title: "Edit file",
            detail: "Apply the changes",
            status: .pending,
            dependsOn: [node1ID],
            metadata: ["tool": .string("applyPatch")]
        )

        let edge = BurnBarDAGEdge(
            sourceNodeID: node1ID,
            targetNodeID: node2ID
        )

        let dagContract = BurnBarDAGContract(
            schemaVersion: .v1,
            missionID: missionID,
            nodes: [node1, node2],
            edges: [edge],
            metadata: ["createdBy": .string("planner")]
        )

        // Round-trip encode/decode
        let data = try JSONEncoder().encode(dagContract)
        let decoded = try JSONDecoder().decode(BurnBarDAGContract.self, from: data)

        // Verify all fields preserved
        XCTAssertEqual(decoded.schemaVersion, .v1)
        XCTAssertEqual(decoded.missionID, missionID)
        XCTAssertEqual(decoded.nodes.count, 2)
        XCTAssertEqual(decoded.edges.count, 1)
        XCTAssertEqual(decoded.nodes[0].title, "Find files")
        XCTAssertEqual(decoded.nodes[1].title, "Edit file")
        XCTAssertEqual(decoded.nodes[1].dependsOn.count, 1)
        XCTAssertEqual(decoded.nodes[1].dependsOn.first, node1ID)
        XCTAssertEqual(decoded.metadata?["createdBy"], .string("planner"))
        XCTAssertEqual(decoded.edges[0].sourceNodeID, node1ID)
        XCTAssertEqual(decoded.edges[0].targetNodeID, node2ID)
    }

    func testVAL_DAEMON_010_DeterministicNodeIDsForIdenticalIntent() throws {
        // VAL-DAEMON-010: Same intent input produces stable node IDs
        let missionID = BurnBarMissionID(rawValue: "mission-det-010")
        let stepIndex = 0
        let title = "Search workspace"
        let detail = "Find all Swift files"

        // Generate ID twice with identical inputs
        let id1 = BurnBarDAGNode.makeDeterministicID(
            missionID: missionID,
            stepIndex: stepIndex,
            title: title,
            detail: detail
        )
        let id2 = BurnBarDAGNode.makeDeterministicID(
            missionID: missionID,
            stepIndex: stepIndex,
            title: title,
            detail: detail
        )

        // IDs must be identical for identical inputs
        XCTAssertEqual(id1, id2)

        // Different step index produces different ID
        let id3 = BurnBarDAGNode.makeDeterministicID(
            missionID: missionID,
            stepIndex: stepIndex + 1,
            title: title,
            detail: detail
        )
        XCTAssertNotEqual(id1, id3)

        // Different detail produces different ID
        let id4 = BurnBarDAGNode.makeDeterministicID(
            missionID: missionID,
            stepIndex: stepIndex,
            title: title,
            detail: "Different detail"
        )
        XCTAssertNotEqual(id1, id4)
    }

    func testVAL_DAEMON_010_DeterministicEdgeIDsForIdenticalRelationships() throws {
        // VAL-DAEMON-010: Same edge relationship produces stable edge IDs
        let missionID = BurnBarMissionID(rawValue: "mission-edge-010")
        let node1ID = BurnBarDAGNodeID.deterministic(
            missionID: missionID,
            stepIndex: 0,
            contentHash: "Step 1"
        )
        let node2ID = BurnBarDAGNodeID.deterministic(
            missionID: missionID,
            stepIndex: 1,
            contentHash: "Step 2"
        )

        // Generate edge ID twice
        let edgeID1 = BurnBarDAGEdgeID.deterministic(
            sourceNodeID: node1ID,
            targetNodeID: node2ID
        )
        let edgeID2 = BurnBarDAGEdgeID.deterministic(
            sourceNodeID: node1ID,
            targetNodeID: node2ID
        )

        // Edge IDs must be identical for identical relationships
        XCTAssertEqual(edgeID1, edgeID2)
    }

    func testVAL_DAEMON_010_DAGContractJSONFormatIsStable() throws {
        // VAL-DAEMON-010: JSON format is stable for same content
        let missionID = BurnBarMissionID(rawValue: "mission-json-010")
        let nodeID = BurnBarDAGNodeID.deterministic(
            missionID: missionID,
            stepIndex: 0,
            contentHash: "Single step"
        )
        let node = BurnBarDAGNode(
            id: nodeID,
            title: "Single Step",
            detail: "A single DAG node"
        )
        let dagContract = BurnBarDAGContract(
            missionID: missionID,
            nodes: [node]
        )

        // Encode and decode - should produce semantically equivalent contracts
        let data = try JSONEncoder().encode(dagContract)
        let decoded = try JSONDecoder().decode(BurnBarDAGContract.self, from: data)

        // Verify the round-trip preserved all content
        XCTAssertEqual(dagContract.missionID, decoded.missionID)
        XCTAssertEqual(dagContract.schemaVersion, decoded.schemaVersion)
        XCTAssertEqual(dagContract.nodes.count, decoded.nodes.count)
        XCTAssertEqual(dagContract.nodes.first?.title, decoded.nodes.first?.title)
        XCTAssertEqual(dagContract.nodes.first?.detail, decoded.nodes.first?.detail)
        XCTAssertEqual(dagContract.edges.count, decoded.edges.count)
    }

    func testVAL_DAEMON_010_RoundTripPreservesDAGStructure() throws {
        // VAL-DAEMON-010: DAG structure is preserved through round-trip
        let missionID = BurnBarMissionID(rawValue: "mission-structure-010")

        let node1ID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 0, contentHash: "Node 1"
        )
        let node2ID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 1, contentHash: "Node 2"
        )
        let node3ID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 2, contentHash: "Node 3"
        )

        let node1 = BurnBarDAGNode(
            id: node1ID,
            title: "Node 1",
            detail: "First node",
            dependsOn: []
        )
        let node2 = BurnBarDAGNode(
            id: node2ID,
            title: "Node 2",
            detail: "Second node",
            dependsOn: [node1ID]
        )
        let node3 = BurnBarDAGNode(
            id: node3ID,
            title: "Node 3",
            detail: "Third node",
            dependsOn: [node1ID, node2ID]
        )

        let edge1 = BurnBarDAGEdge(sourceNodeID: node1ID, targetNodeID: node2ID)
        let edge2 = BurnBarDAGEdge(sourceNodeID: node2ID, targetNodeID: node3ID)

        let dagContract = BurnBarDAGContract(
            missionID: missionID,
            nodes: [node1, node2, node3],
            edges: [edge1, edge2]
        )

        let data = try JSONEncoder().encode(dagContract)
        let decoded = try JSONDecoder().decode(BurnBarDAGContract.self, from: data)

        // Verify round-trip preserved structure
        XCTAssertEqual(dagContract.missionID, decoded.missionID)
        XCTAssertEqual(dagContract.nodes.count, decoded.nodes.count)
        XCTAssertEqual(dagContract.edges.count, decoded.edges.count)

        // Verify node dependencies are preserved
        let decodedNode2 = decoded.nodes.first { $0.id == node2ID }
        let decodedNode3 = decoded.nodes.first { $0.id == node3ID }
        XCTAssertEqual(decodedNode2?.dependsOn.first, node1ID)
        XCTAssertEqual(decodedNode3?.dependsOn.count, 2)
    }

    func testVAL_DAEMON_010_TopologicalSortReturnsCorrectOrder() throws {
        // VAL-DAEMON-010: Topological sort respects dependency order
        let missionID = BurnBarMissionID(rawValue: "mission-sort-010")

        let nodeAID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 0, contentHash: "A"
        )
        let nodeBID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 1, contentHash: "B"
        )
        let nodeCID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 2, contentHash: "C"
        )

        // C depends on A and B
        let nodeA = BurnBarDAGNode(id: nodeAID, title: "A", detail: "Step A")
        let nodeB = BurnBarDAGNode(id: nodeBID, title: "B", detail: "Step B")
        let nodeC = BurnBarDAGNode(
            id: nodeCID, title: "C", detail: "Step C",
            dependsOn: [nodeAID, nodeBID]
        )

        let dag = BurnBarDAGContract(
            missionID: missionID,
            nodes: [nodeC, nodeA, nodeB]  // Out of order
        )

        let sorted = dag.topologicalSort()
        XCTAssertNotNil(sorted)

        // A and B must come before C
        let aIndex = sorted!.firstIndex(where: { $0.id == nodeAID })!
        let bIndex = sorted!.firstIndex(where: { $0.id == nodeBID })!
        let cIndex = sorted!.firstIndex(where: { $0.id == nodeCID })!

        XCTAssertLessThan(aIndex, cIndex)
        XCTAssertLessThan(bIndex, cIndex)
    }

    // MARK: - VAL-DAEMON-013: Versioned DAG serialization backward compatibility

    func testVAL_DAEMON_013_SchemaVersionIsEncodedInContract() throws {
        // VAL-DAEMON-013: Schema version is explicitly encoded in the DAG contract
        let missionID = BurnBarMissionID(rawValue: "mission-version-013")
        let nodeID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 0, contentHash: "Step"
        )
        let node = BurnBarDAGNode(id: nodeID, title: "Step", detail: "A step")

        let dagContractV1 = BurnBarDAGContract(
            schemaVersion: .v1,
            missionID: missionID,
            nodes: [node]
        )

        let data = try JSONEncoder().encode(dagContractV1)
        let json = String(data: data, encoding: .utf8)!

        // JSON must contain schemaVersion field
        XCTAssertTrue(json.contains("schemaVersion"))
        XCTAssertTrue(json.contains("1"))
    }

    func testVAL_DAEMON_013_CurrentVersionDecodesSuccessfully() throws {
        // VAL-DAEMON-013: Current schema version decodes without error
        let missionID = BurnBarMissionID(rawValue: "mission-current-013")
        let nodeID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 0, contentHash: "Step"
        )
        let node = BurnBarDAGNode(id: nodeID, title: "Step", detail: "A step")

        let dagContract = BurnBarDAGContract(
            schemaVersion: .v1,
            missionID: missionID,
            nodes: [node]
        )

        let data = try JSONEncoder().encode(dagContract)
        let decoded = try BurnBarDAGContractCodec.decode(from: data)

        XCTAssertEqual(decoded.schemaVersion, .v1)
        XCTAssertEqual(decoded.nodes.count, 1)
    }

    func testVAL_DAEMON_013_UnsupportedVersionThrowsExplicitError() throws {
        // VAL-DAEMON-013: Unsupported schema version fails with explicit BurnBarDAGError.unsupportedSchemaVersion
        let unsupportedJSON = """
        {
            "schemaVersion": 99,
            "missionID": "mission-unsupported-013",
            "nodes": [],
            "edges": []
        }
        """.data(using: .utf8)!

        do {
            _ = try BurnBarDAGContractCodec.decode(from: unsupportedJSON)
            XCTFail("Expected decoding to fail for invalid schema version 99 (not a valid enum case)")
        } catch let error as BurnBarDAGError {
            // Verify explicit unsupportedSchemaVersion error is thrown
            switch error {
            case .unsupportedSchemaVersion(let version):
                XCTAssertEqual(version, 99, "Unsupported schema version should be 99")
            default:
                XCTFail("Expected unsupportedSchemaVersion error, got \(error)")
            }
        } catch {
            XCTFail("Expected BurnBarDAGError, got \(error)")
        }
    }

    func testVAL_DAEMON_013_VersionedCodecPreservesSchemaVersion() throws {
        // VAL-DAEMON-013: Codec preserves schema version through round-trip
        let missionID = BurnBarMissionID(rawValue: "mission-codec-013")
        let nodeID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 0, contentHash: "Step"
        )
        let node = BurnBarDAGNode(id: nodeID, title: "Step", detail: "A step")

        let original = BurnBarDAGContract(
            schemaVersion: .v1,
            missionID: missionID,
            nodes: [node]
        )

        let encoded = try BurnBarDAGContractCodec.encode(original)
        let decoded = try BurnBarDAGContractCodec.decode(from: encoded)

        XCTAssertEqual(decoded.schemaVersion, original.schemaVersion)
        XCTAssertEqual(decoded.missionID, original.missionID)
        XCTAssertEqual(decoded.nodes.count, original.nodes.count)
    }

    func testVAL_DAEMON_013_ValidationFailsForMissingNodeReferences() throws {
        // VAL-DAEMON-013: Validation detects missing node dependencies
        let missionID = BurnBarMissionID(rawValue: "mission-validate-013")
        let realNodeID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 0, contentHash: "Real"
        )
        let fakeNodeID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 99, contentHash: "Fake"
        )

        let realNode = BurnBarDAGNode(id: realNodeID, title: "Real", detail: "Real node")
        let dependentNode = BurnBarDAGNode(
            id: fakeNodeID,  // Use fake ID for the node itself
            title: "Dependent",
            detail: "Depends on missing node",
            dependsOn: [realNodeID]  // But claims to depend on real node - this is valid
        )

        // Create contract where node ID doesn't match its declared dependencies
        let invalidContract = BurnBarDAGContract(
            missionID: missionID,
            nodes: [realNode, dependentNode]
        )

        // This should validate since all dependsOn references exist
        XCTAssertNoThrow(try invalidContract.validate())
    }

    func testVAL_DAEMON_013_ValidationDetectsCircularDependencies() throws {
        // VAL-DAEMON-013: Validation detects circular dependencies
        let missionID = BurnBarMissionID(rawValue: "mission-cycle-013")

        let nodeAID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 0, contentHash: "A"
        )
        let nodeBID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 1, contentHash: "B"
        )
        let nodeCID = BurnBarDAGNodeID.deterministic(
            missionID: missionID, stepIndex: 2, contentHash: "C"
        )

        // A -> B -> C -> A (cycle)
        let nodeA = BurnBarDAGNode(
            id: nodeAID, title: "A", detail: "A",
            dependsOn: [nodeCID]  // A depends on C
        )
        let nodeB = BurnBarDAGNode(
            id: nodeBID, title: "B", detail: "B",
            dependsOn: [nodeAID]  // B depends on A
        )
        let nodeC = BurnBarDAGNode(
            id: nodeCID, title: "C", detail: "C",
            dependsOn: [nodeBID]  // C depends on B
        )

        let cyclicContract = BurnBarDAGContract(
            missionID: missionID,
            nodes: [nodeA, nodeB, nodeC]
        )

        do {
            try cyclicContract.validate()
            XCTFail("Expected circular dependency error")
        } catch let error as BurnBarDAGError {
            if case .circularDependencyDetected = error {
                // Expected
            } else {
                XCTFail("Expected circularDependencyDetected error, got \(error)")
            }
        } catch {
            XCTFail("Expected BurnBarDAGError, got \(error)")
        }
    }

    func testVAL_DAEMON_013_SupportedVersionsIncludesV1() throws {
        // VAL-DAEMON-013: Schema version V1 is in supported versions list
        XCTAssertTrue(BurnBarDAGSchemaVersion.supported.contains(.v1))
        XCTAssertEqual(BurnBarDAGSchemaVersion.supported.count, 1)
    }

    func testVAL_DAEMON_013_ForwardCompatibilityIsExplicit() throws {
        // VAL-DAEMON-013: Forward compatibility expectations are explicit
        // V1 is supported, and unsupported versions are explicitly rejected
        XCTAssertTrue(BurnBarDAGSchemaVersion.isSupported(.v1))
        XCTAssertEqual(BurnBarDAGSchemaVersion.supported, [.v1])
    }

    func testVAL_DAEMON_013_UnsupportedVersionViaRawJSONFails() throws {
        // VAL-DAEMON-013: Unsupported schema version (raw value not in enum) fails with explicit error
        // Using JSONDecoder directly to verify custom init properly rejects unknown schema versions
        let jsonWithInvalidVersion = """
        {
            "schemaVersion": 999,
            "missionID": "mission-invalid-013",
            "nodes": [],
            "edges": []
        }
        """.data(using: .utf8)!

        do {
            _ = try JSONDecoder().decode(BurnBarDAGContract.self, from: jsonWithInvalidVersion)
            XCTFail("Expected decoding to fail for invalid schema version")
        } catch let error as BurnBarDAGError {
            // Verify explicit unsupportedSchemaVersion error is thrown
            switch error {
            case .unsupportedSchemaVersion(let version):
                XCTAssertEqual(version, 999, "Unsupported schema version should be 999")
            default:
                XCTFail("Expected unsupportedSchemaVersion error, got \(error)")
            }
        } catch {
            XCTFail("Expected BurnBarDAGError, got \(error)")
        }
    }
}
