import Foundation
import XCTest
import OpenBurnBarCore
@preconcurrency import GRDB
@testable import OpenBurnBar

/// Focused coverage for the cost-cap hardening in `SummaryWorker`.
///
/// Background: the daily cloud spend read
/// (`SummaryWorker.summarizeWithOpenAICompatibleProvider` →
/// `spendReader.summarySpendToday(now:)`) gates whether a *paid* cloud LLM
/// call is allowed to proceed. The read result feeds directly into
/// `SummaryCostEstimator.exceedsCloudDailyCap(...)`.
///
/// Before this change the call site read with `try? dataStoreActor.summarySpendToday() ?? 0`.
/// On a DB read fault that collapsed an unknown amount of spend to `0`, which made
/// the cap silently look unbreached — i.e. a read failure could *bypass* the daily
/// cost cap and let an uncapped paid cloud call go out. That is a fail-open
/// security/cost-control defect.
///
/// The migrated call site fails **closed**: a read fault is logged and the cloud
/// call is skipped (the provider yields `nil`) rather than defaulting spend to `0`.
///
/// These tests drive that decision end to end through the public
/// `summarizeAndStore(_:settings:)` entry point, using:
///   * the new `spendReader` injection seam on `SummaryWorker.init` to model a
///     faulting / over-cap / under-cap spend read deterministically, and
///   * a global `URLProtocol` stub registered on `URLSession.shared` (the session
///     `SummaryLLMClient` uses) to *record* whether the paid cloud `/chat/completions`
///     endpoint was ever contacted — the decisive, network-free signal that
///     distinguishes "gate blocked the call" from "gate let the call through".
final class SummaryWorkerMattersTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SummaryWorkerNetworkRecorder.reset()
        URLProtocol.registerClass(SummaryWorkerNetworkRecorder.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(SummaryWorkerNetworkRecorder.self)
        SummaryWorkerNetworkRecorder.reset()
        super.tearDown()
    }

    // MARK: - The matters path: a faulting spend read must FAIL CLOSED

    /// A DB fault on the daily-spend read must NOT default spend to `0` and let a
    /// paid cloud call proceed. The decisive signal is twofold: the provider yields
    /// `nil` (no summary produced) AND the paid `/chat/completions` endpoint was
    /// never contacted. Under the old `try?`-to-`0` behavior the gate would have
    /// seen "spent 0, under cap" and dispatched the network call — so a recorded
    /// request count of zero here is exactly the fail-closed guarantee.
    func test_spendReadFault_failsClosed_noPaidCloudCall() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OLLAMA_API_KEY"] == nil,
            "OLLAMA_API_KEY is set; cannot isolate the no-credential cloud-gate path."
        )

        let reader = FaultyDailySpendReader()
        let worker = try await makeWorker(spendReader: reader)

        // High cap so that, if spend had defaulted to 0, the call WOULD proceed.
        let settings = makeSettings(dailyCapUSD: 1_000_000)

        let result = await worker.summarizeAndStore(makeConversation(), settings: settings)

        XCTAssertNil(result, "A failed spend read must not yield a summary via a paid cloud call")
        XCTAssertEqual(
            reader.callCount,
            1,
            "The cloud cost gate must consult the spend read exactly once before any paid call"
        )
        XCTAssertEqual(
            SummaryWorkerNetworkRecorder.paidCompletionRequestCount,
            0,
            "Fail closed: a faulting spend read must skip the paid cloud /chat/completions call"
        )
    }

    // MARK: - Control: a healthy under-cap read must let the call THROUGH

    /// Proves the gate — not some unrelated short-circuit — is what blocks the
    /// faulting case above. With a successful read of `0` spend under a high cap,
    /// the worker MUST proceed to contact the paid `/chat/completions` endpoint.
    /// (The recorder fails the request, so no summary is produced, but the
    /// recorded request proves the gate let the call through.)
    func test_healthyUnderCapRead_proceedsToPaidCloudCall() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OLLAMA_API_KEY"] == nil,
            "OLLAMA_API_KEY is set; cannot isolate the no-credential cloud-gate path."
        )

        let reader = FixedDailySpendReader(spentToday: 0)
        let worker = try await makeWorker(spendReader: reader)
        let settings = makeSettings(dailyCapUSD: 1_000_000, retryCount: 0)

        _ = await worker.summarizeAndStore(makeConversation(), settings: settings)

        XCTAssertEqual(reader.callCount, 1, "The gate must consult the spend read once")
        XCTAssertGreaterThanOrEqual(
            SummaryWorkerNetworkRecorder.paidCompletionRequestCount,
            1,
            "A healthy under-cap read must let the paid cloud call proceed"
        )
    }

    func test_nilDailyCap_doesNotBehaveLikeZeroDollarCap() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OLLAMA_API_KEY"] == nil,
            "OLLAMA_API_KEY is set; cannot isolate the no-credential cloud-gate path."
        )

        let reader = FixedDailySpendReader(spentToday: 999_999)
        let worker = try await makeWorker(spendReader: reader)
        let settings = makeSettings(dailyCapUSD: nil, retryCount: 0)

        _ = await worker.summarizeAndStore(makeConversation(), settings: settings)

        XCTAssertEqual(reader.callCount, 1, "The worker should still read spend before a cloud provider call")
        XCTAssertGreaterThanOrEqual(
            SummaryWorkerNetworkRecorder.paidCompletionRequestCount,
            1,
            "An absent daily cap must not collapse to a zero-dollar cap that blocks every paid summary"
        )
    }

    // MARK: - Cap-exceeded read must skip the call (existing behavior intact)

    /// A successful read that is already over the cap must skip the paid call,
    /// exactly as before. This guards that the fail-closed migration did not
    /// disturb the normal "over budget → don't spend" branch.
    func test_overCapRead_skipsPaidCloudCall() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OLLAMA_API_KEY"] == nil,
            "OLLAMA_API_KEY is set; cannot isolate the no-credential cloud-gate path."
        )

        let reader = FixedDailySpendReader(spentToday: 999_999)
        let worker = try await makeWorker(spendReader: reader)
        let settings = makeSettings(dailyCapUSD: 1.0)

        let result = await worker.summarizeAndStore(makeConversation(), settings: settings)

        XCTAssertNil(result, "Over-cap spend must skip the paid cloud call")
        XCTAssertEqual(reader.callCount, 1, "The gate must still consult the spend read once")
        XCTAssertEqual(
            SummaryWorkerNetworkRecorder.paidCompletionRequestCount,
            0,
            "Over-cap spend must not contact the paid cloud endpoint"
        )
    }

    // MARK: - Fixtures

    /// Builds a worker whose only cloud provider is `.ollama` (its OpenAI-compatible
    /// path is gated by the daily cost cap and resolves to an empty API key when no
    /// credential is configured, so no real secret is required to exercise the gate).
    private func makeWorker(spendReader: any SummaryDailySpendReading) async throws -> SummaryWorker {
        let summaryStore = SummaryWorkerNoopStore()
        let providerStore = await makeEmptyProviderStore()
        let resolver = SummaryAPIKeyResolver(
            providerAPIKeyStore: providerStore,
            keychainStoreProvider: {
                KeychainStore(
                    service: "com.openburnbar.summaryworker-matters-tests.connector",
                    legacyServices: [],
                    backend: EmptyKeychainBackend()
                )
            }
        )
        return SummaryWorker(
            summaryStore: summaryStore,
            llmClient: SummaryLLMClient(),
            keyResolver: resolver,
            spendReader: spendReader
        )
    }

    /// An isolated, empty `ProviderAPIKeyStore` so `apiKey(for: "ollama")` is `nil`
    /// and the resolver degrades to an empty key, keeping the cloud gate the only
    /// thing under test.
    @MainActor
    private func makeEmptyProviderStore() -> ProviderAPIKeyStore {
        let keychain = KeychainStore(
            service: "com.openburnbar.summaryworker-matters-tests.provider",
            legacyServices: [],
            backend: EmptyKeychainBackend()
        )
        return ProviderAPIKeyStore(keychain: keychain)
    }

    private func makeSettings(dailyCapUSD: Double?, retryCount: Int = 0) -> SummarySettingsSnapshot {
        SummarySettingsSnapshot(
            providerOrder: [.ollama],
            localBaseURL: "",
            localModel: "",
            mlxBaseURL: "",
            mlxModel: "",
            minimaxModel: "",
            openRouterPrimaryModel: "",
            openRouterFallbackModel: "",
            zaiModel: "",
            ollamaBaseURL: "http://summaryworker.test.invalid",
            ollamaModel: "test-model",
            requestTimeoutSeconds: 1,
            maxPromptChars: 4_000,
            maxOutputTokens: 256,
            dailyCapUSD: dailyCapUSD,
            retryCount: retryCount
        )
    }

    private func makeConversation() -> ConversationRecord {
        ConversationRecord(
            id: "conv-summaryworker-matters",
            provider: .claudeCode,
            sessionId: "sess-1",
            projectName: "proj",
            startTime: Date(),
            endTime: Date(),
            messageCount: 2,
            userWordCount: 10,
            assistantWordCount: 10,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Fallback Title",
            lastAssistantMessage: "hello",
            fullText: "user: hi\nassistant: hello",
            fileModifiedAt: nil
        )
    }
}

