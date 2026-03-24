import XCTest
import GRDB
@testable import BurnBar

@MainActor
final class AgentLensTests: XCTestCase {

    func test_rollingDailyAverage_sevenDays() throws {
        let store = DataStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var usages: [TokenUsage] = []
        for d in 1...7 {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            usages.append(
                TokenUsage(
                    provider: .factory,
                    sessionId: "s\(d)",
                    projectName: "p",
                    model: "m",
                    inputTokens: 100,
                    outputTokens: 100,
                    costUSD: Double(d),
                    startTime: day.addingTimeInterval(3600),
                    endTime: day.addingTimeInterval(7200)
                )
            )
        }
        store.replaceUsages(usages)
        let expected = (1.0 + 2.0 + 3.0 + 4.0 + 5.0 + 6.0 + 7.0) / 7.0
        XCTAssertEqual(store.rollingDailyAverage, expected, accuracy: 0.0001)
    }

    func test_rollingDailyAverage_zeroFillsMissingDays() throws {
        let store = DataStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var usages: [TokenUsage] = []
        for d in [1, 3, 5] {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            usages.append(
                TokenUsage(
                    provider: .factory,
                    sessionId: "s\(d)",
                    projectName: "p",
                    model: "m",
                    inputTokens: 10,
                    outputTokens: 10,
                    costUSD: 10,
                    startTime: day.addingTimeInterval(100),
                    endTime: day.addingTimeInterval(200)
                )
            )
        }
        store.replaceUsages(usages)
        XCTAssertEqual(store.rollingDailyAverage, 30.0 / 7.0, accuracy: 0.0001)
    }

    func test_moodBand_light() {
        let store = DataStore()
        store.replaceUsages(moodFixture(today: 0.5, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .light)
    }

    func test_moodBand_onPace() {
        let store = DataStore()
        store.replaceUsages(moodFixture(today: 1.0, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .onPace)
    }

    func test_moodBand_heavy() {
        let store = DataStore()
        store.replaceUsages(moodFixture(today: 2.0, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .heavy)
    }

    func test_moodBand_baseline() {
        let store = DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u = TokenUsage(
            provider: .factory,
            sessionId: "a",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 1,
            startTime: day.addingTimeInterval(10),
            endTime: day.addingTimeInterval(20)
        )
        store.replaceUsages([u])
        XCTAssertEqual(store.moodBand, .baseline)
    }

    func test_moodBand_quiet() {
        let store = DataStore()
        store.replaceUsages(moodFixture(today: 0, rollingAvg: 5))
        XCTAssertEqual(store.moodBand, .quiet)
    }

    func test_moodBand_zeroAverage() {
        let store = DataStore()
        let cal = Calendar.current
        let d0 = cal.startOfDay(for: Date())
        let d1 = cal.date(byAdding: .day, value: -1, to: d0)!
        let older = TokenUsage(
            provider: .factory,
            sessionId: "old",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0,
            startTime: d1.addingTimeInterval(10),
            endTime: d1.addingTimeInterval(20)
        )
        let today = TokenUsage(
            provider: .factory,
            sessionId: "new",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 3,
            startTime: d0.addingTimeInterval(10),
            endTime: d0.addingTimeInterval(20)
        )
        store.replaceUsages([older, today])
        XCTAssertEqual(store.rollingDailyAverage, 0, accuracy: 0.0001)
        XCTAssertEqual(store.moodBand, .onPace)
    }

    func test_cacheRatio_aboveThreshold() {
        let u = TokenUsage(
            provider: .factory,
            sessionId: "c",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 10,
            cacheCreationTokens: 0,
            cacheReadTokens: 25,
            costUSD: 1,
            startTime: Date(),
            endTime: Date()
        )
        XCTAssertTrue(u.totalTokens > 0)
        XCTAssertGreaterThan(Double(u.cacheReadTokens) / Double(u.totalTokens), 0.5)
    }

    func test_cacheRatio_zeroTotal() {
        let u = TokenUsage(
            provider: .factory,
            sessionId: "z",
            projectName: "p",
            model: "m",
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: 0,
            startTime: Date(),
            endTime: Date()
        )
        XCTAssertEqual(u.totalTokens, 0)
    }

    func test_insightCard_zeroInsights() {
        let store = DataStore()
        store.replaceUsages([])
        let insights = InsightEngine.generate(from: store)
        XCTAssertTrue(insights.isEmpty)
    }

    func test_insightCard_oneInsight() {
        let store = DataStore()
        store.replaceUsages(moodFixture(today: 2.0, rollingAvg: 1.0))
        let insights = InsightEngine.generate(from: store)
        XCTAssertTrue(insights.count >= 1)
    }

    func test_narrativeTemplate_noSessions() {
        let store = DataStore()
        store.replaceUsages([])
        let n = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(n.headline.contains("No sessions"))
    }

    func test_narrativeTemplate_oneSessions() {
        let store = DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u = TokenUsage(
            provider: .factory,
            sessionId: "1",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        store.replaceUsages([u, pastDayUsage])
        let n = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(n.headline.hasPrefix("One ") || n.headline.contains("1"))
    }

    func test_narrativeTemplate_nSessions() {
        let store = DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u1 = TokenUsage(
            provider: .factory,
            sessionId: "1",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        let u2 = TokenUsage(
            provider: .claudeCode,
            sessionId: "2",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(300),
            endTime: day.addingTimeInterval(400)
        )
        store.replaceUsages([u1, u2, pastDayUsage])
        let n = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(n.headline.contains("2") || n.headline.contains("sessions"))
    }

    func test_narrativeTemplate_countsDistinctSessionIds() {
        let store = DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u1 = TokenUsage(
            provider: .factory,
            sessionId: "dup-session",
            projectName: "p",
            model: "claude-sonnet",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        let u2 = TokenUsage(
            provider: .factory,
            sessionId: "dup-session",
            projectName: "p",
            model: "claude-opus",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(300),
            endTime: day.addingTimeInterval(400)
        )
        store.replaceUsages([u1, u2, pastDayUsage])
        let n = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(n.headline.hasPrefix("One "))
    }

    func test_insightCard_newSessions_countsDistinctSessionIds() {
        let store = DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u1 = TokenUsage(
            provider: .factory,
            sessionId: "dup-session",
            projectName: "p",
            model: "claude-sonnet",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        let u2 = TokenUsage(
            provider: .factory,
            sessionId: "dup-session",
            projectName: "p",
            model: "claude-opus",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(300),
            endTime: day.addingTimeInterval(400)
        )
        store.replaceUsages([u1, u2, pastDayUsage])

        let insights = InsightEngine.generate(from: store)
        let newSessions = insights.first(where: { $0.type == .newSessions })
        XCTAssertEqual(newSessions?.metric, 1)
    }

    func test_narrativeTemplate_collapsesClaudeSubagentSessionIds() {
        let store = DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let topLevel = TokenUsage(
            provider: .claudeCode,
            sessionId: "root-session",
            projectName: "p",
            model: "claude-opus-4-6",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        let subagent = TokenUsage(
            provider: .claudeCode,
            sessionId: "root-session/agent-abc123",
            projectName: "p",
            model: "claude-opus-4-6",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(300),
            endTime: day.addingTimeInterval(400)
        )
        store.replaceUsages([topLevel, subagent, pastDayUsage])
        let narrative = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(narrative.headline.hasPrefix("One "))
    }

    func test_sparklineData_alwaysSevenPoints() {
        let store = DataStore()
        XCTAssertEqual(store.last7DayCosts.count, 7)
    }

    func test_modelPricing_knownModel() {
        let p = ModelPricing.lookup(model: "claude-3-5-sonnet")
        XCTAssertEqual(p.inputPerMToken, 3, accuracy: 0.001)
        XCTAssertEqual(p.outputPerMToken, 15, accuracy: 0.001)
    }

    func test_insightEngine_structuredFields() {
        let store = DataStore()
        store.replaceUsages(moodFixture(today: 1.0, rollingAvg: 1.0))
        let insights = InsightEngine.generate(from: store)
        XCTAssertFalse(insights.isEmpty)
        let first = insights[0]
        XCTAssertFalse(first.headline.isEmpty)
        XCTAssertFalse(first.icon.isEmpty)
    }

    func test_cliBridge_parseExecutablePath_prefersAbsolutePathLine() {
        let output = """
        Loading shell config...
        /Users/tester/.nvm/versions/node/v24.14.0/bin/codex
        """

        XCTAssertEqual(
            CLIBridge.parseExecutablePath(fromCommandOutput: output),
            "/Users/tester/.nvm/versions/node/v24.14.0/bin/codex"
        )
    }

    func test_cliBridge_claudeArguments_includeVerboseForStreamJSON() {
        XCTAssertEqual(
            CLIBridge.claudeArguments(prompt: "hello"),
            ["-p", "hello", "--output-format", "stream-json", "--verbose"]
        )
    }

    func test_cliBridge_codexArguments_defaultModelAndReasoning() {
        XCTAssertEqual(
            CLIBridge.codexArguments(prompt: "hello"),
            [
                "exec",
                "--json",
                "--ephemeral",
                "--skip-git-repo-check",
                "-m",
                "gpt-5.4-mini",
                "-c",
                #"model_reasoning_effort="medium""#,
                "hello"
            ]
        )
    }

    func test_cliBridge_userManagedSearchDirectories_includeNodeManagerBins() throws {
        let fileManager = FileManager.default
        let tempHome = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: tempHome) }

        let nvmBin = tempHome.appendingPathComponent(".nvm/versions/node/v24.14.0/bin", isDirectory: true)
        let fnmBin = tempHome.appendingPathComponent(".fnm/node-versions/v22.12.0/installation/bin", isDirectory: true)
        try fileManager.createDirectory(at: nvmBin, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: fnmBin, withIntermediateDirectories: true, attributes: nil)

        let directories = CLIBridge.userManagedExecutableSearchDirectories(
            homeDirectory: tempHome.path,
            fileManager: fileManager
        )

        XCTAssertTrue(directories.contains(nvmBin.path))
        XCTAssertTrue(directories.contains(fnmBin.path))
    }

    func test_cliBridge_resolveExecutable_findsVersionManagerInstall() throws {
        let fileManager = FileManager.default
        let tempHome = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: tempHome) }

        let codexPath = tempHome
            .appendingPathComponent(".nvm/versions/node/v24.14.0/bin/codex")
        try fileManager.createDirectory(
            at: codexPath.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let created = fileManager.createFile(
            atPath: codexPath.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: 0o755]
        )
        XCTAssertTrue(created)

        let directories = CLIBridge.userManagedExecutableSearchDirectories(
            homeDirectory: tempHome.path,
            fileManager: fileManager
        )

        XCTAssertEqual(
            CLIBridge.resolveExecutable(
                named: "codex",
                searchDirectories: directories,
                fileManager: fileManager
            ),
            codexPath.path
        )
    }

    func test_fileHandleReadLine_returnsNilAtEOF() throws {
        let fileManager = FileManager.default
        let tempFile = fileManager.temporaryDirectory
            .appendingPathComponent("readline-\(UUID().uuidString).txt")
        defer { try? fileManager.removeItem(at: tempFile) }

        let created = fileManager.createFile(
            atPath: tempFile.path,
            contents: Data("first\n\nthird".utf8),
            attributes: nil
        )
        XCTAssertTrue(created)

        let handle = try FileHandle(forReadingFrom: tempFile)
        defer { try? handle.close() }

        XCTAssertEqual(handle.readLine(), "first")
        XCTAssertEqual(handle.readLine(), "")
        XCTAssertEqual(handle.readLine(), "third")
        XCTAssertNil(handle.readLine())
    }

    // MARK: - Fixtures

    private var pastDayUsage: TokenUsage {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let y = cal.date(byAdding: .day, value: -1, to: today)!
        return TokenUsage(
            provider: .factory,
            sessionId: "past",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 1,
            startTime: y.addingTimeInterval(10),
            endTime: y.addingTimeInterval(20)
        )
    }

    private func moodFixture(today: Double, rollingAvg: Double) -> [TokenUsage] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        var list: [TokenUsage] = []
        for d in 1...7 {
            let day = cal.date(byAdding: .day, value: -d, to: todayStart)!
            let cost = rollingAvg
            list.append(
                TokenUsage(
                    provider: .factory,
                    sessionId: "s\(d)",
                    projectName: "p",
                    model: "m",
                    inputTokens: 10,
                    outputTokens: 10,
                    costUSD: cost,
                    startTime: day.addingTimeInterval(100),
                    endTime: day.addingTimeInterval(200)
                )
            )
        }
        if today > 0 {
            list.append(
                TokenUsage(
                    provider: .factory,
                    sessionId: "today",
                    projectName: "p",
                    model: "m",
                    inputTokens: 10,
                    outputTokens: 10,
                    costUSD: today,
                    startTime: todayStart.addingTimeInterval(5000),
                    endTime: todayStart.addingTimeInterval(6000)
                )
            )
        }
        return list
    }
}

private struct RetrievalReplayGoldenSnapshot: Codable, Equatable {
    let scenario: String
    let query: String
    let resultSourceIDs: [String]
    let topResults: [ReplayResultShape]
}

private struct ReplayResultShape: Codable, Equatable {
    let rank: Int
    let sourceID: String
    let sourceKind: String
    let title: String
    let hasLexicalSignal: Bool
    let hasSemanticSignal: Bool
}

private struct RetrievalDegradedFallbackGoldenSnapshot: Codable, Equatable {
    let scenario: String
    let query: String
    let resultSourceIDs: [String]
    let lexicalHealthStatus: String?
    let lexicalErrorCode: String?
    let semanticHealthStatus: String?
    let semanticErrorCode: String?
    let degradedModes: [String]
}

private struct RetrievalFilterGoldenSnapshot: Codable, Equatable {
    let scenario: String
    let query: String
    let cases: [RetrievalFilterCaseSnapshot]
}

private struct RetrievalFilterCaseSnapshot: Codable, Equatable {
    let name: String
    let sourceIDs: [String]
}

private struct RetrievalANNBaselineGoldenSnapshot: Codable, Equatable {
    let scenario: String
    let query: String
    let annTopCandidates: [SemanticCandidateSnapshot]
    let exactTopCandidates: [SemanticCandidateSnapshot]
}

private struct SemanticCandidateSnapshot: Codable, Equatable {
    let sourceID: String
    let score: Double
}

private struct AuthoringReplayGoldenSnapshot: Codable, Equatable {
    let scenario: String
    let cases: [AuthoringReplayCaseSnapshot]
}

private struct AuthoringReplayCaseSnapshot: Codable, Equatable {
    let name: String
    let sourceKind: String
    let operation: String
    let retrievalQuery: String
    let referenceSourceIDs: [String]
    let referenceKinds: [String]
    let hasGroundingInstruction: Bool
    let hasReferenceLabel: Bool
    let includesExistingMarkdownBlock: Bool
    let generatedHasGroundingSection: Bool
    let generatedHasReferenceCitation: Bool
}

private enum BurnBarReplayGoldens {
    private static let updateEnvironmentKey = "BURNBAR_UPDATE_GOLDENS"

    static func assertGolden<T: Codable & Equatable>(
        _ actual: T,
        fixtureFile: String,
        sourceFilePath: StaticString = #filePath,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixtureURL = makeFixtureURL(fixtureFile: fixtureFile, sourceFilePath: sourceFilePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let actualData = try encoder.encode(actual)

        if ProcessInfo.processInfo.environment[updateEnvironmentKey] == "1" {
            try FileManager.default.createDirectory(
                at: fixtureURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try actualData.write(to: fixtureURL, options: .atomic)
            return
        }

        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            try FileManager.default.createDirectory(
                at: fixtureURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try actualData.write(to: fixtureURL, options: .atomic)
            XCTFail(
                "Missing golden fixture at \(fixtureURL.path). Wrote a candidate fixture; re-run tests to validate.",
                file: file,
                line: line
            )
            return
        }

        let expectedData = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        let expected = try decoder.decode(T.self, from: expectedData)
        guard expected == actual else {
            let actualJSON = String(data: actualData, encoding: .utf8) ?? "<unprintable>"
            XCTFail(
                "Golden mismatch for \(fixtureFile).\nActual payload:\n\(actualJSON)",
                file: file,
                line: line
            )
            return
        }
    }

    private static func makeFixtureURL(
        fixtureFile: String,
        sourceFilePath: StaticString
    ) -> URL {
        let sourceURL = URL(fileURLWithPath: sourceFilePath.description)
        return sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ReplayGoldens", isDirectory: true)
            .appendingPathComponent(fixtureFile, isDirectory: false)
    }
}

@MainActor
private final class ReplayStubSemanticCandidateProvider: SemanticCandidateProviding {
    enum StubError: Error {
        case forced
    }

    var responses: [String: [SemanticCandidate]]
    var shouldThrow = false

    init(responses: [String: [SemanticCandidate]] = [:]) {
        self.responses = responses
    }

    func semanticCandidates(for query: String, filters _: RetrievalFilters, limit: Int) async throws -> [SemanticCandidate] {
        if shouldThrow {
            throw StubError.forced
        }
        return Array((responses[query] ?? []).prefix(max(0, limit)))
    }
}

@MainActor
private final class ReplayStubArtifactAuthoringTextGenerator: ArtifactAuthoringTextGenerating {
    struct Call {
        let systemPrompt: String
        let userPrompt: String
    }

    private let responses: [String]
    private var responseIndex = 0
    private(set) var calls: [Call] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func generate(systemPrompt: String, userPrompt: String) async throws -> String {
        calls.append(Call(systemPrompt: systemPrompt, userPrompt: userPrompt))
        guard responses.isEmpty == false else {
            return "# Empty\n\n## Grounding\n- [R1] No response fixture configured."
        }
        let index = min(responseIndex, responses.count - 1)
        responseIndex += 1
        return responses[index]
    }
}

@MainActor
final class BurnBarRetrievalReplayGoldenTests: XCTestCase {
    func test_replayGolden_lexicalWin() async throws {
        let harness = try BurnBarSearchIntegrationHarness(name: "replay-lexical-win")
        defer { harness.cleanup() }

        let lexicalConversation = harness.makeConversationFixture(
            id: "conv-replay-lexical",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "Discussion about quartzwind rollout and release hardening."
        )
        let semanticConversation = harness.makeConversationFixture(
            id: "conv-replay-semantic",
            provider: .codex,
            projectName: "Beta",
            fullText: "This thread focuses on runtime migration and queue tuning."
        )

        try harness.dataStore.upsertConversation(lexicalConversation)
        try harness.dataStore.upsertConversation(semanticConversation)
        _ = try harness.enqueueConversationProjection(conversationID: lexicalConversation.id, jobType: .project)
        _ = try harness.enqueueConversationProjection(conversationID: semanticConversation.id, jobType: .project)
        _ = try harness.drainProjectionQueue(maxSweeps: 6, maxJobsPerSweep: 32, advanceClockBy: 1)

        let semanticDoc = try XCTUnwrap(
            try harness.dataStore.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == semanticConversation.id })
        )
        let semanticChunk = try XCTUnwrap(try harness.dataStore.fetchSearchChunks(documentID: semanticDoc.id).first)

        let semanticProvider = ReplayStubSemanticCandidateProvider(
            responses: [
                "quartzwind": [SemanticCandidate(chunkID: semanticChunk.id, score: 0.99)]
            ]
        )
        let retrieval = SearchService(
            dataStore: harness.dataStore,
            semanticProvider: semanticProvider,
            sharedArtifactAccessContextProvider: { harness.sharedAccessContext },
            nowProvider: { harness.clock.now() }
        )

        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "quartzwind",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                resultLimit: 10
            )
        )

        let snapshot = RetrievalReplayGoldenSnapshot(
            scenario: "lexical-win",
            query: "quartzwind",
            resultSourceIDs: results.map(\.sourceID),
            topResults: summarize(results, limit: 4)
        )
        try BurnBarReplayGoldens.assertGolden(snapshot, fixtureFile: "retrieval-lexical-win.json")
    }

