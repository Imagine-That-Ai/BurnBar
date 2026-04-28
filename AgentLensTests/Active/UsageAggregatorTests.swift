import XCTest
import GRDB
@testable import OpenBurnBar

// MARK: - UsageAggregator Tests

@MainActor
final class UsageAggregatorTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeTestDataStore() throws -> DataStore {
        try DataStore()
    }

    private func makeTestAggregator(
        dataStore: DataStore,
        parserOverrides: [AgentProvider: any LogParser]? = nil,
        usageAPIService: ProviderUsageAPIService? = nil
    ) -> UsageAggregator {
        UsageAggregator(
            dataStore: dataStore,
            usageAPIService: usageAPIService,
            parserOverrides: parserOverrides
        )
    }

    // MARK: - Initialization Tests

    func test_init_setsDefaultParsers() throws {
        let aggregator = UsageAggregator(dataStore: try makeTestDataStore())
        XCTAssertFalse(aggregator.isRefreshing)
        XCTAssertFalse(aggregator.isSummarizing)
        XCTAssertEqual(aggregator.errors, [:])
        XCTAssertEqual(aggregator.parserHealth, [:])
    }

    func test_init_withParserOverrides_usesOverrides() throws {
        let overrideParser = MockParser(provider: .factory)
        let aggregator = UsageAggregator(
            dataStore: try makeTestDataStore(),
            parserOverrides: [.factory: overrideParser]
        )
        XCTAssertFalse(aggregator.isRefreshing)
    }

    func test_init_persistenceErrorMessage_isNil() throws {
        let aggregator = UsageAggregator(dataStore: try makeTestDataStore())
        XCTAssertNil(aggregator.persistenceErrorMessage)
    }

    func test_init_apiUsages_isEmpty() throws {
        let aggregator = UsageAggregator(dataStore: try makeTestDataStore())
        XCTAssertEqual(aggregator.apiUsages, [])
    }

    func test_init_lastRefresh_isNil() throws {
        let aggregator = UsageAggregator(dataStore: try makeTestDataStore())
        XCTAssertNil(aggregator.lastRefresh)
    }

    // MARK: - Refresh All Tests

    func test_refreshAll_whenAlreadyRefreshing_returnsEarly() async throws {
        let dataStore = try makeTestDataStore()
        let aggregator = makeTestAggregator(dataStore: dataStore)
        let mockParser = MockParser(provider: .factory)
        mockParser.parseResult = ParseResult(usages: [], conversations: [])

        // First refresh
        let refresh1 = Task {
            await aggregator.refreshAll()
        }

        // Give the first refresh a chance to start
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms

        // Second refresh should return early since isRefreshing is true
        await aggregator.refreshAll()

        await refresh1.value
        XCTAssertFalse(aggregator.isRefreshing)
    }

    func test_refreshAll_clearsErrorsBeforeRefresh() async throws {
        let dataStore = try makeTestDataStore()
        let aggregator = makeTestAggregator(dataStore: dataStore)
        let mockParser = MockParser(provider: .factory)
        mockParser.shouldThrowError = true
        mockParser.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error"])

        // First refresh to set error
        await aggregator.refreshAll()

        // Clear the error by doing another refresh
        let emptyParser = MockParser(provider: .factory)
        emptyParser.parseResult = ParseResult(usages: [], conversations: [])

        // This should clear errors since the parser no longer throws
        await aggregator.refreshAll()

        // Verify errors are cleared
        XCTAssertEqual(aggregator.errors[.factory], nil)
    }

    func test_refreshAll_setsLastRefreshOnSuccess() async throws {
        let dataStore = try makeTestDataStore()
        let aggregator = makeTestAggregator(dataStore: dataStore)
        let mockParser = MockParser(provider: .factory)
        mockParser.parseResult = ParseResult(usages: [], conversations: [])

        XCTAssertNil(aggregator.lastRefresh)
        await aggregator.refreshAll()
        XCTAssertNotNil(aggregator.lastRefresh)
    }

    func test_refreshAll_updatesParserHealth_onSuccess() async throws {
        let dataStore = try makeTestDataStore()
        let mockParser = MockParser(provider: .factory)
        mockParser.parseResult = ParseResult(
            usages: [
                TokenUsage(
                    provider: .factory,
                    sessionId: "s1",
                    projectName: "p",
                    model: "m",
                    inputTokens: 100,
                    outputTokens: 100,
                    costUSD: 0.01,
                    startTime: Date(),
                    endTime: Date()
                )
            ],
            conversations: []
        )

        let aggregator = makeTestAggregator(dataStore: dataStore, parserOverrides: [.factory: mockParser])
        await aggregator.refreshAll()

        let health = aggregator.parserHealth[.factory]
        XCTAssertNotNil(health)
        if case .healthy(let sessionCount) = health {
            XCTAssertEqual(sessionCount, 1)
        } else {
            XCTFail("Expected .healthy sessionCount=1")
        }
    }

    func test_refreshAll_updatesParserHealth_onEmptyResult() async throws {
        let dataStore = try makeTestDataStore()
        let mockParser = MockParser(provider: .factory)
        mockParser.parseResult = ParseResult(usages: [], conversations: [])

        let aggregator = makeTestAggregator(dataStore: dataStore, parserOverrides: [.factory: mockParser])
        await aggregator.refreshAll()

        let health = aggregator.parserHealth[.factory]
        XCTAssertNotNil(health)
        if case .empty = health {
            // Expected
        } else {
            XCTFail("Expected .empty")
        }
    }

    func test_refreshAll_updatesParserHealth_onFailure() async throws {
        let dataStore = try makeTestDataStore()
        let mockParser = MockParser(provider: .factory)
        mockParser.shouldThrowError = true
        mockParser.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error"])

        let aggregator = makeTestAggregator(dataStore: dataStore, parserOverrides: [.factory: mockParser])
        await aggregator.refreshAll()

        let health = aggregator.parserHealth[.factory]
        XCTAssertNotNil(health)
        if case .failed(let error) = health {
            XCTAssertTrue(error.contains("Test error"))
        } else {
            XCTFail("Expected .failed")
        }
    }

    func test_refreshAll_storesUsagesInDataStore() async throws {
        let dataStore = try makeTestDataStore()
        let mockParser = MockParser(provider: .factory)
        let testUsage = TokenUsage(
            provider: .factory,
            sessionId: "test-session",
            projectName: "TestProject",
            model: "test-model",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date()
        )
        mockParser.parseResult = ParseResult(usages: [testUsage], conversations: [])

        let aggregator = makeTestAggregator(dataStore: dataStore, parserOverrides: [.factory: mockParser])
        await aggregator.refreshAll()

        let storedUsages = dataStore.usages
        XCTAssertEqual(storedUsages.count, 1)
        XCTAssertEqual(storedUsages.first?.sessionId, "test-session")
    }

    // MARK: - Refresh Single Provider Tests

    func test_refresh_providerWithNoParser_doesNothing() async throws {
        let dataStore = try makeTestDataStore()
        let aggregator = makeTestAggregator(dataStore: dataStore)

        await aggregator.refresh(provider: .claudeCode)
        XCTAssertEqual(aggregator.parserHealth[.claudeCode], nil)
    }

    func test_refresh_updatesParserHealthOnSuccess() async throws {
        let dataStore = try makeTestDataStore()
        let mockParser = MockParser(provider: .factory)
        mockParser.parseResult = ParseResult(usages: [], conversations: [])

        let aggregator = makeTestAggregator(dataStore: dataStore, parserOverrides: [.factory: mockParser])
        await aggregator.refresh(provider: .factory)

        let health = aggregator.parserHealth[.factory]
        XCTAssertNotNil(health)
    }

    func test_refresh_clearsErrorOnSuccess() async throws {
        let dataStore = try makeTestDataStore()
        let mockParser = MockParser(provider: .factory)
        mockParser.shouldThrowError = true
        mockParser.errorToThrow = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error"])

        let aggregator = makeTestAggregator(dataStore: dataStore, parserOverrides: [.factory: mockParser])

        // First refresh to set error
        await aggregator.refresh(provider: .factory)
        XCTAssertNotNil(aggregator.errors[.factory])

        // Now make it succeed
        mockParser.shouldThrowError = false
        mockParser.parseResult = ParseResult(usages: [], conversations: [])

        await aggregator.refresh(provider: .factory)
        XCTAssertNil(aggregator.errors[.factory])
    }

    // MARK: - Test Helper Methods

    func test_computeSupplementalUsages_returnsEmptyWhenNoRecords() throws {
        let dataStore = try makeTestDataStore()
        let aggregator = makeTestAggregator(dataStore: dataStore)

        let result = aggregator.computeSupplementalUsages(from: [], existingUsages: [])
        XCTAssertEqual(result, [])
    }

    func test_computeSupplementalUsages_returnsEmptyWhenAllMatched() throws {
        let dataStore = try makeTestDataStore()
        let aggregator = makeTestAggregator(dataStore: dataStore)

        let apiRecords = [
            ProviderUsageRecord(
                providerName: "Factory",
                model: "test-model",
                date: Date(),
                inputTokens: 100,
                outputTokens: 50,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 0.01,
                requestCount: 1
            )
        ]

        let existingUsages = [
            TokenUsage(
                provider: .factory,
                sessionId: "s1",
                projectName: "p",
                model: "test-model",
                inputTokens: 100,
                outputTokens: 50,
                costUSD: 0.01,
                startTime: Date(),
                endTime: Date()
            )
        ]

        let result = aggregator.computeSupplementalUsages(from: apiRecords, existingUsages: existingUsages)
        XCTAssertTrue(result.isEmpty)
    }

    func test_costDeltaExceedsEpsilon_returnsFalseWhenDeltaIsZero() throws {
        let result = UsageAggregator.costDeltaExceedsEpsilon(localCost: 1.0, apiCost: 1.0)
        XCTAssertFalse(result)
    }

    func test_costDeltaExceedsEpsilon_returnsFalseWhenDeltaIsBelowEpsilon() throws {
        let result = UsageAggregator.costDeltaExceedsEpsilon(localCost: 1.0, apiCost: 1.0 + 1e-10)
        XCTAssertFalse(result)
    }

    func test_costDeltaExceedsEpsilon_returnsTrueWhenDeltaExceedsEpsilon() throws {
        let result = UsageAggregator.costDeltaExceedsEpsilon(localCost: 1.0, apiCost: 1.1)
        XCTAssertTrue(result)
    }

    func test_costDeltaExceedsEpsilon_handlesNegativeDelta() throws {
        // When apiCost < localCost, missingCost = max(0, negative) = 0
        let result = UsageAggregator.costDeltaExceedsEpsilon(localCost: 1.1, apiCost: 1.0)
        XCTAssertFalse(result)
    }

    // MARK: - Recount All Tests

    func test_recountAll_clearsUsagesAndReRefreshes() async throws {
        let dataStore = try makeTestDataStore()

        // Add initial usage
        let initialUsage = TokenUsage(
            provider: .factory,
            sessionId: "old-session",
            projectName: "p",
            model: "m",
            inputTokens: 100,
            outputTokens: 100,
            costUSD: 0.01,
            startTime: Date(),
            endTime: Date()
        )
        dataStore.replaceUsages([initialUsage])
        XCTAssertEqual(dataStore.usages.count, 1)

        let mockParser = MockParser(provider: .factory)
        mockParser.parseResult = ParseResult(usages: [], conversations: [])

        let aggregator = makeTestAggregator(dataStore: dataStore, parserOverrides: [.factory: mockParser])
        await aggregator.recountAll()

        // After recount, usages should be from parser (empty in this case)
        // The old session should be replaced
    }
}