// MARK: - Spend-read fakes

/// Models a DB fault on the daily-spend read. Conforms to the production
/// `SummaryDailySpendReading` seam so the worker's cost gate exercises the
/// real fail-closed branch.
private final class FaultyDailySpendReader: SummaryDailySpendReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    func summarySpendToday(now _: Date) async throws -> Double {
        lock.lock(); _callCount += 1; lock.unlock()
        throw SummaryWorkerTestError.spendReadFailed
    }
}

/// A healthy spend read returning a fixed value, used to drive the under-cap and
/// over-cap branches deterministically.
private final class FixedDailySpendReader: SummaryDailySpendReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private let spentToday: Double

    init(spentToday: Double) {
        self.spentToday = spentToday
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    func summarySpendToday(now _: Date) async throws -> Double {
        lock.lock(); _callCount += 1; lock.unlock()
        return spentToday
    }
}

private actor SummaryWorkerNoopStore: SummaryPersistenceStore {
    func updateConversationSummary(
        id _: String,
        title _: String?,
        summary _: String?,
        provider _: String?,
        model _: String?,
        updatedAt _: Date,
        runCostUSD _: Double
    ) async throws {}

    func markConversationSummaryAttempt(id _: String, attemptedAt _: Date) async throws {}

    func summarySpendToday(now _: Date) async throws -> Double {
        0
    }
}

