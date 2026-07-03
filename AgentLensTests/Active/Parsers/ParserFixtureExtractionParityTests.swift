import XCTest
@testable import OpenBurnBar

/// Marker so `Bundle(for:)` resolves the `OpenBurnBarTests` resource bundle
/// (extracted fixtures live under `AgentLensTests/Fixtures/ParserContract`).
private final class ParserExtractionBundleMarker {}

/// **VAL-P0-HARNESS-023 — Extract the 15 inline parser fixtures to portable
/// on-disk vectors.**
///
/// The 15 inline `ParserTestFixtures` builders were the only source of the
/// parser corpus and stamped wall-clock time, so they could not be extracted to
/// a portable, language-neutral vector a Windows parser port could reproduce.
/// This suite proves the extraction changed nothing observable:
///
///   1. **Byte-identical extraction.** Every committed on-disk fixture file is
///      byte-for-byte equal to its deterministic builder's default render — the
///      vector is a faithful capture, not a hand-authored approximation.
///   2. **Byte-identical parser output, old-inline vs new-file.** For all 15
///      fixtures, running the REAL production parser over the inline builder
///      output and over the extracted on-disk file produces an identical
///      parser-output contract projection (`ParserOutputContractRecord`).
///   3. **Clock-freeze is behaviour-preserving.** For the 5 fixtures that
///      formerly stamped `Date()`, rendering with a perturbed timestamp yields
///      the identical contract projection — proving the freeze changed no
///      token/session/model/cost output, only the (excluded) wall-clock field.
///
/// The 13 per-provider parser suites remain green against the same builders
/// (proven byte-identical to the extracted vectors here) — that is a separate
/// `scripts/test-openburnbar-app.sh` run, not an assertion in this file.
@MainActor
final class ParserFixtureExtractionParityTests: XCTestCase {

    /// The 5 fixtures that historically stamped `Date()` and are now frozen +
    /// clock-injectable. (The other 10 already used fixed epochs.)
    private static let formerlyWallClockFixtureIDs: Set<String> = [
        "claudeCodeSession",
        "factoryDroidSession",
        "factoryDroidSessionWithSettings",
        "sessionWithMissingUsage",
        "sessionWithCacheTokens"
    ]

    // MARK: - Corpus completeness

    func test_corpus_coversExactlyThe15ExtractedFixtures() {
        let expected: Set<String> = [
            "claudeCodeSession",
            "claudeCodeMultiTurnSession",
            "claudeCodeWithSubagent",
            "sessionWithMalformedLines",
            "sessionWithMissingUsage",
            "sessionWithCacheTokens",
            "claudeStreamingSessionWithDuplicateUsage",
            "emptySession",
            "factoryDroidSession",
            "factoryDroidSessionWithSettings",
            "codexRolloutSession",
            "codexRolloutSessionWithLastUsageOnly",
            "codexRolloutSessionWithPartialTokenCountAndDeltas",
            "hermesSessionSnapshot",
            "hermesToolHeavySessionSnapshot"
        ]
        XCTAssertEqual(
            Set(ParserContractCorpus.fixtures.map(\.id)), expected,
            "The extracted corpus must map exactly to the 15 inline ParserTestFixtures builders."
        )
        XCTAssertEqual(ParserContractCorpus.fixtures.count, 15)
    }

    // MARK: - (1) Byte-identical extraction

    func test_extractedFixtures_areByteIdenticalToDeterministicBuilders() throws {
        let bundle = Bundle(for: ParserExtractionBundleMarker.self)
        var validated = 0
        for fixture in ParserContractCorpus.fixtures {
            let rendered = ParserContractCorpus.builderArtifacts(for: fixture)
            guard let committed = try ParserContractCorpus.committedArtifacts(for: fixture, bundle: bundle) else {
                throw XCTSkip(
                    "Extracted fixture files are not bundled yet. Generate them via "
                    + "ParserOutputContractGoldenTests (see its header), copy into "
                    + "AgentLensTests/Fixtures/ParserContract/, regenerate the project, and re-run."
                )
            }
            XCTAssertEqual(
                rendered.count, committed.count,
                "Fixture \(fixture.id): committed file count != builder artifact count."
            )
            for (render, disk) in zip(rendered, committed) {
                XCTAssertEqual(
                    render.content, disk.content,
                    "Fixture \(fixture.id) role \(render.role.rawValue): committed on-disk vector "
                    + "(\(disk.fileName)) drifted from the deterministic builder render."
                )
                validated += 1
            }
        }
        XCTAssertGreaterThanOrEqual(validated, 15, "Every fixture must contribute at least one file.")
    }