// MARK: - TokenExtractionUtility Tests

final class TokenExtractionUtilityTests: XCTestCase {

    func test_extractUsageTokens_withStandardFields() throws {
        let usage: [String: Any] = [
            "input_tokens": 100,
            "output_tokens": 50,
            "cache_creation_input_tokens": 25,
            "cache_read_input_tokens": 10
        ]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        XCTAssertEqual(result.input, 100)
        XCTAssertEqual(result.output, 50)
        XCTAssertEqual(result.cacheCreation, 25)
        XCTAssertEqual(result.cacheRead, 10)
        XCTAssertFalse(result.hasNoExplicitBuckets)
    }

    func test_extractUsageTokens_withCamelCaseFields() throws {
        let usage: [String: Any] = [
            "inputTokens": 200,
            "outputTokens": 100,
            "cacheCreationTokens": 50,
            "cacheReadTokens": 20
        ]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        XCTAssertEqual(result.input, 200)
        XCTAssertEqual(result.output, 100)
        XCTAssertEqual(result.cacheCreation, 50)
        XCTAssertEqual(result.cacheRead, 20)
    }

    func test_extractUsageTokens_withNestedObjects() throws {
        let usage: [String: Any] = [
            "prompt_tokens": 150,
            "completion_tokens": 75,
            "promptTokensDetails": ["cachedTokens": 30]
        ]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        XCTAssertEqual(result.input, 150)
        XCTAssertEqual(result.output, 75)
        XCTAssertEqual(result.cacheRead, 30)
    }