    func test_replayGolden_semanticRescue() async throws {
        let harness = try BurnBarSearchIntegrationHarness(name: "replay-semantic-rescue")
        defer { harness.cleanup() }

        let artifact = harness.makeSkillArtifactFixture(
            id: "artifact-semantic-rescue",
            relativePath: "skills/BOOTSTRAP.md",
            title: "Bootstrap skill",
            body: "Workstation bootstrap checklist for new machine setup."
        )

        _ = try harness.dataStore.upsertSourceArtifact(artifact)
        _ = try harness.enqueueArtifactProjection(artifact, jobType: .project)
        _ = try harness.drainProjectionQueue(maxSweeps: 6, maxJobsPerSweep: 32, advanceClockBy: 1)

        let document = try XCTUnwrap(
            try harness.dataStore.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == artifact.id })
        )
        let chunk = try XCTUnwrap(try harness.dataStore.fetchSearchChunks(documentID: document.id).first)

        let semanticProvider = ReplayStubSemanticCandidateProvider(
            responses: [
                "onboarding runbook": [SemanticCandidate(chunkID: chunk.id, score: 0.92)]
            ]
        )
        let retrieval = SearchService(
            dataStore: harness.dataStore,
            semanticProvider: semanticProvider,
            sharedArtifactAccessContextProvider: { harness.sharedAccessContext },
            nowProvider: { harness.clock.now() }
        )
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "onboarding runbook",
                filters: RetrievalFilters(artifactTypes: [.skillDoc]),
                resultLimit: 10
            )
        )

        let snapshot = RetrievalReplayGoldenSnapshot(
            scenario: "semantic-rescue",
            query: "onboarding runbook",
            resultSourceIDs: results.map(\.sourceID),
            topResults: summarize(results, limit: 4)
        )
        try BurnBarReplayGoldens.assertGolden(snapshot, fixtureFile: "retrieval-semantic-rescue.json")
    }

    func test_replayGolden_degradedModeFallback() async throws {
        let harness = try BurnBarSearchIntegrationHarness(name: "replay-degraded-fallback")
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-semantic-fallback",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "Rollout hardening checklist for lexical fallback coverage."
        )
        try harness.dataStore.upsertConversation(conversation)
        _ = try harness.enqueueConversationProjection(conversationID: conversation.id, jobType: .project)
        _ = try harness.drainProjectionQueue(maxSweeps: 6, maxJobsPerSweep: 32, advanceClockBy: 1)

        let semanticProvider = ReplayStubSemanticCandidateProvider()
        semanticProvider.shouldThrow = true
        let retrieval = SearchService(
            dataStore: harness.dataStore,
            semanticProvider: semanticProvider,
            sharedArtifactAccessContextProvider: { harness.sharedAccessContext },
            nowProvider: { harness.clock.now() }
        )
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "hardening checklist",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                resultLimit: 10
            )
        )

        let lexicalHealth = try harness.retrievalHealthRecord(for: .lexical)
        let semanticHealth = try harness.retrievalHealthRecord(for: .semantic)
        let degradedModes = harness
            .healthSnapshot(indexingEnabled: true, sharedFeaturesAvailable: true)
            .degradedModes
            .map(\.mode.rawValue)
            .sorted()

        let snapshot = RetrievalDegradedFallbackGoldenSnapshot(
            scenario: "degraded-fallback",
            query: "hardening checklist",
            resultSourceIDs: results.map(\.sourceID),
            lexicalHealthStatus: lexicalHealth?.status.rawValue,
            lexicalErrorCode: lexicalHealth?.errorCode,
            semanticHealthStatus: semanticHealth?.status.rawValue,
            semanticErrorCode: semanticHealth?.errorCode,
            degradedModes: degradedModes
        )
        try BurnBarReplayGoldens.assertGolden(snapshot, fixtureFile: "retrieval-degraded-fallback.json")
    }

    func test_replayGolden_filterCorrectness() async throws {
        let harness = try BurnBarSearchIntegrationHarness(name: "replay-filter-correctness")
        defer { harness.cleanup() }

        let base = Date(timeIntervalSince1970: 1_742_720_000)

        _ = harness.clock.set(base.addingTimeInterval(-86_400))
        let convClaude = harness.makeConversationFixture(
            id: "conv-filter-claude-alpha",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "filterneedle task continuity and release notes",
            sourceType: .providerLog
        )
        _ = harness.clock.set(base.addingTimeInterval(-40 * 86_400))
        let convCodex = harness.makeConversationFixture(
            id: "conv-filter-codex-beta",
            provider: .codex,
            projectName: "Beta",
            fullText: "filterneedle task continuity and release notes",
            sourceType: .providerLog
        )
        _ = harness.clock.set(base.addingTimeInterval(-2 * 86_400))
        let convCLI = harness.makeConversationFixture(
            id: "conv-filter-cli-alpha",
            provider: .factory,
            projectName: "Alpha",
            fullText: "filterneedle task continuity and release notes",
            sourceType: .cliAssistant
        )
        _ = harness.clock.set(base)

        try harness.dataStore.upsertConversation(convClaude)
        try harness.dataStore.upsertConversation(convCodex)
        try harness.dataStore.upsertConversation(convCLI)
        _ = try harness.enqueueConversationProjection(conversationID: convClaude.id, jobType: .project)
        _ = try harness.enqueueConversationProjection(conversationID: convCodex.id, jobType: .project)
        _ = try harness.enqueueConversationProjection(conversationID: convCLI.id, jobType: .project)

        _ = harness.clock.set(base.addingTimeInterval(-3 * 86_400))
        let skillArtifact = harness.makeSkillArtifactFixture(
            id: "artifact-filter-skill",
            relativePath: "SKILL.md",
            title: "Skill Alpha",
            body: "filterneedle task continuity and release notes"
        )
        _ = harness.clock.set(base.addingTimeInterval(-4 * 86_400))
        let sharedArtifact = harness.makeSharedArtifactFixture(
            id: "artifact-filter-shared",
            relativePath: "SHARED.md",
            title: "Shared Alpha",
            body: "filterneedle task continuity and release notes"
        )
        _ = harness.clock.set(base)

        _ = try harness.dataStore.upsertSourceArtifact(skillArtifact)
        _ = try harness.dataStore.upsertSourceArtifact(sharedArtifact)
        _ = try harness.grantSharedReadAccess(to: sharedArtifact.id)
        _ = try harness.enqueueArtifactProjection(skillArtifact, jobType: .project)
        _ = try harness.enqueueArtifactProjection(sharedArtifact, jobType: .project)
        _ = try harness.drainProjectionQueue(maxSweeps: 8, maxJobsPerSweep: 64, advanceClockBy: 1)

        let retrieval = harness.makeSearchService(semanticEnabled: false)
        let query = "filterneedle"

        let providerFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(provider: .claudeCode, artifactTypes: [.conversation]),
                resultLimit: 20
            )
        )
        let projectFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(projectName: "Alpha", artifactTypes: [.conversation]),
                resultLimit: 20
            )
        )
        let artifactTypeFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(artifactTypes: [.skillDoc]),
                resultLimit: 20
            )
        )
        let dateRangeFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(
                    artifactTypes: [.conversation],
                    dateRange: base.addingTimeInterval(-7 * 86_400)...base
                ),
                resultLimit: 20
            )
        )
        let sharedOnly = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(ownership: .shared),
                resultLimit: 20
            )
        )
        let sourceFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(sourceIDs: [skillArtifact.id]),
                resultLimit: 20
            )
        )
        let conversationSourceFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(artifactTypes: [.conversation], conversationSources: [.cliAssistant]),
                resultLimit: 20
            )
        )

        let snapshot = RetrievalFilterGoldenSnapshot(
            scenario: "filter-correctness",
            query: query,
            cases: [
                RetrievalFilterCaseSnapshot(
                    name: "provider_claude_conversation",
                    sourceIDs: sortedUnique(providerFiltered.map(\.sourceID))
                ),
                RetrievalFilterCaseSnapshot(
                    name: "project_alpha_conversation",
                    sourceIDs: sortedUnique(projectFiltered.map(\.sourceID))
                ),
                RetrievalFilterCaseSnapshot(
                    name: "artifact_type_skill_doc",
                    sourceIDs: sortedUnique(artifactTypeFiltered.map(\.sourceID))
                ),
                RetrievalFilterCaseSnapshot(
                    name: "date_range_recent_conversation",
                    sourceIDs: sortedUnique(dateRangeFiltered.map(\.sourceID))
                ),
                RetrievalFilterCaseSnapshot(
                    name: "ownership_shared_only",
                    sourceIDs: sortedUnique(sharedOnly.map(\.sourceID))
                ),
                RetrievalFilterCaseSnapshot(
                    name: "explicit_source_id",
                    sourceIDs: sortedUnique(sourceFiltered.map(\.sourceID))
                ),
                RetrievalFilterCaseSnapshot(
                    name: "conversation_source_cli_assistant",
                    sourceIDs: sortedUnique(conversationSourceFiltered.map(\.sourceID))
                )
            ]
        )
        try BurnBarReplayGoldens.assertGolden(snapshot, fixtureFile: "retrieval-filter-correctness.json")
    }

    func test_replayGolden_annMatchesExactRerankBaseline() async throws {
        let harness = try BurnBarSearchIntegrationHarness(name: "replay-ann-baseline")
        defer { harness.cleanup() }

        for index in 0..<48 {
            _ = harness.clock.advance(seconds: 1)
            let body: String
            if index % 9 == 0 {
                body = "reliability hardening checklist rollout runbook \(index)"
            } else {
                body = "generic notes \(index) queue metrics stabilization tracking"
            }
            let artifact = harness.makeSkillArtifactFixture(
                id: "artifact-ann-\(index)",
                relativePath: "skills/ann-\(index).md",
                title: "ANN Candidate \(index)",
                body: body
            )
            _ = try harness.dataStore.upsertSourceArtifact(artifact)
            _ = try harness.enqueueArtifactProjection(artifact, jobType: .project)
        }
        _ = try harness.drainProjectionQueue(maxSweeps: 12, maxJobsPerSweep: 128, advanceClockBy: 1)

        let annProvider = VectorSemanticCandidateProvider(
            dataStore: harness.dataStore,
            queryEmbedder: harness.queryEmbedder,
            backend: .ann,
            exactRerankEnabled: true,
            exactRerankLimit: 256,
            annCandidateMultiplier: 24,
            nowProvider: { harness.clock.now() }
        )
        let exactProvider = VectorSemanticCandidateProvider(
            dataStore: harness.dataStore,
            queryEmbedder: harness.queryEmbedder,
            backend: .exact,
            exactRerankEnabled: true,
            exactRerankLimit: 256,
            annCandidateMultiplier: 24,
            nowProvider: { harness.clock.now() }
        )

        let query = "reliability hardening checklist rollout"
        let annCandidates = try await annProvider.semanticCandidates(
            for: query,
            filters: RetrievalFilters(artifactTypes: [.skillDoc]),
            limit: 20
        )
        let exactCandidates = try await exactProvider.semanticCandidates(
            for: query,
            filters: RetrievalFilters(artifactTypes: [.skillDoc]),
            limit: 20
        )

        XCTAssertEqual(annCandidates.map(\.chunkID), exactCandidates.map(\.chunkID))

        let snapshot = RetrievalANNBaselineGoldenSnapshot(
            scenario: "ann-vs-exact-rerank",
            query: query,
            annTopCandidates: try summarizeSemantic(annCandidates, limit: 12, dataStore: harness.dataStore),
            exactTopCandidates: try summarizeSemantic(exactCandidates, limit: 12, dataStore: harness.dataStore)
        )
        try BurnBarReplayGoldens.assertGolden(snapshot, fixtureFile: "retrieval-ann-vs-exact-baseline.json")
    }

    private func summarize(_ results: [RetrievalResult], limit: Int) -> [ReplayResultShape] {
        Array(results.prefix(limit)).enumerated().map { index, result in
            ReplayResultShape(
                rank: index + 1,
                sourceID: result.sourceID,
                sourceKind: result.sourceKind.rawValue,
                title: result.title,
                hasLexicalSignal: result.lexicalRank != nil,
                hasSemanticSignal: result.semanticScore != nil
            )
        }
    }

    private func summarizeSemantic(
        _ candidates: [SemanticCandidate],
        limit: Int,
        dataStore: DataStore
    ) throws -> [SemanticCandidateSnapshot] {
        let boundedCandidates = Array(candidates.prefix(limit))
        let chunkIDs = Array(Set(boundedCandidates.map(\.chunkID)))
        let chunks = try dataStore.fetchSearchChunks(ids: chunkIDs)
        let chunkByID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
        let documentIDs = Array(Set(chunks.map(\.documentID)))
        let documents = try dataStore.fetchSearchDocuments(ids: documentIDs)
        let documentByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

        return boundedCandidates.map { candidate in
            let sourceID = chunkByID[candidate.chunkID]
                .flatMap { documentByID[$0.documentID]?.sourceID } ?? "missing-source"
            return SemanticCandidateSnapshot(
                sourceID: sourceID,
                score: rounded(candidate.score)
            )
        }
    }

    private func rounded(_ value: Double, precision: Double = 1_000_000) -> Double {
        (value * precision).rounded() / precision
    }

    private func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}

