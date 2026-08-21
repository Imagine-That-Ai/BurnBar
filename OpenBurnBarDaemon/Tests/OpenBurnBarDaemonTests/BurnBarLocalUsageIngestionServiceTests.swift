import Foundation
import XCTest
@testable import OpenBurnBarDaemon
import OpenBurnBarEngine

final class BurnBarLocalUsageIngestionServiceTests: XCTestCase {
    func testLinuxDefaultConfiguresEveryCoreParserAndXDGExtensionRoot() {
        let home = URL(fileURLWithPath: "/home/test-user", isDirectory: true)
        let parsers = BurnBarLocalUsageIngestionService.linuxDefaultParsers(
            environment: ["XDG_CONFIG_HOME": "/srv/test-config"],
            homeDirectoryURL: home
        )

        XCTAssertEqual(parsers.count, 32)
        XCTAssertEqual(Set(parsers.map(\.provider)), [
            .factory, .claudeCode, .copilot, .cursorAgent, .codex, .windsurf,
            .warp, .kimi, .xAI, .cline, .kiloCode, .rooCode, .forgeDev,
            .augment, .hermes, .geminiCLI, .antigravity, .goose, .aider,
            .cursor, .openCode, .piAgent, .openClaw, .ollama, .junie, .zai,
            .minimax, .omp, .openClaude, .primeAgent, .muse, .fx
        ])

        let paths = BurnBarLocalUsageIngestionService.linuxClineStoragePaths(
            environment: ["XDG_CONFIG_HOME": "/srv/test-config"],
            homeDirectoryURL: home
        )
        XCTAssertEqual(paths[.cline]?.count, 4)
        XCTAssertEqual(paths[.kiloCode]?.count, 4)
        XCTAssertEqual(paths[.rooCode]?.count, 8)
        XCTAssertTrue(paths.values.flatMap { $0 }.allSatisfy { $0.hasPrefix("/srv/test-config/") })

        let fallbackPaths = BurnBarLocalUsageIngestionService.linuxClineStoragePaths(
            environment: ["XDG_CONFIG_HOME": "relative-path-is-invalid"],
            homeDirectoryURL: home
        )
        XCTAssertTrue(fallbackPaths.values.flatMap { $0 }.allSatisfy { $0.hasPrefix("/home/test-user/.config/") })
    }

    func testLinuxDefaultParserMembershipAndOrderFollowGeneratedIngestionCatalog() {
        let parsers = BurnBarLocalUsageIngestionService.linuxDefaultParsers(
            environment: [:],
            homeDirectoryURL: URL(fileURLWithPath: "/home/test-user", isDirectory: true)
        )
        let expected = AgentProviderIngestionCatalog.entries
            .filter { $0.ingestion == .localParser }
            .map(\.provider)

        XCTAssertEqual(parsers.map(\.provider), expected)
        XCTAssertEqual(
            Set(parsers.map(\.provider)),
            AgentProviderIngestionCatalog.localParserProviders
        )
    }

    func testRefreshPersistsOnlyCumulativeDeltasAcrossRestartAndModelTransition() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        let first = fixture.usage(model: "model-a", input: 10, output: 5, cost: 0.15, start: 100, end: 200)
        let firstService = fixture.service(usages: [first])

        let initial = await firstService.refresh()
        let unchanged = await firstService.refresh()

        XCTAssertEqual(initial.insertedDeltas, 1)
        XCTAssertEqual(unchanged.unchangedRows, 1)
        XCTAssertTrue(initial.failures.isEmpty)

        let grown = fixture.usage(model: "model-b", input: 17, output: 8, cost: 0.25, start: 100, end: 300)
        let restarted = fixture.service(usages: [grown])
        let growth = await restarted.refresh()

