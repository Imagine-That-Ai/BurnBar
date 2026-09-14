import XCTest
import CryptoKit
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - PR-D1 LLM Extractor tests
//
// Proves the six PR-D1 must-fixes of the memory-activation build plan:
//   1. The WORKER (not the model) is the sole provenance authority: it recomputes
//      `content_hash` from the cited SOURCE MESSAGE body and stamps a v1 local
//      `xdevice_hmac`, ignoring whatever the extractor/model supplied.
//   2. `xdevice_hmac` is a v1 NON-CRYPTO, content-derived `v1-local:` tag (memory is
//      local-only), never the promptVersion-salted idempotency key.
//   3. `content_hash` binds the SOURCE message body, not the extracted memory body.
//   4. The G7 gate is a per-candidate DROP filter, not a batch-failing throw.
//   5. Total extractor wall-clock is strictly below the 15-min job lease.
//   6. (Local-only posture; cloud gates are exercised in the cost-cap test.)
//
// The whole feature stays OFF by default; these tests force the kill switches ON
// explicitly to exercise the dormant machinery.
@MainActor
final class MemoryExtractionExtractorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MemoryExtractionExtractorHTTPStub.reset()
        URLProtocol.registerClass(MemoryExtractionExtractorHTTPStub.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MemoryExtractionExtractorHTTPStub.self)
        MemoryExtractionExtractorHTTPStub.reset()
        super.tearDown()
    }

    // MARK: - Parser

    func test_parser_decodesStrictJSONAndValidatesCandidates() {
        let json = """
        {"memories":[
          {"text":"User prefers dark mode.","kind":"preference","confidence":0.9,"messageId":"m1"},
          {"text":"","kind":"fact","confidence":0.5,"messageId":"m2"},
          {"text":"User lives in Berlin.","kind":"profile","confidence":2.5,"messageId":"m3"}
        ]}
        """
        let candidates = MemoryExtractionParser.parse(json, maxCandidates: 10)
        // The empty-text candidate is dropped; the over-range confidence is clamped.
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].text, "User prefers dark mode.")
        XCTAssertEqual(candidates[0].kind, .preference)
        XCTAssertEqual(candidates[0].confidence, 0.9, accuracy: 0.0001)
        XCTAssertEqual(candidates[0].claimedMessageID, "m1")
        XCTAssertEqual(candidates[1].kind, .profile)
        XCTAssertEqual(candidates[1].confidence, 1.0, accuracy: 0.0001)
    }

    func test_parser_recoversJSONEmbeddedInProse() {
        let body = "Sure! Here is the JSON:\n{\"memories\":[{\"text\":\"Likes tea.\",\"messageId\":\"x\"}]}\nDone."
        let candidates = MemoryExtractionParser.parse(body, maxCandidates: 10)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].text, "Likes tea.")
        XCTAssertEqual(candidates[0].kind, .fact) // default when omitted
    }

    func test_parser_returnsEmptyForGarbageOrEmpty() {
        XCTAssertTrue(MemoryExtractionParser.parse("not json at all", maxCandidates: 10).isEmpty)
        XCTAssertTrue(MemoryExtractionParser.parse("", maxCandidates: 10).isEmpty)
        XCTAssertTrue(MemoryExtractionParser.parse("{\"memories\":[]}", maxCandidates: 10).isEmpty)
    }

    func test_parser_dropsStructurallyMalformedCandidatesWithoutDroppingSiblings() {
        let json = """
        {"memories":[
          {"text":"User prefers concise status updates.","kind":"preference","confidence":0.8,"messageId":"m1"},
          {"kind":"fact","confidence":0.9,"messageId":"missing-text"},
          {"text":123,"kind":"fact","confidence":0.9,"messageId":"wrong-type"},
          42,
          {"text":"User deploys on Fridays.","kind":"fact","confidence":0.7,"messageId":"m2"}
        ]}
        """
        let candidates = MemoryExtractionParser.parse(json, maxCandidates: 10)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].text, "User prefers concise status updates.")
        XCTAssertEqual(candidates[0].claimedMessageID, "m1")
        XCTAssertEqual(candidates[1].text, "User deploys on Fridays.")
        XCTAssertEqual(candidates[1].claimedMessageID, "m2")
    }

    func test_parser_respectsCandidateCap() {
        let json = """
        {"memories":[
          {"text":"a","messageId":"1"},{"text":"b","messageId":"2"},{"text":"c","messageId":"3"}
        ]}
        """
        XCTAssertEqual(MemoryExtractionParser.parse(json, maxCandidates: 2).count, 2)
        XCTAssertEqual(MemoryExtractionParser.parse(json, maxCandidates: 0).count, 0)
    }

    // MARK: - Prompt builder

    func test_promptBuilder_boundsTranscriptAndKeepsRecentLines() {
        let lines = (0 ..< 50).map { index in
            MemoryExtractionPromptBuilder.TranscriptLine(
                messageID: "m\(index)",
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                text: String(repeating: "x", count: 40)
            )
        }
        let rendered = MemoryExtractionPromptBuilder.renderTranscript(lines: lines, maxChars: 300)
        XCTAssertLessThanOrEqual(rendered.count, 300)
        // The newest line must survive truncation (extraction triggers on the terminal turn).
        XCTAssertTrue(rendered.contains("[m49]"))
        XCTAssertFalse(rendered.contains("[m0]"))
    }

    func test_promptBuilder_truncatesSingleOversizedRecentLine() {
        let lines = [
            MemoryExtractionPromptBuilder.TranscriptLine(
                messageID: "huge",
                role: "user",
                text: String(repeating: "x", count: 200)
            )
        ]
        let rendered = MemoryExtractionPromptBuilder.renderTranscript(lines: lines, maxChars: 80)
        XCTAssertLessThanOrEqual(rendered.count, 80)
        XCTAssertTrue(rendered.hasPrefix("[huge] user: "))
    }

    func test_promptBuilder_embedsUntrustedFenceAndNoFabricateRule() {
        let lines = [
            MemoryExtractionPromptBuilder.TranscriptLine(messageID: "m1", role: "user", text: "Hi")
        ]
        let prompt = MemoryExtractionPromptBuilder.buildPrompt(lines: lines, maxChars: 4_000)
        XCTAssertTrue(prompt.contains("BEGIN TRANSCRIPT"))
        XCTAssertTrue(prompt.contains("END TRANSCRIPT"))
        XCTAssertTrue(prompt.contains("UNTRUSTED"))
        XCTAssertTrue(prompt.contains("Do not invent ids"))
        XCTAssertTrue(prompt.contains("[m1] user: Hi"))
    }

    // MARK: - Wall-clock deadline (must-fix #5)

    func test_deadline_isStrictlyBelowJobLease() {
        XCTAssertLessThan(
            ChatTranscriptExtractor.maxWallClock,
            ControlPlaneStore.MemoryExtractionJob.defaultLeaseDuration
        )
    }

    func test_deadline_returnsFastResultAndThrowsOnTimeout() async throws {
        let fast = try await withThrowingDeadline(seconds: 5) { 42 }
        XCTAssertEqual(fast, 42)

        do {
            _ = try await withThrowingDeadline(seconds: 0.05) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 0
            }
            XCTFail("Expected deadline to fire")
        } catch let error as MemoryExtractionDeadlineError {
            XCTAssertEqual(error.seconds, 0.05, accuracy: 0.0001)
        }
    }

    // MARK: - Worker provenance recomputation (must-fix #1/#3)

    func test_worker_recomputesProvenanceFromSourceMessageIgnoringModelSuppliedHashes() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_100_000)

        let threadID = "thread-prov"
        let sourceID = "msg-source-1"
        let sourceBody = "I always deploy on Fridays."
        try await insertChatMessage(queue, threadID: threadID, id: sourceID, role: "assistant", body: sourceBody, at: now)

        let intent = ExtractionIntent(
            threadID: threadID,
            threadLogicalID: "thread-logical-prov",
            messageID: sourceID,
            scope: MemoryScope(appID: "openburnbar"),
            promptVersion: "memory-extract-v1",
            idempotencyKey: "prov-idem"
        )
        let jobID = try await store.enqueueMemoryExtraction(intent, now: now)

        // The extractor (stand-in) supplies a citation with DELIBERATELY WRONG hashes —
        // the worker must ignore them and recompute from the source message body.
        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now },
            authorityWritesEnabled: { true },
            extractor: { job in
                [
                    MemoryAddRequest(
                        text: "User deploys on Fridays.",
                        kind: .preference,
                        scope: job.scope,
                        confidence: 0.8,
                        citations: [
                            MemoryCitation(
                                id: "model-supplied-id",
                                threadLogicalID: "model-supplied-logical",
                                messageID: sourceID,
                                role: "user", // wrong; source row is assistant
                                authoredAt: Date(timeIntervalSince1970: 0),
                                contentHash: "MODEL-FORGED-HASH",
                                crossDeviceHMAC: "MODEL-FORGED-HMAC",
                                citationState: .live
                            )
                        ],
                        reviewStatus: .approved
                    )
                ]
            }
        )

        let _v0 = try await worker.drainOne()
        XCTAssertTrue(_v0)

        let row = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT content_hash, xdevice_hmac, role, thread_logical_id, message_id
                FROM memory_provenance WHERE memory_id = ?
                """,
                arguments: ["memory-\(jobID)-0"]
            )
        }
        let expectedHash = SHA256.hash(data: Data(sourceBody.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(row?["content_hash"] as? String, expectedHash)
        XCTAssertNotEqual(row?["content_hash"] as? String, "MODEL-FORGED-HASH")
        XCTAssertTrue((row?["xdevice_hmac"] as? String ?? "").hasPrefix("v1-local:"))
        XCTAssertNotEqual(row?["xdevice_hmac"] as? String, "MODEL-FORGED-HMAC")
        // Role + logical id come from the authoritative source/job, not the model.
        XCTAssertEqual(row?["role"] as? String, "assistant")
        XCTAssertEqual(row?["thread_logical_id"] as? String, "thread-logical-prov")
    }

    func test_worker_dropsFactWhenMessageIdNotInTranscript() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_100_100)

        let intent = ExtractionIntent(
            threadID: "thread-missing",
            threadLogicalID: "thread-logical-missing",
            messageID: "ghost",
            scope: MemoryScope(appID: "openburnbar"),
            promptVersion: "memory-extract-v1",
            idempotencyKey: "missing-idem"
        )
        let jobID = try await store.enqueueMemoryExtraction(intent, now: now)

        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now },
            authorityWritesEnabled: { true },
            extractor: { job in
                [
                    MemoryAddRequest(
                        text: "Fact with an unresolvable citation.",
                        scope: job.scope,
                        citations: [
                            MemoryCitation(
                                id: "c",
                                threadLogicalID: "tl",
                                messageID: "does-not-exist",
                                role: "assistant",
                                authoredAt: now,
                                contentHash: "x",
                                crossDeviceHMAC: "y"
                            )
                        ]
                    )
                ]
            }
        )

        let _v1 = try await worker.drainOne()
        XCTAssertTrue(_v1)
        let provenanceCount = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memory_provenance WHERE memory_id = ?",
                arguments: ["memory-\(jobID)-0"]
            ) ?? -1
        }
        XCTAssertEqual(provenanceCount, 0)
        let factCount = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agent_memories WHERE id = ?",
                arguments: ["memory-\(jobID)-0"]
            ) ?? -1
        }
        XCTAssertEqual(factCount, 0, "unsupported facts are dropped instead of becoming recallable without provenance")
    }

    // MARK: - End-to-end extractor closure with a stubbed local HTTP model

    func test_extractor_endToEndThreadsResolvedCitationAndDefersSecretDropToWorker() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_100_200)

        let threadID = "thread-e2e"
        let sourceID = "msg-e2e-1"
        try await insertChatMessage(
            queue,
            threadID: threadID,
            id: sourceID,
            role: "user",
            body: "Remember I prefer Swift over Python.",
            at: now
        )

        // Stub the OpenAI-compatible endpoint to return one safe + one secret candidate.
        MemoryExtractionExtractorHTTPStub.responseJSON = """
        {"memories":[
          {"text":"User prefers Swift over Python.","kind":"preference","confidence":0.9,"messageId":"\(sourceID)"},
          {"text":"key sk-ant-deadbeefdeadbeefdeadbeef0001","kind":"fact","confidence":0.9,"messageId":"\(sourceID)"}
        ]}
        """

        let settings = MemoryExtractionSettingsSnapshot(
            providerOrder: [.mlx], // OpenAI-compatible path; the stub answers /chat/completions
            localBaseURL: "http://127.0.0.1:11434",
            localModel: "",
            mlxBaseURL: "http://127.0.0.1:9999",
            mlxModel: "test-model",
            minimaxModel: "",
            openRouterPrimaryModel: "",
            openRouterFallbackModel: "",
            zaiModel: "",
            ollamaBaseURL: "",
            ollamaModel: "",
            requestTimeoutSeconds: 5,
            maxPromptChars: 4_000,
            maxOutputTokens: 256,
            dailyCapUSD: 100,
            retryCount: 0,
            maxCandidatesPerJob: 8,
            promptVersion: "memory-extract-v1"
        )
        let extractor = ChatTranscriptExtractor(
            transcriptReader: store,
            spendReader: ZeroSpendReader(),
            keyResolver: MemoryExtractionAPIKeyResolver(providerAPIKeyStore: ProviderAPIKeyStore()),
            settingsProvider: { settings }
        )

        let job = ControlPlaneStore.MemoryExtractionJob(
            id: "memory-extraction-e2e",
            idempotencyKey: "e2e-idem",
            threadID: threadID,
            threadLogicalID: "thread-logical-e2e",
            messageID: sourceID,
            promptVersion: "memory-extract-v1",
            scope: MemoryScope(appID: "openburnbar"),
            status: .running,
            attempts: 1,
            lastError: nil,
            notBefore: nil,
            leaseExpiresAt: now.addingTimeInterval(900),
            createdAt: now,
            updatedAt: now
        )

        let requests = try await extractor.extract(job)
        // Secret candidate DROP/audit is owned by the worker; the extractor only
        // validates provenance and maps model output into requests.
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].text, "User prefers Swift over Python.")
        XCTAssertEqual(requests[0].kind, .preference)
        // The claimed (and transcript-present) message id is threaded through for the
        // worker to recompute provenance against; hashes are placeholders here.
        XCTAssertEqual(requests[0].citations.count, 1)
        XCTAssertEqual(requests[0].citations[0].messageID, sourceID)
        XCTAssertTrue(MemoryExtractionExtractorHTTPStub.requestCount >= 1)
    }

    func test_extractorRefusesNonLoopbackLocalEndpointBeforeTranscriptEgress() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_100_250)

        let threadID = "thread-remote-url"
        let sourceID = "msg-remote-url-1"
        try await insertChatMessage(
            queue,
            threadID: threadID,
            id: sourceID,
            role: "user",
            body: "Remember my passport number is not for remote models.",
            at: now
        )
        MemoryExtractionExtractorHTTPStub.responseJSON = """
        {"memories":[{"text":"This must not be reached.","kind":"fact","confidence":0.9,"messageId":"\(sourceID)"}]}
        """

        let settings = MemoryExtractionSettingsSnapshot(
            providerOrder: [.mlx],
            localBaseURL: "http://127.0.0.1:11434",
            localModel: "",
            mlxBaseURL: "https://remote.example",
            mlxModel: "test-model",
            minimaxModel: "",
            openRouterPrimaryModel: "",
            openRouterFallbackModel: "",
            zaiModel: "",
            ollamaBaseURL: "",
            ollamaModel: "",
            requestTimeoutSeconds: 5,
            maxPromptChars: 4_000,
            maxOutputTokens: 256,
            dailyCapUSD: 100,
            retryCount: 0,
            maxCandidatesPerJob: 8,
            promptVersion: "memory-extract-v1"
        )
        let extractor = ChatTranscriptExtractor(
            transcriptReader: store,
            spendReader: ZeroSpendReader(),
            keyResolver: MemoryExtractionAPIKeyResolver(providerAPIKeyStore: ProviderAPIKeyStore()),
            settingsProvider: { settings }
        )

        let job = ControlPlaneStore.MemoryExtractionJob(
            id: "memory-extraction-remote-url",
            idempotencyKey: "remote-url-idem",
            threadID: threadID,
            threadLogicalID: "thread-logical-remote-url",
            messageID: sourceID,
            promptVersion: "memory-extract-v1",
            scope: MemoryScope(appID: "openburnbar"),
            status: .running,
            attempts: 1,
            lastError: nil,
            notBefore: nil,
            leaseExpiresAt: now.addingTimeInterval(900),
            createdAt: now,
            updatedAt: now
        )

        let requests = try await extractor.extract(job)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(MemoryExtractionExtractorHTTPStub.requestCount, 0)
    }

    func test_localLLMEndpointPolicy_allowsLoopbackAndRejectsRemoteOrAmbiguousHosts() {
        XCTAssertEqual(
            LocalLLMEndpointPolicy.sanitizedLoopbackBaseURL(" http://127.0.0.1:11434/ "),
            "http://127.0.0.1:11434"
        )
        XCTAssertEqual(
            LocalLLMEndpointPolicy.sanitizedLoopbackBaseURL("http://localhost:8080"),
            "http://localhost:8080"
        )
        XCTAssertEqual(
            LocalLLMEndpointPolicy.sanitizedLoopbackBaseURL("http://[::1]:8080"),
            "http://[::1]:8080"
        )

        XCTAssertNil(LocalLLMEndpointPolicy.sanitizedLoopbackBaseURL("https://remote.example"))
        XCTAssertNil(LocalLLMEndpointPolicy.sanitizedLoopbackBaseURL("http://192.168.1.10:11434"))
        XCTAssertNil(LocalLLMEndpointPolicy.sanitizedLoopbackBaseURL("http://example.com@127.0.0.1:11434"))
        XCTAssertNil(LocalLLMEndpointPolicy.sanitizedLoopbackBaseURL("127.0.0.1:11434"))
    }

    func test_extractor_returnsEmptyWhenTranscriptMissingTerminalMessage() async throws {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_100_300)
        // No chat_messages inserted → empty transcript → benign empty, no model call.
        MemoryExtractionExtractorHTTPStub.responseJSON = "{\"memories\":[]}"

        let settings = Self.minimalLocalSettings
        let extractor = ChatTranscriptExtractor(
            transcriptReader: store,
            spendReader: ZeroSpendReader(),
            keyResolver: MemoryExtractionAPIKeyResolver(providerAPIKeyStore: ProviderAPIKeyStore()),
            settingsProvider: { settings }
        )
        let job = ControlPlaneStore.MemoryExtractionJob(
            id: "memory-extraction-empty",
            idempotencyKey: "empty-idem",
            threadID: "thread-empty",
            threadLogicalID: "tl",
            messageID: "missing",
            promptVersion: "memory-extract-v1",
            scope: MemoryScope(appID: "openburnbar"),
            status: .running,
            attempts: 1,
            lastError: nil,
            notBefore: nil,
            leaseExpiresAt: now.addingTimeInterval(900),
            createdAt: now,
            updatedAt: now
        )
        let requests = try await extractor.extract(job)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(MemoryExtractionExtractorHTTPStub.requestCount, 0)
    }

    // MARK: - Helpers

    private static let minimalLocalSettings = MemoryExtractionSettingsSnapshot(
        providerOrder: [.mlx],
        localBaseURL: "",
        localModel: "",
        mlxBaseURL: "http://127.0.0.1:9999",
        mlxModel: "test-model",
        minimaxModel: "",
        openRouterPrimaryModel: "",
        openRouterFallbackModel: "",
        zaiModel: "",
        ollamaBaseURL: "",
        ollamaModel: "",
        requestTimeoutSeconds: 5,
        maxPromptChars: 4_000,
        maxOutputTokens: 256,
        dailyCapUSD: 100,
        retryCount: 0,
        maxCandidatesPerJob: 8,
        promptVersion: "memory-extract-v1"
    )

    private func insertChatMessage(
        _ queue: DatabaseQueue,
        threadID: String,
        id: String,
        role: String,
        body: String,
        at date: Date
    ) async throws {
        try await queue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO chat_threads (id, createdAt, updatedAt) VALUES (?, ?, ?)",
                arguments: [threadID, date, date]
            )
            try db.execute(
                sql: """
                INSERT INTO chat_messages (id, role, content, timestamp, threadId)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [id, role, body, date, threadID]
            )
        }
    }
}