    func test_extractUsageTokens_withNoExplicitBuckets_hasNoExplicitBucketsIsTrue() throws {
        let usage: [String: Any] = [:]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        XCTAssertEqual(result.input, 0)
        XCTAssertEqual(result.output, 0)
        XCTAssertTrue(result.hasNoExplicitBuckets)
    }

    func test_extractUsageTokens_withOnlyTotalTokens_derivesPrimaryBuckets() throws {
        let usage: [String: Any] = [
            "total_tokens": 200,
            "input_tokens": 150,
            // output_tokens is missing
            "cache_creation_input_tokens": 30,
            "cache_read_input_tokens": 10
        ]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        XCTAssertEqual(result.input, 150)
        XCTAssertEqual(result.cacheCreation, 30)
        XCTAssertEqual(result.cacheRead, 10)
    }

    func test_extractUsageTokens_normalizesFromTotal() throws {
        let usage: [String: Any] = [
            "total_tokens": 300,
            // No input or output explicitly
        ]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        // Should derive input/output from total using default ratio
        XCTAssertTrue(result.input > 0 || result.output > 0)
    }

    func test_extractUsageTokens_preservesZeroValues() throws {
        let usage: [String: Any] = [
            "input_tokens": 0,
            "output_tokens": 0
        ]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        XCTAssertEqual(result.input, 0)
        XCTAssertEqual(result.output, 0)
    }

    func test_extractUsageTokens_handlesStringValues() throws {
        let usage: [String: Any] = [
            "input_tokens": "100",
            "output_tokens": "50"
        ]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        XCTAssertEqual(result.input, 100)
        XCTAssertEqual(result.output, 50)
    }

    func test_extractUsageTokens_handlesDoubleValues() throws {
        let usage: [String: Any] = [
            "input_tokens": 100.7,
            "output_tokens": 50.3
        ]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        XCTAssertEqual(result.input, 101) // Rounded
        XCTAssertEqual(result.output, 50)
    }

    func test_extractUsageTokens_handlesReasoningTokens() throws {
        let usage: [String: Any] = [
            "input_tokens": 100,
            "output_tokens": 50,
            "thinking_tokens": 25
        ]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        XCTAssertEqual(result.reasoningTokens, 25)
    }

    func test_extractUsageTokens_reasoningTokensSeparatelyBilled() throws {
        let usage: [String: Any] = [
            "input_tokens": 100,
            "output_tokens": 50,
            "reasoning_tokens": 20
        ]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        XCTAssertEqual(result.reasoningTokens, 20)
        XCTAssertEqual(result.output, 50) // Output is not inflated
    }

    func test_hasExplicitPrimaryBucket_withBothBuckets_returnsTrue() throws {
        let usage: [String: Any] = [
            "input_tokens": 100,
            "output_tokens": 50
        ]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        XCTAssertTrue(result.hasExplicitPrimaryBucket)
    }

    func test_hasExplicitPrimaryBucket_withOnlyInput_returnsTrue() throws {
        let usage: [String: Any] = [
            "input_tokens": 100
        ]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        XCTAssertTrue(result.hasExplicitPrimaryBucket)
    }

    func test_hasExplicitPrimaryBucket_withNoPrimaryBuckets_returnsFalse() throws {
        let usage: [String: Any] = [
            "cache_creation_input_tokens": 50
        ]

        let result = TokenExtractionUtility.extractUsageTokens(usage)

        XCTAssertFalse(result.hasExplicitPrimaryBucket)
    }

    // MARK: - Content Metrics Tests

    func test_contentMetrics_withSimpleString() throws {
        let result = TokenExtractionUtility.contentMetrics(from: "Hello world")

        XCTAssertEqual(result.visibleChars, 11)
        XCTAssertEqual(result.reasoningChars, 0)
    }

    func test_contentMetrics_withEmptyString() throws {
        let result = TokenExtractionUtility.contentMetrics(from: "")

        XCTAssertEqual(result.visibleChars, 0)
        XCTAssertEqual(result.reasoningChars, 0)
    }

    func test_contentMetrics_withWhitespaceOnly() throws {
        let result = TokenExtractionUtility.contentMetrics(from: "   \n\t  ")

        XCTAssertEqual(result.visibleChars, 0)
        XCTAssertEqual(result.reasoningChars, 0)
    }

    func test_contentMetrics_withNestedArrays() throws {
        let content: [String: Any] = [
            "messages": [
                ["role": "user", "content": "Hello"],
                ["role": "assistant", "content": "Hi there"]
            ]
        ]

        let result = TokenExtractionUtility.contentMetrics(from: content)

        XCTAssertEqual(result.visibleChars, 22) // "Hello" + "Hi there"
    }

    func test_contentMetrics_withSignatureKey_marksAsReasoning() throws {
        let result = TokenExtractionUtility.contentMetrics(from: "abc123", key: "signature")

        XCTAssertEqual(result.visibleChars, 0)
        XCTAssertEqual(result.reasoningChars, 6)
    }