@MainActor
final class BurnBarAuthoringReplayGoldenTests: XCTestCase {
    func test_replayGolden_draftAndRefineGrounding() async throws {
        let harness = try BurnBarSearchIntegrationHarness(name: "replay-authoring-grounding")
        defer { harness.cleanup() }

        let now = harness.clock.now()
        let skillContextDocument = SearchDocumentRecord(
            id: "doc-authoring-skill-context",
            sourceKind: .skillDoc,
            sourceID: "artifact-skill-context",
            sourceVersionID: "skill-context-v1",
            provider: nil,
            projectName: "BurnBar",
            title: "Skill Grounding Context",
            subtitle: "SKILL.md",
            bodyPreview: "Skill context for release hardening.",
            sourceUpdatedAt: now,
            indexedAt: now,
            contentHash: "hash-authoring-skill-context",
            createdAt: now,
            updatedAt: now
        )
        try harness.dataStore.upsertSearchDocument(skillContextDocument)
        try harness.dataStore.replaceSearchChunks(
            documentID: skillContextDocument.id,
            title: skillContextDocument.title,
            chunks: [
                SearchChunkRecord(
                    id: "chunk-authoring-skill-context",
                    documentID: skillContextDocument.id,
                    sourceKind: .skillDoc,
                    sourceID: skillContextDocument.sourceID,
                    sourceVersionID: skillContextDocument.sourceVersionID,
                    ordinal: 0,
                    startOffset: 0,
                    endOffset: 140,
                    sectionPath: "Release",
                    text: "skill-grounding-needle release hardening checklist with rollback drills and smoke validations.",
                    createdAt: now,
                    updatedAt: now
                )
            ]
        )

        let agentContextDocument = SearchDocumentRecord(
            id: "doc-authoring-agent-context",
            sourceKind: .agentDoc,
            sourceID: "artifact-agent-context",
            sourceVersionID: "agent-context-v1",
            provider: nil,
            projectName: "BurnBar",
            title: "Agent Grounding Context",
            subtitle: "AGENTS.md",
            bodyPreview: "Agent context for escalation policy.",
            sourceUpdatedAt: now,
            indexedAt: now,
            contentHash: "hash-authoring-agent-context",
            createdAt: now,
            updatedAt: now
        )
        try harness.dataStore.upsertSearchDocument(agentContextDocument)
        try harness.dataStore.replaceSearchChunks(
            documentID: agentContextDocument.id,
            title: agentContextDocument.title,
            chunks: [
                SearchChunkRecord(
                    id: "chunk-authoring-agent-context",
                    documentID: agentContextDocument.id,
                    sourceKind: .agentDoc,
                    sourceID: agentContextDocument.sourceID,
                    sourceVersionID: agentContextDocument.sourceVersionID,
                    ordinal: 0,
                    startOffset: 0,
                    endOffset: 144,
                    sectionPath: "Escalation",
                    text: "agent-grounding-needle escalation policy with handoff rules, ownership boundaries, and response contracts.",
                    createdAt: now,
                    updatedAt: now
                )
            ]
        )

        let generator = ReplayStubArtifactAuthoringTextGenerator(
            responses: [
                """
                # Skill Draft
                Add release hardening checks.

                ## Grounding
                - [R1] Skill context applied.
                """,
                """
                # Skill Refine
                Improve escalation and rollback sections.

                ## Grounding
                - [R1] Agent context applied.
                """,
                """
                # Agent Draft
                Define ownership and escalation boundaries.

                ## Grounding
                - [R1] Agent context applied.
                """,
                """
                # Agent Refine
                Tighten release sequencing and guardrails.

                ## Grounding
                - [R1] Skill context applied.
                """
            ]
        )
        let settings = BurnBarHarnessArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: [harness.fileRoots.registeredProjectRootURL.path],
            artifactDiscoveryAdditionalKnownPatterns: []
        )
        let service = ArtifactAuthoringService(
            dataStore: harness.dataStore,
            retrievalService: harness.makeSearchService(semanticEnabled: false),
            settingsProvider: settings,
            textGenerator: generator,
            nowProvider: { harness.clock.now() }
        )

        let draftSkill = try await service.draftSkill(
            request: "Draft release hardening workflow steps.",
            projectName: "BurnBar",
            retrievalQuery: "skill-grounding-needle",
            contextLimit: 4
        )
        let refineSkill = try await service.refineSkill(
            existingMarkdown: "# Existing Skill\nCurrent checklist.",
            instructions: "Refine with escalation and rollback details.",
            projectName: "BurnBar",
            retrievalQuery: "agent-grounding-needle",
            contextLimit: 4
        )
        let draftAgent = try await service.draftAgentDoc(
            request: "Draft ownership and escalation policy for agents.",
            projectName: "BurnBar",
            retrievalQuery: "agent-grounding-needle",
            contextLimit: 4
        )
        let refineAgent = try await service.refineAgentDoc(
            existingMarkdown: "# Existing Agent Doc\nCurrent operating policy.",
            instructions: "Refine sequencing and release guardrails.",
            projectName: "BurnBar",
            retrievalQuery: "skill-grounding-needle",
            contextLimit: 4
        )

        let snapshot = AuthoringReplayGoldenSnapshot(
            scenario: "authoring-draft-refine-grounding",
            cases: [
                summarizeAuthoringCase(name: "draft-skill", draft: draftSkill),
                summarizeAuthoringCase(name: "refine-skill", draft: refineSkill),
                summarizeAuthoringCase(name: "draft-agent-doc", draft: draftAgent),
                summarizeAuthoringCase(name: "refine-agent-doc", draft: refineAgent)
            ]
        )
        try BurnBarReplayGoldens.assertGolden(snapshot, fixtureFile: "authoring-draft-refine-grounding.json")
    }

    func test_optionalSmoke_realProviderAuthoringIntegration() async throws {
        guard ProcessInfo.processInfo.environment["BURNBAR_REAL_PROVIDER_SMOKE"] == "1" else {
            throw XCTSkip("Set BURNBAR_REAL_PROVIDER_SMOKE=1 to run optional real provider smoke coverage.")
        }

        let harness = try BurnBarSearchIntegrationHarness(name: "real-provider-authoring-smoke")
        defer { harness.cleanup() }

        let now = harness.clock.now()
        let contextDocument = SearchDocumentRecord(
            id: "doc-smoke-context",
            sourceKind: .skillDoc,
            sourceID: "artifact-smoke-context",
            sourceVersionID: "smoke-v1",
            provider: nil,
            projectName: "BurnBar",
            title: "Smoke Context",
            subtitle: "SKILL.md",
            bodyPreview: "Smoke context for real provider test.",
            sourceUpdatedAt: now,
            indexedAt: now,
            contentHash: "hash-smoke-context",
            createdAt: now,
            updatedAt: now
        )
        try harness.dataStore.upsertSearchDocument(contextDocument)
        try harness.dataStore.replaceSearchChunks(
            documentID: contextDocument.id,
            title: contextDocument.title,
            chunks: [
                SearchChunkRecord(
                    id: "chunk-smoke-context",
                    documentID: contextDocument.id,
                    sourceKind: .skillDoc,
                    sourceID: contextDocument.sourceID,
                    sourceVersionID: contextDocument.sourceVersionID,
                    ordinal: 0,
                    startOffset: 0,
                    endOffset: 96,
                    sectionPath: "Smoke",
                    text: "smoke-grounding-needle release hardening smoke validation context.",
                    createdAt: now,
                    updatedAt: now
                )
            ]
        )

        let settings = BurnBarHarnessArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: [harness.fileRoots.registeredProjectRootURL.path],
            artifactDiscoveryAdditionalKnownPatterns: []
        )
        let service = ArtifactAuthoringService(
            dataStore: harness.dataStore,
            retrievalService: harness.makeSearchService(semanticEnabled: false),
            settingsProvider: settings,
            textGenerator: CLIArtifactAuthoringTextGenerator(),
            nowProvider: { harness.clock.now() }
        )

        do {
            let draft = try await service.draftSkill(
                request: "Draft two concise release hardening bullets.",
                projectName: "BurnBar",
                retrievalQuery: "smoke-grounding-needle",
                contextLimit: 2
            )
            XCTAssertFalse(draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(draft.references.isEmpty == false)
        } catch let error as ArtifactAuthoringError {
            if case .cliUnavailable = error {
                throw XCTSkip("No real CLI provider is available in this environment.")
            }
            throw error
        }
    }

    private func summarizeAuthoringCase(name: String, draft: ArtifactAuthoringDraft) -> AuthoringReplayCaseSnapshot {
        AuthoringReplayCaseSnapshot(
            name: name,
            sourceKind: draft.sourceKind.rawValue,
            operation: draft.operation.rawValue,
            retrievalQuery: draft.retrievalQuery,
            referenceSourceIDs: draft.references.map(\.sourceID),
            referenceKinds: draft.references.map(\.sourceKind.rawValue),
            hasGroundingInstruction: draft.userPrompt.contains("## Grounding"),
            hasReferenceLabel: draft.userPrompt.contains("[R1]"),
            includesExistingMarkdownBlock: draft.userPrompt.contains("Existing markdown to refine:"),
            generatedHasGroundingSection: draft.content.localizedCaseInsensitiveContains("## grounding"),
            generatedHasReferenceCitation: draft.content.contains("[R1]")
        )
    }
}

@MainActor
final class WorkflowInsightRollupServiceTests: XCTestCase {
    func test_rollupSnapshot_materializesFreshAndPersistsHealth() throws {
        let store = try makeRollupInMemoryStore()
        store.replaceUsages(makeRollupFixtureUsages())

        let snapshot = WorkflowInsightRollupService(dataStore: store).snapshot(refreshIfStale: true)

        XCTAssertEqual(snapshot.freshness, .fresh)
        XCTAssertFalse(snapshot.insights.isEmpty)
        XCTAssertNotNil(snapshot.computedAt)
        let health = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .insightRollups })
        XCTAssertEqual(health?.status, .healthy)
        XCTAssertNil(health?.errorCode)
    }

    func test_rollupSnapshot_reportsStale_whenNewUsageArrivesAfterMaterialization() throws {
        let store = try makeRollupInMemoryStore()
        let fixture = makeRollupFixtureUsages()
        store.replaceUsages(fixture)

        let now = Date()
        let initialService = WorkflowInsightRollupService(dataStore: store, nowProvider: { now })
        _ = initialService.snapshot(refreshIfStale: true)

        let futureUsage = TokenUsage(
            provider: .factory,
            sessionId: "rollup-future",
            projectName: "BurnBar",
            model: "future-model",
            inputTokens: 12,
            outputTokens: 8,
            costUSD: 0.30,
            startTime: now.addingTimeInterval(120),
            endTime: now.addingTimeInterval(180)
        )
        store.replaceUsages(fixture + [futureUsage])

        let staleSnapshot = initialService.snapshot(refreshIfStale: false)
        XCTAssertEqual(staleSnapshot.freshness, .stale)

        let refreshed = WorkflowInsightRollupService(
            dataStore: store,
            nowProvider: { now.addingTimeInterval(900) }
        ).snapshot(refreshIfStale: true)
        XCTAssertEqual(refreshed.freshness, .fresh)
    }

    func test_rollupSnapshot_reportsRebuilding_whenRebuildJobsArePending() throws {
        let store = try makeRollupInMemoryStore()
        store.replaceUsages(makeRollupFixtureUsages())
        let service = WorkflowInsightRollupService(dataStore: store)
        _ = service.snapshot(refreshIfStale: true)

        let now = Date()
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "rollup-rebuild-pending",
                jobType: .rebuild,
                status: .queued,
                priority: 1,
                scheduledAt: now,
                availableAt: now,
                createdAt: now,
                updatedAt: now
            )
        )

        let snapshot = service.snapshot(refreshIfStale: false)
        XCTAssertEqual(snapshot.freshness, .rebuilding)
        XCTAssertFalse(snapshot.insights.isEmpty)
    }

    func test_rollupSnapshot_reportsUnavailable_whenNoInputsExist() throws {
        let store = try makeRollupInMemoryStore()
        store.replaceUsages([])

        let snapshot = WorkflowInsightRollupService(dataStore: store).snapshot(refreshIfStale: false)

        XCTAssertEqual(snapshot.freshness, .unavailable)
        XCTAssertTrue(snapshot.insights.isEmpty)
    }

    private func makeRollupInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeRollupFixtureUsages() -> [TokenUsage] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart

        return [
            TokenUsage(
                provider: .factory,
                sessionId: "rollup-yesterday",
                projectName: "BurnBar",
                model: "gpt-5.4-mini",
                inputTokens: 30,
                outputTokens: 20,
                costUSD: 0.90,
                startTime: yesterdayStart.addingTimeInterval(120),
                endTime: yesterdayStart.addingTimeInterval(180)
            ),
            TokenUsage(
                provider: .claudeCode,
                sessionId: "rollup-today",
                projectName: "BurnBar",
                model: "claude-sonnet",
                inputTokens: 24,
                outputTokens: 16,
                costUSD: 0.50,
                startTime: todayStart.addingTimeInterval(120),
                endTime: todayStart.addingTimeInterval(180)
            )
        ]
    }
}

