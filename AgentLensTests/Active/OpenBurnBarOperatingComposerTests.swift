import Foundation
import GRDB
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class OpenBurnBarOperatingComposerTests: XCTestCase {
    @MainActor
    func testMissionUsesIncompleteHintInsteadOfBlockedKeywordMatching() throws {
        let store = try makeInMemoryStore()
        let now = Date()
        try seedProject(
            store: store,
            project: "Apollo",
            conversationDates: stride(from: 4, through: 0, by: -1).map { now.addingTimeInterval(Double(-$0) * 3_600) },
            latestMessage: "The release notes say the migration is blocked. Should we keep the current launch scope?",
            latestSummary: nil,
            latestSummaryTitle: "Review launch scope",
            usageCosts: [1.8, 1.4]
        )

        let snapshot = makeLayer(dataStore: store).snapshot

        XCTAssertEqual(snapshot.mission.state, .partial)
        XCTAssertNotEqual(snapshot.mission.state, .blocked)
        XCTAssertTrue(snapshot.mission.recommendationSummary.contains("unfinished") || snapshot.mission.recommendationSummary.contains("open"))
    }

    @MainActor
    func testMissionMarksCompletedWhenSummarizedWorkCoolsOff() throws {
        let store = try makeInMemoryStore()
        let now = Date()
        try seedProject(
            store: store,
            project: "Apollo",
            conversationDates: [
                now.addingTimeInterval(-40 * 3_600),
                now.addingTimeInterval(-30 * 3_600),
                now.addingTimeInterval(-20 * 3_600),
                now.addingTimeInterval(-10 * 3_600),
                now.addingTimeInterval(-5 * 3_600),
            ],
            latestMessage: "Approval sheet shipped and wrapped.",
            latestSummary: "Approval sheet rollout is wrapped and the dashboard copy is stable.",
            latestSummaryTitle: "Ship the approval sheet",
            usageCosts: [2.2, 1.1]
        )

        let snapshot = makeLayer(dataStore: store).snapshot

        XCTAssertEqual(snapshot.mission.state, .completed)
        XCTAssertTrue(snapshot.mission.recommendationSummary.contains("Ship the approval sheet"))
        XCTAssertTrue(snapshot.mission.subtitle.contains("$"))
    }

    @MainActor
    func testDirectionReturnsNotEnoughSignalBelowFiveProjectConversations() throws {
        let store = try makeInMemoryStore()
        let now = Date()
        try seedProject(
            store: store,
            project: "Apollo",
            conversationDates: stride(from: 3, through: 0, by: -1).map { now.addingTimeInterval(Double(-$0) * 1_800) },
            latestMessage: "Continue tightening the approval sheet copy.",
            latestSummary: "Apollo is still iterating on the approval sheet.",
            latestSummaryTitle: "Tighten approval sheet",
            usageCosts: [1.2]
        )
        try seedProject(
            store: store,
            project: "Zephyr",
            conversationDates: [
                now.addingTimeInterval(-7 * 24 * 3_600),
                now.addingTimeInterval(-6 * 24 * 3_600),
                now.addingTimeInterval(-5 * 24 * 3_600),
                now.addingTimeInterval(-4 * 24 * 3_600),
                now.addingTimeInterval(-3 * 24 * 3_600),
            ],
            latestMessage: "Zephyr is burning harder, but Apollo is still the active focus under test.",
            latestSummary: "Zephyr remains noisy background work.",
            latestSummaryTitle: "Keep Zephyr in the background",
            usageCosts: [0.2]
        )

        let snapshot = makeLayer(dataStore: store).snapshot

        XCTAssertEqual(snapshot.direction.status, .notEnoughSignal)
        XCTAssertEqual(snapshot.direction.availability, .sparse)
        XCTAssertTrue(snapshot.direction.sparseReason?.contains("Only 4 indexed conversation") == true)
        XCTAssertTrue(snapshot.direction.sparseReason?.contains("Apollo") == true)
    }

    @MainActor
    func testDirectionMarksAlignedWhenRecentSignalStaysFocused() throws {
        let store = try makeInMemoryStore()
        let now = Date()
        try seedProject(
            store: store,
            project: "Apollo",
            conversationDates: stride(from: 4, through: 0, by: -1).map { now.addingTimeInterval(Double(-$0) * 2_400) },
            latestMessage: "Approval sheet pass is stable and ready to ship.",
            latestSummary: "Approval sheet rollout is stable, QA passed, and launch coordination is the only remaining step.",
            latestSummaryTitle: "Ship approval sheet",
            usageCosts: [2.4, 1.8, 1.1]
        )

        let snapshot = makeLayer(dataStore: store).snapshot

        XCTAssertEqual(snapshot.direction.status, .aligned)
        XCTAssertTrue(snapshot.direction.summary.contains("Ship approval sheet"))
    }

    @MainActor
    func testDirectionMarksDriftingWhenOpenWorkHasGoneCold() throws {
        let store = try makeInMemoryStore()
        let now = Date()
        try seedProject(
            store: store,
            project: "Apollo",
            conversationDates: [
                now.addingTimeInterval(-72 * 3_600),
                now.addingTimeInterval(-60 * 3_600),
                now.addingTimeInterval(-48 * 3_600),
                now.addingTimeInterval(-36 * 3_600),
                now.addingTimeInterval(-30 * 3_600),
            ],
            latestMessage: "The release notes say the migration is blocked. Should we keep the current launch scope?",
            latestSummary: nil,
            latestSummaryTitle: nil,
            usageCosts: [0.4]
        )

        let snapshot = makeLayer(dataStore: store).snapshot

        XCTAssertEqual(snapshot.direction.status, .drifting)
    }

    @MainActor
    func testSecondaryProjectNeedsRecentCompetingBurnBeforeDirectionBecomesAmbiguous() throws {
        let store = try makeInMemoryStore()
        let now = Date()

        try seedProject(
            store: store,
            project: "Apollo",
            conversationDates: stride(from: 4, through: 0, by: -1).map { now.addingTimeInterval(Double(-$0) * 2_400) },
            latestMessage: "Approval sheet pass is ready for review.",
            latestSummary: "Apollo remains focused on the approval sheet release.",
            latestSummaryTitle: "Ship approval sheet",
            usageCosts: [2.4, 1.8, 1.1]
        )
        try seedProject(
            store: store,
            project: "Zephyr",
            conversationDates: [
                now.addingTimeInterval(-4 * 24 * 3_600),
                now.addingTimeInterval(-3 * 24 * 3_600),
                now.addingTimeInterval(-2 * 24 * 3_600),
                now.addingTimeInterval(-36 * 3_600),
            ],
            latestMessage: "Older cleanup pass is archived.",
            latestSummary: "Zephyr cleanup is archived.",
            latestSummaryTitle: "Archive cleanup",
            usageCosts: [0.2]
        )

        var snapshot = makeLayer(dataStore: store).snapshot
        XCTAssertNil(snapshot.secondaryProjectName)
        XCTAssertNotEqual(snapshot.direction.status, .ambiguous)

        try seedProject(
            store: store,
            project: "Zephyr",
            conversationDates: [
                now.addingTimeInterval(-4 * 24 * 3_600),
                now.addingTimeInterval(-3 * 24 * 3_600),
                now.addingTimeInterval(-2 * 24 * 3_600),
                now.addingTimeInterval(-45 * 60),
                now.addingTimeInterval(-15 * 60),
            ],
            latestMessage: "Zephyr is actively pulling burn away from Apollo.",
            latestSummary: "Zephyr work resumed and is consuming fresh budget.",
            latestSummaryTitle: "Resume Zephyr push",
            usageCosts: [2.4, 2.1]
        )

        snapshot = makeLayer(dataStore: store).snapshot
        XCTAssertEqual(snapshot.secondaryProjectName, "Zephyr")
        XCTAssertEqual(snapshot.direction.status, .ambiguous)
        XCTAssertTrue(snapshot.direction.summary.contains("Zephyr"))
    }

    @MainActor
    func testMissionBlocksOnProjectionFailure() throws {
        let store = try makeInMemoryStore()
        let now = Date()
        try seedProject(
            store: store,
            project: "Apollo",
            conversationDates: stride(from: 4, through: 0, by: -1).map { now.addingTimeInterval(Double(-$0) * 2_700) },
            latestMessage: "Ship the approval sheet after QA.",
            latestSummary: "Approval sheet is stable, QA passed, and only launch coordination remains before release.",
            latestSummaryTitle: "Ship the approval sheet",
            usageCosts: [2.0, 1.6]
        )
        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .projection,
                status: .failed,
                errorCode: "projection_failed",
                errorMessage: "Projection sweep failed for Apollo."
            )
        )

        let snapshot = makeLayer(dataStore: store).snapshot

        XCTAssertEqual(snapshot.mission.state, .blocked)
        XCTAssertEqual(snapshot.mission.recommendationSummary, "Projection sweep failed for Apollo.")
    }

    @MainActor
    func testDirectionOverrideWinsEvenWhenSignalIsSparse() throws {
        let store = try makeInMemoryStore()
        let now = Date()
        try seedProject(
            store: store,
            project: "Apollo",
            conversationDates: stride(from: 3, through: 0, by: -1).map { now.addingTimeInterval(Double(-$0) * 1_800) },
            latestMessage: "Continue tightening the approval sheet copy.",
            latestSummary: "Apollo is still iterating on the approval sheet.",
            latestSummaryTitle: "Tighten approval sheet",
            usageCosts: [1.2]
        )

        let layer = makeLayer(dataStore: store)
        layer.saveDirectionOverride(
            mode: .supersedeStatus,
            forcedStatus: .aligned,
            summary: "Stay on the approval sheet release path.",
            rationale: "Operator confirmed Apollo is still the intended priority."
        )

        let snapshot = layer.snapshot

        XCTAssertEqual(snapshot.direction.status, .aligned)
        XCTAssertEqual(snapshot.direction.mode, .overrideSuperseding)
        XCTAssertEqual(snapshot.direction.summary, "Stay on the approval sheet release path.")
    }

    @MainActor
    func testMissionFingerprintStaysStableAcrossReindexTimestampChurn() throws {
        let store = try makeInMemoryStore()
        let now = Date()
        try seedProject(
            store: store,
            project: "Apollo",
            conversationDates: stride(from: 4, through: 0, by: -1).map { now.addingTimeInterval(Double(-$0) * 2_700) },
            latestMessage: "Ship the approval sheet after QA.",
            latestSummary: "Approval sheet is stable, QA passed, and only launch coordination remains before release.",
            latestSummaryTitle: "Ship the approval sheet",
            usageCosts: [2.0, 1.6]
        )

        let initialLayer = makeLayer(dataStore: store)
        let initialMissionID = initialLayer.snapshot.mission.missionID
        initialLayer.approveMission(note: "Carry this forward.")

        let updatedConversation = ConversationRecord(
            id: "Codex:apollo-4",
            provider: .codex,
            sessionId: "apollo-4",
            projectName: "Apollo",
            startTime: now.addingTimeInterval(-20 * 60),
            endTime: now.addingTimeInterval(-10 * 60),
            messageCount: 24,
            userWordCount: 120,
            assistantWordCount: 240,
            keyFiles: [],
            keyCommands: ["xcodebuild test"],
            keyTools: ["Read", "Edit"],
            inferredTaskTitle: "Ship the approval sheet",
            lastAssistantMessage: "Ship the approval sheet after QA with a slightly different tail for timestamp churn.",
            fullText: "Ship the approval sheet after QA with a slightly different tail for timestamp churn.",
            indexedAt: now.addingTimeInterval(15 * 60),
            fileModifiedAt: now.addingTimeInterval(15 * 60),
            summary: "Approval sheet is stable, QA passed, and only launch coordination remains before release with refreshed timestamps.",
            summaryTitle: "Ship the approval sheet",
            summaryUpdatedAt: now.addingTimeInterval(20 * 60),
            summaryProvider: "openrouter",
            summaryModel: "gpt-5"
        )
        try store.upsertConversation(updatedConversation)

        let refreshedSnapshot = makeLayer(dataStore: store).snapshot

        XCTAssertEqual(refreshedSnapshot.mission.missionID, initialMissionID)
        XCTAssertEqual(refreshedSnapshot.mission.approval, .approved)
    }

    @MainActor
    private func makeLayer(dataStore: DataStore) -> OpenBurnBarOperatingLayer {
        SettingsManager.shared.conversationIndexingEnabled = true
        let controller = ChatSessionController(dataStore: dataStore, settingsManager: .shared)
        return OpenBurnBarOperatingLayer(
            dataStore: dataStore,
            settingsManager: .shared,
            accountManager: .shared,
            chatController: controller
        )
    }

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func seedProject(
        store: DataStore,
        project: String,
        conversationDates: [Date],
        latestMessage: String,
        latestSummary: String?,
        latestSummaryTitle: String?,
        usageCosts: [Double]
    ) throws {
        let sortedDates = conversationDates.sorted()
        for (index, date) in sortedDates.enumerated() {
            let isLatest = index == sortedDates.count - 1
            let sessionID = "\(project.lowercased())-\(index)"
            let summaryTitle = isLatest ? latestSummaryTitle : "\(project) checkpoint \(index)"
            let summary = isLatest ? latestSummary : "\(project) checkpoint \(index) is summarized."
            let message = isLatest ? latestMessage : "\(project) checkpoint \(index) is still on track."
            try store.upsertConversation(
                ConversationRecord(
                    id: "\(AgentProvider.codex.rawValue):\(sessionID)",
                    provider: .codex,
                    sessionId: sessionID,
                    projectName: project,
                    startTime: date.addingTimeInterval(-900),
                    endTime: date,
                    messageCount: 14 + index,
                    userWordCount: 90,
                    assistantWordCount: 180,
                    keyFiles: [],
                    keyCommands: [],
                    keyTools: ["Read"],
                    inferredTaskTitle: summaryTitle ?? "\(project) checkpoint \(index)",
                    lastAssistantMessage: message,
                    fullText: message,
                    indexedAt: date.addingTimeInterval(120),
                    fileModifiedAt: date.addingTimeInterval(120),
                    summary: summary,
                    summaryTitle: summaryTitle,
                    summaryUpdatedAt: date.addingTimeInterval(180),
                    summaryProvider: "openrouter",
                    summaryModel: "gpt-5"
                )
            )
        }

        let usages = usageCosts.enumerated().map { index, cost in
            TokenUsage(
                provider: .factory,
                sessionId: "\(project.lowercased())-usage-\(index)",
                projectName: project,
                model: "gpt-5",
                inputTokens: 10_000 + (index * 500),
                outputTokens: 3_000 + (index * 250),
                costUSD: cost,
                startTime: sortedDates[max(sortedDates.count - 1 - min(index, sortedDates.count - 1), 0)].addingTimeInterval(-600),
                endTime: sortedDates[max(sortedDates.count - 1 - min(index, sortedDates.count - 1), 0)]
            )
        }

        let preserved = store.usages.filter { $0.projectName != project }
        store.replaceUsages(preserved + usages)
    }
}