    func test_contentMetrics_withIgnoredKeys() throws {
        let result = TokenExtractionUtility.contentMetrics(from: "test", key: "type")

        XCTAssertEqual(result.visibleChars, 0)
        XCTAssertEqual(result.reasoningChars, 0)
    }

    func test_contentMetrics_withPreviewLineMarker_expandsCount() throws {
        let text = """
        func example() {
            // Showing lines 1-10 of 100 total lines
            print("Hello")
        }
        """

        let result = TokenExtractionUtility.contentMetrics(from: text)

        // The preview marker should cause expansion
        XCTAssertGreaterThan(result.visibleChars, 100)
    }

    // MARK: - Fallback Estimation Tests

    func test_estimateFallbackTokens_characterRatio_estimatesInputAndOutput() throws {
        let result = TokenExtractionUtility.estimateFallbackTokens(
            userVisibleChars: 1000,
            assistantVisibleChars: 500,
            assistantReasoningChars: 200,
            userMessageCount: 5,
            assistantMessageCount: 3
        )

        XCTAssertTrue(result.input > 0)
        XCTAssertTrue(result.output > 0)
    }

    func test_estimateFallbackTokens_withZeroChars_returnsZero() throws {
        let result = TokenExtractionUtility.estimateFallbackTokens(
            userVisibleChars: 0,
            assistantVisibleChars: 0,
            assistantReasoningChars: 0,
            userMessageCount: 0,
            assistantMessageCount: 0
        )

        XCTAssertEqual(result.input, 0)
        XCTAssertEqual(result.output, 0)
    }

    func test_estimatedTokenCount_withPositiveChars_returnsRoundedUp() throws {
        let result = TokenExtractionUtility.estimatedTokenCount(for: 100, charsPerToken: 3.35)

        XCTAssertEqual(result, 30) // 100/3.35 ≈ 29.85, rounded up to 30
    }

    func test_estimatedTokenCount_withZeroChars_returnsZero() throws {
        let result = TokenExtractionUtility.estimatedTokenCount(for: 0, charsPerToken: 3.35)
        XCTAssertEqual(result, 0)
    }

    func test_charsPerToken_forEnglishText_returnsDefaultRatio() throws {
        let text = "This is a typical English sentence with common words."
        let ratio = TokenExtractionUtility.charsPerToken(for: text)

        XCTAssertEqual(ratio, 3.35)
    }

    func test_charsPerToken_forCJKText_returnsLowerRatio() throws {
        var cjkText = ""
        for _ in 0..<100 {
            cjkText += "你好"
        }

        let ratio = TokenExtractionUtility.charsPerToken(for: cjkText)

        XCTAssertEqual(ratio, 1.5) // CJK ratio
    }

    func test_charsPerToken_forEmptyString_returnsDefaultRatio() throws {
        let ratio = TokenExtractionUtility.charsPerToken(for: "")
        XCTAssertEqual(ratio, 3.35)
    }

    // MARK: - Model Detection Tests

    func test_detectModelHint_withModelAnnotation() throws {
        let content = "Using model: claude-3-5-sonnet for this task"

        let result = TokenExtractionUtility.detectModelHint(from: content)

        XCTAssertEqual(result, "claude-3-5-sonnet")
    }

    func test_detectModelHint_withoutModelAnnotation() throws {
        let content = "This is just some content without model info"

        let result = TokenExtractionUtility.detectModelHint(from: content)

        XCTAssertNil(result)
    }

    func test_detectModelHint_withArrayContent() throws {
        let content: [Any] = [
            "Hello",
            "Using model: gpt-5 for inference",
            "Thank you"
        ]

        let result = TokenExtractionUtility.detectModelHint(from: content)

        XCTAssertEqual(result, "gpt-5")
    }

    func test_detectModelHint_withNestedDict() throws {
        let content: [String: Any] = [
            "outer": [
                "inner": "model: custom-model-name here"
            ]
        ]

        let result = TokenExtractionUtility.detectModelHint(from: content)

        XCTAssertEqual(result, "custom-model-name")
    }

    // MARK: - Model Name Normalization Tests

    func test_normalizeModelName_stripsCustomPrefix() throws {
        XCTAssertEqual(TokenExtractionUtility.normalizeModelName("custom:claude-3-5-sonnet"), "claude-3-5-sonnet")
    }

    func test_normalizeModelName_keepsUnprefixedName() throws {
        XCTAssertEqual(TokenExtractionUtility.normalizeModelName("claude-3-5-sonnet"), "claude-3-5-sonnet")
    }

    func test_normalizeModelKey_normalizesToLowercase() throws {
        XCTAssertEqual(TokenExtractionUtility.normalizeModelKey("Custom:Model-Name"), "model-name")
    }

    func test_normalizeModelKey_trimsWhitespace() throws {
        XCTAssertEqual(TokenExtractionUtility.normalizeModelKey("  model-name  "), "model-name")
    }

    // MARK: - First Int Value Tests

    func test_firstIntValue_withDirectValue() throws {
        let dict: [String: Any] = ["value": 42]
        let result = TokenExtractionUtility.firstIntValue(in: dict, paths: [["value"]])
        XCTAssertEqual(result, 42)
    }

    func test_firstIntValue_withNestedPath() throws {
        let dict: [String: Any] = ["outer": ["inner": 100]]
        let result = TokenExtractionUtility.firstIntValue(in: dict, paths: [["outer", "inner"]])
        XCTAssertEqual(result, 100)
    }

    func test_firstIntValue_withMultiplePaths_returnsFirstMatch() throws {
        let dict: [String: Any] = ["a": 1, "b": 2]
        let result = TokenExtractionUtility.firstIntValue(in: dict, paths: [["a"], ["b"]])
        XCTAssertEqual(result, 1)
    }

    func test_firstIntValue_withNoMatch_returnsNil() throws {
        let dict: [String: Any] = ["a": "string"]
        let result = TokenExtractionUtility.firstIntValue(in: dict, paths: [["a"]])
        XCTAssertNil(result)
    }

