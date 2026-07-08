import XCTest
@testable import OpenBurnBar

/// Marker so `Bundle(for:)` resolves the `OpenBurnBarTests` resource bundle,
/// where the committed live-stream golden pair is bundled (they live under
/// `AgentLensTests/Fixtures/StreamGolden`, which `project.yml` bundles as test
/// resources).
private final class StreamGoldenBundleMarker {}

/// **VAL-P0-STREAM-028 — Live `claude --output-format stream-json` Mac golden +
/// parse-diff harness.**
///
/// Captures a REAL, authenticated `claude --output-format stream-json` run on
/// macOS (Claude Code 2.1.191) for a fixed prompt/scenario that exercises
/// representative event variety, commits the RAW stream verbatim, and re-parses
/// it through the SHIPPED live parser (`ClaudeCodeStreamJSONParser` — the exact
/// closure `CLIProcessStreamRunner.runClaude` feeds `stdout` lines to) to prove
/// the live CLIBridge→stream→parser path, not a static reimplementation.
///
/// The RAW stream (`claude-stream-mac-golden.jsonl`) is committed so Windows
/// (STREAM-029) can replay the identical bytes and diff the identical parsed
/// events. The fixed scenario is documented at
/// `docs/windows-port/STREAM_JSON_MAC_GOLDEN.md`.
///
/// ### What is proven here
///   1. **Re-parse match.** Re-parsing the committed RAW stream through the
///      shipped parser yields exactly the committed N events (`claude-stream-mac-
///      golden-events.json`) — the STREAM-028 headline.
///   2. **Determinism.** Re-parsing twice is byte-identical (no ordering leakage).
///   3. **Representative variety.** The parsed events cover the kinds the Claude
///      stream parser actually emits (toolUse + toolResult + text), and the RAW
///      stream exercised system/init, assistant, user, and result-with-usage.
///   4. **Canonical committed golden.** The committed events golden is in canonical
///      form (guards against a hand-edited / reformatted golden).
///   5. **Raw↔events consistency.** The raw metadata (line count + event-kind
///      histogram) recomputed from the committed RAW equals the committed golden's
///      — the two committed files can never silently drift apart.
///
/// ### (Re)capture workflow (macOS) — see the scenario doc for the full recipe
/// App-hosted XCTest can lack the Documents-folder TCC grant, so the test never
/// writes into the repo; it emits a fresh candidate events golden to a writable
/// output dir (temp, overridable via `OPENBURNBAR_STREAM_GOLDEN_OUT` /
/// `TEST_RUNNER_OPENBURNBAR_STREAM_GOLDEN_OUT`). To refresh after a deliberate
/// parser change: re-run, copy the emitted `claude-stream-mac-golden-events.json`
/// into `AgentLensTests/Fixtures/StreamGolden/`, `xcodegen generate`, re-run.
final class ClaudeStreamGoldenParseDiffTests: XCTestCase {

    // MARK: - Parse-diff: re-parse the RAW golden, assert N events match

    func test_liveStreamGolden_reparsesToCommittedEvents() throws {
        let bundle = Bundle(for: StreamGoldenBundleMarker.self)

        guard let rawURL = StreamParseContract.bundledURL(
            resource: StreamParseContract.rawResourceName, ext: "jsonl", bundle: bundle
        ) else {
            throw XCTSkip("Committed RAW stream golden not bundled yet — regenerate the project so "
                + "AgentLensTests/Fixtures/StreamGolden/*.jsonl bundles as a test resource.")
        }
        let raw = try String(contentsOf: rawURL, encoding: .utf8)

        guard let eventsURL = StreamParseContract.bundledURL(
            resource: StreamParseContract.eventsResourceName, ext: "json", bundle: bundle
        ) else {
            throw XCTSkip("Committed events golden not bundled yet.")
        }
        let committedData = try Data(contentsOf: eventsURL)
        let committed = try StreamParseContract.decode(committedData)

        // (1) Re-parse the committed RAW stream through the SHIPPED parser and
        //     rebuild the golden, trusting only the committed scenario metadata
        //     (documentation) — the parsed events + raw metadata are regenerated.
        let regenerated = StreamParseContract.golden(
            fromRaw: raw,
            scenario: committed.scenario,
            provider: committed.provider,
            parser: committed.parser,
            model: committed.model
        )

        XCTAssertEqual(
            regenerated, committed,
            "Re-parsing the committed RAW stream through the shipped ClaudeCodeStreamJSONParser diverged "
            + "from the committed events golden — either the parser changed its output or the raw/events "
            + "files drifted. Regenerate the events golden (see the file header) after confirming the change."
        )

        // (2) Determinism — a second re-parse is byte-identical.
        let regeneratedAgain = StreamParseContract.golden(
            fromRaw: raw,
            scenario: committed.scenario,
            provider: committed.provider,
            parser: committed.parser,
            model: committed.model
        )
        XCTAssertEqual(
            try StreamParseContract.encode(regenerated), try StreamParseContract.encode(regeneratedAgain),
            "Live stream re-parse is not deterministic across regeneration."
        )

        // (3) The committed events golden is in canonical form (not hand-edited).
        XCTAssertEqual(
            try StreamParseContract.encode(committed), committedData,
            "Committed events golden is not in canonical form — regenerate it, do not hand-edit."
        )

        // (4) Emit a fresh candidate events golden to the writable output dir —
        //     never the repo (TCC-safe).
        let outputDir = try outputDirectory()
        try StreamParseContract.encode(regenerated).write(
            to: outputDir.appendingPathComponent("\(StreamParseContract.eventsResourceName).json"), options: .atomic
        )
        print("[stream-golden] Candidate events golden written to \(outputDir.path)")
    }