@MainActor
final class ArtifactAuthoringServiceTests: XCTestCase {
    func test_draftSkill_buildsBoundedPromptWithRetrievedContext() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let now = Date(timeIntervalSince1970: 1_742_780_000)

        let contextDocument = SearchDocumentRecord(
            id: "doc-authoring-context",
            sourceKind: .agentDoc,
            sourceID: "artifact-context",
            sourceVersionID: "context-v1",
            provider: nil,
            projectName: "BurnBar",
            title: "Release Hardening Agent Guide",
            subtitle: "AGENTS.md",
            bodyPreview: "Checklist for release hardening.",
            sourceUpdatedAt: now,
            indexedAt: now,
            contentHash: "hash-authoring-context",
            createdAt: now,
            updatedAt: now
        )
        try store.upsertSearchDocument(contextDocument)
        try store.replaceSearchChunks(
            documentID: contextDocument.id,
            title: contextDocument.title,
            chunks: [
                SearchChunkRecord(
                    id: "chunk-authoring-context",
                    documentID: contextDocument.id,
                    sourceKind: .agentDoc,
                    sourceID: contextDocument.sourceID,
                    sourceVersionID: contextDocument.sourceVersionID,
                    ordinal: 0,
                    startOffset: 0,
                    endOffset: 96,
                    sectionPath: "Hardening",
                    text: "Release hardening requires smoke tests, rollback drills, and deployment health checks.",
                    createdAt: now,
                    updatedAt: now
                )
            ]
        )

        let generator = StubArtifactAuthoringTextGenerator(
            response: """
            # Release hardening skill
            Keep rollback paths rehearsed.

            ## Grounding
            - [R1] Context applied.
            """
        )
        let settings = StubArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: ["/tmp"]
        )
        let service = ArtifactAuthoringService(
            dataStore: store,
            retrievalService: SearchService(dataStore: store),
            settingsProvider: settings,
            textGenerator: generator,
            nowProvider: { now }
        )

        let draft = try await service.draftSkill(
            request: "Create a release hardening skill with deployment safeguards.",
            projectName: "BurnBar",
            retrievalQuery: "release hardening smoke tests rollback",
            contextLimit: 4
        )

        XCTAssertEqual(draft.sourceKind, .skillDoc)
        XCTAssertEqual(draft.operation, .draft)
        XCTAssertEqual(draft.references.count, 1)
        XCTAssertEqual(draft.references.first?.sourceID, "artifact-context")
        XCTAssertTrue(draft.userPrompt.contains("[R1]"))
        XCTAssertTrue(draft.userPrompt.localizedCaseInsensitiveContains("release hardening"))
        XCTAssertTrue(draft.provenanceSummary.contains("artifact-context"))
        XCTAssertEqual(generator.userPrompts.last, draft.userPrompt)
    }

    func test_saveDraft_roundTripsIntoProjectionAndSearch() async throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: sandbox) }
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let root = sandbox.appendingPathComponent("workspace", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let store = try makeDiscoveryInMemoryStore()
        let now = Date(timeIntervalSince1970: 1_742_790_000)
        let generator = StubArtifactAuthoringTextGenerator(
            response: """
            # Bootstrap Skill
            Use the orion-e2e-authoring-needle checklist before every release.

            ## Grounding
            - No historical references available.
            """
        )
        let settings = StubArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: [root.path]
        )
        let service = ArtifactAuthoringService(
            dataStore: store,
            retrievalService: SearchService(dataStore: store),
            settingsProvider: settings,
            textGenerator: generator,
            fileManager: fileManager,
            nowProvider: { now }
        )

        let draft = try await service.draftSkill(
            request: "Draft a bootstrap release skill.",
            projectName: "BurnBar",
            retrievalQuery: "bootstrap release checklist",
            contextLimit: 3
        )
        let destinationPath = root.appendingPathComponent("SKILL.md").path
        let saveResult = try service.saveDraft(draft, to: destinationPath)

        XCTAssertEqual(saveResult.disposition, .inserted)
        XCTAssertTrue(saveResult.projectionJobEnqueued)
        XCTAssertNotNil(saveResult.projectionJobID)
        XCTAssertTrue(saveResult.artifact.provenance.hasPrefix("authoring:draft|"))

        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "authoring-roundtrip")
        _ = try projector.runSweep(maxJobs: 10)

        let retrieval = SearchService(dataStore: store)
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "orion-e2e-authoring-needle",
                filters: RetrievalFilters(artifactTypes: [.skillDoc]),
                resultLimit: 10
            )
        )
        XCTAssertEqual(Set(results.map(\.sourceID)), Set([saveResult.artifact.id]))
    }
}

@MainActor
private final class StubArtifactAuthoringTextGenerator: ArtifactAuthoringTextGenerating {
    var response: String
    private(set) var systemPrompts: [String] = []
    private(set) var userPrompts: [String] = []

    init(response: String) {
        self.response = response
    }

    func generate(systemPrompt: String, userPrompt: String) async throws -> String {
        systemPrompts.append(systemPrompt)
        userPrompts.append(userPrompt)
        return response
    }
}

@MainActor
final class LocalSearchSchemaStoreTests: XCTestCase {

    func test_localSearchSchemaInventory_containsExpectedObjects() throws {
        let store = try makeInMemoryStore()
        let inventory = try store.localSearchSchemaInventory()

        XCTAssertEqual(
            Set(inventory.tables),
            Set([
                "artifact_permissions",
                "audit_events",
                "chunk_embeddings",
                "embedding_models",
                "embedding_versions",
                "projection_jobs",
                "retrieval_health",
                "search_chunks",
                "search_chunks_fts",
                "search_documents"
            ])
        )
        XCTAssertEqual(
            Set(inventory.indexes),
            Set([
                "artifact_permissions_principal_lookup_idx",
                "artifact_permissions_source_lookup_idx",
                "audit_events_action_time_idx",
                "audit_events_scope_time_idx",
                "audit_events_source_time_idx",
                "chunk_embeddings_version_lookup_idx",
                "embedding_models_provider_model_idx",
                "embedding_versions_active_idx",
                "embedding_versions_identity_idx",
                "projection_jobs_poll_idx",
                "projection_jobs_source_lookup_idx",
                "search_chunks_document_offset_idx",
                "search_chunks_source_lookup_idx",
                "search_chunks_unique_document_ordinal_idx",
                "search_documents_project_provider_idx",
                "search_documents_source_lookup_idx"
            ])
        )
    }

    func test_localSearchStore_roundTrips_document_chunk_job_embedding_and_health() throws {
        let store = try makeInMemoryStore()
        let now = Date(timeIntervalSince1970: 1_742_009_600)

        let document = SearchDocumentRecord(
            id: "doc-1",
            sourceKind: .conversation,
            sourceID: "conv-1",
            sourceVersionID: "v1",
            provider: AgentProvider.claudeCode.rawValue,
            projectName: "BurnBar",
            title: "Conversation about store split",
            subtitle: "P01",
            bodyPreview: "Schema + repository split",
            sourceUpdatedAt: now,
            indexedAt: now,
            contentHash: "hash-1",
            createdAt: now,
            updatedAt: now
        )
        try store.upsertSearchDocument(document)

        let chunks = [
            SearchChunkRecord(
                id: "chunk-1",
                documentID: "doc-1",
                sourceKind: .conversation,
                sourceID: "conv-1",
                sourceVersionID: "v1",
                ordinal: 0,
                startOffset: 0,
                endOffset: 32,
                text: "First chunk text",
                createdAt: now,
                updatedAt: now
            ),
            SearchChunkRecord(
                id: "chunk-2",
                documentID: "doc-1",
                sourceKind: .conversation,
                sourceID: "conv-1",
                sourceVersionID: "v1",
                ordinal: 1,
                startOffset: 33,
                endOffset: 70,
                text: "Second chunk text",
                createdAt: now,
                updatedAt: now
            )
        ]
        try store.replaceSearchChunks(documentID: "doc-1", title: document.title, chunks: chunks)

        let fetchedDocuments = try store.fetchSearchDocuments(limit: 10)
        XCTAssertEqual(fetchedDocuments.count, 1)
        XCTAssertEqual(fetchedDocuments.first?.id, "doc-1")

        let fetchedChunks = try store.fetchSearchChunks(documentID: "doc-1")
        XCTAssertEqual(fetchedChunks.map(\.id), ["chunk-1", "chunk-2"])
        XCTAssertEqual(fetchedChunks.map(\.startOffset), [0, 33])
        XCTAssertEqual(fetchedChunks.map(\.endOffset), [32, 70])
        XCTAssertEqual(
            try store.fetchSearchDocuments(sourceKind: .conversation, sourceID: "conv-1").map(\.id),
            ["doc-1"]
        )
        XCTAssertEqual(
            try store.fetchSearchChunks(sourceKind: .conversation, sourceID: "conv-1").map(\.id),
            ["chunk-1", "chunk-2"]
        )

        let queuedJob = ProjectionJobRecord(
            id: "job-1",
            jobType: .project,
            sourceKind: .conversation,
            sourceID: "conv-1",
            sourceVersionID: "v1",
            status: .queued,
            priority: 5,
            attempts: 0,
            maxAttempts: 5,
            scheduledAt: now,
            availableAt: now,
            createdAt: now,
            updatedAt: now
        )
        try store.enqueueProjectionJob(queuedJob)
        XCTAssertEqual(try store.fetchProjectionJobs(statuses: [.queued], limit: 10).count, 1)

        try store.markProjectionJobLeased(id: "job-1", leaseOwner: "worker-1", leaseDuration: 120, now: now)
        XCTAssertEqual(try store.fetchProjectionJobs(statuses: [.leased], limit: 10).first?.id, "job-1")
        try store.markProjectionJobCompleted(id: "job-1", completedAt: now.addingTimeInterval(60))
        XCTAssertEqual(try store.fetchProjectionJobs(statuses: [.completed], limit: 10).first?.id, "job-1")

        let model = EmbeddingModelRecord(
            id: "model-1",
            provider: "openai",
            modelName: "text-embedding-3-large",
            dimensions: 3072,
            distanceMetric: .cosine,
            createdAt: now,
            updatedAt: now
        )
        try store.upsertEmbeddingModel(model)
        XCTAssertEqual(try store.fetchEmbeddingModels().map(\.id), ["model-1"])

        let version = EmbeddingVersionRecord(
            id: "version-1",
            modelID: "model-1",
            versionTag: "2026-03-24",
            chunkerVersion: "chunker-v1",
            normalizationVersion: "norm-v1",
            promptVersion: "prompt-v1",
            isActive: true,
            createdAt: now,
            updatedAt: now
        )
        try store.upsertEmbeddingVersion(version)
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: "model-1").map(\.id), ["version-1"])

        let embedding = ChunkEmbeddingRecord(
            chunkID: "chunk-1",
            embeddingVersionID: "version-1",
            vectorBlob: Data([0, 1, 2, 3]),
            createdAt: now,
            updatedAt: now
        )
        try store.upsertChunkEmbedding(embedding)
        let fetchedEmbeddings = try store.fetchChunkEmbeddings(chunkID: "chunk-1")
        XCTAssertEqual(fetchedEmbeddings.count, 1)
        XCTAssertEqual(fetchedEmbeddings.first?.vectorBlob, Data([0, 1, 2, 3]))
        XCTAssertEqual(
            try store.fetchChunkEmbeddings(embeddingVersionID: "version-1").map(\.chunkID),
            ["chunk-1"]
        )

        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .projection,
                status: .degraded,
                errorCode: "PROJECTOR_TIMEOUT",
                errorMessage: "Projection worker exceeded lease",
                detailsJSON: "{\"queueDepth\":12}",
                observedAt: now,
                updatedAt: now
            )
        )
        let healthRows = try store.fetchRetrievalHealth()
        XCTAssertEqual(healthRows.count, 1)
        XCTAssertEqual(healthRows.first?.subsystem, .projection)
        XCTAssertEqual(healthRows.first?.status, .degraded)
        XCTAssertEqual(healthRows.first?.errorCode, "PROJECTOR_TIMEOUT")
    }

    func test_projectionJobs_queueOrdering_and_failureRetryState() throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_100_000)

        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "job-ready",
                jobType: .project,
                status: .queued,
                priority: 1,
                scheduledAt: base,
                availableAt: base,
                createdAt: base,
                updatedAt: base
            )
        )
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "job-later",
                jobType: .project,
                status: .queued,
                priority: 1,
                scheduledAt: base,
                availableAt: base.addingTimeInterval(120),
                createdAt: base.addingTimeInterval(1),
                updatedAt: base.addingTimeInterval(1)
            )
        )
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "job-low-priority",
                jobType: .project,
                status: .queued,
                priority: 20,
                scheduledAt: base,
                availableAt: base,
                createdAt: base.addingTimeInterval(2),
                updatedAt: base.addingTimeInterval(2)
            )
        )

        let queued = try store.fetchProjectionJobs(statuses: [.queued], limit: 10)
        XCTAssertEqual(queued.map(\.id), ["job-ready", "job-later", "job-low-priority"])

        let retryAt = base.addingTimeInterval(300)
        try store.markProjectionJobFailed(
            id: "job-ready",
            errorCode: "EMBEDDING_UNAVAILABLE",
            errorMessage: "Embedder offline",
            retryAt: retryAt,
            updatedAt: retryAt
        )

        let failed = try store.fetchProjectionJobs(statuses: [.failed], limit: 10)
        XCTAssertEqual(failed.count, 1)
        guard let failedJob = failed.first else {
            return XCTFail("Expected one failed job record")
        }
        XCTAssertEqual(failedJob.id, "job-ready")
        XCTAssertEqual(failedJob.attempts, 1)
        XCTAssertEqual(failedJob.lastErrorCode, "EMBEDDING_UNAVAILABLE")
        XCTAssertEqual(failedJob.availableAt.timeIntervalSince1970, retryAt.timeIntervalSince1970, accuracy: 0.001)
    }

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }
}

@MainActor
final class SourceArtifactStoreTests: XCTestCase {
    func test_sourceArtifactStore_upsertRoundTrip_andDeleteFlow() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_100_000)

        let initial = SourceArtifactRecord(
            id: "artifact-1",
            sourceKind: .agentDoc,
            canonicalPath: "/tmp/repo/AGENTS.md",
            rootPath: "/tmp/repo",
            relativePath: "AGENTS.md",
            provenance: "basename:AGENTS.MD",
            title: "Agent Guide",
            body: "# Agent Guide\nInitial",
            contentHash: "hash-v1",
            fileSizeBytes: 64,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )

        XCTAssertEqual(try store.upsertSourceArtifact(initial), .inserted)

        let timestampOnlyUpdate = SourceArtifactRecord(
            id: initial.id,
            sourceKind: initial.sourceKind,
            canonicalPath: initial.canonicalPath,
            rootPath: initial.rootPath,
            relativePath: initial.relativePath,
            provenance: initial.provenance,
            title: initial.title,
            body: initial.body,
            contentHash: initial.contentHash,
            fileSizeBytes: initial.fileSizeBytes,
            fileModifiedAt: initial.fileModifiedAt,
            status: .active,
            discoveredAt: base.addingTimeInterval(5),
            deletedAt: nil,
            createdAt: initial.createdAt,
            updatedAt: base.addingTimeInterval(5)
        )
        XCTAssertEqual(try store.upsertSourceArtifact(timestampOnlyUpdate), .unchanged)

        let updated = SourceArtifactRecord(
            id: initial.id,
            sourceKind: initial.sourceKind,
            canonicalPath: initial.canonicalPath,
            rootPath: initial.rootPath,
            relativePath: initial.relativePath,
            provenance: initial.provenance,
            title: initial.title,
            body: "# Agent Guide\nUpdated",
            contentHash: "hash-v2",
            fileSizeBytes: 72,
            fileModifiedAt: base.addingTimeInterval(10),
            status: .active,
            discoveredAt: base.addingTimeInterval(10),
            deletedAt: nil,
            createdAt: initial.createdAt,
            updatedAt: base.addingTimeInterval(10)
        )
        XCTAssertEqual(try store.upsertSourceArtifact(updated), .updated)

        let active = try store.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.contentHash, "hash-v2")

        XCTAssertTrue(try store.markSourceArtifactDeleted(id: initial.id, deletedAt: base.addingTimeInterval(20)))
        XCTAssertEqual(
            try store.fetchSourceArtifacts(includeDeleted: false, rootPaths: nil, sourceKinds: [.skillDoc, .agentDoc]).count,
            0
        )
        let allArtifacts = try store.fetchSourceArtifacts(
            includeDeleted: true,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(allArtifacts.count, 1)
        XCTAssertEqual(allArtifacts.first?.status, .deleted)
    }
}