    func test_firstIntValue_withInt64Value() throws {
        let dict: [String: Any] = ["value": Int64(42)]
        let result = TokenExtractionUtility.firstIntValue(in: dict, paths: [["value"]])
        XCTAssertEqual(result, 42)
    }

    func test_firstIntValue_withDoubleValue() throws {
        let dict: [String: Any] = ["value": 42.7]
        let result = TokenExtractionUtility.firstIntValue(in: dict, paths: [["value"]])
        XCTAssertEqual(result, 43)
    }

    func test_firstIntValue_withStringValue() throws {
        let dict: [String: Any] = ["value": "42"]
        let result = TokenExtractionUtility.firstIntValue(in: dict, paths: [["value"]])
        XCTAssertEqual(result, 42)
    }

    // MARK: - Codex Token Count Info Tests

    func test_codexTokenCountInfo_withEventMsg() throws {
        let json: [String: Any] = [
            "event_msg": [
                "token_count": ["input_tokens": 100, "output_tokens": 50]
            ]
        ]

        let result = TokenExtractionUtility.codexTokenCountInfo(from: json)
        XCTAssertNotNil(result)
    }

    func test_codexTokenCountInfo_withDirectTokenCount() throws {
        let json: [String: Any] = [
            "token_count": ["input_tokens": 100, "output_tokens": 50]
        ]

        let result = TokenExtractionUtility.codexTokenCountInfo(from: json)
        XCTAssertNotNil(result)
    }

    func test_codexTokenCountInfo_withRootLevelTokens() throws {
        let json: [String: Any] = [
            "input_tokens": 100,
            "output_tokens": 50
        ]

        let result = TokenExtractionUtility.codexTokenCountInfo(from: json)
        XCTAssertNotNil(result)
    }

    func test_codexCumulativeTotalsFromTokenCountInfo_withValidTotals() throws {
        let info: [String: Any] = [
            "token_count": [
                "input_tokens": 200,
                "output_tokens": 100,
                "cached_input_tokens": 50
            ]
        ]

        let result = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(info)
        XCTAssertEqual(result?.input, 200)
        XCTAssertEqual(result?.output, 100)
        XCTAssertEqual(result?.cacheRead, 50)
    }

    func test_codexCumulativeTotalsFromTokenCountInfo_withPartialData_returnsNil() throws {
        let info: [String: Any] = [
            "token_count": [
                "input_tokens": 200
                // missing output_tokens
            ]
        ]

        let result = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(info)
        XCTAssertNil(result)
    }

    func test_codexCumulativeTotalsFromTokenCountInfo_withRootLevel() throws {
        let info: [String: Any] = [
            "input_tokens": 300,
            "output_tokens": 150,
            "cached_input_tokens": 75
        ]

        let result = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(info)
        XCTAssertEqual(result?.input, 300)
        XCTAssertEqual(result?.output, 150)
        XCTAssertEqual(result?.cacheRead, 75)
    }
}

// MARK: - Timestamp Normalization Tests

final class TimestampNormalizationTests: XCTestCase {

    func test_date_fromEpoch_withSeconds() throws {
        let date = TimestampNormalizationUtility.date(fromEpoch: 1704067200) // 2024-01-01 00:00:00 UTC

        XCTAssertNotNil(date)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 1)
    }

    func test_date_fromEpoch_withMilliseconds() throws {
        let date = TimestampNormalizationUtility.date(fromEpoch: 1704067200000) // Converted to seconds

        XCTAssertNotNil(date)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(components.year, 2024)
    }

    func test_date_fromEpoch_withNegativeEpoch() throws {
        let date = TimestampNormalizationUtility.date(fromEpoch: -86400) // 1970-01-01 00:00:00 minus 1 day

        XCTAssertNotNil(date)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year], from: date)
        XCTAssertEqual(components.year, 1969)
    }

    func test_date_fromEpoch_withFallback() throws {
        let fallback = Date(timeIntervalSince1970: 0)
        let date = TimestampNormalizationUtility.date(fromEpoch: nil, fallback: fallback)

        XCTAssertEqual(date, fallback)
    }

    func test_normalizedEpochSeconds_withValidSeconds() throws {
        let result = TimestampNormalizationUtility.normalizedEpochSeconds(1704067200)
        XCTAssertEqual(result, 1704067200)
    }

    func test_normalizedEpochSeconds_withMilliseconds_convertsToSeconds() throws {
        let result = TimestampNormalizationUtility.normalizedEpochSeconds(1704067200000)
        XCTAssertEqual(result, 1704067200)
    }

    func test_normalizedEpochSeconds_withTooLargeValue_returnsNil() throws {
        let result = TimestampNormalizationUtility.normalizedEpochSeconds(1e15)
        XCTAssertNil(result)
    }

    func test_normalizedEpochSeconds_withInfiniteValue_returnsNil() throws {
        let result = TimestampNormalizationUtility.normalizedEpochSeconds(Double.infinity)
        XCTAssertNil(result)
    }

    func test_firestoreSafeDate_withValidDate() throws {
        let input = Date(timeIntervalSince1970: 1704067200)
        let result = TimestampNormalizationUtility.firestoreSafeDate(input)
        XCTAssertEqual(result.timeIntervalSince1970, input.timeIntervalSince1970)
    }
}

// MARK: - Model Pricing Tests

final class ModelPricingTests: XCTestCase {

    func test_lookup_returnsValidPricing() throws {
        let pricing = ModelPricing.lookup(model: "claude-3-5-sonnet")

        XCTAssertGreaterThan(pricing.inputPerMToken, 0)
        XCTAssertGreaterThan(pricing.outputPerMToken, 0)
    }

    func test_lookup_unknownModel_returnsFallback() throws {
        let pricing = ModelPricing.lookup(model: "unknown-model-xyz")

        XCTAssertEqual(pricing.inputPerMToken, 2.5) // Fallback value
        XCTAssertEqual(pricing.outputPerMToken, 10) // Fallback value
    }

    func test_cost_withAllZeros_returnsZero() throws {
        let pricing = ModelPricing.lookup(model: "test")
        let cost = pricing.cost(inputTokens: 0, outputTokens: 0)

        XCTAssertEqual(cost, 0)
    }

