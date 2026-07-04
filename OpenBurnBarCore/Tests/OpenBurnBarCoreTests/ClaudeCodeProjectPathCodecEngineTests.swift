import Foundation
import XCTest
@testable import OpenBurnBarCore

/// Windows-port Phase-2: the Claude Code project-path codec (`VAL-P0-PATH-021`),
/// now the single, Windows-buildable source of truth in the Engine. These vectors
/// mirror the macOS app-test coverage against the SAME committed capture corpus,
/// so the decoder that the Windows parser-parity gate runs is proven on macOS too.
final class ClaudeCodeProjectPathCodecEngineTests: XCTestCase {

    // MARK: Fixture locations (read from the source tree, like the other Core vectors)

    /// `<repo>` — four `deletingLastPathComponent` up from this file
    /// (`…/OpenBurnBarCore/Tests/OpenBurnBarCoreTests/<file>.swift`).
    private static let repoRoot = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()   // OpenBurnBarCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // OpenBurnBarCore
        .deletingLastPathComponent()   // <repo>

    /// The canonical PATH-021 capture corpus (shared with the macOS app tests).
    private static let canonicalFixtureURL = repoRoot
        .appendingPathComponent("AgentLensTests/Fixtures/ClaudeCodePaths/claude-code-project-path-fixtures.json")

    /// The copy bundled into the Windows parity harness target.
    private static let harnessFixtureURL = repoRoot
        .appendingPathComponent(
            "OpenBurnBarCore/Sources/OpenBurnBarWindowsParserPathParity/Fixtures/claude-code-project-path-fixtures.json"
        )

    private struct PathFixture: Decodable {
        let encodedDirectoryName: String
        let sourcePath: String?
        let style: ClaudeCodeProjectPathCodec.PathStyle
        let captured: Bool
    }

    private struct PathFixtureFile: Decodable {
        let fixtures: [PathFixture]
    }

    private func loadCanonicalCorpus() throws -> [PathFixture] {
        let data = try Data(contentsOf: Self.canonicalFixtureURL)
        return try JSONDecoder().decode(PathFixtureFile.self, from: data).fixtures
    }

    // MARK: - Ground-truth encode + canonical round-trip over the whole corpus

    func testCorpusEncodeAndCanonicalRoundTrip() throws {
        let fixtures = try loadCanonicalCorpus()
        XCTAssertFalse(fixtures.isEmpty)
        for fixture in fixtures {
            if let source = fixture.sourcePath {
                XCTAssertEqual(
                    ClaudeCodeProjectPathCodec.encode(source),
                    fixture.encodedDirectoryName,
                    "encode(\(source)) must equal \(fixture.encodedDirectoryName)"
                )
            }
            XCTAssertTrue(
                ClaudeCodeProjectPathCodec.canonicalRoundTrips(fixture.encodedDirectoryName, style: fixture.style),
                "canonical round-trip must hold for \(fixture.encodedDirectoryName)"
            )
        }
    }

    // MARK: - The two named forms in VAL-P0-PATH-021

    func testPosixLeadingDashFormDecodes() {
        let decoded = ClaudeCodeProjectPathCodec.decode(
            "-Users-albertonunez-Documents-Developer-BurnBar",
            style: .posix
        )
        XCTAssertEqual(decoded.form, .posixAbsolute)
        XCTAssertEqual(decoded.reconstructedPath, "/Users/albertonunez/Documents/Developer/BurnBar")
    }

    func testWindowsDriveFormDecodes() {
        let decoded = ClaudeCodeProjectPathCodec.decode("C--Users-Alice-project", style: .windows)
        XCTAssertEqual(decoded.form, .windowsDrive)
        XCTAssertEqual(decoded.driveLetter, "C")
        XCTAssertEqual(decoded.reconstructedPath, "C:\\Users\\Alice\\project")
        XCTAssertTrue(ClaudeCodeProjectPathCodec.canonicalRoundTrips("C--Users-Alice-project", style: .windows))
    }

    func testWindowsUNCFormDecodes() {
        let decoded = ClaudeCodeProjectPathCodec.decode("--fileserver-team-project", style: .windows)
        XCTAssertEqual(decoded.form, .windowsUNC)
        XCTAssertEqual(decoded.reconstructedPath, "\\\\fileserver\\team\\project")
    }

    func testAutoStyleTreatsDriveDoubleAsWindows() {
        XCTAssertEqual(ClaudeCodeProjectPathCodec.decode("C--Users-Alice-project").form, .windowsDrive)
        XCTAssertEqual(ClaudeCodeProjectPathCodec.decode("-Users-alberto-x").form, .posixAbsolute)
    }

    // MARK: - Anti-drift: the harness copy is byte-identical to the canonical corpus

    func testHarnessFixtureIsByteIdenticalToCanonicalCorpus() throws {
        let canonical = try Data(contentsOf: Self.canonicalFixtureURL)
        let harness = try Data(contentsOf: Self.harnessFixtureURL)
        XCTAssertEqual(
            harness,
            canonical,
            "The parity-harness bundled fixtures must stay byte-identical to AgentLensTests/Fixtures/ClaudeCodePaths/"
        )
    }
}
