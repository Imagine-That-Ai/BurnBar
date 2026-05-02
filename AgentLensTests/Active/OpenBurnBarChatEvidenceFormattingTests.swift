import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

private typealias AppAgentProvider = OpenBurnBar.AgentProvider
private typealias AppTokenUsage = OpenBurnBar.TokenUsage
private typealias AppUsageSource = OpenBurnBar.UsageSource
final class OpenBurnBarChatEvidenceFormattingTests: XCTestCase {

    func test_emptyResults_showsPlaceholder() throws {
        let s = OpenBurnBarChatEvidenceFormatting.formatPack(results: [], maxTotalChars: 2_000)
        XCTAssertTrue(s.contains("## Retrieved evidence"))
        XCTAssertTrue(s.contains("No matching indexed excerpts"))
    }

    func test_dedupesSecondChunkFromSameConversation() throws {
        let now = Date()
        let conv = ConversationRecord(
            id: "cursor:abc",
            provider: .cursor,
            sessionId: "abc",
            projectName: "P",
            startTime: now,
            endTime: now,
            messageCount: 1,
            userWordCount: 1,
            assistantWordCount: 1,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "T",
            lastAssistantMessage: "",
            fullText: "body",
            indexedAt: now,
            fileModifiedAt: now,
            sourceType: .providerLog
        )
        let r1 = RetrievalResult(
            chunkID: "ch1",
            documentID: "d1",
            sourceKind: .conversation,
            sourceID: "cursor:abc",
            provider: .cursor,
            providerRawValue: nil,
            projectName: "P",
            title: "T",
            subtitle: nil,
            snippet: "first",
            sectionPath: nil,
            startOffset: 0,
            endOffset: 10,
            sourceUpdatedAt: nil,
            indexedAt: now,
            lexicalRank: 1,
            semanticScore: nil,
            rerankScore: 0.9,
            conversation: conv
        )
        let r2 = RetrievalResult(
            chunkID: "ch2",
            documentID: "d1",
            sourceKind: .conversation,
            sourceID: "cursor:abc",
            provider: .cursor,
            providerRawValue: nil,
            projectName: "P",
            title: "T",
            subtitle: nil,
            snippet: "second",
            sectionPath: nil,
            startOffset: 10,
            endOffset: 20,
            sourceUpdatedAt: nil,
            indexedAt: now,
            lexicalRank: 2,
            semanticScore: nil,
            rerankScore: 0.8,
            conversation: conv
        )
        let s = OpenBurnBarChatEvidenceFormatting.formatPack(results: [r1, r2], maxTotalChars: 20_000)
        XCTAssertEqual(s.components(separatedBy: "chunk_id:").count - 1, 1)
        XCTAssertTrue(s.contains("`ch1`"))
        XCTAssertFalse(s.contains("`ch2`"))
    }

    func test_truncatesToMaxChars() throws {
        let now = Date()
        let longSnippet = String(repeating: "x", count: 500)
        var results: [RetrievalResult] = []
        for i in 0..<5 {
            results.append(
                RetrievalResult(
                    chunkID: "c\(i)",
                    documentID: "d\(i)",
                    sourceKind: .skillDoc,
                    sourceID: "s\(i)",
                    provider: nil,
                    providerRawValue: nil,
                    projectName: nil,
                    title: "Skill \(i)",
                    subtitle: nil,
                    snippet: longSnippet,
                    sectionPath: nil,
                    startOffset: 0,
                    endOffset: 1,
                    sourceUpdatedAt: nil,
                    indexedAt: now,
                    lexicalRank: nil,
                    semanticScore: nil,
                    rerankScore: Double(5 - i),
                    conversation: nil
                )
            )
        }
        let s = OpenBurnBarChatEvidenceFormatting.formatPack(results: results, maxTotalChars: 900)
        XCTAssertLessThanOrEqual(s.count, 1_200)
        XCTAssertTrue(s.contains("truncated") || s.contains("…"))
    }

    @MainActor
    func test_memorySyncBoundary_isExplicitlyLocalFirst() throws {
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let boundary = CloudSyncService(
            dataStore: store,
            accountManager: AccountManager.shared,
            settingsManager: SettingsManager()
        ).memorySyncBoundarySnapshot()

        XCTAssertEqual(boundary.mode, .localFirstOptionalCloud)
        XCTAssertEqual(boundary.canonicalAuthority, .localSQLite)
        XCTAssertTrue(boundary.notes.contains(where: { $0.contains("not the serving authority") }))
    }

    @MainActor
    func test_dataStoreLocalAuthoritySnapshot_reportsCountsAndControllerMirrorPresence() throws {
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        try store.insert(
            TokenUsage(
                provider: .factory,
                sessionId: "authority-1",
                projectName: "Apollo",
                model: "glm-5",
                inputTokens: 10,
                outputTokens: 12,
                costUSD: 0.12,
                startTime: Date(),
                endTime: Date()
            )
        )
        try store.saveControllerRuntimeMirror(OpenBurnBarControllerRuntimeSnapshot.empty)

        let snapshot = try store.localAuthoritySnapshot()

        XCTAssertEqual(snapshot.usageRowCount, 1)
        XCTAssertEqual(snapshot.conversationRowCount, 0)
        XCTAssertEqual(snapshot.sharedArtifactCount, 0)
        XCTAssertTrue(snapshot.controllerRuntimeCached)
    }
}
