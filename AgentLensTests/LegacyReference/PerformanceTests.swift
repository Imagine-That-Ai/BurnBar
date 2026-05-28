import Foundation
import XCTest
import GRDB
@testable import OpenBurnBar

// MARK: - Performance Test Configuration

/// Performance thresholds for various operations.
/// These define the maximum acceptable duration for each operation type.
struct PerformanceThresholds {
    /// Maximum time to parse 1000 JSONL lines (in seconds)
    static let parse1000Lines: TimeInterval = 0.5

    /// Maximum time to calculate cost for a single usage record (in seconds)
    static let calculateCost: TimeInterval = 0.001

    /// Maximum time for a database write operation (in seconds)
    static let databaseWrite: TimeInterval = 0.05

    /// Maximum time for a database read operation (in seconds)
    static let databaseRead: TimeInterval = 0.01

    /// Maximum time to process projection pipeline for a single conversation (in seconds)
    static let projectionSingleConversation: TimeInterval = 0.1

    /// Maximum time for semantic search with 100 items (in seconds)
    static let semanticSearch100Items: TimeInterval = 1.0
}

// MARK: - Fixture Data for Performance Tests

/// Large fixture data generators for performance testing
enum PerformanceFixtures {

    /// Generates a large JSONL content for parsing benchmarks
    static func largeJSONLContent(lineCount: Int, tokensPerLine: Int = 100) -> String {
        var lines: [String] = []
        let baseTime = ISO8601DateFormatter().string(from: Date())

        for i in 0..<lineCount {
            let type = i % 2 == 0 ? "user" : "assistant"
            let content = type == "assistant"
                ? #"{"type":"\#(type)","timestamp":"\#(baseTime)","message":{"role":"assistant","content":[{"type":"text","text":"Response \#(i)"}],"usage":{"input_tokens":\#(tokensPerLine),"output_tokens":\#(tokensPerLine)},"model":"claude-sonnet-4-20250514"}}"#
                : #"{"type":"\#(type)","timestamp":"\#(baseTime)","message":{"role":"user","content":[{"type":"text","text":"Query \#(i)"}]}}"#

            lines.append(content)
        }

        return lines.joined(separator: "\n")
    }

    /// Generates a large set of token usages for database benchmarks
    static func generateTokenUsages(count: Int, provider: AgentProvider = .claudeCode) -> [TokenUsage] {
        let baseDate = Date()
        let model = "claude-sonnet-4-20250514"

        return (0..<count).map { index in
            TokenUsage(
                id: UUID(),
                provider: provider,
                sessionId: "perf-session-\(index)",
                projectName: "~/PerformanceTest",
                model: model,
                inputTokens: 100 + (index % 1000),
                outputTokens: 50 + (index % 500),
                cacheCreationTokens: index % 2 == 0 ? 100 : 0,
                cacheReadTokens: index % 3 == 0 ? 200 : 0,
                costUSD: 0.01 + Double(index) * 0.001,
                startTime: baseDate.addingTimeInterval(Double(index)),
                endTime: baseDate.addingTimeInterval(Double(index) + 60)
            )
        }
    }

    /// Generates conversation records for projection benchmarks
    static func generateConversations(count: Int) -> [ConversationRecord] {
        let baseDate = Date()

        return (0..<count).map { index in
            ConversationRecord(
                id: "perf-conv-\(index)",
                provider: .claudeCode,
                sessionId: "perf-session-\(index)",
                projectName: "~/PerformanceTest",
                startTime: baseDate.addingTimeInterval(Double(index) * 3600),
                endTime: baseDate.addingTimeInterval(Double(index) * 3600 + 1800),
                messageCount: 10 + (index % 50),
                userWordCount: 100 + (index % 500),
                assistantWordCount: 500 + (index % 2000),
                keyFiles: ["File\(index % 10).swift", "File\(index % 5).ts"],
                keyCommands: ["command\(index % 3)"],
                keyTools: ["Tool\(index % 4)"],
                inferredTaskTitle: "Performance Test Task \(index)",
                lastAssistantMessage: "This is response \(index) with some meaningful content for testing.",
                fullText: String(repeating: "Word ", count: 100 + (index % 500)),
                indexedAt: Date(),
                fileModifiedAt: nil,
                summary: nil
            )
        }
    }
}