// MARK: - Mission Authoring Tests

extension OpenBurnBarOperatingComposerTests {
    @MainActor
    func testMissionAuthoringValidationFailsWithEmptyProjectSlug() async throws {
        let store = try makeInMemoryStore()
        let layer = makeLayer(dataStore: store)

        do {
            _ = try await layer.createMission(
                projectSlug: "",
                title: "Ship the approval sheet",
                summary: "OpenBurnBar should wrap up the approval sheet release.",
                recommendation: .review
            )
            XCTFail("Expected validation error for empty projectSlug")
        } catch {
            XCTAssertTrue(error is MissionAuthoringError)
            if case .validationFailed(let message) = error as? MissionAuthoringError {
                XCTAssertTrue(message.contains("Project identifier"))
            }
        }

        XCTAssertNotNil(layer.actionFeedback)
        XCTAssertEqual(layer.actionFeedback?.kind, .missionCreation)
        XCTAssertEqual(layer.actionFeedback?.tone, .error)
    }

    @MainActor
    func testMissionAuthoringValidationFailsWithWhitespaceProjectSlug() async throws {
        let store = try makeInMemoryStore()
        let layer = makeLayer(dataStore: store)

        do {
            _ = try await layer.createMission(
                projectSlug: "   ",
                title: "Ship the approval sheet",
                summary: "OpenBurnBar should wrap up the approval sheet release.",
                recommendation: .review
            )
            XCTFail("Expected validation error for whitespace projectSlug")
        } catch {
            XCTAssertTrue(error is MissionAuthoringError)
        }

        XCTAssertNotNil(layer.actionFeedback)
        XCTAssertEqual(layer.actionFeedback?.tone, .error)
    }