private enum SummaryWorkerTestError: Error {
    case spendReadFailed
}

// MARK: - Empty Keychain backend

/// In-memory `KeychainStoreBackend` with no stored items, so credential reads
/// resolve to `nil` (no real secret involved in these tests).
private final class EmptyKeychainBackend: KeychainStoreBackend {
    func set(_: Data, service _: String, account _: String) throws {}
    func data(for _: String, account _: String, allowUserInteraction _: Bool) throws -> Data? { nil }
    func delete(service _: String, account _: String) throws {}
}

// MARK: - Network recorder

/// Global `URLProtocol` registered on `URLSession.shared` (the session
/// `SummaryLLMClient` uses) that records contact with the paid cloud
/// `/chat/completions` endpoint and fails every request, keeping the test
/// hermetic. The recorded count is the network-free signal that distinguishes
/// "gate blocked the paid call" from "gate let it through".
private final class SummaryWorkerNetworkRecorder: URLProtocol {
    private static let lock = NSLock()
    private static var _paidCompletionRequestCount = 0

    static var paidCompletionRequestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _paidCompletionRequestCount
    }

    static func reset() {
        lock.lock(); _paidCompletionRequestCount = 0; lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let path = request.url?.path else { return false }
        return path.contains("chat/completions")
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self._paidCompletionRequestCount += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}