@MainActor
final class SharedArtifactSyncStateStoreTests: XCTestCase {
    func test_sharedArtifactSyncStateStore_roundTripLookupAndFiltering() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_112_000)

        let artifact = SourceArtifactRecord(
            id: "shared-artifact-1",
            sourceKind: .sharedArtifact,
            canonicalPath: "shared://workspace/team/shared-artifact-1.md",
            rootPath: "shared://workspace/team",
            relativePath: "shared-artifact-1.md",
            provenance: SharedArtifactCloudCodec.encodeProvenance(
                workspaceID: "workspace-a",
                teamID: "team-a",
                remoteArtifactID: "remote-1",
                ownerUserID: "user-1"
            ),
            title: "Shared Artifact",
            body: "# Shared\nv1",
            contentHash: "hash-shared-v1",
            fileSizeBytes: 24,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(artifact)

        let syncedState = SharedArtifactSyncStateRecord(
            sourceArtifactID: artifact.id,
            remoteArtifactID: "remote-1",
            workspaceID: "workspace-a",
            teamID: "team-a",
            ownerUserID: "user-1",
            revisionID: "rev-1",
            remoteContentHash: "hash-shared-v1",
            localContentHashAtSync: "hash-shared-v1",
            remoteUpdatedAt: base,
            lastPulledAt: base,
            lastSyncedAt: base,
            syncStatus: .synced,
            lastErrorCode: nil,
            lastErrorMessage: nil,
            createdAt: base,
            updatedAt: base
        )
        try store.upsertSharedArtifactSyncState(syncedState)

        let fetchedBySource = try store.fetchSharedArtifactSyncState(sourceArtifactID: artifact.id)
        XCTAssertEqual(fetchedBySource?.remoteArtifactID, "remote-1")
        XCTAssertEqual(fetchedBySource?.syncStatus, .synced)

        let fetchedByRemote = try store.fetchSharedArtifactSyncState(remoteArtifactID: "remote-1")
        XCTAssertEqual(fetchedByRemote?.sourceArtifactID, artifact.id)

        let conflictedState = SharedArtifactSyncStateRecord(
            sourceArtifactID: artifact.id,
            remoteArtifactID: "remote-1",
            workspaceID: "workspace-a",
            teamID: "team-a",
            ownerUserID: "user-1",
            revisionID: "rev-2",
            remoteContentHash: "hash-remote-v2",
            localContentHashAtSync: "hash-shared-v1",
            remoteUpdatedAt: base.addingTimeInterval(30),
            lastPulledAt: base.addingTimeInterval(30),
            lastSyncedAt: base,
            syncStatus: .conflicted,
            lastErrorCode: "SHARED_ARTIFACT_DIVERGED",
            lastErrorMessage: "Local and remote content diverged.",
            createdAt: base,
            updatedAt: base.addingTimeInterval(30)
        )
        try store.upsertSharedArtifactSyncState(conflictedState)

        let conflicted = try store.fetchSharedArtifactSyncStates(
            workspaceID: "workspace-a",
            teamID: "team-a",
            statuses: [.conflicted],
            limit: 20
        )
        XCTAssertEqual(conflicted.count, 1)
        XCTAssertEqual(conflicted.first?.lastErrorCode, "SHARED_ARTIFACT_DIVERGED")
    }

    func test_sharedArtifactPermissionStore_roundTripFilteringAndReadableLookup() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_125_000)

        let artifact = SourceArtifactRecord(
            id: "shared-permission-artifact-1",
            sourceKind: .sharedArtifact,
            canonicalPath: "shared://workspace-a/team-a/shared-permission-artifact-1.md",
            rootPath: "shared://workspace-a/team-a",
            relativePath: "shared-permission-artifact-1.md",
            provenance: "shared-sync:workspace-a|team-a|remote-perm-1|user-1",
            title: "Shared Permission Artifact",
            body: "# Shared\npermissions",
            contentHash: "hash-perm-v1",
            fileSizeBytes: 24,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(artifact)

        let ownerPermission = SharedArtifactPermissionRecord(
            sourceArtifactID: artifact.id,
            workspaceID: "workspace-a",
            teamID: "team-a",
            principalType: .user,
            principalID: "user-1",
            role: .owner,
            visibility: .team,
            canRead: true,
            canWrite: true,
            canShare: true,
            createdAt: base,
            updatedAt: base
        )
        XCTAssertEqual(try store.upsertSharedArtifactPermission(ownerPermission), .inserted)
        XCTAssertEqual(try store.upsertSharedArtifactPermission(ownerPermission), .unchanged)

        let updatedOwnerPermission = SharedArtifactPermissionRecord(
            sourceArtifactID: artifact.id,
            workspaceID: "workspace-a",
            teamID: "team-a",
            principalType: .user,
            principalID: "user-1",
            role: .editor,
            visibility: .team,
            canRead: true,
            canWrite: true,
            canShare: false,
            createdAt: base,
            updatedAt: base.addingTimeInterval(15)
        )
        XCTAssertEqual(try store.upsertSharedArtifactPermission(updatedOwnerPermission), .updated)

        let fetchedPermissions = try store.fetchSharedArtifactPermissions(
            sourceArtifactID: artifact.id,
            workspaceID: "workspace-a",
            teamID: "team-a",
            principalType: .user,
            principalID: "user-1",
            limit: 10
        )
        XCTAssertEqual(fetchedPermissions.count, 1)
        XCTAssertEqual(fetchedPermissions.first?.role, .editor)
        XCTAssertEqual(fetchedPermissions.first?.canShare, false)

        let readableForOwner = try store.fetchReadableSharedArtifactSourceIDs(
            accessContext: SharedArtifactAccessContext(
                userID: "user-1",
                workspaceID: "workspace-a",
                teamID: "team-a"
            )
        )
        XCTAssertEqual(readableForOwner, Set([artifact.id]))

        let readableForOther = try store.fetchReadableSharedArtifactSourceIDs(
            accessContext: SharedArtifactAccessContext(
                userID: "user-2",
                workspaceID: "workspace-a",
                teamID: "team-a"
            )
        )
        XCTAssertTrue(readableForOther.isEmpty)
    }

    func test_sharedArtifactReadableLookup_includesSyncOwnerFallback() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_127_500)

        let artifact = SourceArtifactRecord(
            id: "shared-owner-fallback-1",
            sourceKind: .sharedArtifact,
            canonicalPath: "shared://workspace-a/team-a/shared-owner-fallback-1.md",
            rootPath: "shared://workspace-a/team-a",
            relativePath: "shared-owner-fallback-1.md",
            provenance: "shared-sync:workspace-a|team-a|remote-owner-1|user-owner",
            title: "Shared Owner Fallback",
            body: "owner fallback",
            contentHash: "hash-owner-fallback",
            fileSizeBytes: 14,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(artifact)
        try store.upsertSharedArtifactSyncState(
            SharedArtifactSyncStateRecord(
                sourceArtifactID: artifact.id,
                remoteArtifactID: "remote-owner-1",
                workspaceID: "workspace-a",
                teamID: "team-a",
                ownerUserID: "user-owner",
                revisionID: "rev-owner-1",
                remoteContentHash: "hash-owner-fallback",
                localContentHashAtSync: "hash-owner-fallback",
                remoteUpdatedAt: base,
                lastPulledAt: base,
                lastSyncedAt: base,
                syncStatus: .synced,
                lastErrorCode: nil,
                lastErrorMessage: nil,
                createdAt: base,
                updatedAt: base
            )
        )

        let ownerReadable = try store.fetchReadableSharedArtifactSourceIDs(
            accessContext: SharedArtifactAccessContext(
                userID: "user-owner",
                workspaceID: "workspace-a",
                teamID: "team-a"
            )
        )
        XCTAssertEqual(ownerReadable, Set([artifact.id]))

        let otherReadable = try store.fetchReadableSharedArtifactSourceIDs(
            accessContext: SharedArtifactAccessContext(
                userID: "user-other",
                workspaceID: "workspace-a",
                teamID: "team-a"
            )
        )
        XCTAssertTrue(otherReadable.isEmpty)
    }

    func test_sharedArtifactCloudCodec_roundTripSerialization() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_742_130_000)
        let record = SharedArtifactCloudRecord(
            artifactID: "remote-42",
            workspaceID: "workspace-a",
            teamID: "team-a",
            ownerUserID: "user-1",
            visibility: .workspace,
            revisionID: "rev-42",
            baseRevisionID: "rev-41",
            title: "Shared Runbook",
            body: "Body content",
            contentHash: "hash-42",
            relativePath: "docs/runbook.md",
            isDeleted: false,
            updatedByUserID: "user-2",
            updatedByDeviceID: "device-7",
            resolvedConflictRevisionID: "rev-40",
            updatedAt: updatedAt
        )

        let encoded = SharedArtifactCloudCodec.encode(record, useServerTimestamp: false)
        let decoded = try SharedArtifactCloudCodec.decode(documentID: "remote-42", data: encoded)

        XCTAssertEqual(decoded.artifactID, record.artifactID)
        XCTAssertEqual(decoded.workspaceID, record.workspaceID)
        XCTAssertEqual(decoded.teamID, record.teamID)
        XCTAssertEqual(decoded.ownerUserID, record.ownerUserID)
        XCTAssertEqual(decoded.visibility, record.visibility)
        XCTAssertEqual(decoded.revisionID, record.revisionID)
        XCTAssertEqual(decoded.baseRevisionID, record.baseRevisionID)
        XCTAssertEqual(decoded.title, record.title)
        XCTAssertEqual(decoded.body, record.body)
        XCTAssertEqual(decoded.contentHash, record.contentHash)
        XCTAssertEqual(decoded.relativePath, record.relativePath)
        XCTAssertEqual(decoded.isDeleted, record.isDeleted)
        XCTAssertEqual(decoded.updatedByUserID, record.updatedByUserID)
        XCTAssertEqual(decoded.updatedByDeviceID, record.updatedByDeviceID)
        XCTAssertEqual(decoded.resolvedConflictRevisionID, record.resolvedConflictRevisionID)
        guard let decodedUpdatedAt = decoded.updatedAt else {
            return XCTFail("Expected decoded updatedAt timestamp.")
        }
        XCTAssertEqual(decodedUpdatedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_sharedArtifactOptimisticWriteGate_detectsStaleWriteRace() {
        XCTAssertThrowsError(
            try SharedArtifactOptimisticWriteGate.validate(
                expectedRevisionID: "rev-base",
                observedRevisionID: "rev-remote"
            )
        ) { error in
            let conflict = SharedArtifactOptimisticWriteGate.conflict(from: error)
            XCTAssertEqual(conflict?.expectedRevisionID, "rev-base")
            XCTAssertEqual(conflict?.observedRevisionID, "rev-remote")
        }
    }

    func test_sharedArtifactOptimisticWriteGate_allowsCreateAndMatchingHead() throws {
        XCTAssertNoThrow(
            try SharedArtifactOptimisticWriteGate.validate(
                expectedRevisionID: nil,
                observedRevisionID: nil
            )
        )
        XCTAssertNoThrow(
            try SharedArtifactOptimisticWriteGate.validate(
                expectedRevisionID: "rev-9",
                observedRevisionID: "rev-9"
            )
        )
    }

    func test_sharedArtifactConcurrentEdits_detectRaceAndAvoidSilentOverwrite() {
        XCTAssertNoThrow(
            try SharedArtifactOptimisticWriteGate.validate(
                expectedRevisionID: "rev-base",
                observedRevisionID: "rev-base"
            )
        )

        XCTAssertThrowsError(
            try SharedArtifactOptimisticWriteGate.validate(
                expectedRevisionID: "rev-base",
                observedRevisionID: "rev-peer"
            )
        ) { error in
            let conflict = SharedArtifactOptimisticWriteGate.conflict(from: error)
            XCTAssertEqual(conflict?.expectedRevisionID, "rev-base")
            XCTAssertEqual(conflict?.observedRevisionID, "rev-peer")
        }

        XCTAssertEqual(
            SharedArtifactSyncResolver.mergeDecision(
                localContentHash: "hash-local-writer-b",
                syncedContentHash: "hash-base",
                remoteContentHash: "hash-local-writer-a"
            ),
            .conflict
        )

        XCTAssertEqual(
            SharedArtifactSyncResolver.mergeDecision(
                localContentHash: "hash-merged",
                syncedContentHash: "hash-base",
                remoteContentHash: "hash-merged"
            ),
            .noChange
        )
    }

    func test_sharedArtifactAuditEvents_captureConflictAndRecoveryOutcomes() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_140_000)

        let artifact = SourceArtifactRecord(
            id: "shared-audit-artifact-1",
            sourceKind: .sharedArtifact,
            canonicalPath: "shared://workspace-a/team-a/incident-runbook.md",
            rootPath: "shared://workspace-a/team-a",
            relativePath: "incident-runbook.md",
            provenance: "shared-sync:workspace-a|team-a|remote-audit-1|user-1",
            title: "Incident Runbook",
            body: "v1",
            contentHash: "hash-a",
            fileSizeBytes: 2,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(artifact)
        try store.upsertSharedArtifactSyncState(
            SharedArtifactSyncStateRecord(
                sourceArtifactID: artifact.id,
                remoteArtifactID: "remote-audit-1",
                workspaceID: "workspace-a",
                teamID: "team-a",
                ownerUserID: "user-1",
                revisionID: "rev-base",
                remoteContentHash: "hash-a",
                localContentHashAtSync: "hash-a",
                remoteUpdatedAt: base,
                lastPulledAt: base,
                lastSyncedAt: base,
                syncStatus: .conflicted,
                lastErrorCode: "SHARED_ARTIFACT_STALE_WRITE",
                lastErrorMessage: "Stale write detected.",
                createdAt: base,
                updatedAt: base
            )
        )

        try store.appendSharedArtifactAuditEvent(
            SharedArtifactAuditEventRecord(
                sourceArtifactID: artifact.id,
                remoteArtifactID: "remote-audit-1",
                workspaceID: "workspace-a",
                teamID: "team-a",
                actorUserID: "user-1",
                actorRole: .editor,
                action: .conflictDetected,
                detailsJSON: #"{"message":"conflict","revisionID":"rev-peer","baseRevisionID":"rev-base","conflictRevisionID":"rev-peer"}"#,
                occurredAt: base.addingTimeInterval(5),
                createdAt: base.addingTimeInterval(5)
            )
        )
        try store.upsertSharedArtifactSyncState(
            SharedArtifactSyncStateRecord(
                sourceArtifactID: artifact.id,
                remoteArtifactID: "remote-audit-1",
                workspaceID: "workspace-a",
                teamID: "team-a",
                ownerUserID: "user-1",
                revisionID: "rev-peer",
                remoteContentHash: "hash-peer",
                localContentHashAtSync: "hash-peer",
                remoteUpdatedAt: base.addingTimeInterval(10),
                lastPulledAt: base.addingTimeInterval(10),
                lastSyncedAt: base.addingTimeInterval(10),
                syncStatus: .synced,
                lastErrorCode: nil,
                lastErrorMessage: nil,
                createdAt: base,
                updatedAt: base.addingTimeInterval(10)
            )
        )
        try store.appendSharedArtifactAuditEvent(
            SharedArtifactAuditEventRecord(
                sourceArtifactID: artifact.id,
                remoteArtifactID: "remote-audit-1",
                workspaceID: "workspace-a",
                teamID: "team-a",
                actorUserID: "user-1",
                actorRole: .editor,
                action: .conflictResolved,
                detailsJSON: #"{"message":"resolved","resolution":"remote_pull","revisionID":"rev-peer","baseRevisionID":"rev-base","conflictRevisionID":"rev-peer"}"#,
                occurredAt: base.addingTimeInterval(10),
                createdAt: base.addingTimeInterval(10)
            )
        )

        let syncState = try store.fetchSharedArtifactSyncState(sourceArtifactID: artifact.id)
        XCTAssertEqual(syncState?.syncStatus, .synced)
        XCTAssertEqual(syncState?.remoteArtifactID, "remote-audit-1")
        XCTAssertEqual(syncState?.revisionID, "rev-peer")

        let events = try store.fetchSharedArtifactAuditEvents(
            sourceArtifactID: artifact.id,
            workspaceID: "workspace-a",
            teamID: "team-a",
            actions: [.conflictDetected, .conflictResolved],
            limit: 10
        )
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.action), [.conflictResolved, .conflictDetected])
        XCTAssertTrue(events.allSatisfy { $0.sourceArtifactID == artifact.id })
        XCTAssertTrue(events.allSatisfy { $0.remoteArtifactID == "remote-audit-1" })

        var detailsByAction: [SharedArtifactAuditAction: [String: String]] = [:]
        for event in events {
            detailsByAction[event.action] = try decodeAuditDetails(event.detailsJSON)
        }
        XCTAssertEqual(detailsByAction[.conflictDetected]?["baseRevisionID"], "rev-base")
        XCTAssertEqual(detailsByAction[.conflictResolved]?["resolution"], "remote_pull")
    }

    private func decodeAuditDetails(_ raw: String?) throws -> [String: String] {
        guard let raw, let data = raw.data(using: .utf8) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    func test_sharedArtifactSyncResolver_handlesDivergenceCases() {
        XCTAssertEqual(
            SharedArtifactSyncResolver.mergeDecision(
                localContentHash: "hash-local",
                syncedContentHash: "hash-base",
                remoteContentHash: "hash-base"
            ),
            .pushLocal
        )

        XCTAssertEqual(
            SharedArtifactSyncResolver.mergeDecision(
                localContentHash: "hash-base",
                syncedContentHash: "hash-base",
                remoteContentHash: "hash-remote"
            ),
            .pullRemote
        )

        XCTAssertEqual(
            SharedArtifactSyncResolver.mergeDecision(
                localContentHash: "hash-local",
                syncedContentHash: "hash-base",
                remoteContentHash: "hash-remote"
            ),
            .conflict
        )

        XCTAssertEqual(
            SharedArtifactSyncResolver.mergeDecision(
                localContentHash: "hash-a",
                syncedContentHash: nil,
                remoteContentHash: "hash-b"
            ),
            .conflict
        )
    }
}

