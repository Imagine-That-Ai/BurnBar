import XCTest
@testable import OpenBurnBarCore

/// Contract tests for the perf-round-2 (macos-007) additions in
/// `OpenBurnBarMissionControlMissionsContracts.swift`: the aggregated
/// `BurnBarControllerRuntimeSnapshot{Request,Payload,Response}` types and the
/// optional `runtimeSnapshot` riders on the controller-mutation responses.
/// Complements `BurnBarMissionControlContractsTests`, which round-trips a
/// minimal payload through Swift's encoder: here we pin the RAW wire shape
/// (hand-authored JSON), fully populate the sections that suite leaves empty,
/// and check field-sensitive equality plus explicit-null tolerance.
final class OpenBurnBarMissionControlMissionsContractsTests: XCTestCase {
    // MARK: - Wire fixtures (hand-authored daemon JSON; dates are
    // timeIntervalSinceReferenceDate per the default JSONDecoder strategy)

    private static let questionWireJSON = """
    {
      "id": "question-wire-1",
      "projectSlug": "openburnbar",
      "title": "Approve rollout?",
      "prompt": "Ship the deferred round?",
      "status": "pending",
      "priority": "critical",
      "askedAt": 1001
    }
    """

    private static let followupWireJSON = """
    {
      "id": "followup-wire-1",
      "projectSlug": "openburnbar",
      "title": "Verify rollout",
      "summary": "Confirm the deferred work landed.",
      "status": "open",
      "kind": "controller_nudge",
      "createdAt": 1002,
      "metadata": {}
    }
    """

    private static let payloadWireJSON = """
    {
      "summary": {
        "updatedAt": 1000,
        "activeProjectSlug": "openburnbar",
        "counts": {
          "projectCount": 2,
          "pendingQuestionCount": 1,
          "openFollowupCount": 1,
          "activeMissionCount": 1,
          "staleProjectCount": 0
        },
        "nextSuggestedCadence": "ad_hoc",
        "freshness": "fresh",
        "projectionStatus": [],
        "recentEvents": []
      },
      "questions": [\(questionWireJSON)],
      "followups": [\(followupWireJSON)],
      "missions": [
        {
          "id": "mission-wire-1",
          "projectSlug": "openburnbar",
          "title": "Deferred round 2",
          "summary": "Land the aggregated snapshot RPC.",
          "status": "in_progress",
          "recommendation": "proceed",
          "createdAt": 1003,
          "updatedAt": 1004,
          "approval": { "approved": true },
          "packets": [],
          "results": [],
          "burnRecords": [],
          "metadata": {}
        }
      ],
      "notificationHealth": {
        "checkedAt": 1005,
        "channels": [
          {
            "channel": "telegram",
            "status": "degraded",
            "checkedAt": 1006
          }
        ]
      },
      "simulatorRuns": [
        {
          "id": "sim-wire-1",
          "projectSlug": "openburnbar",
          "scenarioName": "runtime-snapshot",
          "status": "completed",
          "seed": 7,
          "startedAt": 1007,
          "emittedEvents": [],
          "projectionStatus": [],
          "summary": "Replay finished."
        }
      ]
    }
    """

    // MARK: - Builder (fully populated, single-knob variants for equality)

    private let now = Date(timeIntervalSince1970: 1_710_002_000)