// MARK: - Performance Test Harness

@MainActor
final class PerformanceTestHarness {
    let rootURL: URL
    let databaseQueue: DatabaseQueue
    let dataStore: DataStore
    let fileManager: FileManager

    init(name: String = "performance") throws {
        self.fileManager = .default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("BurnBarPerfTest-\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        rootURL = root

        let dbDirectory = root.appendingPathComponent("db", isDirectory: true)
        try fileManager.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        let dbPath = dbDirectory.appendingPathComponent("test.sqlite")

        databaseQueue = try DatabaseQueue(path: dbPath.path)
        dataStore = try DataStore(
            databaseQueue: databaseQueue,
            runMigrations: true,
            refreshOnInit: false
        )
    }

    func cleanup() {
        try? databaseQueue.close()
        try? fileManager.removeItem(at: rootURL)
    }
}

// MARK: - Performance Tests

@MainActor
final class PerformanceTests: XCTestCase {

    var harness: PerformanceTestHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try PerformanceTestHarness(name: "\(name ?? "unknown")-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        harness.cleanup()
        harness = nil
        try await super.tearDown()
    }

    // MARK: - Parsing Performance Tests

    func test_performance_parseJSONL_throughput1000Lines() throws {
        let content = PerformanceFixtures.largeJSONLContent(lineCount: 1000, tokensPerLine: 100)

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            var totalInput = 0
            var totalOutput = 0

            for line in lines {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let message = json["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else {
                    continue
                }

                totalInput += (usage["input_tokens"] as? Int) ?? 0
                totalOutput += (usage["output_tokens"] as? Int) ?? 0
            }

            XCTAssertGreaterThan(totalInput, 0, "Should parse some tokens")
            XCTAssertGreaterThan(totalOutput, 0, "Should parse some tokens")
        }