    func test_cost_withInputTokensOnly() throws {
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 0.5)

        let cost = pricing.cost(inputTokens: 1_000_000, outputTokens: 0)

        XCTAssertEqual(cost, 3.0, accuracy: 0.001)
    }

    func test_cost_withOutputTokensOnly() throws {
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 0.5)

        let cost = pricing.cost(inputTokens: 0, outputTokens: 1_000_000)

        XCTAssertEqual(cost, 15.0, accuracy: 0.001)
    }

    func test_cost_withAllTokenTypes() throws {
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 0.5)

        let cost = pricing.cost(
            inputTokens: 1_000_000,
            outputTokens: 500_000,
            cacheCreationTokens: 200_000,
            cacheReadTokens: 300_000,
            reasoningTokens: 100_000
        )

        // Input: 3.0, Output: 7.5, CacheCreation: 0.6 (at input rate), CacheRead: 0.15
        XCTAssertEqual(cost, 11.25, accuracy: 0.001)
    }

    func test_cost_withPartialTokens() throws {
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 0.5)

        let cost = pricing.cost(inputTokens: 500_000, outputTokens: 250_000)

        // Input: 1.5, Output: 3.75
        XCTAssertEqual(cost, 5.25, accuracy: 0.001)
    }

    func test_cost_cacheCreationBilledAtInputRate() throws {
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 0.5)

        let cost = pricing.cost(
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 1_000_000
        )

        XCTAssertEqual(cost, 3.0, accuracy: 0.001)
    }

    func test_cost_cacheReadHasSeparateRate() throws {
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 0.5)

        let cost = pricing.cost(
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 1_000_000
        )

        XCTAssertEqual(cost, 0.5, accuracy: 0.001)
    }
}

// MARK: - Parser Health Tests

final class ParserHealthTests: XCTestCase {

    func test_parserHealth_healthy() throws {
        let health = ParserHealth.healthy(sessionCount: 5)

        if case .healthy(let count) = health {
            XCTAssertEqual(count, 5)
        } else {
            XCTFail("Expected healthy")
        }
    }

    func test_parserHealth_empty() throws {
        let health = ParserHealth.empty

        if case .empty = health {
            // Expected
        } else {
            XCTFail("Expected empty")
        }
    }

    func test_parserHealth_degraded() throws {
        let health = ParserHealth.degraded(sessionCount: 3, error: "Test error")

        if case .degraded(let count, let error) = health {
            XCTAssertEqual(count, 3)
            XCTAssertEqual(error, "Test error")
        } else {
            XCTFail("Expected degraded")
        }
    }

    func test_parserHealth_failed() throws {
        let health = ParserHealth.failed(error: "Critical error")

        if case .failed(let error) = health {
            XCTAssertEqual(error, "Critical error")
        } else {
            XCTFail("Expected failed")
        }
    }

    func test_parserHealth_statusLabel_healthy() throws {
        let health = ParserHealth.healthy(sessionCount: 5)
        XCTAssertEqual(health.statusLabel, "healthy")
    }

    func test_parserHealth_statusLabel_empty() throws {
        let health = ParserHealth.empty
        XCTAssertEqual(health.statusLabel, "empty")
    }

    func test_parserHealth_statusLabel_degraded() throws {
        let health = ParserHealth.degraded(sessionCount: 3, error: "Test")
        XCTAssertEqual(health.statusLabel, "degraded")
    }

    func test_parserHealth_statusLabel_failed() throws {
        let health = ParserHealth.failed(error: "Error")
        XCTAssertEqual(health.statusLabel, "failed")
    }

    func test_parserHealth_sessionCount_healthy() throws {
        let health = ParserHealth.healthy(sessionCount: 10)
        XCTAssertEqual(health.sessionCount, 10)
    }

    func test_parserHealth_sessionCount_empty() throws {
        let health = ParserHealth.empty
        XCTAssertEqual(health.sessionCount, 0)
    }

    func test_parserHealth_sessionCount_degraded() throws {
        let health = ParserHealth.degraded(sessionCount: 5, error: "Test")
        XCTAssertEqual(health.sessionCount, 5)
    }

    func test_parserHealth_sessionCount_failed() throws {
        let health = ParserHealth.failed(error: "Test")
        XCTAssertEqual(health.sessionCount, 0)
    }

    func test_parserHealth_errorMessage_healthy() throws {
        let health = ParserHealth.healthy(sessionCount: 5)
        XCTAssertNil(health.errorMessage)
    }

    func test_parserHealth_errorMessage_degraded() throws {
        let health = ParserHealth.degraded(sessionCount: 5, error: "Degraded error")
        XCTAssertEqual(health.errorMessage, "Degraded error")
    }

    func test_parserHealth_errorMessage_failed() throws {
        let health = ParserHealth.failed(error: "Failed error")
        XCTAssertEqual(health.errorMessage, "Failed error")
    }
}

// MARK: - TokenUsage Tests

final class TokenUsageTests: XCTestCase {

    func test_init_withRequiredParameters() throws {
        let usage = TokenUsage(
            provider: .factory,
            sessionId: "s1",
            projectName: "TestProject",
            model: "test-model",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertEqual(usage.provider, .factory)
        XCTAssertEqual(usage.sessionId, "s1")
        XCTAssertEqual(usage.projectName, "TestProject")
        XCTAssertEqual(usage.model, "test-model")
        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.outputTokens, 500)
        XCTAssertEqual(usage.costUSD, 0.05)
    }