    private func makePayload(
        staleProjectCount: Int = 1,
        questionTitle: String = "Approve rollout?",
        followupStatus: BurnBarFollowupStatus = .open,
        missionRecommendation: BurnBarMissionRecommendation = .proceed,
        telegramStatus: BurnBarNotificationHealthStatus = .healthy,
        simulatorSeed: Int = 7
    ) -> BurnBarControllerRuntimeSnapshotPayload {
        let missionID = BurnBarMissionID(rawValue: "mission-full-1")
        let packet = BurnBarMissionPacketSnapshot(
            id: BurnBarMissionPacketID(rawValue: "packet-full-1"),
            missionID: missionID,
            workerName: "executor",
            objective: "Apply the aggregated snapshot",
            status: .running,
            runID: BurnBarRunID(rawValue: "run-full-1"),
            dispatchedAt: now
        )
        let result = BurnBarMissionResultSnapshot(
            id: BurnBarMissionResultID(rawValue: "result-full-1"),
            missionID: missionID,
            packetID: packet.id,
            status: .partial,
            summary: "First slice landed.",
            burnDelta: 1.5,
            createdAt: now.addingTimeInterval(60)
        )
        return BurnBarControllerRuntimeSnapshotPayload(
            summary: BurnBarControllerSummary(
                updatedAt: now,
                activeProjectSlug: "openburnbar",
                counts: BurnBarControllerCounts(
                    projectCount: 2,
                    pendingQuestionCount: 1,
                    openFollowupCount: 1,
                    activeMissionCount: 1,
                    staleProjectCount: staleProjectCount
                ),
                nextSuggestedCadence: .weekly,
                latestReviewAt: now,
                freshness: .aging,
                projectionStatus: [
                    BurnBarProjectionStatusSnapshot(
                        projectionName: "controller_summary",
                        status: .upToDate,
                        freshness: .fresh,
                        lastMaterializedAt: now,
                        lastEventSequence: 12
                    )
                ],
                recentEvents: [
                    BurnBarControllerEvent(
                        id: BurnBarControllerEventID(rawValue: "event-full-1"),
                        family: .controller,
                        eventType: "runtime_snapshot_served",
                        projectSlug: "openburnbar",
                        recordedAt: now,
                        sequence: 12,
                        summary: "Aggregate snapshot served in one round trip"
                    )
                ],
                nextActions: [
                    BurnBarControllerNextActionSnapshot(
                        id: "next-1",
                        missionID: missionID,
                        projectSlug: "openburnbar",
                        title: "Review partial result",
                        summary: "One packet still running.",
                        bucket: .interruption,
                        status: .inProgress,
                        recommendation: .review,
                        updatedAt: now
                    )
                ]
            ),
            questions: [
                BurnBarPendingQuestionSnapshot(
                    id: BurnBarQuestionID(rawValue: "question-full-1"),
                    projectSlug: "openburnbar",
                    title: questionTitle,
                    prompt: "Ship the deferred round?",
                    status: .pending,
                    priority: .high,
                    askedAt: now
                )
            ],
            followups: [
                BurnBarFollowupSnapshot(
                    id: BurnBarFollowupID(rawValue: "followup-full-1"),
                    projectSlug: "openburnbar",
                    title: "Verify rollout",
                    summary: "Confirm the deferred work landed.",
                    status: followupStatus,
                    kind: .controllerNudge,
                    createdAt: now
                )
            ],
            missions: [
                BurnBarMissionSnapshot(
                    id: missionID,
                    projectSlug: "openburnbar",
                    title: "Deferred round 2",
                    summary: "Land the aggregated snapshot RPC.",
                    status: .inProgress,
                    recommendation: missionRecommendation,
                    createdAt: now,
                    updatedAt: now.addingTimeInterval(60),
                    approval: BurnBarMissionApprovalSnapshot(
                        approved: true,
                        approvedAt: now,
                        approvedBy: "operator"
                    ),
                    packets: [packet],
                    results: [result],
                    burnRecords: [
                        BurnBarMissionBurnRecord(
                            id: "burn-full-1",
                            label: "Executor pass",
                            amount: 1.5,
                            unit: "points",
                            recordedAt: now.addingTimeInterval(60)
                        )
                    ]
                )
            ],
            notificationHealth: BurnBarNotificationHealthSnapshot(
                checkedAt: now,
                channels: [
                    BurnBarNotificationChannelHealth(channel: .local, status: .healthy, checkedAt: now),
                    BurnBarNotificationChannelHealth(
                        channel: .telegram,
                        status: telegramStatus,
                        detail: telegramStatus == .healthy ? nil : "Webhook lagging",
                        checkedAt: now
                    ),
                    BurnBarNotificationChannelHealth(channel: .calendar, status: .disabled, checkedAt: now)
                ]
            ),
            simulatorRuns: [
                BurnBarSimulatorRunSnapshot(
                    id: BurnBarSimulatorRunID(rawValue: "sim-full-1"),
                    projectSlug: "openburnbar",
                    scenarioName: "runtime-snapshot",
                    status: .completed,
                    seed: simulatorSeed,
                    startedAt: now,
                    completedAt: now.addingTimeInterval(3),
                    summary: "Replay finished."
                )
            ]
        )
    }

    // MARK: - Request

    func testRuntimeSnapshotRequest_encodesAsEmptyObjectAndToleratesUnknownKeys() throws {
        let request = BurnBarControllerRuntimeSnapshotRequest()

        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "{}",
            "The aggregate request carries no parameters; anything else on the wire is accidental API surface."
        )

        XCTAssertEqual(
            try JSONDecoder().decode(BurnBarControllerRuntimeSnapshotRequest.self, from: data),
            request
        )

