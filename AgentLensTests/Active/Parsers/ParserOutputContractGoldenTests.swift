import XCTest
@testable import OpenBurnBar

/// Marker so `Bundle(for:)` resolves the `OpenBurnBarTests` resource bundle,
/// where the committed parser-output golden + extracted fixture corpus are
/// bundled (they live under `AgentLensTests/Fixtures/ParserContract`, which
/// `project.yml` bundles as test resources).
private final class ParserContractBundleMarker {}

/// **VAL-P0-HARNESS-024 — Parser-output contract format + Mac golden.**
///
/// Defines and validates the portable parser-output contract (`TokenUsage` /
/// session / model / cost, see `ParserOutputContract`) and freezes a **Mac
/// golden** over the extracted fixture corpus (`ParserContractCorpus`). A future
/// Windows parser port must regenerate this golden BYTE-IDENTICALLY from the same
/// on-disk fixtures (the G2 headline of the Windows-port master plan). That
/// Windows diff is Phase-2; this test delivers the format + Mac golden now and
/// guards it against drift.
///
/// ### What is proven here
///   1. **Determinism.** The golden regenerated twice from the builders is
///      byte-identical — no wall-clock / iteration-order leakage.
///   2. **Committed-golden match.** The freshly generated golden equals the
///      committed `parser-output-golden.json` (catches a stale golden after a
///      parser change).
///   3. **Corpus↔golden consistency.** Regenerating the golden from the COMMITTED
///      on-disk fixture files (not the inline builders) also equals the committed
///      golden — so the extracted vectors and the golden can never silently drift
///      apart.
///
/// ### (Re)generation workflow (macOS)
/// App-hosted XCTest can lack the Documents-folder TCC grant, so the test never
/// writes into the repo. It emits fresh candidate artifacts (the 15 fixture files
/// + the golden) to a writable output dir (temp, overridable via
/// `OPENBURNBAR_PARSER_CONTRACT_OUT` / `TEST_RUNNER_OPENBURNBAR_PARSER_CONTRACT_OUT`).
/// To (re)generate the committed corpus:
///
///   1. `TEST_RUNNER_OPENBURNBAR_PARSER_CONTRACT_OUT=/tmp/obb-parser-contract-out \`
///      `  scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/ParserOutputContractGoldenTests`
///   2. Copy `/tmp/obb-parser-contract-out/ParserContract/*` into
///      `AgentLensTests/Fixtures/ParserContract/`.
///   3. Regenerate the Xcode project (`xcodegen generate`) so the resources bundle.
///   4. Re-run — the committed-golden assertions now activate and pass.
@MainActor
final class ParserOutputContractGoldenTests: XCTestCase {

    private let goldenBaseName = "parser-output-golden"

    // MARK: - Golden: determinism + committed match