// MARK: - OpenAI-compatible response parser

/// Pins the one `/chat/completions` body reader that `SummaryLLMClient` and
/// `MemoryExtractionLLMClient` now share.
///
/// Both clients used to carry a verbatim copy of this walk. The copies were
/// retired into `OpenAICompatibleChatResponse.assistantText(fromResponseBody:)`,
/// so these cases are what stops the two lanes from silently drifting apart
/// again — every branch the two copies had is asserted here, including the two
/// that only differed in spelling (`compactMap` with an `if let` vs a direct
/// cast) and therefore had to keep behaving identically.
final class OpenAICompatibleChatResponseTests: XCTestCase {

    private func body(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func test_string_content_is_returned_verbatim() throws {
        let data = try body([
            "choices": [["message": ["content": "hello world"]]]
        ])
        XCTAssertEqual(OpenAICompatibleChatResponse.assistantText(fromResponseBody: data), "hello world")
    }

    func test_content_blocks_are_joined_in_order() throws {
        let data = try body([
            "choices": [["message": ["content": [
                ["type": "text", "text": "one "],
                ["type": "text", "text": "two"]
            ]]]]
        ])
        XCTAssertEqual(OpenAICompatibleChatResponse.assistantText(fromResponseBody: data), "one two")
    }

    func test_blocks_without_text_are_skipped_not_failed() throws {
        let data = try body([
            "choices": [["message": ["content": [
                ["type": "thinking"],
                ["type": "text", "text": "kept"]
            ]]]]
        ])
        XCTAssertEqual(OpenAICompatibleChatResponse.assistantText(fromResponseBody: data), "kept")
    }

    /// An all-empty block array is `nil`, not `""` — both retired copies did
    /// this, and a caller that treats `""` as a usable completion would store an
    /// empty summary / memory.
    func test_all_empty_blocks_are_nil_not_empty_string() throws {
        let data = try body([
            "choices": [["message": ["content": [["type": "thinking"]]]]]
        ])
        XCTAssertNil(OpenAICompatibleChatResponse.assistantText(fromResponseBody: data))
    }

    func test_first_choice_wins() throws {
        let data = try body([
            "choices": [
                ["message": ["content": "first"]],
                ["message": ["content": "second"]]
            ]
        ])
        XCTAssertEqual(OpenAICompatibleChatResponse.assistantText(fromResponseBody: data), "first")
    }

    func test_missing_choices_is_nil() throws {
        XCTAssertNil(OpenAICompatibleChatResponse.assistantText(fromResponseBody: try body(["error": "nope"])))
    }

    func test_empty_choices_is_nil() throws {
        XCTAssertNil(OpenAICompatibleChatResponse.assistantText(fromResponseBody: try body(["choices": []])))
    }

    func test_missing_message_is_nil() throws {
        XCTAssertNil(OpenAICompatibleChatResponse.assistantText(fromResponseBody: try body(["choices": [["finish_reason": "stop"]]])))
    }

    func test_unreadable_content_type_is_nil() throws {
        let data = try body(["choices": [["message": ["content": 42]]]])
        XCTAssertNil(OpenAICompatibleChatResponse.assistantText(fromResponseBody: data))
    }

    func test_non_json_body_is_nil() {
        XCTAssertNil(OpenAICompatibleChatResponse.assistantText(fromResponseBody: Data("not json".utf8)))
    }

    func test_empty_body_is_nil() {
        XCTAssertNil(OpenAICompatibleChatResponse.assistantText(fromResponseBody: Data()))
    }
}