        // Forward compatibility: a future daemon adding knobs must not break
        // current clients decoding the request shape.
        let withFutureKnob = Data(#"{"includeArchivedMissions": true}"#.utf8)
        XCTAssertNoThrow(
            try JSONDecoder().decode(BurnBarControllerRuntimeSnapshotRequest.self, from: withFutureKnob)
        )
    }

    // MARK: - Payload

    func testRuntimeSnapshotPayload_roundTripsFullyPopulatedSections() throws {
        // The sibling suite round-trips a payload with empty missions,
        // channels, and simulator runs; this populates every section.
        let payload = makePayload()

        let data = try JSONEncoder().encode(BurnBarControllerRuntimeSnapshotResponse(snapshot: payload))
        let decoded = try JSONDecoder().decode(BurnBarControllerRuntimeSnapshotResponse.self, from: data)

        XCTAssertEqual(decoded.snapshot, payload)
        XCTAssertEqual(decoded.snapshot.summary.nextActions?.first?.bucket, .interruption)
        XCTAssertEqual(decoded.snapshot.summary.projectionStatus.first?.lastEventSequence, 12)
        XCTAssertEqual(decoded.snapshot.summary.recentEvents.first?.eventType, "runtime_snapshot_served")
        XCTAssertEqual(decoded.snapshot.missions.first?.packets.first?.workerName, "executor")
        XCTAssertEqual(decoded.snapshot.missions.first?.results.first?.burnDelta, 1.5)
        XCTAssertEqual(decoded.snapshot.missions.first?.burnRecords.first?.unit, "points")
        XCTAssertEqual(decoded.snapshot.missions.first?.approval.approvedBy, "operator")
        XCTAssertEqual(
            decoded.snapshot.notificationHealth.channels.map(\.channel),
            [.local, .telegram, .calendar]
        )
        XCTAssertEqual(decoded.snapshot.simulatorRuns.first?.status, .completed)
        XCTAssertEqual(decoded.snapshot.simulatorRuns.first?.seed, 7)
    }

    func testRuntimeSnapshotPayload_equalityIsSensitiveToEverySection() {
        let base = makePayload()
        let identicalTwin = makePayload()

        XCTAssertEqual(base, identicalTwin)
        XCTAssertEqual(base.hashValue, identicalTwin.hashValue)

        // Flipping exactly one field in each of the six sections must break
        // equality — the client uses payload equality to skip redundant UI
        // refreshes, so an insensitive section would mask live changes.
        XCTAssertNotEqual(base, makePayload(staleProjectCount: 2), "summary must participate in equality")
        XCTAssertNotEqual(base, makePayload(questionTitle: "Hold rollout?"), "questions must participate in equality")
        XCTAssertNotEqual(base, makePayload(followupStatus: .done), "followups must participate in equality")
        XCTAssertNotEqual(base, makePayload(missionRecommendation: .pause), "missions must participate in equality")
        XCTAssertNotEqual(base, makePayload(telegramStatus: .degraded), "notificationHealth must participate in equality")
        XCTAssertNotEqual(base, makePayload(simulatorSeed: 8), "simulatorRuns must participate in equality")
    }

