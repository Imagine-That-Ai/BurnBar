import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class CredentialExposureScanTests: XCTestCase {

    private var store: DataStore!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cred-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: ":memory:")
        store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeConversation(
        id: String,
        fullText: String,
        provider: AgentProvider = .claudeCode,
        projectName: String = "test-project",
        startTime: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: provider,
            sessionId: id,
            projectName: projectName,
            startTime: startTime,
            endTime: startTime,
            messageCount: 1,
            userWordCount: 1,
            assistantWordCount: 1,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Test",
            lastAssistantMessage: "",
            fullText: fullText,
            indexedAt: Date(),
            workingDirectory: nil,
            fileModifiedAt: startTime,
            summary: nil
        )
    }

    // MARK: - Tests

    func test_credentialScan_findsOpenAIKey() async throws {
        let conv = makeConversation(
            id: "test-openai-key",
            fullText: "## You\nI set the API key to sk-abc123def456ghi789jkl012mno345pqr678\n## Assistant\nGot it."
        )
        try await store.upsertConversation(conv)

        let result = try await store.scanConversationFullTextForCredentialExposure(limit: 10)
        XCTAssertGreaterThan(result.totalMatches, 0, "Should find the OpenAI key")
        XCTAssertTrue(result.jumpTargets.contains { $0.conversation.id == "test-openai-key" })
    }

    func test_credentialScan_findsGitHubToken() async throws {
        let conv = makeConversation(
            id: "test-github-token",
            fullText: "## You\nMy GitHub token is ghp_1234567890abcdefghijklmnopqrstuvwxyz\n## Assistant\nOK."
        )
        try await store.upsertConversation(conv)

        let result = try await store.scanConversationFullTextForCredentialExposure(limit: 10)
        XCTAssertGreaterThan(result.totalMatches, 0, "Should find the GitHub token")
        XCTAssertTrue(result.jumpTargets.contains { $0.conversation.id == "test-github-token" })
    }

    func test_credentialScan_findsGoogleAPIKey() async throws {
        let conv = makeConversation(
            id: "test-google-key",
            fullText: "## You\nGoogle API key: AIzaSyA1234567890BCDEfghijklmnopqrstuv\n## Assistant\nNoted."
        )
        try await store.upsertConversation(conv)

        let result = try await store.scanConversationFullTextForCredentialExposure(limit: 10)
        XCTAssertGreaterThan(result.totalMatches, 0, "Should find the Google API key")
    }

    func test_credentialScan_findsGenericKeyAssignment() async throws {
        let conv = makeConversation(
            id: "test-generic-key",
            fullText: "## You\nSet API_KEY=abcdef1234567890abcdefghij\n## Assistant\nDone."
        )
        try await store.upsertConversation(conv)

        let result = try await store.scanConversationFullTextForCredentialExposure(limit: 10)
        XCTAssertGreaterThan(result.totalMatches, 0, "Should find the generic API_KEY assignment")
    }

    func test_credentialScan_skipsConversationsWithoutCredentials() async throws {
        // A conversation with no credential indicators should not appear.
        let conv = makeConversation(
            id: "test-no-creds",
            fullText: "## You\nCan you help me refactor the auth service?\n## Assistant\nSure, let me look at the code."
        )
        try await store.upsertConversation(conv)

        let result = try await store.scanConversationFullTextForCredentialExposure(limit: 10)
        // The pre-filter should skip this conversation entirely.
        XCTAssertEqual(result.totalMatches, 0, "Should not find credentials in a clean conversation")
    }

    func test_credentialScan_preFilterSkipsCleanConversations() async throws {
        // Insert conversations with and without credentials.
        let cleanConv = makeConversation(
            id: "clean-conv",
            fullText: "## You\nHelp me write a unit test for the parser.\n## Assistant\nHere is the test code."
        )
        let credConv = makeConversation(
            id: "cred-conv",
            fullText: "## You\nI need to set up the API key sk-abc123def456ghi789jkl012mno345\n## Assistant\nOK."
        )
        try await store.upsertConversation(cleanConv)
        try await store.upsertConversation(credConv)

        let result = try await store.scanConversationFullTextForCredentialExposure(limit: 10)
        // Should only find the credential conversation.
        XCTAssertGreaterThan(result.totalMatches, 0)
        XCTAssertTrue(result.jumpTargets.contains { $0.conversation.id == "cred-conv" })
        XCTAssertFalse(result.jumpTargets.contains { $0.conversation.id == "clean-conv" })
    }

    func test_credentialScan_filtersPlaceholderCredentials() async throws {
        let conv = makeConversation(
            id: "test-placeholder",
            fullText: "## You\nSet API_KEY=your-key-here-placeholder\n## Assistant\nDone."
        )
        try await store.upsertConversation(conv)

        let result = try await store.scanConversationFullTextForCredentialExposure(limit: 10)
        // Placeholder credentials should be filtered out by looksLikePlaceholderCredential.
        XCTAssertEqual(result.totalMatches, 0, "Should not match placeholder credentials")
    }

    func test_credentialScan_respectsLimit() async throws {
        // Insert multiple conversations with credentials.
        for i in 0..<5 {
            let conv = makeConversation(
                id: "cred-\(i)",
                fullText: "## You\nToken: sk-abc123def456ghi789jkl012mno\(i)\n## Assistant\nOK."
            )
            try await store.upsertConversation(conv)
        }

        let result = try await store.scanConversationFullTextForCredentialExposure(limit: 2)
        XCTAssertLessThanOrEqual(result.jumpTargets.count, 2, "Should respect the limit")
    }

    func test_credentialScan_findsPasswordAndTokenAssignments() async throws {
        // The pre-filter must catch generic key=value patterns, including
        // standalone PASSWORD and TOKEN assignments, to preserve recall.
        let passwordConv = makeConversation(
            id: "test-password",
            fullText: "## You\nSet PASSWORD=abcdef1234567890abcdefghij\n## Assistant\nDone."
        )
        let tokenConv = makeConversation(
            id: "test-token",
            fullText: "## You\nSet TOKEN=abcdef1234567890abcdefghij\n## Assistant\nDone."
        )
        try await store.upsertConversation(passwordConv)
        try await store.upsertConversation(tokenConv)

        let result = try await store.scanConversationFullTextForCredentialExposure(limit: 10)
        XCTAssertTrue(result.jumpTargets.contains { $0.conversation.id == "test-password" }, "Should find PASSWORD= assignment")
        XCTAssertTrue(result.jumpTargets.contains { $0.conversation.id == "test-token" }, "Should find TOKEN= assignment")
    }

    func test_credentialScan_preFilterFalsePositive_doesNotCountAsMatch() async throws {
        // A conversation containing a pre-filter keyword but no real credential
        // should pass the pre-filter, then be rejected by the precise regex.
        let conv = makeConversation(
            id: "test-false-positive",
            fullText: "## You\nI need to change my password. Can you help me reset it?\n## Assistant\nSure."
        )
        try await store.upsertConversation(conv)

        let result = try await store.scanConversationFullTextForCredentialExposure(limit: 10)
        XCTAssertEqual(result.totalMatches, 0, "Conversations with only credential-adjacent words should not be counted")
    }
}