    @MainActor
    func testMissionAuthoringValidationFailsWithEmptyTitle() async throws {
        let store = try makeInMemoryStore()
        let layer = makeLayer(dataStore: store)

        do {
            _ = try await layer.createMission(
                projectSlug: "apollo",
                title: "",
                summary: "OpenBurnBar should wrap up the approval sheet release.",
                recommendation: .review
            )
            XCTFail("Expected validation error for empty title")
        } catch {
            XCTAssertTrue(error is MissionAuthoringError)
            if case .validationFailed(let message) = error as? MissionAuthoringError {
                XCTAssertTrue(message.contains("title"))
            }
        }

        XCTAssertNotNil(layer.actionFeedback)
        XCTAssertEqual(layer.actionFeedback?.tone, .error)
    }

    @MainActor
    func testMissionAuthoringValidationFailsWithEmptySummary() async throws {
        let store = try makeInMemoryStore()
        let layer = makeLayer(dataStore: store)

        do {
            _ = try await layer.createMission(
                projectSlug: "apollo",
                title: "Ship the approval sheet",
                summary: "",
                recommendation: .review
            )
            XCTFail("Expected validation error for empty summary")
        } catch {
            XCTAssertTrue(error is MissionAuthoringError)
            if case .validationFailed(let message) = error as? MissionAuthoringError {
                XCTAssertTrue(message.contains("summary"))
            }
        }

        XCTAssertNotNil(layer.actionFeedback)
        XCTAssertEqual(layer.actionFeedback?.tone, .error)
    }