    // MARK: - (2) Byte-identical parser output, old-inline vs new-file

    func test_parserOutput_isIdenticalOldInlineVsExtractedFile() async throws {
        let bundle = Bundle(for: ParserExtractionBundleMarker.self)
        for fixture in ParserContractCorpus.fixtures {
            guard let committed = try ParserContractCorpus.committedArtifacts(for: fixture, bundle: bundle) else {
                throw XCTSkip("Extracted fixture files are not bundled yet (see the header workflow).")
            }
            let inlineContract = try await ParserContractCorpus.contract(
                for: fixture, artifacts: ParserContractCorpus.builderArtifacts(for: fixture)
            )
            let fileContract = try await ParserContractCorpus.contract(for: fixture, artifacts: committed)
            XCTAssertEqual(
                inlineContract, fileContract,
                "Parser output diverged old-inline vs new-file for fixture \(fixture.id) "
                + "(\(fixture.parserName))."
            )
        }
    }

    // MARK: - (3) Clock-freeze is behaviour-preserving

    func test_formerlyWallClockFixtures_areTimestampInvariant() async throws {
        // A timestamp deliberately far from the frozen reference; a leaked
        // wall-clock stamp would surface as a contract diff (it must not).
        let perturbed = Date(timeIntervalSince1970: 1_609_459_200) // 2021-01-01T00:00:00Z

        for fixture in ParserContractCorpus.fixtures
        where Self.formerlyWallClockFixtureIDs.contains(fixture.id) {
            guard let perturbedArtifacts = perturbedArtifacts(for: fixture.id, now: perturbed) else {
                XCTFail("Missing perturbed render for formerly-wall-clock fixture \(fixture.id)")
                continue
            }
            let frozen = try await ParserContractCorpus.contract(
                for: fixture, artifacts: ParserContractCorpus.builderArtifacts(for: fixture)
            )
            let shifted = try await ParserContractCorpus.contract(for: fixture, artifacts: perturbedArtifacts)
            XCTAssertEqual(
                frozen, shifted,
                "Fixture \(fixture.id): parser output depends on the wall-clock timestamp — freezing "
                + "the clock is NOT behaviour-preserving for the contract projection."
            )
        }
    }

    // MARK: - Perturbed renders (only the 5 formerly-wall-clock fixtures)

    private func perturbedArtifacts(for id: String, now: Date) -> [ParserContractCorpus.Artifact]? {
        typealias Artifact = ParserContractCorpus.Artifact
        switch id {
        case "claudeCodeSession":
            return [Artifact(role: .primary, resourceName: "pc-claude-basic-session", fileExtension: "jsonl",
                             content: ParserTestFixtures.claudeCodeSession(now: now))]
        case "factoryDroidSession":
            return [Artifact(role: .primary, resourceName: "pc-factory-basic", fileExtension: "jsonl",
                             content: ParserTestFixtures.factoryDroidSession(now: now))]
        case "factoryDroidSessionWithSettings":
            let bundle = ParserTestFixtures.factoryDroidSessionWithSettings(
                sessionId: "factory-with-settings", model: "glm-4", inputTokens: 800, outputTokens: 400, now: now
            )
            var artifacts: [Artifact] = [
                Artifact(role: .primary, resourceName: "pc-factory-with-settings", fileExtension: "jsonl", content: bundle.jsonl),
                Artifact(role: .settings, resourceName: "pc-factory-with-settings-settings", fileExtension: "json", content: bundle.settings)
            ]
            if let metadata = bundle.metadata {
                artifacts.append(Artifact(role: .metadata, resourceName: "pc-factory-with-settings-metadata", fileExtension: "json", content: metadata))
            }
            return artifacts
        case "sessionWithMissingUsage":
            return [Artifact(role: .primary, resourceName: "pc-claude-missing-usage", fileExtension: "jsonl",
                             content: ParserTestFixtures.sessionWithMissingUsage(now: now))]
        case "sessionWithCacheTokens":
            return [Artifact(role: .primary, resourceName: "pc-claude-cache-tokens", fileExtension: "jsonl",
                             content: ParserTestFixtures.sessionWithCacheTokens(now: now))]
        default:
            return nil
        }
    }
}
