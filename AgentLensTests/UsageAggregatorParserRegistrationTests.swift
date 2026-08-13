@testable import BurnBar
import GRDB
import XCTest

// MARK: - Usage Aggregator Parser Registration Tests

/// VAL-PROV-009/018: the new parsers are registered in UsageAggregator, parse
/// their fixture trees with exact per-provider counts, and re-parsing is
/// idempotent (no duplicate rows).
///
/// NOTE: a full `refreshAll()` is NOT exercised here because the pre-existing
/// parsers (claude/factory/codex/hermes/kimi/…) resolve their roots from the
/// real `~`-based `logDirectory` values and write parse caches into the real
/// app support dir — running them in a unit test would scan the user's real
/// agent roots and mutate real app state, violating the mission's
/// hermetic-first rule. The new parsers' fixture-environment behavior is
/// covered exactly by PiParserTests/GrokCLIParserTests; this class covers the
/// aggregator registration contract and idempotency at the source level.
@MainActor
final class UsageAggregatorParserRegistrationTests: XCTestCase {

    private var fixturesRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .path
    }

    // MARK: VAL-PROV-009 — registration

    func test_newParsersRegistered() throws {
        let aggregator = try makeAggregator()
        XCTAssertTrue(aggregator.registeredParserProviders.contains(.pi))
        XCTAssertTrue(aggregator.registeredParserProviders.contains(.grokCLI))
        XCTAssertTrue(aggregator.registeredParserProviders.contains(.grokBot))
    }

    func test_existingProvidersStillRegistered() throws {
        let aggregator = try makeAggregator()
        for provider in [AgentProvider.factory, .claudeCode, .codex, .hermes, .kimi, .geminiCLI, .goose] {
            XCTAssertTrue(
                aggregator.registeredParserProviders.contains(provider),
                "\(provider) must remain registered (no regression)"
            )
        }
    }

    // MARK: VAL-PROV-009 — fixture-environment counts

    func test_newParsersParseFixturesWithExactCounts() async throws {
        let piParser = PiParser(
            sessionsRoot: fixturesRoot + "/pi/agent/sessions"
        )
        let grokParser = GrokCLIParser(
            sessionsRoot: fixturesRoot + "/grok/sessions"
        )

        let piResult = try await piParser.parse()
        let grokResult = try await grokParser.parse()

        // Pi fixture tree: 27 transcripts; 1 zero-byte + 1 blank-lines-only
        // are silent no-ops; 1 has no timestamps; 3 have no usage; 1 has no
        // usage and no timestamps → 19 rows.
        XCTAssertEqual(piResult.usages.count, 19, "Pi rows must match the fixture baseline")
        XCTAssertEqual(grokResult.usages.count, 5, "Grok CLI rows must match the fixture baseline")
        XCTAssertTrue(piResult.usages.allSatisfy { $0.provider == .pi })
        XCTAssertTrue(grokResult.usages.allSatisfy { $0.provider == .grokCLI })
    }

    // MARK: VAL-PROV-018 — idempotent re-parse

    func test_reParseIsIdempotent() async throws {
        let piParser = PiParser(sessionsRoot: fixturesRoot + "/pi/agent/sessions")
        let grokParser = GrokCLIParser(sessionsRoot: fixturesRoot + "/grok/sessions")

        let firstPi = try await piParser.parse()
        let firstGrok = try await grokParser.parse()
        let secondPi = try await piParser.parse()
        let secondGrok = try await grokParser.parse()

        XCTAssertEqual(firstPi.usages.count, secondPi.usages.count,
                       "Pi counts must be identical after re-parse")
        XCTAssertEqual(firstGrok.usages.count, secondGrok.usages.count,
                       "Grok CLI counts must be identical after re-parse")

        // No duplicate sessionIds for the new providers.
        let piSessionIds = secondPi.usages.map(\.sessionId)
        let grokSessionIds = secondGrok.usages.map(\.sessionId)
        XCTAssertEqual(Set(piSessionIds).count, piSessionIds.count, "No duplicate Pi sessionIds")
        XCTAssertEqual(Set(grokSessionIds).count, grokSessionIds.count, "No duplicate Grok CLI sessionIds")
    }

    // MARK: helpers

    private func makeAggregator() throws -> UsageAggregator {
        let queue = try DatabaseQueue(path: ":memory:")
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        return UsageAggregator(
            dataStore: store,
            settingsManager: SettingsManager.shared,
            quotaService: ProviderQuotaService(
                appPaths: BurnBarAppPaths(
                    applicationSupportRoot: FileManager.default.temporaryDirectory
                ),
                homeDirectoryURL: FileManager.default.temporaryDirectory
            ),
            artifactDiscoveryService: ArtifactDiscoveryService(
                dataStore: store,
                settingsProvider: SettingsManager.shared
            ),
            projectionPipelineService: ProjectionPipelineService(
                dataStore: store,
                leaseOwner: "usage-parser-registration-tests",
                chunker: ProjectionChunker(),
                chunkEmbedder: DeterministicFakeEmbeddingProvider()
            )
        )
    }
}