    @MainActor
    func testMissionAuthoringValidationFailsWithWhitespaceSummary() async throws {
        let store = try makeInMemoryStore()
        let layer = makeLayer(dataStore: store)

        do {
            _ = try await layer.createMission(
                projectSlug: "apollo",
                title: "Ship the approval sheet",
                summary: "   ",
                recommendation: .review
            )
            XCTFail("Expected validation error for whitespace summary")
        } catch {
            XCTAssertTrue(error is MissionAuthoringError)
        }

        XCTAssertNotNil(layer.actionFeedback)
        XCTAssertEqual(layer.actionFeedback?.tone, .error)
    }

    @MainActor
    func testMissionAuthoringValidationAcceptsAllRecommendationKinds() async throws {
        let store = try makeInMemoryStore()
        let layer = makeLayer(dataStore: store)

        // Test that all recommendation kinds are accepted by validation (they don't cause validation failure)
        // The daemon call would fail since there's no real daemon, but validation should pass
        for recommendation in [BurnBarMissionRecommendation.proceed, .review, .pause] {
            do {
                _ = try await layer.createMission(
                    projectSlug: "apollo-\(recommendation.rawValue)",
                    title: "Mission with \(recommendation.rawValue) recommendation",
                    summary: "Testing \(recommendation.rawValue) recommendation.",
                    recommendation: recommendation
                )
                XCTFail("Expected daemon error (not validation error) for valid inputs with missing daemon")
            } catch let error as MissionAuthoringError {
                // Validation passed but daemon call failed
                if case .daemonError = error {
                    // Expected - daemon is not running in tests
                } else {
                    XCTFail("Expected daemonError, got \(error)")
                }
            } catch {
                // Other errors are also acceptable since daemon is not running
            }
        }
    }

    @MainActor
    func testMissionAuthoringActionKindIsAvailableInActionBar() throws {
        let store = try makeInMemoryStore()
        let layer = makeLayer(dataStore: store)

        // Verify missionCreation action kind exists and has proper display properties
        XCTAssertEqual(OpenBurnBarActionKind.missionCreation.label, "Create Mission")
        XCTAssertEqual(OpenBurnBarActionKind.missionCreation.icon, "flag.badge.ellipsis")

        // Verify history entry tint for missionCreation
        let historyEntry = OpenBurnBarOperatingHistoryEntry(
            id: "test-1",
            kind: .missionCreation,
            title: "Create Mission",
            summary: "Mission created",
            detail: nil,
            createdAt: Date()
        )
        XCTAssertEqual(historyEntry.tint, DesignSystem.Colors.hermesAureate)
    }
}