        XCTAssertEqual(growth.insertedDeltas, 1)
        XCTAssertTrue(growth.failures.isEmpty, growth.failures.joined(separator: "\n"))
        let records = try await fixture.recorder.records()
        XCTAssertEqual(records.count, 2)
        guard records.count == 2 else { return }
        XCTAssertEqual(records[1].event.modelID, "model-b")
        XCTAssertEqual(records[1].event.inputTokens, 7)
        XCTAssertEqual(records[1].event.outputTokens, 3)
        XCTAssertEqual(records[1].event.cost, 0.10, accuracy: 0.000_000_001)
        let projection = try await fixture.recorder.projection()
        XCTAssertEqual(projection.totals.inputTokens, 17)
        XCTAssertEqual(projection.totals.outputTokens, 8)

        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.checkpointURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        #endif
    }

    func testTransientRegressionRetainsHighWaterButNewGenerationImportsFromZero() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        _ = await fixture.service(usages: [
            fixture.usage(model: "model", input: 100, output: 20, cost: 1.2, start: 100, end: 200)
        ]).refresh()

        let truncated = await fixture.service(usages: [
            fixture.usage(model: "model", input: 10, output: 2, cost: 0.12, start: 100, end: 250)
        ]).refresh()
        XCTAssertEqual(truncated.unchangedRows, 1)
        let truncatedRecords = try await fixture.recorder.records()
        XCTAssertEqual(truncatedRecords.count, 1)

        let recovered = await fixture.service(usages: [
            fixture.usage(model: "model", input: 120, output: 25, cost: 1.45, start: 100, end: 300)
        ]).refresh()
        XCTAssertEqual(recovered.insertedDeltas, 1)
        let recoveredRecords = try await fixture.recorder.records()
        XCTAssertEqual(recoveredRecords.count, 2)
        guard recoveredRecords.count == 2 else { return }
        XCTAssertEqual(recoveredRecords[1].event.inputTokens, 20)
        XCTAssertEqual(recoveredRecords[1].event.outputTokens, 5)

        let reset = await fixture.service(usages: [
            fixture.usage(model: "model", input: 7, output: 3, cost: 0.1, start: 400, end: 500)
        ]).refresh()
        XCTAssertEqual(reset.insertedDeltas, 1)
        let resetRecords = try await fixture.recorder.records()
        XCTAssertEqual(resetRecords.count, 3)
        guard resetRecords.count == 3 else { return }
        XCTAssertEqual(resetRecords[2].event.inputTokens, 7)
        XCTAssertEqual(resetRecords[2].event.outputTokens, 3)
    }

    func testCorruptCheckpointFailsClosedBeforeParserOrLedgerMutation() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.remove() }
        try Data("not-json".utf8).write(to: fixture.checkpointURL)

        let report = await fixture.service(usages: [
            fixture.usage(model: "model", input: 10, output: 2, cost: 0.1, start: 100, end: 200)
        ]).refresh()

        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].hasPrefix("checkpoint:"))
        let records = try await fixture.recorder.records()
        XCTAssertTrue(records.isEmpty)
    }
}

private struct FixedUsageParser: LogParser {
    let provider: AgentProvider = .copilot
    let usages: [TokenUsage]

    func parse(options: LogParseOptions) async throws -> ParseResult {
        ParseResult(usages: usages, conversations: [])
    }
}

private final class IngestionFixture {
    private static let epochBase: TimeInterval = 1_700_000_000
    let root: URL
    let checkpointURL: URL
    let recorder: BurnBarUsageRecorder

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-usage-ingestion-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        checkpointURL = root.appendingPathComponent("checkpoint.json")
        recorder = BurnBarUsageRecorder(
            fileURL: root.appendingPathComponent("ledger.jsonl"),
            projectionFileURL: root.appendingPathComponent("projection.json")
        )
    }

    func service(usages: [TokenUsage]) -> BurnBarLocalUsageIngestionService {
        BurnBarLocalUsageIngestionService(
            parsers: [FixedUsageParser(usages: usages)],
            usageRecorder: recorder,
            checkpointURL: checkpointURL
        )
    }

    func usage(
        model: String,
        input: Int,
        output: Int,
        cost: Double,
        start: TimeInterval,
        end: TimeInterval
    ) -> TokenUsage {
        TokenUsage(
            provider: .copilot,
            sessionId: "session-1",
            projectName: "Copilot",
            model: model,
            inputTokens: input,
            outputTokens: output,
            costUSD: cost,
            startTime: Date(timeIntervalSince1970: Self.epochBase + start),
            endTime: Date(timeIntervalSince1970: Self.epochBase + end),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
