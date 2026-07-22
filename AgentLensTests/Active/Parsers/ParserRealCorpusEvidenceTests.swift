import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

// MARK: - ParserRealCorpusEvidenceTests

/// LOCAL-ONLY EVIDENCE HARNESS — not part of the regular suite.
///
/// Runs the real app-side Codex parser over the machine's actual `~/.codex`
/// corpus under production-shaped `ParserResourcePolicy` limits, and records
/// the resource evidence the 2026-07-16 incident fix is judged by (process
/// footprint delta, wall time, bytes admitted, files deferred).
///
/// Gated behind `OPENBURNBAR_REAL_CORPUS_EVIDENCE=1` because it depends on
/// whatever corpus the current machine happens to have (potentially tens of
/// GB) — it is deliberately non-hermetic and must never run in CI. Example:
///
///     OPENBURNBAR_REAL_CORPUS_EVIDENCE=1 xcodebuild test … \
///         -only-testing:OpenBurnBarTests/ParserRealCorpusEvidenceTests
///
/// The parser is constructed with the DEFAULT home directory (real corpus)
/// but a throwaway support root, so the live app's parser cache is never
/// touched and the pass measures the cold-cache worst case.
final class ParserRealCorpusEvidenceTests: XCTestCase {

    func test_realCodexCorpus_governedUsageRefreshPass_staysWithinFootprintBounds() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OPENBURNBAR_REAL_CORPUS_EVIDENCE"] == "1",
            "Local-only evidence harness: set OPENBURNBAR_REAL_CORPUS_EVIDENCE=1 to run against the real ~/.codex corpus."
        )

        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-real-corpus-evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        // Real home (real corpus), throwaway cache.
        let parser = OpenBurnBar.CodexParser(
            fileManager: .default,
            appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: scratchRoot)
        )

        // Production-shaped limits (usage-refresh lane of ParserResourcePolicy):
        // 256MB of new content per pass, 4GB hard footprint ceiling.
        let governor = ParserResourceGovernor(
            limits: ParserResourceLimits(
                fileByteBudget: ParserResourcePolicy.refreshFileByteBudget,
                memoryCeilingBytes: ParserResourcePolicy.memoryCeilingBytes,
                memorySoftLimitBytes: ParserResourcePolicy.memorySoftLimitBytes
            )
        )

        let footprintBefore = ParserResourceGovernor.currentPhysicalFootprint()
        let startedAt = Date()
        let result = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            resourceGovernor: governor
        ))
        let duration = Date().timeIntervalSince(startedAt)
        let footprintAfter = ParserResourceGovernor.currentPhysicalFootprint()
        let footprintDelta = footprintAfter - footprintBefore

        let megabyte: Int64 = 1024 * 1024
        print(
            "EVIDENCE codex_real_corpus_usage_refresh "
                + "footprint_delta_mb=\(footprintDelta / megabyte) "
                + "footprint_before_mb=\(footprintBefore / megabyte) "
                + "footprint_after_mb=\(footprintAfter / megabyte) "
                + "duration_s=\(String(format: "%.2f", duration)) "
                + "consumed_mb=\(governor.consumedBytes / megabyte) "
                + "deferred_files=\(governor.deferredFileCount) "
                + "usages=\(result.usages.count)"
        )

        // The incident pass grew the process by tens of GB. A governed
        // usage-refresh pass over the same class of corpus must stay far
        // under that — 1.5GB of headroom is generous for a cold cache.
        XCTAssertLessThan(
            footprintDelta,
            Int64(1.5 * 1024) * megabyte,
            "governed usage-refresh pass must not balloon the process footprint"
        )
        XCTAssertTrue(result.conversations.isEmpty, "usage-only pass must not build conversation bodies")
    }
}
