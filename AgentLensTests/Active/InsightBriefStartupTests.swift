import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
@MainActor
final class InsightBriefStartupTests: XCTestCase {

    func test_insightsFollowUp_keepsVisibleLocalRulesSelectionLocal() {
        let selected = InsightModelTag(
            providerKey: "local-rules",
            modelID: "local-rules-v1",
            displayName: "Local rules",
            egressTier: .localOnly
        )

        let resolved = InsightsMacEnvironment.resolvedAnalysisModel(
            selectedModelTag: selected,
            modelCatalog: [
                InsightCatalogModel(
                    id: "hermes-auto",
                    displayName: "Hermes",
                    providerKey: "hermes",
                    egressTier: .userRelay,
                    capabilities: .init()
                ),
                InsightCatalogModel(
                    id: "hosted-answer",
                    displayName: "Hosted",
                    providerKey: "burnbar-hosted",
                    egressTier: .hosted,
                    capabilities: .init()
                )
            ],
            privacyMode: false,
            instruction: .answerFollowUp
        )

        XCTAssertEqual(resolved.providerKey, "local-rules")
        XCTAssertEqual(resolved.egressTier, .localOnly)
    }

    func test_insightsFollowUp_preservesExplicitNonLocalSelection() {
        let selected = InsightModelTag(
            providerKey: "hermes",
            modelID: "hermes-auto",
            displayName: "Hermes",
            egressTier: .userRelay
        )

        let resolved = InsightsMacEnvironment.resolvedAnalysisModel(
            selectedModelTag: selected,
            modelCatalog: [
                InsightCatalogModel(
                    id: "local-rules-v1",
                    displayName: "Local rules",
                    providerKey: "local-rules",
                    egressTier: .localOnly,
                    capabilities: .init()
                )
            ],
            privacyMode: false,
            instruction: .answerFollowUp
        )

        XCTAssertEqual(resolved.providerKey, "hermes")
        XCTAssertEqual(resolved.egressTier, .userRelay)
    }

    func test_persistedLocalRulesPreferenceIsExplicitAfterUserSelection() {
        let selected = InsightModelTag(
            providerKey: "local-rules",
            modelID: "local-rules-v1",
            displayName: "Local rules",
            egressTier: .localOnly
        )

        let preference = InsightsMacEnvironment.persistedModelPreference(
            selectedModelTag: selected,
            privacyMode: false
        )

        XCTAssertEqual(preference.mode, .explicit)
        XCTAssertEqual(preference.explicitModel?.providerKey, "local-rules")
        XCTAssertEqual(preference.explicitModel?.egressTier, .localOnly)
    }

    func test_automaticModelSelectionStillPersistsAsAutomatic() {
        let selected = InsightModelTag(
            providerKey: "local-rules",
            modelID: "local-rules-v1",
            displayName: "Local rules",
            egressTier: .localOnly
        )

        let preference = InsightsMacEnvironment.persistedModelPreference(
            selectedModelTag: selected,
            privacyMode: false,
            automaticSelection: true
        )

        XCTAssertEqual(preference.mode, .automatic)
        XCTAssertEqual(preference.explicitModel?.providerKey, "local-rules")
        XCTAssertEqual(preference.explicitModel?.egressTier, .localOnly)
    }

    func test_fetchSessionLogSummaries_omitsTranscriptBodies() async throws {
        let store = try makeInMemoryStore()
        try await store.upsertConversation(
            makeConversation(
                id: "Factory:brief-summary",
                title: "Auth refactor",
                lastAssistantMessage: "Ship the auth patch after QA.",
                fullText: String(repeating: "Large transcript block. ", count: 2_000)
            )
        )

        let summaries = try await store.fetchSessionLogSummaries(limit: 10)

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].inferredTaskTitle, "Auth refactor")
        XCTAssertEqual(summaries[0].lastAssistantMessage, "Ship the auth patch after QA.")
        XCTAssertEqual(summaries[0].fullText, "")
    }

    func test_build_usesConversationSummaryMetadataForBrief() async throws {
        let store = try makeInMemoryStore()
        let now = Date()
        try await store.upsertConversation(
            makeConversation(
                id: "Factory:latest",
                sessionId: "session-latest",
                projectName: "OpenBurnBar",
                startTime: now.addingTimeInterval(-60),
                endTime: now,
                title: "Auth refactor",
                lastAssistantMessage: "Ship the auth patch after QA.",
                fullText: String(repeating: "Large transcript block. ", count: 2_000)
            )
        )
        store.replaceUsages([
            TokenUsage(
                provider: .factory,
                sessionId: "session-latest",
                projectName: "OpenBurnBar",
                model: "gpt-5.4-mini",
                inputTokens: 120,
                outputTokens: 40,
                costUSD: 3.25,
                startTime: now.addingTimeInterval(-120),
                endTime: now.addingTimeInterval(-30)
            )
        ])

        let snapshot = await InsightBriefSnapshot.buildAsync(from: store, refreshRollups: false)

        XCTAssertEqual(snapshot.whereLeftOff, "Ship the auth patch after QA.")
        XCTAssertEqual(snapshot.whereLeftOffProject, "OpenBurnBar")
        XCTAssertEqual(snapshot.heaviestTaskTitle, "Auth refactor")
        XCTAssertEqual(snapshot.heaviestTaskProject, "OpenBurnBar")
        XCTAssertEqual(snapshot.heaviestTaskCost ?? -1, 3.25, accuracy: 0.0001)
    }

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeConversation(
        id: String,
        sessionId: String = "session-1",
        projectName: String = "OpenBurnBar",
        startTime: Date = Date(timeIntervalSince1970: 1_700_000_000),
        endTime: Date = Date(timeIntervalSince1970: 1_700_000_060),
        title: String,
        lastAssistantMessage: String,
        fullText: String
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: .factory,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
            messageCount: 2,
            userWordCount: 4,
            assistantWordCount: 5,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: title,
            lastAssistantMessage: lastAssistantMessage,
            fullText: fullText,
            indexedAt: endTime,
            fileModifiedAt: endTime,
            summary: nil
        )
    }
}