    func testRuntimeSnapshotPayload_decodesFromRawDaemonWireJSON() throws {
        // Hand-authored JSON pins the wire key names independently of Swift's
        // encoder, so a CodingKeys rename cannot slip through a symmetric
        // encode-then-decode test.
        let decoded = try JSONDecoder().decode(
            BurnBarControllerRuntimeSnapshotPayload.self,
            from: Data(Self.payloadWireJSON.utf8)
        )

        XCTAssertEqual(decoded.summary.updatedAt, Date(timeIntervalSinceReferenceDate: 1000))
        XCTAssertEqual(decoded.summary.activeProjectSlug, "openburnbar")
        XCTAssertEqual(decoded.summary.counts.projectCount, 2)
        XCTAssertEqual(decoded.summary.counts.activeMissionCount, 1)
        XCTAssertEqual(decoded.summary.nextSuggestedCadence, .adHoc)
        XCTAssertEqual(decoded.summary.freshness, .fresh)
        XCTAssertNil(decoded.summary.nextActions)

        XCTAssertEqual(decoded.questions.count, 1)
        let question = try XCTUnwrap(decoded.questions.first)
        XCTAssertEqual(question.id, BurnBarQuestionID(rawValue: "question-wire-1"))
        XCTAssertEqual(question.status, .pending)
        XCTAssertEqual(question.priority, .critical)
        XCTAssertEqual(question.askedAt, Date(timeIntervalSinceReferenceDate: 1001))
        // Absent optional/collection keys on the wire decode to defaults.
        XCTAssertNil(question.sessionID)
        XCTAssertEqual(question.evidenceRefs, [])
        XCTAssertEqual(question.suggestedOptions, [])
        XCTAssertEqual(question.metadata, [:])

        let followup = try XCTUnwrap(decoded.followups.first)
        XCTAssertEqual(followup.id, BurnBarFollowupID(rawValue: "followup-wire-1"))
        XCTAssertEqual(followup.status, .open)
        XCTAssertEqual(followup.kind, .controllerNudge)
        XCTAssertEqual(followup.createdAt, Date(timeIntervalSinceReferenceDate: 1002))
        XCTAssertNil(followup.questionID)

        let mission = try XCTUnwrap(decoded.missions.first)
        XCTAssertEqual(mission.id, BurnBarMissionID(rawValue: "mission-wire-1"))
        XCTAssertEqual(mission.status, .inProgress)
        XCTAssertEqual(mission.recommendation, .proceed)
        XCTAssertEqual(mission.createdAt, Date(timeIntervalSinceReferenceDate: 1003))
        XCTAssertEqual(mission.updatedAt, Date(timeIntervalSinceReferenceDate: 1004))
        XCTAssertTrue(mission.approval.approved)
        XCTAssertEqual(mission.packets, [])
        XCTAssertNil(mission.takeoverHistory)
        XCTAssertNil(mission.prLinkage)

        XCTAssertEqual(decoded.notificationHealth.checkedAt, Date(timeIntervalSinceReferenceDate: 1005))
        let channel = try XCTUnwrap(decoded.notificationHealth.channels.first)
        XCTAssertEqual(channel.channel, .telegram)
        XCTAssertEqual(channel.status, .degraded)
        XCTAssertNil(channel.detail)
        XCTAssertEqual(channel.checkedAt, Date(timeIntervalSinceReferenceDate: 1006))

        let run = try XCTUnwrap(decoded.simulatorRuns.first)
        XCTAssertEqual(run.id, BurnBarSimulatorRunID(rawValue: "sim-wire-1"))
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.seed, 7)
        XCTAssertEqual(run.startedAt, Date(timeIntervalSinceReferenceDate: 1007))
        XCTAssertNil(run.completedAt)
        XCTAssertEqual(run.summary, "Replay finished.")
    }

    // MARK: - Mutation riders

    func testMutationResponses_decodeExplicitNullAndPopulatedWireRuntimeSnapshot() throws {
        // The sibling suite covers the ABSENT-key case via encode-then-decode.
        // A daemon emitting an explicit null (e.g. a serializer that does not
        // strip nils) must also land as "no snapshot, use the fallback RPCs".
        let answerWithNull = Data("""
        {
          "question": \(Self.questionWireJSON),
          "runtimeSnapshot": null
        }
        """.utf8)
        let answerDecoded = try JSONDecoder().decode(BurnBarQuestionAnswerResponse.self, from: answerWithNull)
        XCTAssertEqual(answerDecoded.question.id, BurnBarQuestionID(rawValue: "question-wire-1"))
        XCTAssertNil(answerDecoded.runtimeSnapshot)
        XCTAssertNil(answerDecoded.followup)
        XCTAssertNil(answerDecoded.emittedEvent)

        // A new daemon embeds the full aggregate under the exact
        // "runtimeSnapshot" wire key; the rider must decode intact.
        let followupWithSnapshot = Data("""
        {
          "followup": \(Self.followupWireJSON),
          "runtimeSnapshot": \(Self.payloadWireJSON)
        }
        """.utf8)
        let followupDecoded = try JSONDecoder().decode(
            BurnBarFollowupMutationResponse.self,
            from: followupWithSnapshot
        )
        XCTAssertEqual(followupDecoded.followup.id, BurnBarFollowupID(rawValue: "followup-wire-1"))
        let rider = try XCTUnwrap(followupDecoded.runtimeSnapshot)
        XCTAssertEqual(rider.questions.count, 1)
        XCTAssertEqual(rider.followups.count, 1)
        XCTAssertEqual(rider.missions.count, 1)
        XCTAssertEqual(rider.simulatorRuns.count, 1)
        XCTAssertEqual(rider.summary.counts.activeMissionCount, 1)
        XCTAssertEqual(rider.notificationHealth.channels.first?.status, .degraded)
    }
}