        // Verify against threshold
        let content2 = PerformanceFixtures.largeJSONLContent(lineCount: 1000, tokensPerLine: 100)
        let start = CFAbsoluteTimeGetCurrent()
        let lines = content2.components(separatedBy: "\n").filter { !$0.isEmpty }
        var totalInput = 0
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }
            totalInput += (usage["input_tokens"] as? Int) ?? 0
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, PerformanceThresholds.parse1000Lines,
            "Parsing 1000 lines should complete within \(PerformanceThresholds.parse1000Lines)s, took \(String(format: "%.4f", elapsed))s")
    }

    func test_performance_parseJSONL_handlesLargeLines() throws {
        // Simulate a realistic large line with extensive content
        let largeContent = """
        {"type":"assistant","timestamp":"2024-01-15T10:30:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\(String(repeating: "word ", count: 1000))"}],"usage":{"input_tokens":5000,"output_tokens":8000},"model":"claude-sonnet-4-20250514"}}
        """

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            guard let data = largeContent.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                XCTFail("Should parse large content")
                return
            }

            let inputTokens = (usage["input_tokens"] as? Int) ?? 0
            let outputTokens = (usage["output_tokens"] as? Int) ?? 0

            XCTAssertEqual(inputTokens, 5000)
            XCTAssertEqual(outputTokens, 8000)
        }
    }

    // MARK: - Cost Calculation Performance Tests

    func test_performance_calculateCost_singleRecord() throws {
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "test",
            projectName: "~/Test",
            model: "claude-sonnet-4-20250514",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheCreationTokens: 500_000,
            cacheReadTokens: 2_000_000,
            startTime: Date(),
            endTime: Date()
        )

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            let pricing = ModelPricing.lookup(model: usage.model)
            let cost = pricing.cost(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheCreationTokens: usage.cacheCreationTokens,
                cacheReadTokens: usage.cacheReadTokens
            )

            XCTAssertGreaterThan(cost, 0, "Should calculate a positive cost")
        }
    }

    func test_performance_calculateCost_batch1000Records() throws {
        let usages = PerformanceFixtures.generateTokenUsages(count: 1000)

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            var totalCost: Double = 0
            for usage in usages {
                let pricing = ModelPricing.lookup(model: usage.model)
                totalCost += pricing.cost(
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens
                )
            }

            XCTAssertGreaterThan(totalCost, 0, "Should calculate total cost")
        }
    }

    // MARK: - Database Performance Tests

    func test_performance_databaseWrite_1000Records() throws {
        let usages = PerformanceFixtures.generateTokenUsages(count: 1000)

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            harness.dataStore.replaceUsages(usages)
        }
    }

    func test_performance_databaseRead_fetchAllUsage() throws {
        // First write some data
        let usages = PerformanceFixtures.generateTokenUsages(count: 100)
        harness.dataStore.replaceUsages(usages)

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            let result = try harness.dataStore.fetchAllUsage()
            XCTAssertEqual(result.count, 100)
        }
    }

    func test_performance_databaseRead_filterByProvider() throws {
        // Write mixed provider data
        let claudeUsages = PerformanceFixtures.generateTokenUsages(count: 50, provider: .claudeCode)
        let factoryUsages = PerformanceFixtures.generateTokenUsages(count: 50, provider: .factory)
        harness.dataStore.replaceUsages(claudeUsages + factoryUsages)

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            let result = try harness.databaseQueue.read { db in
                try TokenUsageRecord.filter(Column("provider") == AgentProvider.claudeCode.rawValue).fetchAll(db)
            }

            XCTAssertEqual(result.count, 50)
        }
    }

    func test_performance_databaseAggregation_groupByDay() throws {
        // Write usages across multiple days
        let usages = PerformanceFixtures.generateTokenUsages(count: 365)
        harness.dataStore.replaceUsages(usages)

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            let result = try harness.databaseQueue.read { db in
                let sql = """
                    SELECT date(startTime) as day, SUM(costUSD) as totalCost, COUNT(*) as count
                    FROM tokenUsageRecord
                    GROUP BY date(startTime)
                    """
                return try Row.fetchAll(db, sql: sql)
            }

            XCTAssertGreaterThan(result.count, 0, "Should have grouped data")
        }
    }

    // MARK: - Projection Pipeline Performance Tests

    func test_performance_projection_singleConversation() throws {
        let conversations = PerformanceFixtures.generateConversations(count: 1)

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            guard let conversation = conversations.first else {
                XCTFail("Should have a conversation")
                return
            }

            // Simulate projection pipeline processing
            let projection = ProjectionResult(
                conversationId: conversation.id,
                provider: conversation.provider,
                sessionId: conversation.sessionId,
                projectName: conversation.projectName,
                startTime: conversation.startTime,
                endTime: conversation.endTime,
                messageCount: conversation.messageCount,
                userWordCount: conversation.userWordCount,
                assistantWordCount: conversation.assistantWordCount,
                keyFiles: conversation.keyFiles,
                keyCommands: conversation.keyCommands,
                keyTools: conversation.keyTools,
                inferredTaskTitle: conversation.inferredTaskTitle,
                lastAssistantMessage: conversation.lastAssistantMessage,
                fullTextWordCount: conversation.fullText.split(separator: " ").count,
                messageDensity: Double(conversation.messageCount) / max(1.0, conversation.fullText.split(separator: " ").count),
                createdAt: Date()
            )

            XCTAssertEqual(projection.conversationId, conversation.id)
        }
    }

    func test_performance_projection_batch100Conversations() throws {
        let conversations = PerformanceFixtures.generateConversations(count: 100)

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            var projections: [ProjectionResult] = []

            for conversation in conversations {
                let projection = ProjectionResult(
                    conversationId: conversation.id,
                    provider: conversation.provider,
                    sessionId: conversation.sessionId,
                    projectName: conversation.projectName,
                    startTime: conversation.startTime,
                    endTime: conversation.endTime,
                    messageCount: conversation.messageCount,
                    userWordCount: conversation.userWordCount,
                    assistantWordCount: conversation.assistantWordCount,
                    keyFiles: conversation.keyFiles,
                    keyCommands: conversation.keyCommands,
                    keyTools: conversation.keyTools,
                    inferredTaskTitle: conversation.inferredTaskTitle,
                    lastAssistantMessage: conversation.lastAssistantMessage,
                    fullTextWordCount: conversation.fullText.split(separator: " ").count,
                    messageDensity: Double(conversation.messageCount) / max(1.0, conversation.fullText.split(separator: " ").count),
                    createdAt: Date()
                )
                projections.append(projection)
            }

            XCTAssertEqual(projections.count, 100)
        }
    }

    // MARK: - String Processing Performance Tests

    func test_performance_stringProcessing_projectPathDecoding() throws {
        let encodedPaths = (0..<1000).map { i in
            "-Users-\(String(repeating: "Folder\(i % 10)", count: 5))"
        }

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            for encoded in encodedPaths {
                var segments: [String] = []
                var currentSegment = ""
                let pathAfterPrefix = String(encoded.dropFirst(7))

                for (index, char) in pathAfterPrefix.enumerated() {
                    if char == "-" && index + 1 < pathAfterPrefix.count {
                        let nextIndex = pathAfterPrefix.index(pathAfterPrefix.startIndex, offsetBy: index + 1)
                        let nextChar = pathAfterPrefix[nextIndex]
                        if nextChar.isUppercase {
                            if !currentSegment.isEmpty {
                                segments.append(currentSegment)
                            }
                            currentSegment = ""
                        } else {
                            currentSegment.append(char)
                        }
                    } else {
                        currentSegment.append(char)
                    }
                }
                if !currentSegment.isEmpty {
                    segments.append(currentSegment)
                }
            }
        }
    }

    func test_performance_stringProcessing_regexAPIKeyScrubbing() throws {
        let sampleLogs = (0..<100).map { i in
            """
            Processing request with API key sk-ant-xxxxx\(i) for model claude-sonnet-4
            User query: Hello, help me with code
            Response generated successfully
            """
        }

        let apiKeyPattern = #"sk-[a-zA-Z0-9]{20,}"#

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            for log in sampleLogs {
                if let regex = try? NSRegularExpression(pattern: apiKeyPattern) {
                    let range = NSRange(log.startIndex..., in: log)
                    let scrubbed = regex.stringByReplacingMatches(in: log, range: range, withTemplate: "[REDACTED]")
                    XCTAssertTrue(scrubbed.contains("[REDACTED]"))
                }
            }
        }
    }

    // MARK: - JSON Serialization Performance Tests

    func test_performance_JSONSerialization_encodeTokenUsage() throws {
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "test-session-123",
            projectName: "~/TestProject",
            model: "claude-sonnet-4-20250514",
            inputTokens: 1000,
            outputTokens: 500,
            cacheCreationTokens: 100,
            cacheReadTokens: 200,
            startTime: Date(),
            endTime: Date()
        )

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(usage)
            XCTAssertGreaterThan(data.count, 0)
        }
    }

    func test_performance_JSONSerialization_decodeTokenUsage() throws {
        let jsonString = """
        {"id":"550e8400-e29b-41d4-a716-446655440000","provider":"claudeCode","sessionId":"test-123","projectName":"~/Test","model":"claude-sonnet-4-20250514","inputTokens":1000,"outputTokens":500,"cacheCreationTokens":100,"cacheReadTokens":200,"totalTokens":1800,"cost":0.015,"startTime":"2024-01-15T10:00:00Z","endTime":"2024-01-15T10:05:00Z","createdAt":"2024-01-15T10:05:00Z","sourceDeviceId":null,"sourceDeviceName":null,"isRemote":false}
        """
        let data = jsonString.data(using: .utf8)!

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let usage = try decoder.decode(TokenUsage.self, from: data)
            XCTAssertEqual(usage.inputTokens, 1000)
        }
    }

    func test_performance_JSONSerialization_batch100Usages() throws {
        let usages = PerformanceFixtures.generateTokenUsages(count: 100)

        measure(metrics: [XCTPerformanceMetric.wallClockTime]) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(usages)
            XCTAssertGreaterThan(data.count, 0)
        }
    }

    // MARK: - Memory Pressure Tests

    func test_performance_memoryHandling_largeCorpusSimulation() throws {
        // Simulate processing a large corpus (1000 sessions, 100 messages each)
        let sessionCount = 1000
        let messagesPerSession = 100

        measure(metrics: [XCTPerformanceMetric.wallClockTime, XCTPerformanceMetric.memory]) {
            var totalTokens = 0

            for sessionIndex in 0..<sessionCount {
                var sessionTokens = 0

                for messageIndex in 0..<messagesPerSession {
                    let content = #"{"type":"assistant","timestamp":"2024-01-15T10:30:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Response \#(messageIndex)"}],"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-sonnet-4-20250514"}}"#

                    if let data = content.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let message = json["message"] as? [String: Any],
                       let usage = message["usage"] as? [String: Any] {
                        let input = (usage["input_tokens"] as? Int) ?? 0
                        let output = (usage["output_tokens"] as? Int) ?? 0
                        sessionTokens += input + output
                    }
                }

                totalTokens += sessionTokens
            }

            XCTAssertEqual(totalTokens, sessionCount * messagesPerSession * 150)
        }
    }

    // MARK: - Benchmark Summary Test

    func test_benchmarkSummary_allOperations() throws {
        // This test provides a summary of all performance metrics
        // Run this to get a quick overview of system performance

        var results: [(String, TimeInterval)] = []

        // 1. Parse throughput
        let parseStart = CFAbsoluteTimeGetCurrent()
        let parseContent = PerformanceFixtures.largeJSONLContent(lineCount: 1000)
        let parseLines = parseContent.components(separatedBy: "\n").filter { !$0.isEmpty }
        var parsedCount = 0
        for line in parseLines {
            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["message"] != nil {
                parsedCount += 1
            }
        }
        results.append(("Parse 1000 lines", CFAbsoluteTimeGetCurrent() - parseStart))

        // 2. Cost calculation
        let costStart = CFAbsoluteTimeGetCurrent()
        let usages = PerformanceFixtures.generateTokenUsages(count: 1000)
        for usage in usages {
            _ = ModelPricing.lookup(model: usage.model)
        }
        results.append(("1000 cost lookups", CFAbsoluteTimeGetCurrent() - costStart))

        // 3. JSON encoding
        let encodeStart = CFAbsoluteTimeGetCurrent()
        let encoder = JSONEncoder()
        for usage in usages.prefix(100) {
            _ = try? encoder.encode(usage)
        }
        results.append(("100 JSON encodes", CFAbsoluteTimeGetCurrent() - encodeStart))

        // Print summary
        print("\n=== Performance Benchmark Summary ===")
        for (name, time) in results {
            print("\(name): \(String(format: "%.4f", time))s")
        }
        print("===================================\n")

        // Verify all results are reasonable
        for (name, time) in results {
            XCTAssertLessThan(time, 5.0, "\(name) should complete in under 5 seconds")
        }
    }
}

// MARK: - Projection Result (for testing)

/// Result type from projection pipeline processing
struct ProjectionResult: Codable, Sendable {
    let conversationId: String
    let provider: AgentProvider
    let sessionId: String
    let projectName: String
    let startTime: Date
    let endTime: Date
    let messageCount: Int
    let userWordCount: Int
    let assistantWordCount: Int
    let keyFiles: [String]
    let keyCommands: [String]
    let keyTools: [String]
    let inferredTaskTitle: String
    let lastAssistantMessage: String?
    let fullTextWordCount: Int
    let messageDensity: Double
    let createdAt: Date
}