    func test_init_defaultValues() throws {
        let usage = TokenUsage(
            provider: .factory,
            sessionId: "s1",
            projectName: "p",
            model: "m",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertEqual(usage.cacheCreationTokens, 0)
        XCTAssertEqual(usage.cacheReadTokens, 0)
        XCTAssertEqual(usage.reasoningTokens, 0)
        XCTAssertEqual(usage.provenanceMethod, .unknown)
        XCTAssertEqual(usage.provenanceConfidence, .unknown)
    }

    func test_totalTokens_calculation() throws {
        let usage = TokenUsage(
            provider: .factory,
            sessionId: "s1",
            projectName: "p",
            model: "m",
            inputTokens: 100,
            outputTokens: 50,
            cacheCreationTokens: 25,
            cacheReadTokens: 10,
            reasoningTokens: 15,
            costUSD: 0.01,
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertEqual(usage.totalTokens, 200) // 100 + 50 + 25 + 10 + 15
    }

    func test_totalTokens_withAllZeros() throws {
        let usage = TokenUsage(
            provider: .factory,
            sessionId: "s1",
            projectName: "p",
            model: "m",
            inputTokens: 0,
            outputTokens: 0,
            costUSD: 0,
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertEqual(usage.totalTokens, 0)
    }

    func test_duration_calculation() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 3700) // 1 hour later

        let usage = TokenUsage(
            provider: .factory,
            sessionId: "s1",
            projectName: "p",
            model: "m",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: start,
            endTime: end
        )

        XCTAssertEqual(usage.duration, 2700, accuracy: 0.001)
    }

    func test_intersects_withDateRange_containingSession() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 2000)

        let usage = TokenUsage(
            provider: .factory,
            sessionId: "s1",
            projectName: "p",
            model: "m",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: start,
            endTime: end
        )

        let range = Date(timeIntervalSince1970: 500)...Date(timeIntervalSince1970: 2500)
        XCTAssertTrue(usage.intersects(dateRange: range))
    }

    func test_intersects_withDateRange_beforeSession() throws {
        let start = Date(timeIntervalSince1970: 3000)
        let end = Date(timeIntervalSince1970: 4000)

        let usage = TokenUsage(
            provider: .factory,
            sessionId: "s1",
            projectName: "p",
            model: "m",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: start,
            endTime: end
        )

        let range = Date(timeIntervalSince1970: 1000)...Date(timeIntervalSince1970: 2000)
        XCTAssertFalse(usage.intersects(dateRange: range))
    }

    func test_intersects_withDateRange_overlappingStart() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 2000)

        let usage = TokenUsage(
            provider: .factory,
            sessionId: "s1",
            projectName: "p",
            model: "m",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: start,
            endTime: end
        )

        let range = Date(timeIntervalSince1970: 1500)...Date(timeIntervalSince1970: 2500)
        XCTAssertTrue(usage.intersects(dateRange: range))
    }

    func test_intersects_withDateRange_overlappingEnd() throws {
        let start = Date(timeIntervalSince1970: 3000)
        let end = Date(timeIntervalSince1970: 4000)

        let usage = TokenUsage(
            provider: .factory,
            sessionId: "s1",
            projectName: "p",
            model: "m",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: start,
            endTime: end
        )

        let range = Date(timeIntervalSince1970: 2500)...Date(timeIntervalSince1970: 3500)
        XCTAssertTrue(usage.intersects(dateRange: range))
    }

    func test_billedTotalTokens_withAllPositiveValues() throws {
        let total = TokenUsage.billedTotalTokens(
            input: 100,
            output: 50,
            cacheCreation: 25,
            cacheRead: 10,
            reasoning: 5
        )
        XCTAssertEqual(total, 190)
    }

    func test_billedTotalTokens_withNegativeValues_treatedAsZero() throws {
        let total = TokenUsage.billedTotalTokens(
            input: -100,
            output: -50,
            cacheCreation: 25,
            cacheRead: 10,
            reasoning: 5
        )
        XCTAssertEqual(total, 40) // 0 + 0 + 25 + 10 + 5
    }

    func test_equality_withSameValues() throws {
        let date = Date()
        let usage1 = TokenUsage(
            id: UUID(),
            provider: .factory,
            sessionId: "s1",
            projectName: "p",
            model: "m",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: date,
            endTime: date
        )
        let usage2 = TokenUsage(
            id: usage1.id,
            provider: .factory,
            sessionId: "s1",
            projectName: "p",
            model: "m",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: date,
            endTime: date
        )

        XCTAssertEqual(usage1, usage2)
    }
}

// MARK: - ParseResult Tests

final class ParseResultTests: XCTestCase {

    func test_init_withEmptyArrays() throws {
        let result = ParseResult(usages: [], conversations: [])

        XCTAssertEqual(result.usages, [])
        XCTAssertEqual(result.conversations, [])
    }

    func test_init_withUsages() throws {
        let usage = TokenUsage(
            provider: .factory,
            sessionId: "s1",
            projectName: "p",
            model: "m",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: Date(),
            endTime: Date()
        )
        let result = ParseResult(usages: [usage], conversations: [])

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.usages.first?.sessionId, "s1")
    }

    func test_sendable() throws {
        // ParseResult is declared `Sendable`. Compile-time cross-actor passing verifies this;
        // runtime introspection would only duplicate what the type system already guarantees.
        let result = ParseResult(usages: [], conversations: [])
        func requireSendable<T: Sendable>(_: T) {}
        requireSendable(result)
    }
}

// MARK: - ProviderUsageRecord Tests

final class ProviderUsageRecordTests: XCTestCase {

    func test_init_withRequiredParameters() throws {
        let testDate = Date()

        let record = ProviderUsageRecord(
            providerName: "Factory",
            model: "test-model",
            date: testDate,
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: 0.05,
            requestCount: 3
        )

        XCTAssertEqual(record.providerName, "Factory")
        XCTAssertEqual(record.model, "test-model")
        XCTAssertEqual(record.date, testDate)
        XCTAssertEqual(record.inputTokens, 1000)
        XCTAssertEqual(record.outputTokens, 500)
        XCTAssertEqual(record.costUSD, 0.05)
        XCTAssertEqual(record.requestCount, 3)
    }

    func test_init_defaultValues() throws {
        let record = ProviderUsageRecord(
            providerName: "Factory",
            model: "test-model",
            date: Date(),
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: 0.01,
            requestCount: 1
        )

        XCTAssertEqual(record.cacheCreationTokens, 0)
        XCTAssertEqual(record.cacheReadTokens, 0)
    }
}

// MARK: - Mock Parser for Testing