// MARK: - Test doubles

/// Always reports zero cloud spend so the cap never blocks the stubbed call.
private struct ZeroSpendReader: SummaryDailySpendReading {
    func summarySpendToday(now: Date) async throws -> Double { 0 }
}

/// `URLProtocol` registered on `URLSession.shared` that answers the OpenAI-compatible
/// `/chat/completions` endpoint with a canned assistant message wrapping
/// `responseJSON`. Keeps the extractor end-to-end test hermetic (no real network).
private final class MemoryExtractionExtractorHTTPStub: URLProtocol {
    private static let lock = NSLock()
    private static var _requestCount = 0
    private static var _responseJSON = "{\"memories\":[]}"

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestCount
    }

    static var responseJSON: String {
        get { lock.lock(); defer { lock.unlock() }; return _responseJSON }
        set { lock.lock(); _responseJSON = newValue; lock.unlock() }
    }

    static func reset() {
        lock.lock(); _requestCount = 0; _responseJSON = "{\"memories\":[]}"; lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.path.contains("chat/completions") ?? false
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self._requestCount += 1; let json = Self._responseJSON; Self.lock.unlock()

        let escaped = json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let envelope = """
        {"choices":[{"message":{"role":"assistant","content":"\(escaped)"}}]}
        """
        let data = Data(envelope.utf8)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Agent-conversation extraction source (T0.2: memory learns from the corpus)

@MainActor
final class AgentConversationExtractionSourceTests: XCTestCase {

    // MARK: Turn splitting

    func test_splitTranscript_parsesCodexAndClaudeHeadings() {
        let anchor = Date(timeIntervalSince1970: 1_755_300_000)
        let codex = AgentConversationExtractionSource.splitTranscript(
            conversationID: "conv-codex",
            fullText: "## User\n\nFix the flaky test\n\n## Assistant\n\nThe retry loop was the culprit.",
            anchoredAt: anchor
        )
        XCTAssertEqual(codex.map(\.role), ["user", "assistant"])
        XCTAssertEqual(codex.map(\.id), ["conv-codex#turn-0", "conv-codex#turn-1"])
        XCTAssertEqual(codex[0].body, "Fix the flaky test")

        let claude = AgentConversationExtractionSource.splitTranscript(
            conversationID: "conv-claude",
            fullText: "## You\n\nAdd the migration\n\n## Assistant\n\nDone — v50 adds the column.",
            anchoredAt: anchor
        )
        XCTAssertEqual(claude.map(\.role), ["user", "assistant"])
        XCTAssertEqual(claude[1].body, "Done — v50 adds the column.")
    }

    func test_splitTranscript_fallsBackToOneUserTurnForUnheadedText() {
        // Several parsers store plain concatenated text with no turn headings —
        // those transcripts must still be extractable, not silently skipped.
        let turns = AgentConversationExtractionSource.splitTranscript(
            conversationID: "conv-plain",
            fullText: "The build needs cmake on the self-hosted runners.",
            anchoredAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].role, "user")
        XCTAssertEqual(turns[0].id, "conv-plain#turn-0")
    }

    func test_splitTranscript_emptyAndWhitespaceYieldNothing() {
        XCTAssertTrue(
            AgentConversationExtractionSource.splitTranscript(
                conversationID: "c", fullText: "  \n\n  ", anchoredAt: Date()
            ).isEmpty
        )
    }

    func test_threadIDRoundTrip() {
        let threadID = AgentConversationExtractionSource.threadID(forConversationID: "abc:with:colons")
        XCTAssertEqual(
            AgentConversationExtractionSource.conversationID(fromThreadID: threadID),
            "abc:with:colons"
        )
        XCTAssertNil(AgentConversationExtractionSource.conversationID(fromThreadID: "chat-thread-1"))
        XCTAssertNil(AgentConversationExtractionSource.conversationID(fromThreadID: "agent-conversation:"))
    }

    // MARK: Harvest → jobs table (idempotent, quiet-gated)

    private struct Stores {
        let dataStore: DataStore
        let controlPlane: ControlPlaneStore
    }

    private func makeStores() throws -> Stores {
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        // Same construction as production (AgentLensApp+MemoryServices): the
        // control plane shares the data store's queue.
        return Stores(
            dataStore: dataStore,
            controlPlane: ControlPlaneStore(dbQueue: dataStore.actor.dbQueue)
        )
    }

    private func makeConversation(
        id: String,
        fullText: String,
        fileModifiedAt: Date,
        messageCount: Int = 4
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: .claudeCode,
            sessionId: "session-\(id)",
            projectName: "BurnBar",
            startTime: fileModifiedAt.addingTimeInterval(-600),
            endTime: fileModifiedAt,
            messageCount: messageCount,
            userWordCount: 20,
            assistantWordCount: 40,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Task \(id)",
            lastAssistantMessage: "Done.",
            fullText: fullText,
            indexedAt: fileModifiedAt,
            fileModifiedAt: fileModifiedAt,
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: .providerLog
        )
    }

    private func pendingJobs(in store: ControlPlaneStore) async throws -> [(id: String, threadID: String)] {
        try await store.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, thread_id FROM memory_extraction_jobs ORDER BY created_at ASC"
            ).compactMap { row -> (id: String, threadID: String)? in
                guard let id = row["id"] as? String, let threadID = row["thread_id"] as? String else { return nil }
                return (id: id, threadID: threadID)
            }
        }
    }

    func test_harvest_enqueuesQuietConversationsExactlyOnce() async throws {
        let stores = try makeStores()
        let now = Date(timeIntervalSince1970: 1_755_300_000)
        let quiet = makeConversation(
            id: "conv-quiet",
            fullText: "## User\n\nShip it\n\n## Assistant\n\nShipped.",
            fileModifiedAt: now.addingTimeInterval(-45 * 60)
        )
        let active = makeConversation(
            id: "conv-active",
            fullText: "## User\n\nStill going",
            fileModifiedAt: now.addingTimeInterval(-2 * 60)
        )
        _ = try await ConversationIndexer.shared.index([quiet, active], in: stores.dataStore)

        let first = try await stores.controlPlane.harvestAgentConversationExtractions(now: now)
        XCTAssertEqual(first, 1, "Only the QUIET conversation is harvested; an active session waits.")

        let jobs = try await pendingJobs(in: stores.controlPlane)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(
            jobs[0].threadID,
            AgentConversationExtractionSource.threadID(forConversationID: "conv-quiet")
        )

        // Idempotency: the sweep drops content states that already carry a job
        // before it enqueues anything, so an unchanged conversation costs zero
        // enqueues on the next pass…
        let second = try await stores.controlPlane.harvestAgentConversationExtractions(now: now)
        XCTAssertEqual(second, 0, "An already-harvested content state is skipped, not re-enqueued.")
        let jobsAfter = try await pendingJobs(in: stores.controlPlane)
        XCTAssertEqual(jobsAfter.count, 1, "…and it stays ONE job.")

        // Growth: new content state becomes exactly one new job.
        let grown = makeConversation(
            id: "conv-quiet",
            fullText: "## User\n\nShip it\n\n## Assistant\n\nShipped.\n\n## User\n\nNow document it",
            fileModifiedAt: now.addingTimeInterval(-31 * 60),
            messageCount: 6
        )
        _ = try await ConversationIndexer.shared.index([grown], in: stores.dataStore)
        _ = try await stores.controlPlane.harvestAgentConversationExtractions(now: now)
        let jobsGrown = try await pendingJobs(in: stores.controlPlane)
        XCTAssertEqual(jobsGrown.count, 2, "A grown conversation re-extracts under a new content-state key.")
    }

    // MARK: Store transcript + provenance resolution

    func test_storeResolvesConversationTranscriptAndProvenanceTurns() async throws {
        let stores = try makeStores()
        let now = Date(timeIntervalSince1970: 1_755_300_000)
        let conversation = makeConversation(
            id: "conv-prov",
            fullText: "## User\n\nWhere does the key live?\n\n## Assistant\n\nIn the Keychain item.",
            fileModifiedAt: now.addingTimeInterval(-60 * 60)
        )
        _ = try await ConversationIndexer.shared.index([conversation], in: stores.dataStore)

        let threadID = AgentConversationExtractionSource.threadID(forConversationID: "conv-prov")
        let transcript = try await stores.controlPlane.fetchChatTranscriptForExtraction(threadID: threadID)
        XCTAssertEqual(transcript.map(\.role), ["user", "assistant"])

        // The worker's provenance lookup resolves the same deterministic turn id
        // the extractor prompted with — citations bind to real corpus content.
        let cited = try await stores.controlPlane.fetchChatProvenanceSourceMessage(
            threadID: threadID,
            messageID: "conv-prov#turn-1"
        )
        XCTAssertEqual(cited?.role, "assistant")
        XCTAssertEqual(cited?.body, "In the Keychain item.")

        let missing = try await stores.controlPlane.fetchChatProvenanceSourceMessage(
            threadID: threadID,
            messageID: "conv-prov#turn-99"
        )
        XCTAssertNil(missing, "A turn the split no longer produces is dropped, never fabricated.")
    }
}