    // MARK: - Representative event variety (parsed + raw)

    func test_liveStreamGolden_exercisesRepresentativeVariety() throws {
        let committed = try loadCommittedGolden()

        // Parsed events: the kinds the Claude stream parser actually emits.
        let parsedKinds = Set(committed.events.map(\.kind))
        XCTAssertTrue(parsedKinds.contains("toolUse"),
            "Golden must exercise a tool_use event (representative variety).")
        XCTAssertTrue(parsedKinds.contains("toolResult"),
            "Golden must exercise a tool_result event (representative variety).")
        XCTAssertTrue(parsedKinds.contains("text"),
            "Golden must exercise an assistant text event (representative variety).")
        XCTAssertEqual(committed.eventCount, committed.events.count, "eventCount must equal events.count.")
        XCTAssertGreaterThanOrEqual(committed.eventCount, 3, "Expected at least 3 parsed events.")

        // The tool_use is the Bash tool with its command detail, and the parser
        // extracted the tool_result payload (not a trivial scenario).
        let toolUse = committed.events.first { $0.kind == "toolUse" }
        XCTAssertEqual(toolUse?.toolName, "Bash")
        XCTAssertEqual(toolUse?.detail, "cat marker.txt")
        let toolResult = committed.events.first { $0.kind == "toolResult" }
        XCTAssertEqual(toolResult?.detail, committed.scenario.marker,
            "The tool_result must carry the marker the scenario forced the model to read.")

        // Raw stream: exercised system/init, assistant, user, and result-with-usage.
        let rawTypes = Set(committed.rawEventKinds.map { "\($0.type)/\($0.subtype)" })
        XCTAssertTrue(rawTypes.contains("system/init"), "Raw stream must include a system/init event.")
        XCTAssertTrue(rawTypes.contains("assistant/"), "Raw stream must include assistant events.")
        XCTAssertTrue(rawTypes.contains("user/"), "Raw stream must include the tool_result user event.")
        XCTAssertTrue(rawTypes.contains("result/success"), "Raw stream must include the final result event.")

        // Every parsed event maps back to a real raw line.
        for event in committed.events {
            XCTAssertGreaterThanOrEqual(event.sourceLineIndex, 0)
            XCTAssertLessThan(event.sourceLineIndex, committed.rawLineCount + 1,
                "Parsed event \(event.index) points past the raw stream.")
        }
    }

    // MARK: - Helpers

    private func loadCommittedGolden() throws -> StreamParseGolden {
        let bundle = Bundle(for: StreamGoldenBundleMarker.self)
        guard let url = StreamParseContract.bundledURL(
            resource: StreamParseContract.eventsResourceName, ext: "json", bundle: bundle
        ) else {
            throw XCTSkip("Committed events golden not bundled yet.")
        }
        return try StreamParseContract.decode(Data(contentsOf: url))
    }

    private func outputDirectory() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let raw = env["OPENBURNBAR_STREAM_GOLDEN_OUT"] ?? env["TEST_RUNNER_OPENBURNBAR_STREAM_GOLDEN_OUT"]
        let dir: URL
        if let raw, !raw.isEmpty {
            dir = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("openburnbar-stream-golden-out", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