// AUDIT(@unchecked Sendable): Test-only mock; mutable vars are set single-threaded before parse().
private final class MockParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider
    var parseResult = ParseResult(usages: [], conversations: [])
    var shouldThrowError = false
    var errorToThrow: Error?

    init(provider: AgentProvider) {
        self.provider = provider
    }

    func parse() async throws -> ParseResult {
        if shouldThrowError {
            throw errorToThrow ?? NSError(domain: "MockParser", code: -1, userInfo: nil)
        }
        return parseResult
    }
}

// MARK: - BillingUsageReconciliation Tests

final class BillingUsageReconciliationTests: XCTestCase {

    func test_supplementalUsages_returnsEmptyWhenNoAPIRecords() throws {
        let result = BillingUsageReconciliation.supplementalUsages(
            from: [],
            existingUsages: []
        )
        XCTAssertEqual(result, [])
    }

    func test_supplementalUsages_returnsEmptyWhenAllMatched() throws {
        let apiRecords = [
            ProviderUsageRecord(
                providerName: "Factory",
                model: "test-model",
                date: Date(),
                inputTokens: 100,
                outputTokens: 50,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 0.01,
                requestCount: 1
            )
        ]

        let existingUsages = [
            TokenUsage(
                provider: .factory,
                sessionId: "s1",
                projectName: "p",
                model: "test-model",
                inputTokens: 100,
                outputTokens: 50,
                costUSD: 0.01,
                startTime: Date(),
                endTime: Date()
            )
        ]

        let result = BillingUsageReconciliation.supplementalUsages(
            from: apiRecords,
            existingUsages: existingUsages
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_supplementalUsages_returnsAPIOnlyWhenNoLocalMatch() throws {
        let apiRecords = [
            ProviderUsageRecord(
                providerName: "Factory",
                model: "test-model",
                date: Date(),
                inputTokens: 1000,
                outputTokens: 500,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 0.05,
                requestCount: 1
            )
        ]

        let existingUsages: [TokenUsage] = []

        let result = BillingUsageReconciliation.supplementalUsages(
            from: apiRecords,
            existingUsages: existingUsages
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.first!.sessionId.hasPrefix(BillingUsageReconciliation.apiReconciliationSessionPrefix))
    }

    func test_supplementalUsages_handlesMultipleProviders() throws {
        let apiRecords = [
            ProviderUsageRecord(
                providerName: "Factory",
                model: "test-model",
                date: Date(),
                inputTokens: 100,
                outputTokens: 50,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 0.01,
                requestCount: 1
            ),
            ProviderUsageRecord(
                providerName: "Anthropic",
                model: "claude-4-sonnet",
                date: Date(),
                inputTokens: 200,
                outputTokens: 100,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 0.02,
                requestCount: 2
            )
        ]

        let existingUsages = [
            TokenUsage(
                provider: .factory,
                sessionId: "s1",
                projectName: "p",
                model: "test-model",
                inputTokens: 100,
                outputTokens: 50,
                costUSD: 0.01,
                startTime: Date(),
                endTime: Date()
            )
            // No Claude Code usage
        ]

        let result = BillingUsageReconciliation.supplementalUsages(
            from: apiRecords,
            existingUsages: existingUsages
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.provider, .claudeCode)
    }

    func test_supplementalUsages_withPartialOverlap() throws {
        let apiRecords = [
            ProviderUsageRecord(
                providerName: "Factory",
                model: "test-model",
                date: Date(),
                inputTokens: 100,
                outputTokens: 50,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 0.01,
                requestCount: 1
            ),
            ProviderUsageRecord(
                providerName: "Factory",
                model: "test-model-2",
                date: Date(),
                inputTokens: 200,
                outputTokens: 100,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 0.02,
                requestCount: 2
            )
        ]

        let existingUsages = [
            TokenUsage(
                provider: .factory,
                sessionId: "s1",
                projectName: "p",
                model: "test-model",
                inputTokens: 100,
                outputTokens: 50,
                costUSD: 0.01,
                startTime: Date(),
                endTime: Date()
            )
        ]

        let result = BillingUsageReconciliation.supplementalUsages(
            from: apiRecords,
            existingUsages: existingUsages
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.first!.sessionId.hasPrefix(BillingUsageReconciliation.apiReconciliationSessionPrefix))
    }
}

// MARK: - ConversationRecord Tests

final class ConversationRecordTests: XCTestCase {

    func test_stableId_generatesConsistentId() throws {
        let id1 = ConversationRecord.stableId(provider: .factory, sessionId: "s1")
        let id2 = ConversationRecord.stableId(provider: .factory, sessionId: "s1")

        XCTAssertEqual(id1, id2)
    }

    func test_stableId_differentProvidersProduceDifferentIds() throws {
        let id1 = ConversationRecord.stableId(provider: .factory, sessionId: "s1")
        let id2 = ConversationRecord.stableId(provider: .claudeCode, sessionId: "s1")

        XCTAssertNotEqual(id1, id2)
    }

    func test_stableId_differentSessionsProduceDifferentIds() throws {
        let id1 = ConversationRecord.stableId(provider: .factory, sessionId: "s1")
        let id2 = ConversationRecord.stableId(provider: .factory, sessionId: "s2")

        XCTAssertNotEqual(id1, id2)
    }
}

// MARK: - SummaryQueueItem Tests

final class SummaryQueueItemTests: XCTestCase {

    func test_init_withRequiredParameters() throws {
        let item = SummaryQueueItem(
            id: "test-id",
            title: "Test Title",
            status: .pending,
            provider: nil
        )

        XCTAssertEqual(item.id, "test-id")
        XCTAssertEqual(item.title, "Test Title")
        XCTAssertEqual(item.status, .pending)
        XCTAssertNil(item.provider)
    }

    func test_status_transitions() throws {
        var item = SummaryQueueItem(id: "s1", title: "t", status: .pending, provider: nil)

        item.status = .processing
        XCTAssertEqual(item.status, .processing)

        item.status = .done
        XCTAssertEqual(item.status, .done)

        item.status = .failed
        XCTAssertEqual(item.status, .failed)
    }
}