    func test_parserOutputGolden_isDeterministicAndMatchesCommitted() async throws {
        // (1) Determinism — regenerate twice from the inline builders.
        let genA = try await generateGolden(from: .builders)
        let genB = try await generateGolden(from: .builders)
        XCTAssertEqual(
            try ParserOutputContract.encode(genA), try ParserOutputContract.encode(genB),
            "Parser-output golden is not deterministic across regeneration — a wall-clock, "
            + "device id, or iteration-order field leaked into the contract projection."
        )

        // The corpus must cover exactly the 15 extracted fixtures.
        XCTAssertEqual(genA.fixtures.count, 15, "Expected all 15 extracted fixtures in the golden.")
        XCTAssertEqual(
            Set(genA.fixtures.map(\.fixtureId)).count, 15, "Fixture ids in the golden must be unique."
        )

        // (2) Emit candidate artifacts (fixture files + golden) to the writable
        //     output dir — never the repo (TCC-safe).
        let outputDir = try corpusOutputDirectory()
        try emitCandidateCorpus(golden: genA, to: outputDir)
        print("[parser-contract] Candidate corpus + golden written to \(outputDir.path)")

        // (3) Validate against the COMMITTED (bundled) golden.
        guard let committedURL = bundledGoldenURL() else {
            throw XCTSkip(
                "No committed parser-output golden bundled yet. Copy \(outputDir.path)/ParserContract/* into "
                + "AgentLensTests/Fixtures/ParserContract/, regenerate the project, and re-run."
            )
        }
        let committed = try ParserOutputContract.decode(Data(contentsOf: committedURL))

        XCTAssertEqual(
            genA, committed,
            "Freshly generated golden diverged from the committed golden — a parser changed its "
            + "output. Regenerate the golden (see the file header) after confirming the change is intended."
        )

        // The committed golden's canonical bytes must match a fresh encode
        // (guards against a hand-edited / reformatted golden file).
        XCTAssertEqual(
            try ParserOutputContract.encode(committed), try Data(contentsOf: committedURL),
            "Committed golden is not in canonical form — regenerate it, do not hand-edit."
        )

        // (4) Corpus↔golden consistency: regenerate the golden from the COMMITTED
        //     on-disk fixture files and require the same result.
        let fromFiles = try await generateGolden(from: .committedFiles(Bundle(for: ParserContractBundleMarker.self)))
        XCTAssertEqual(
            fromFiles, committed,
            "Golden regenerated from the committed on-disk fixtures != committed golden — the "
            + "extracted vectors and the golden have drifted apart."
        )
    }

    // MARK: - Generation

    private enum GoldenSource {
        case builders
        case committedFiles(Bundle)
    }

    private func generateGolden(from source: GoldenSource) async throws -> ParserOutputGolden {
        var fixtures: [ParserFixtureContract] = []
        for fixture in ParserContractCorpus.fixtures {
            let artifacts: [ParserContractCorpus.Artifact]
            switch source {
            case .builders:
                artifacts = ParserContractCorpus.builderArtifacts(for: fixture)
            case .committedFiles(let bundle):
                guard let committed = try ParserContractCorpus.committedArtifacts(for: fixture, bundle: bundle) else {
                    throw XCTSkip("Committed fixture files for \(fixture.id) are not bundled yet.")
                }
                artifacts = committed
            }
            fixtures.append(try await ParserContractCorpus.contract(for: fixture, artifacts: artifacts))
        }
        return ParserOutputContract.golden(from: fixtures)
    }

    // MARK: - Candidate emission (writable output dir only)

    private func emitCandidateCorpus(golden: ParserOutputGolden, to outputDir: URL) throws {
        let fm = FileManager.default
        let corpusDir = outputDir.appendingPathComponent("ParserContract", isDirectory: true)
        try fm.createDirectory(at: corpusDir, withIntermediateDirectories: true)

        // 15 fixtures → their default-argument builder bytes (the canonical vectors).
        for fixture in ParserContractCorpus.fixtures {
            for artifact in ParserContractCorpus.builderArtifacts(for: fixture) {
                try artifact.content.write(
                    to: corpusDir.appendingPathComponent(artifact.fileName),
                    atomically: true, encoding: .utf8
                )
            }
        }

        // The golden itself.
        try ParserOutputContract.encode(golden).write(
            to: corpusDir.appendingPathComponent("\(goldenBaseName).json"), options: .atomic
        )
    }

    // MARK: - Paths

    private func corpusOutputDirectory() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let raw = env["OPENBURNBAR_PARSER_CONTRACT_OUT"] ?? env["TEST_RUNNER_OPENBURNBAR_PARSER_CONTRACT_OUT"]
        let dir: URL
        if let raw, !raw.isEmpty {
            dir = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("openburnbar-parser-contract-out", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bundledGoldenURL() -> URL? {
        ParserContractCorpus.bundledURL(
            resource: goldenBaseName, ext: "json", bundle: Bundle(for: ParserContractBundleMarker.self)
        )
    }
}
