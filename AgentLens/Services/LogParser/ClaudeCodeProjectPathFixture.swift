import Foundation
import OpenBurnBarCore

// MARK: - Claude Code Project Path Fixture Format
//
// On-disk schema for capturing `<directory-name> ↔ <cwd>` observations from real
// Claude Code installs. This is the format `VAL-P0-PATH-022` fills in from a
// genuine `%USERPROFILE%\.claude\projects\` capture on Windows; the macOS rows
// shipped alongside it (`captured: true`, `style: .posix`) are the ground-truth
// seed captured from a live install.
//
// A capture row is authoritative because `sourcePath` is read from the session
// JSONL's own `cwd` field, so `encode(sourcePath) == encodedDirectoryName` must
// hold for every real row — that equality is exactly what the decoder is
// validated against. Pending rows (`captured: false`) document the shapes a real
// Windows capture is expected to confirm without asserting a capture that has not
// happened yet.

/// One captured (or pending) Claude Code project-path encoding observation.
struct ClaudeCodeProjectPathFixture: Codable, Equatable, Sendable {
    /// The directory name exactly as it appears under `.claude/projects/`.
    var encodedDirectoryName: String

    /// The absolute working directory the session recorded (`cwd` in the JSONL),
    /// or `nil` for a pending row awaiting a real capture.
    var sourcePath: String?

    /// The path convention of `sourcePath` (`.posix` for macOS/Linux captures,
    /// `.windows` for Windows captures).
    var style: ClaudeCodeProjectPathCodec.PathStyle

    /// `true` when the row was captured from a real install; `false` for a
    /// synthetic/modeled row that `VAL-P0-PATH-022` should confirm.
    var captured: Bool

    /// Free-form provenance / description for the row.
    var note: String?
}

/// A versioned collection of `ClaudeCodeProjectPathFixture` rows.
struct ClaudeCodeProjectPathFixtureSet: Codable, Equatable, Sendable {
    /// Schema version for forward-compatible evolution.
    var schemaVersion: Int

    /// What this fixture set is and where its captured rows came from.
    var description: String

    /// The tool/agent/process that produced the file (provenance).
    var generatedBy: String

    /// The observation rows.
    var fixtures: [ClaudeCodeProjectPathFixture]

    /// The schema version this build understands.
    static let currentSchemaVersion = 1

    // MARK: Decoding

    /// Decode a fixture set from JSON `Data`.
    static func decode(from data: Data) throws -> ClaudeCodeProjectPathFixtureSet {
        try JSONDecoder().decode(ClaudeCodeProjectPathFixtureSet.self, from: data)
    }

    /// Encode this fixture set to pretty, key-sorted JSON `Data`.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    // MARK: Validation

    /// A row whose `encode(sourcePath)` disagrees with its recorded directory name.
    struct Mismatch: Equatable, Sendable {
        let encodedDirectoryName: String
        let sourcePath: String
        let expectedEncoding: String
    }

    /// Verify every captured row: `encode(sourcePath) == encodedDirectoryName`.
    /// Pending rows (`captured == false`) are skipped. Returns the mismatches
    /// (empty when every captured row is self-consistent).
    func capturedRowMismatches() -> [Mismatch] {
        fixtures.compactMap { fixture in
            guard fixture.captured, let source = fixture.sourcePath else { return nil }
            let expected = ClaudeCodeProjectPathCodec.encode(source)
            guard expected != fixture.encodedDirectoryName else { return nil }
            return Mismatch(
                encodedDirectoryName: fixture.encodedDirectoryName,
                sourcePath: source,
                expectedEncoding: expected
            )
        }
    }
}