@MainActor
final class ArtifactDiscoveryServiceTests: XCTestCase {
    func test_discovery_staysWithinRegisteredRootsAndKnownPatterns() throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: sandbox) }
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let approvedRoot = sandbox.appendingPathComponent("approved-root", isDirectory: true)
        let outsideRoot = sandbox.appendingPathComponent("outside-root", isDirectory: true)
        try fileManager.createDirectory(at: approvedRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideRoot, withIntermediateDirectories: true)

        try writeDiscoveryFixture("# Skill\nDo this.", to: approvedRoot.appendingPathComponent("SKILL.md"))
        try writeDiscoveryFixture("# Agent\nRun tests.", to: approvedRoot.appendingPathComponent("docs/AGENTS.md"))
        try writeDiscoveryFixture("# Notes\nIgnore me.", to: approvedRoot.appendingPathComponent("README.md"))
        try writeDiscoveryFixture("# Outside\nShould not index.", to: outsideRoot.appendingPathComponent("AGENTS.md"))

        let store = try makeDiscoveryInMemoryStore()
        let settings = StubArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: [approvedRoot.path]
        )
        let service = ArtifactDiscoveryService(dataStore: store, settingsProvider: settings, fileManager: fileManager)
        let report = try service.discoverAndIngest()

        XCTAssertEqual(report.discoveredArtifacts, 2)
        XCTAssertEqual(report.insertedArtifacts, 2)
        XCTAssertTrue(report.issues.isEmpty)

        let artifacts = try store.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(artifacts.count, 2)
        XCTAssertFalse(artifacts.contains { $0.canonicalPath.hasPrefix(outsideRoot.path) })
        XCTAssertFalse(artifacts.contains { $0.relativePath == "README.md" })

        let queuedJobs = try store.fetchProjectionJobs(statuses: [.queued], limit: 10)
        XCTAssertEqual(queuedJobs.count, 2)
        XCTAssertEqual(Set(queuedJobs.map(\.jobType)), Set([.project]))

        let health = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .discovery })
        XCTAssertEqual(health?.status, .healthy)
    }

    func test_discovery_marksMissingArtifactsDeleted_andQueuesPurge() throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: sandbox) }
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let root = sandbox.appendingPathComponent("root", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let agentsURL = root.appendingPathComponent("AGENTS.md")
        try writeDiscoveryFixture("# Agent\nv1", to: agentsURL)

        let store = try makeDiscoveryInMemoryStore()
        let settings = StubArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: [root.path]
        )
        let service = ArtifactDiscoveryService(dataStore: store, settingsProvider: settings, fileManager: fileManager)

        _ = try service.discoverAndIngest()
        try fileManager.removeItem(at: agentsURL)
        let secondRun = try service.discoverAndIngest()

        XCTAssertEqual(secondRun.deletedArtifacts, 1)

        let allArtifacts = try store.fetchSourceArtifacts(
            includeDeleted: true,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(allArtifacts.count, 1)
        XCTAssertEqual(allArtifacts.first?.status, .deleted)

        let queuedJobs = try store.fetchProjectionJobs(statuses: [.queued], limit: 20)
        XCTAssertTrue(queuedJobs.contains { $0.jobType == .purge })
    }
}

@MainActor
private final class StubArtifactDiscoverySettings: ArtifactDiscoverySettingsProviding {
    var artifactDiscoveryEnabled: Bool
    var artifactDiscoveryRegisteredRoots: [String]
    var artifactDiscoveryAdditionalKnownPatterns: [String]

    init(
        artifactDiscoveryEnabled: Bool,
        artifactDiscoveryRegisteredRoots: [String],
        artifactDiscoveryAdditionalKnownPatterns: [String] = []
    ) {
        self.artifactDiscoveryEnabled = artifactDiscoveryEnabled
        self.artifactDiscoveryRegisteredRoots = artifactDiscoveryRegisteredRoots
        self.artifactDiscoveryAdditionalKnownPatterns = artifactDiscoveryAdditionalKnownPatterns
    }
}

@MainActor
private func makeDiscoveryInMemoryStore() throws -> DataStore {
    let queue = try DatabaseQueue(path: ":memory:")
    return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
}

private func writeDiscoveryFixture(_ text: String, to url: URL) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    guard let data = text.data(using: .utf8) else {
        throw NSError(domain: "AgentLensTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "UTF-8 encoding failed"])
    }
    try data.write(to: url)
}

@MainActor
final class ProjectionPipelineServiceTests: XCTestCase {
    func test_projectionWorker_recoversExpiredRunningJob_afterCrash() throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-recovery")

        let conversation = makeConversation(
            id: "conv-crash",
            fullText: "Line 1\nLine 2\nLine 3",
            indexedAt: Date(timeIntervalSince1970: 1_742_200_000)
        )
        try store.upsertConversation(conversation)

        let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
        let expiredLeaseTime = Date(timeIntervalSince1970: 1_742_200_010)
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: ProjectionIdentity.jobID(
                    jobType: .project,
                    sourceKind: .conversation,
                    sourceID: conversation.id,
                    sourceVersionID: sourceVersionID
                ),
                jobType: .project,
                sourceKind: .conversation,
                sourceID: conversation.id,
                sourceVersionID: sourceVersionID,
                status: .running,
                priority: 5,
                attempts: 0,
                maxAttempts: 5,
                scheduledAt: expiredLeaseTime,
                availableAt: expiredLeaseTime,
                startedAt: expiredLeaseTime,
                leaseOwner: "stale-worker",
                leaseExpiresAt: expiredLeaseTime.addingTimeInterval(-30),
                createdAt: expiredLeaseTime,
                updatedAt: expiredLeaseTime
            )
        )

        let report = try service.runSweep(maxJobs: 5)
        XCTAssertGreaterThanOrEqual(report.completedJobs, 1)

        let completed = try store.fetchProjectionJobs(statuses: [.completed], limit: 20)
        XCTAssertTrue(completed.contains(where: { $0.sourceID == conversation.id }))

        let documents = try store.fetchSearchDocuments(limit: 20)
        guard let projectedConversationDocument = documents.first(where: { $0.sourceID == conversation.id }) else {
            return XCTFail("Expected projected document for crash-recovered conversation.")
        }
        let chunks = try store.fetchSearchChunks(documentID: projectedConversationDocument.id)
        XCTAssertFalse(chunks.isEmpty)
    }

    func test_projectionJob_enqueueSuppression_preventsDuplicateRequeueAfterCompletion() throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-duplicates")
        let now = Date(timeIntervalSince1970: 1_742_300_000)

        let conversation = makeConversation(id: "conv-dedupe", fullText: String(repeating: "abc ", count: 500), indexedAt: now)
        try store.upsertConversation(conversation)

        let sourceVersionID = ProjectionIdentity.conversationSourceVersionID(for: conversation)
        let job = ProjectionJobRecord(
            id: ProjectionIdentity.jobID(
                jobType: .project,
                sourceKind: .conversation,
                sourceID: conversation.id,
                sourceVersionID: sourceVersionID
            ),
            jobType: .project,
            sourceKind: .conversation,
            sourceID: conversation.id,
            sourceVersionID: sourceVersionID,
            status: .queued,
            priority: 5,
            attempts: 0,
            maxAttempts: 5,
            scheduledAt: now,
            availableAt: now,
            createdAt: now,
            updatedAt: now
        )

        try store.enqueueProjectionJob(job)
        try store.enqueueProjectionJob(job)
        _ = try service.runSweep(maxJobs: 10)

        let documents = try store.fetchSearchDocuments(limit: 10)
        XCTAssertEqual(documents.count, 1)
        let chunkCount = try store.fetchSearchChunks(documentID: documents[0].id).count
        XCTAssertGreaterThan(chunkCount, 1)

        try store.enqueueProjectionJob(job)
        XCTAssertTrue(try store.fetchProjectionJobs(statuses: [.queued], limit: 10).isEmpty)

        let secondSweep = try service.runSweep(maxJobs: 10)
        XCTAssertEqual(secondSweep.completedJobs, 0)
        let secondChunkCount = try store.fetchSearchChunks(documentID: documents[0].id).count
        XCTAssertEqual(secondChunkCount, chunkCount)
    }

    func test_projectionPipeline_handlesArtifactDeleteWithPurgeJob() throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-purge")
        let base = Date(timeIntervalSince1970: 1_742_400_000)

        let artifact = SourceArtifactRecord(
            id: "artifact-delete",
            sourceKind: .agentDoc,
            canonicalPath: "/tmp/project/AGENTS.md",
            rootPath: "/tmp/project",
            relativePath: "AGENTS.md",
            provenance: "basename:AGENTS.MD",
            title: "Agent Guide",
            body: "# Agent Guide\nRun tests first.",
            contentHash: "hash-delete-v1",
            fileSizeBytes: 42,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(artifact)

        try service.enqueueSelectiveReproject(
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try service.runSweep(maxJobs: 10)
        XCTAssertEqual(try store.fetchSearchDocuments(limit: 10).count, 1)

        XCTAssertTrue(try store.markSourceArtifactDeleted(id: artifact.id, deletedAt: base.addingTimeInterval(60)))
        try service.enqueueSelectiveReproject(
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.deletedSourceVersionID,
            jobType: .purge,
            priority: 2
        )
        _ = try service.runSweep(maxJobs: 10)

        XCTAssertEqual(try store.fetchSearchDocuments(limit: 10).count, 0)
    }

    func test_rebuildJob_enqueuesReprojectAndPurgeCandidates() throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = ProjectionPipelineService(dataStore: store, leaseOwner: "worker-rebuild")
        let base = Date(timeIntervalSince1970: 1_742_500_000)

        let conversation = makeConversation(id: "conv-rebuild", fullText: "Need to rebuild projections.", indexedAt: base)
        try store.upsertConversation(conversation)

        let activeArtifact = SourceArtifactRecord(
            id: "artifact-active",
            sourceKind: .skillDoc,
            canonicalPath: "/tmp/repo/SKILL.md",
            rootPath: "/tmp/repo",
            relativePath: "SKILL.md",
            provenance: "basename:SKILL.MD",
            title: "Skill",
            body: "# Skill\nDo this.",
            contentHash: "hash-active",
            fileSizeBytes: 24,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(activeArtifact)

        let deletedArtifact = SourceArtifactRecord(
            id: "artifact-deleted",
            sourceKind: .agentDoc,
            canonicalPath: "/tmp/repo/AGENTS.md",
            rootPath: "/tmp/repo",
            relativePath: "AGENTS.md",
            provenance: "basename:AGENTS.MD",
            title: "Agents",
            body: "# Agents\nLegacy",
            contentHash: "hash-deleted",
            fileSizeBytes: 24,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(deletedArtifact)
        XCTAssertTrue(try store.markSourceArtifactDeleted(id: deletedArtifact.id, deletedAt: base.addingTimeInterval(120)))

        try service.enqueueRebuildJob(reason: "test-rebuild", priority: 1)
        let rebuildReport = try service.runSweep(maxJobs: 1)
        XCTAssertEqual(rebuildReport.completedJobs, 1)

        let queued = try store.fetchProjectionJobs(statuses: [.queued], limit: 20)
        XCTAssertTrue(queued.contains(where: { $0.sourceKind == .conversation && $0.sourceID == conversation.id && $0.jobType == .reproject }))
        XCTAssertTrue(queued.contains(where: { $0.sourceKind == activeArtifact.sourceKind && $0.sourceID == activeArtifact.id && $0.jobType == .reproject }))
        XCTAssertTrue(queued.contains(where: { $0.sourceKind == deletedArtifact.sourceKind && $0.sourceID == deletedArtifact.id && $0.jobType == .purge }))
    }

    func test_projectionPipeline_indexesEmbeddings_withActiveVersionLineage() throws {
        let store = try makeDiscoveryInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "projection-test-v1", seed: "projection-seed-v1")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-embedding-lineage",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_742_510_000)

        let conversation = makeConversation(
            id: "conv-embedding-lineage",
            fullText: "Embedding lineage test for hybrid retrieval indexing.",
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        _ = try service.runSweep(maxJobs: 20)

        let expectedModelID = EmbeddingIdentity.modelID(for: embedder.descriptor)
        let expectedVersionID = EmbeddingIdentity.versionID(for: embedder.descriptor)

        XCTAssertEqual(try store.fetchEmbeddingModels().map(\.id), [expectedModelID])
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: expectedModelID).first?.id, expectedVersionID)
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: expectedModelID).first?.isActive, true)

        guard
            let document = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == conversation.id })
        else {
            return XCTFail("Expected projected conversation document for embedding lineage test.")
        }
        let chunks = try store.fetchSearchChunks(documentID: document.id)
        XCTAssertFalse(chunks.isEmpty)

        let indexedEmbeddings = try store.fetchChunkEmbeddings(embeddingVersionID: expectedVersionID)
        XCTAssertEqual(Set(indexedEmbeddings.map(\.chunkID)), Set(chunks.map(\.id)))
        if let firstVector = indexedEmbeddings.first?.vectorBlob, let decoded = VectorBlobCodec.decode(firstVector) {
            XCTAssertEqual(decoded.count, embedder.descriptor.dimensions)
        } else {
            XCTFail("Expected a decodable embedding vector.")
        }
    }

    func test_reembedJob_createsNewActiveEmbeddingVersion_withoutRemovingPreviousVersion() throws {
        let store = try makeDiscoveryInMemoryStore()
        let embedderV1 = DeterministicFakeEmbeddingProvider(versionTag: "projection-test-v1", seed: "projection-seed-a")
        let serviceV1 = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-reembed-v1",
            chunkEmbedder: embedderV1
        )
        let base = Date(timeIntervalSince1970: 1_742_520_000)
        let conversation = makeConversation(
            id: "conv-reembed",
            fullText: "Re-embed this conversation into the new embedding version.",
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        _ = try serviceV1.runSweep(maxJobs: 20)

        guard
            let document = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == conversation.id }),
            let chunk = try store.fetchSearchChunks(documentID: document.id).first
        else {
            return XCTFail("Expected projected chunk before re-embed.")
        }

        let versionV1ID = EmbeddingIdentity.versionID(for: embedderV1.descriptor)
        guard
            let blobV1 = try store.fetchChunkEmbeddings(chunkID: chunk.id).first(where: { $0.embeddingVersionID == versionV1ID })?.vectorBlob
        else {
            return XCTFail("Expected initial embedding for first version.")
        }

        let embedderV2 = DeterministicFakeEmbeddingProvider(versionTag: "projection-test-v2", seed: "projection-seed-b")
        let serviceV2 = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-reembed-v2",
            chunkEmbedder: embedderV2
        )
        try serviceV2.enqueueReembedJob(
            reason: "test-reembed",
            sourceKind: .conversation,
            sourceID: conversation.id,
            priority: 1
        )
        _ = try serviceV2.runSweep(maxJobs: 20)

        let versionV2ID = EmbeddingIdentity.versionID(for: embedderV2.descriptor)
        let chunkEmbeddings = try store.fetchChunkEmbeddings(chunkID: chunk.id)
        XCTAssertTrue(chunkEmbeddings.contains { $0.embeddingVersionID == versionV1ID })
        XCTAssertTrue(chunkEmbeddings.contains { $0.embeddingVersionID == versionV2ID })
        XCTAssertNotEqual(
            chunkEmbeddings.first(where: { $0.embeddingVersionID == versionV2ID })?.vectorBlob,
            blobV1
        )

        let modelID = EmbeddingIdentity.modelID(for: embedderV2.descriptor)
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: modelID).first?.id, versionV2ID)
        XCTAssertEqual(try store.fetchEmbeddingVersions(modelID: modelID).first?.isActive, true)
    }

    func test_timestampNormalization_convertsMillisecondEpochToSeconds() {
        let milliseconds = 1_774_329_122_146.0
        let normalized = TimestampNormalizationUtility.normalizedEpochSeconds(milliseconds)

        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized ?? 0, milliseconds / 1000.0, accuracy: 0.0001)
    }

    func test_timestampNormalization_firestoreSafeDateRepairsMillisecondAsSecondDate() {
        let invalidDate = Date(timeIntervalSince1970: 1_774_329_122_146.0)
        let safeDate = TimestampNormalizationUtility.firestoreSafeDate(invalidDate)

        XCTAssertEqual(safeDate.timeIntervalSince1970, 1_774_329_122.146, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(
            safeDate.timeIntervalSince1970,
            TimestampNormalizationUtility.firestoreMaxEpochSeconds
        )
    }

    private func makeConversation(id: String, fullText: String, indexedAt: Date) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: .claudeCode,
            sessionId: "session-\(id)",
            projectName: "BurnBar",
            startTime: indexedAt.addingTimeInterval(-60),
            endTime: indexedAt,
            messageCount: 4,
            userWordCount: 20,
            assistantWordCount: 40,
            keyFiles: ["DataStore.swift"],
            keyCommands: ["swift test"],
            keyTools: ["Read"],
            inferredTaskTitle: "Projection Test",
            lastAssistantMessage: "Done.",
            fullText: fullText,
            indexedAt: indexedAt,
            fileModifiedAt: indexedAt,
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: .providerLog
        )
    }
}

final class ProjectionChunkerTests: XCTestCase {
    func test_chunker_isDeterministicForSameInput() {
        let text = """
        # Title
        Intro paragraph.

        ## Section A
        \(String(repeating: "Alpha beta gamma. ", count: 120))

        ## Section B
        \(String(repeating: "Delta epsilon zeta. ", count: 120))
        """

        let chunker = ProjectionChunker(maxChunkCharacters: 280, minChunkCharacters: 160, overlapCharacters: 40, maxChunksPerDocument: 32)
        let createdAt = Date(timeIntervalSince1970: 1_742_600_000)
        let first = chunker.makeChunks(
            text: text,
            sourceKind: .agentDoc,
            sourceID: "artifact-1",
            sourceVersionID: "version-1",
            documentID: "doc-1",
            createdAt: createdAt
        )
        let second = chunker.makeChunks(
            text: text,
            sourceKind: .agentDoc,
            sourceID: "artifact-1",
            sourceVersionID: "version-1",
            documentID: "doc-1",
            createdAt: createdAt
        )

        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.startOffset), second.map(\.startOffset))
        XCTAssertEqual(first.map(\.endOffset), second.map(\.endOffset))
        XCTAssertEqual(first.map(\.sectionPath), second.map(\.sectionPath))
        XCTAssertEqual(first.map(\.text), second.map(\.text))
    }
}

@MainActor
private final class StubSemanticCandidateProvider: SemanticCandidateProviding {
    enum StubError: Error {
        case forced
    }

    var responses: [String: [SemanticCandidate]]
    var shouldThrow = false

    init(responses: [String: [SemanticCandidate]] = [:]) {
        self.responses = responses
    }

    func semanticCandidates(for query: String, filters _: RetrievalFilters, limit: Int) async throws -> [SemanticCandidate] {
        if shouldThrow {
            throw StubError.forced
        }
        return Array((responses[query] ?? []).prefix(max(0, limit)))
    }
}

@MainActor
final class HybridRetrievalServiceTests: XCTestCase {
    func test_retrieval_lexicalWinsAgainstSemanticOnlyCandidate() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-lexical-wins")
        let base = Date(timeIntervalSince1970: 1_742_700_000)

        let lexicalConversation = makeConversation(
            id: "conv-lexical",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "Discussion about quartzwind rollout and release hardening.",
            indexedAt: base.addingTimeInterval(-120),
            sourceType: .providerLog
        )
        let semanticConversation = makeConversation(
            id: "conv-semantic",
            provider: .codex,
            projectName: "Beta",
            fullText: "This thread focuses on runtime migration and queue tuning.",
            indexedAt: base.addingTimeInterval(-60),
            sourceType: .providerLog
        )

        try store.upsertConversation(lexicalConversation)
        try store.upsertConversation(semanticConversation)
        try store.enqueueConversationProjectionJob(conversationID: lexicalConversation.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: semanticConversation.id, jobType: .project, now: base)
        _ = try projector.runSweep(maxJobs: 20)

        guard
            let semanticDoc = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == semanticConversation.id }),
            let semanticChunk = try store.fetchSearchChunks(documentID: semanticDoc.id).first
        else {
            return XCTFail("Expected projected semantic conversation chunk.")
        }

        let semanticProvider = StubSemanticCandidateProvider(
            responses: [
                "quartzwind": [SemanticCandidate(chunkID: semanticChunk.id, score: 0.99)]
            ]
        )
        let retrieval = SearchService(dataStore: store, semanticProvider: semanticProvider, nowProvider: { base })
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "quartzwind",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                resultLimit: 10
            )
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.sourceID, lexicalConversation.id)
        XCTAssertEqual(results.first?.sourceKind, .conversation)
    }

    func test_retrieval_semanticRescueReturnsResultWhenLexicalIsEmpty() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-semantic-rescue")
        let base = Date(timeIntervalSince1970: 1_742_710_000)

        let artifact = makeArtifact(
            id: "artifact-semantic-rescue",
            sourceKind: .skillDoc,
            rootPath: "/tmp/alpha-repo",
            relativePath: "SKILL.md",
            title: "Bootstrap skill",
            body: "Workstation bootstrap checklist for new machine setup.",
            contentHash: "hash-semantic-rescue",
            fileModifiedAt: base
        )

        _ = try store.upsertSourceArtifact(artifact)
        try projector.enqueueSelectiveReproject(
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try projector.runSweep(maxJobs: 10)

        guard
            let artifactDoc = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == artifact.id }),
            let artifactChunk = try store.fetchSearchChunks(documentID: artifactDoc.id).first
        else {
            return XCTFail("Expected projected artifact chunk for semantic rescue.")
        }

        let semanticProvider = StubSemanticCandidateProvider(
            responses: [
                "onboarding runbook": [SemanticCandidate(chunkID: artifactChunk.id, score: 0.92)]
            ]
        )
        let retrieval = SearchService(dataStore: store, semanticProvider: semanticProvider, nowProvider: { base })
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "onboarding runbook",
                filters: RetrievalFilters(artifactTypes: [.skillDoc]),
                resultLimit: 10
            )
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceID, artifact.id)
        XCTAssertEqual(results.first?.sourceKind, .skillDoc)
        XCTAssertNotNil(results.first?.semanticScore)
        XCTAssertNil(results.first?.lexicalRank)
    }

    func test_retrieval_emptyQueryReturnsNoResults() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let retrieval = SearchService(dataStore: store)

        let results = await retrieval.retrieve(RetrievalQuery(text: "   \n\t  "))
        XCTAssertTrue(results.isEmpty)
    }

    func test_retrieval_filters_applyProviderProjectArtifactDateOwnershipAndSource() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-filters")
        let base = Date(timeIntervalSince1970: 1_742_720_000)

        let convClaude = makeConversation(
            id: "conv-claude-alpha",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "filterneedle task continuity and release notes",
            indexedAt: base.addingTimeInterval(-86_400),
            sourceType: .providerLog
        )
        let convCodex = makeConversation(
            id: "conv-codex-beta",
            provider: .codex,
            projectName: "Beta",
            fullText: "filterneedle task continuity and release notes",
            indexedAt: base.addingTimeInterval(-40 * 86_400),
            sourceType: .providerLog
        )
        let convCLI = makeConversation(
            id: "conv-cli-alpha",
            provider: .factory,
            projectName: "Alpha",
            fullText: "filterneedle task continuity and release notes",
            indexedAt: base.addingTimeInterval(-2 * 86_400),
            sourceType: .cliAssistant
        )

        try store.upsertConversation(convClaude)
        try store.upsertConversation(convCodex)
        try store.upsertConversation(convCLI)
        try store.enqueueConversationProjectionJob(conversationID: convClaude.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: convCodex.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: convCLI.id, jobType: .project, now: base)

        let skillArtifact = makeArtifact(
            id: "artifact-skill-alpha",
            sourceKind: .skillDoc,
            rootPath: "/tmp/AlphaRepo",
            relativePath: "SKILL.md",
            title: "Skill Alpha",
            body: "filterneedle task continuity and release notes",
            contentHash: "hash-skill-alpha",
            fileModifiedAt: base.addingTimeInterval(-3 * 86_400)
        )
        let sharedArtifact = makeArtifact(
            id: "artifact-shared-alpha",
            sourceKind: .sharedArtifact,
            rootPath: "/tmp/SharedRepo",
            relativePath: "SHARED.md",
            title: "Shared Alpha",
            body: "filterneedle task continuity and release notes",
            contentHash: "hash-shared-alpha",
            fileModifiedAt: base.addingTimeInterval(-4 * 86_400)
        )

        _ = try store.upsertSourceArtifact(skillArtifact)
        _ = try store.upsertSourceArtifact(sharedArtifact)
        let sharedAccess = SharedArtifactAccessContext(
            userID: "user-alpha",
            workspaceID: "workspace-alpha",
            teamID: "team-alpha"
        )
        _ = try store.upsertSharedArtifactPermission(
            SharedArtifactPermissionRecord(
                sourceArtifactID: sharedArtifact.id,
                workspaceID: sharedAccess.workspaceID,
                teamID: sharedAccess.teamID,
                principalType: .user,
                principalID: sharedAccess.userID,
                role: .editor,
                visibility: .team,
                canRead: true,
                canWrite: true,
                canShare: false,
                createdAt: base,
                updatedAt: base
            )
        )
        try projector.enqueueSelectiveReproject(
            sourceKind: skillArtifact.sourceKind,
            sourceID: skillArtifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: skillArtifact.contentHash),
            jobType: .project,
            priority: 5
        )
        try projector.enqueueSelectiveReproject(
            sourceKind: sharedArtifact.sourceKind,
            sourceID: sharedArtifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: sharedArtifact.contentHash),
            jobType: .project,
            priority: 5
        )

        _ = try projector.runSweep(maxJobs: 40)

        let retrieval = SearchService(
            dataStore: store,
            sharedArtifactAccessContextProvider: { sharedAccess },
            nowProvider: { base }
        )

        let providerFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(provider: .claudeCode, artifactTypes: [.conversation]),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(providerFiltered.map(\.sourceID)), Set([convClaude.id]))

        let projectFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(projectName: "Alpha", artifactTypes: [.conversation]),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(projectFiltered.map(\.sourceID)), Set([convClaude.id, convCLI.id]))

        let artifactTypeFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(artifactTypes: [.skillDoc]),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(artifactTypeFiltered.map(\.sourceID)), Set([skillArtifact.id]))

        let recentConversationRange = base.addingTimeInterval(-7 * 86_400)...base
        let dateFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(artifactTypes: [.conversation], dateRange: recentConversationRange),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(dateFiltered.map(\.sourceID)), Set([convClaude.id, convCLI.id]))

        let sharedOnly = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(ownership: .shared),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(sharedOnly.map(\.sourceID)), Set([sharedArtifact.id]))
        XCTAssertTrue(sharedOnly.allSatisfy { $0.sourceKind == .sharedArtifact })

        let sourceFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(sourceIDs: [skillArtifact.id]),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(sourceFiltered.map(\.sourceID)), Set([skillArtifact.id]))

        let conversationSourceFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(
                    artifactTypes: [.conversation],
                    conversationSources: [.cliAssistant]
                ),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(conversationSourceFiltered.map(\.sourceID)), Set([convCLI.id]))
        XCTAssertTrue(conversationSourceFiltered.allSatisfy { $0.conversation?.sourceType == .cliAssistant })
    }

    func test_retrieval_sharedArtifactVisibility_requiresReadablePermission() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-rbac")
        let base = Date(timeIntervalSince1970: 1_742_721_000)

        let sharedArtifact = makeArtifact(
            id: "artifact-shared-rbac",
            sourceKind: .sharedArtifact,
            rootPath: "/tmp/SharedRepo",
            relativePath: "RBAC.md",
            title: "Shared RBAC",
            body: "rbacneedle team visibility and permissions",
            contentHash: "hash-shared-rbac",
            fileModifiedAt: base
        )
        _ = try store.upsertSourceArtifact(sharedArtifact)
        try projector.enqueueSelectiveReproject(
            sourceKind: .sharedArtifact,
            sourceID: sharedArtifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: sharedArtifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try projector.runSweep(maxJobs: 20)

        let noAccess = SharedArtifactAccessContext(
            userID: "user-no-access",
            workspaceID: "workspace-a",
            teamID: "team-a"
        )
        let noAccessRetrieval = SearchService(
            dataStore: store,
            sharedArtifactAccessContextProvider: { noAccess },
            nowProvider: { base }
        )
        let hiddenResults = await noAccessRetrieval.retrieve(
            RetrievalQuery(
                text: "rbacneedle",
                filters: RetrievalFilters(ownership: .shared),
                resultLimit: 20
            )
        )
        XCTAssertTrue(hiddenResults.isEmpty)

        _ = try store.upsertSharedArtifactPermission(
            SharedArtifactPermissionRecord(
                sourceArtifactID: sharedArtifact.id,
                workspaceID: "workspace-a",
                teamID: "team-a",
                principalType: .team,
                principalID: "team-a",
                role: .viewer,
                visibility: .team,
                canRead: true,
                canWrite: false,
                canShare: false,
                createdAt: base,
                updatedAt: base
            )
        )

        let teamMember = SharedArtifactAccessContext(
            userID: "user-team-member",
            workspaceID: "workspace-a",
            teamID: "team-a"
        )
        let teamRetrieval = SearchService(
            dataStore: store,
            sharedArtifactAccessContextProvider: { teamMember },
            nowProvider: { base }
        )
        let visibleResults = await teamRetrieval.retrieve(
            RetrievalQuery(
                text: "rbacneedle",
                filters: RetrievalFilters(ownership: .shared),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(visibleResults.map(\.sourceID)), Set([sharedArtifact.id]))

        let differentTeam = SharedArtifactAccessContext(
            userID: "user-other-team",
            workspaceID: "workspace-a",
            teamID: "team-b"
        )
        let blockedRetrieval = SearchService(
            dataStore: store,
            sharedArtifactAccessContextProvider: { differentTeam },
            nowProvider: { base }
        )
        let blockedResults = await blockedRetrieval.retrieve(
            RetrievalQuery(
                text: "rbacneedle",
                filters: RetrievalFilters(ownership: .shared),
                resultLimit: 20
            )
        )
        XCTAssertTrue(blockedResults.isEmpty)
    }

    func test_conversationSearch_keepsParityBetweenChatAndSessionLogs() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "conversation-search-parity")
        let base = Date(timeIntervalSince1970: 1_742_725_000)

        let providerConversation = makeConversation(
            id: "conv-parity-provider",
            provider: .claudeCode,
            projectName: "Parity",
            fullText: "parityneedle release hardening and rollout checklist",
            indexedAt: base.addingTimeInterval(-120),
            sourceType: .providerLog
        )
        let assistantConversation = makeConversation(
            id: "conv-parity-assistant",
            provider: .factory,
            projectName: "Parity",
            fullText: "parityneedle follow-up in assistant context",
            indexedAt: base.addingTimeInterval(-60),
            sourceType: .cliAssistant
        )

        try store.upsertConversation(providerConversation)
        try store.upsertConversation(assistantConversation)
        try store.enqueueConversationProjectionJob(conversationID: providerConversation.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: assistantConversation.id, jobType: .project, now: base)
        _ = try projector.runSweep(maxJobs: 20)

        let chatSearch = SearchService.makeConversationSearchService(dataStore: store, nowProvider: { base })
        let sessionLogSearch = SearchService.makeConversationSearchService(dataStore: store, nowProvider: { base })
        let query = "parityneedle"

        let chatResults = await chatSearch.search(query: query)
        let sessionLogResults = await sessionLogSearch.search(query: query, conversationSources: nil)

        XCTAssertEqual(chatResults.map(\.conversation.id), sessionLogResults.map(\.conversation.id))

        let providerOnly = await sessionLogSearch.search(query: query, conversationSources: [.providerLog])
        XCTAssertEqual(Set(providerOnly.map(\.conversation.id)), Set([providerConversation.id]))

        let assistantOnly = await sessionLogSearch.search(query: query, conversationSources: [.cliAssistant])
        XCTAssertEqual(Set(assistantOnly.map(\.conversation.id)), Set([assistantConversation.id]))
    }

    func test_vectorSemanticCandidates_annAndExactMatch_whenExactRerankEnabled() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_730_000)
        let embedder = DeterministicFakeEmbeddingProvider(
            dimensions: 64,
            versionTag: "ann-parity-v1",
            seed: "ann-parity-seed-v1"
        )

        let modelID = EmbeddingIdentity.modelID(for: embedder.descriptor)
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        try store.upsertEmbeddingModel(
            EmbeddingModelRecord(
                id: modelID,
                provider: embedder.descriptor.provider,
                modelName: embedder.descriptor.modelName,
                dimensions: embedder.descriptor.dimensions,
                distanceMetric: embedder.descriptor.distanceMetric,
                createdAt: base,
                updatedAt: base
            )
        )
        try store.upsertEmbeddingVersion(
            EmbeddingVersionRecord(
                id: versionID,
                modelID: modelID,
                versionTag: embedder.descriptor.versionTag,
                chunkerVersion: embedder.descriptor.chunkerVersion,
                normalizationVersion: embedder.descriptor.normalizationVersion,
                promptVersion: embedder.descriptor.promptVersion,
                isActive: true,
                createdAt: base,
                updatedAt: base
            )
        )

        for index in 0..<96 {
            let docID = "doc-ann-\(index)"
            let sourceID = "artifact-ann-\(index)"
            let title = "ANN Candidate Document \(index)"
            let chunkText: String
            if index % 13 == 0 {
                chunkText = "reliability hardening checklist rollout runbook \(index)"
            } else {
                chunkText = "generic notes \(index) queue metrics stabilization tracking"
            }

            let document = SearchDocumentRecord(
                id: docID,
                sourceKind: .skillDoc,
                sourceID: sourceID,
                sourceVersionID: "v\(index)",
                provider: nil,
                projectName: "VectorParity",
                title: title,
                subtitle: "SKILL.md",
                bodyPreview: String(chunkText.prefix(120)),
                sourceUpdatedAt: base,
                indexedAt: base,
                contentHash: "hash-\(index)",
                createdAt: base,
                updatedAt: base
            )
            try store.upsertSearchDocument(document)

            let chunk = SearchChunkRecord(
                id: "chunk-ann-\(index)",
                documentID: docID,
                sourceKind: .skillDoc,
                sourceID: sourceID,
                sourceVersionID: "v\(index)",
                ordinal: 0,
                startOffset: 0,
                endOffset: chunkText.utf16.count,
                messageStartOffset: nil,
                messageEndOffset: nil,
                sectionPath: nil,
                text: chunkText,
                createdAt: base,
                updatedAt: base
            )
            try store.replaceSearchChunks(documentID: docID, title: title, chunks: [chunk])

            let vector = try embedder.embedding(for: chunkText)
            try store.upsertChunkEmbedding(
                ChunkEmbeddingRecord(
                    chunkID: chunk.id,
                    embeddingVersionID: versionID,
                    vectorBlob: VectorBlobCodec.encode(vector),
                    createdAt: base,
                    updatedAt: base
                )
            )
        }

        let queryEmbedder = DeterministicQueryEmbeddingProvider(embedder: embedder)
        let annProvider = VectorSemanticCandidateProvider(
            dataStore: store,
            queryEmbedder: queryEmbedder,
            embeddingVersionID: versionID,
            backend: .ann,
            exactRerankEnabled: true,
            exactRerankLimit: 256,
            annCandidateMultiplier: 32,
            nowProvider: { base }
        )
        let exactProvider = VectorSemanticCandidateProvider(
            dataStore: store,
            queryEmbedder: queryEmbedder,
            embeddingVersionID: versionID,
            backend: .exact,
            exactRerankEnabled: true,
            exactRerankLimit: 256,
            nowProvider: { base }
        )

        let query = "reliability hardening checklist rollout"
        let annCandidates = try await annProvider.semanticCandidates(for: query, filters: RetrievalFilters(), limit: 20)
        let exactCandidates = try await exactProvider.semanticCandidates(for: query, filters: RetrievalFilters(), limit: 20)

        XCTAssertEqual(annCandidates.map(\.chunkID), exactCandidates.map(\.chunkID))
        XCTAssertEqual(annCandidates.count, exactCandidates.count)
        if let annTop = annCandidates.first?.score, let exactTop = exactCandidates.first?.score {
            XCTAssertEqual(annTop, exactTop, accuracy: 0.000001)
        }
    }

    func test_retrieval_semanticFallback_persistsDegradedSemanticHealth() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-semantic-fallback-health")
        let base = Date(timeIntervalSince1970: 1_742_740_000)

        let conversation = makeConversation(
            id: "conv-semantic-fallback",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "Rollout hardening checklist for lexical fallback coverage.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        _ = try projector.runSweep(maxJobs: 20)

        let semanticProvider = StubSemanticCandidateProvider()
        semanticProvider.shouldThrow = true
        let retrieval = SearchService(dataStore: store, semanticProvider: semanticProvider, nowProvider: { base })
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "hardening checklist",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                resultLimit: 10
            )
        )

        XCTAssertFalse(results.isEmpty)
        let semanticHealth = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .semantic })
        XCTAssertEqual(semanticHealth?.status, .degraded)
        XCTAssertEqual(semanticHealth?.errorCode, "SEMANTIC_PROVIDER_FALLBACK")
    }

    func test_retrievalHealthService_reportsDegradedModes_forIndexSemanticRebuildAndCloud() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_750_000)

        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .projection,
                status: .degraded,
                errorCode: "PROJECTION_JOBS_DEGRADED",
                errorMessage: "Projection queue has pending jobs.",
                detailsJSON: #"{"queueDepth":3,"failedJobs":1}"#,
                observedAt: base,
                updatedAt: base
            )
        )
        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .semantic,
                status: .degraded,
                errorCode: "SEMANTIC_NO_EMBEDDINGS",
                errorMessage: "No embeddings indexed yet.",
                detailsJSON: #"{"backend":"ann","indexedVectorCount":0,"candidateCount":0}"#,
                observedAt: base,
                updatedAt: base
            )
        )
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "rebuild-job-1",
                jobType: .rebuild,
                sourceVersionID: "rebuild-v1",
                status: .queued,
                priority: 1,
                attempts: 0,
                maxAttempts: 3,
                scheduledAt: base,
                availableAt: base,
                createdAt: base,
                updatedAt: base
            )
        )

        let service = RetrievalHealthService(dataStore: store, nowProvider: { base })
        let snapshot = service.snapshot(indexingEnabled: true, sharedFeaturesAvailable: false)
        let modes = Set(snapshot.degradedModes.map(\.mode))

        XCTAssertTrue(modes.contains(.indexStale))
        XCTAssertTrue(modes.contains(.semanticUnavailable))
        XCTAssertTrue(modes.contains(.rebuildInProgress))
        XCTAssertTrue(modes.contains(.cloudSharedUnavailable))
    }

    func test_retrievalHealthService_hidesIndexModesWhenIndexingDisabled() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_760_000)

        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .projection,
                status: .degraded,
                errorCode: "PROJECTION_JOBS_DEGRADED",
                errorMessage: "Projection queue has pending jobs.",
                detailsJSON: #"{"queueDepth":2,"failedJobs":0}"#,
                observedAt: base,
                updatedAt: base
            )
        )
        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .semantic,
                status: .failed,
                errorCode: "SEMANTIC_BACKEND_QUERY_FAILED",
                errorMessage: "Semantic backend failed.",
                detailsJSON: #"{"backend":"ann","indexedVectorCount":0,"candidateCount":0}"#,
                observedAt: base,
                updatedAt: base
            )
        )
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "rebuild-job-2",
                jobType: .rebuild,
                sourceVersionID: "rebuild-v2",
                status: .queued,
                priority: 1,
                attempts: 0,
                maxAttempts: 3,
                scheduledAt: base,
                availableAt: base,
                createdAt: base,
                updatedAt: base
            )
        )

        let service = RetrievalHealthService(dataStore: store, nowProvider: { base })
        let snapshot = service.snapshot(indexingEnabled: false, sharedFeaturesAvailable: true)
        let modes = Set(snapshot.degradedModes.map(\.mode))

        XCTAssertFalse(modes.contains(.indexStale))
        XCTAssertFalse(modes.contains(.semanticUnavailable))
        XCTAssertFalse(modes.contains(.rebuildInProgress))
    }

    private func makeConversation(
        id: String,
        provider: AgentProvider,
        projectName: String,
        fullText: String,
        indexedAt: Date,
        sourceType: ConversationSourceType
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: provider,
            sessionId: "session-\(id)",
            projectName: projectName,
            startTime: indexedAt.addingTimeInterval(-120),
            endTime: indexedAt,
            messageCount: 6,
            userWordCount: 48,
            assistantWordCount: 76,
            keyFiles: ["SearchService.swift"],
            keyCommands: ["swift test"],
            keyTools: ["Read", "Edit"],
            inferredTaskTitle: "Retrieval Test \(id)",
            lastAssistantMessage: "Done",
            fullText: fullText,
            indexedAt: indexedAt,
            fileModifiedAt: indexedAt,
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: sourceType
        )
    }

    private func makeArtifact(
        id: String,
        sourceKind: SearchSourceKind,
        rootPath: String,
        relativePath: String,
        title: String,
        body: String,
        contentHash: String,
        fileModifiedAt: Date
    ) -> SourceArtifactRecord {
        SourceArtifactRecord(
            id: id,
            sourceKind: sourceKind,
            canonicalPath: "\(rootPath)/\(relativePath)",
            rootPath: rootPath,
            relativePath: relativePath,
            provenance: "test:\(relativePath)",
            title: title,
            body: body,
            contentHash: contentHash,
            fileSizeBytes: body.utf8.count,
            fileModifiedAt: fileModifiedAt,
            status: .active,
            discoveredAt: fileModifiedAt,
            deletedAt: nil,
            createdAt: fileModifiedAt,
            updatedAt: fileModifiedAt
        )
    }
}
