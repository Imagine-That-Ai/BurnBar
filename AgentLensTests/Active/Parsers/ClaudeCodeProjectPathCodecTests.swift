import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Marker so `Bundle(for:)` resolves the `OpenBurnBarTests` resource bundle,
/// which `project.yml` bundles `AgentLensTests/Fixtures/**` (including
/// `ClaudeCodePaths/`) into.
private final class ClaudeCodePathsBundleMarker {}

/// `VAL-P0-PATH-021` — Claude Code Windows path decoder + fixture format.
///
/// Validates the ground-truth encoder, the both-form decoder, the round-trip
/// invariants, and the capture-fixture schema. All vectors run on macOS.
final class ClaudeCodeProjectPathCodecTests: XCTestCase {

    private typealias Codec = OpenBurnBar.ClaudeCodeProjectPathCodec

    // MARK: Encode — ground truth against REAL macOS observations

    /// These exact pairs were read from the `cwd` field inside live
    /// `~/.claude/projects/**/*.jsonl` sessions and confirmed against their
    /// directory names.
    func testEncodeMatchesRealMacOSDirectoryNames() {
        let vectors: [(cwd: String, dir: String)] = [
            ("/Users/albertonunez/Documents/Developer/BurnBar",
             "-Users-albertonunez-Documents-Developer-BurnBar"),
            ("/Users/albertonunez/.hermes/hermes-agent",
             "-Users-albertonunez--hermes-hermes-agent"),
            ("/private/var/folders/dp/my0vtv691tb7sm48kktgry2w0000gn/T/claude-obb-smoke-0fO1CJ",
             "-private-var-folders-dp-my0vtv691tb7sm48kktgry2w0000gn-T-claude-obb-smoke-0fO1CJ"),
            ("/Users/albertonunez", "-Users-albertonunez"),
            ("/private/tmp", "-private-tmp")
        ]
        for vector in vectors {
            XCTAssertEqual(Codec.encode(vector.cwd), vector.dir, "cwd \(vector.cwd)")
        }
    }

    func testEncodeReplacesEveryNonAlphanumericWithHyphen() {
        XCTAssertEqual(Codec.encode("a.b_c d-e/f\\g:h"), "a-b-c-d-e-f-g-h")
        XCTAssertEqual(Codec.encode(""), "")
        XCTAssertEqual(Codec.encode("/"), "-")
        XCTAssertEqual(Codec.encode("AZaz09"), "AZaz09")
    }

    // MARK: Encode — the drive-prefixed Windows form

    func testEncodeWindowsDriveProducesDoubleDashPrefix() {
        XCTAssertEqual(Codec.encode("C:\\Users\\Alice\\project"), "C--Users-Alice-project")
        XCTAssertEqual(Codec.encode("C:\\"), "C--")
    }

    func testEncodeWindowsNonCDriveLetters() {
        XCTAssertEqual(Codec.encode("D:\\Work\\app"), "D--Work-app")
        XCTAssertEqual(Codec.encode("Z:\\src"), "Z--src")
        // Lowercase drive letters are preserved (they are ASCII letters).
        XCTAssertEqual(Codec.encode("c:\\Users"), "c--Users")
    }

    func testEncodeUNCPath() {
        XCTAssertEqual(Codec.encode("\\\\server\\share\\project"), "--server-share-project")
    }

    // MARK: Encode — edge cases named by the contract

    func testEncodeSpaces() {
        XCTAssertEqual(Codec.encode("/Users/a/My Project"), "-Users-a-My-Project")
        XCTAssertEqual(Codec.encode("C:\\Work\\my project"), "C--Work-my-project")
    }

    func testEncodeNonASCIIBMPScalarBecomesSingleHyphen() {
        // `é` (U+00E9) is one UTF-16 unit -> one `-`; `José` -> `Jos-`.
        XCTAssertEqual(Codec.encode("José"), "Jos-")
        XCTAssertEqual(Codec.encode("C:\\Users\\José\\proyecto"), "C--Users-Jos--proyecto")
    }

    func testEncodeNonASCIIAstralScalarBecomesTwoHyphens() {
        // `😀` (U+1F600) is a surrogate pair (two UTF-16 units) -> two `-`, matching
        // Claude Code's Node/JS `replace(/[^A-Za-z0-9]/g, "-")` semantics.
        XCTAssertEqual(Codec.encode("😀"), "--")
        XCTAssertEqual(Codec.encode("a😀b"), "a--b")
    }

    // MARK: Decode — POSIX form

    func testDecodePOSIXAbsolute() {
        let decoded = Codec.decode("-Users-albertonunez-Documents-Developer-BurnBar")
        XCTAssertEqual(decoded.reconstructedPath, "/Users/albertonunez/Documents/Developer/BurnBar")
        XCTAssertEqual(decoded.form, .posixAbsolute)
        XCTAssertEqual(decoded.style, .posix)
        XCTAssertNil(decoded.driveLetter)
        XCTAssertFalse(decoded.isAmbiguous)
    }

    func testDecodePOSIXRootAndRelative() {
        XCTAssertEqual(Codec.decode("-").reconstructedPath, "/")
        XCTAssertEqual(Codec.decode("-").form, .posixAbsolute)

        let relative = Codec.decode("project-sub")
        XCTAssertEqual(relative.reconstructedPath, "project/sub")
        XCTAssertEqual(relative.form, .relative)
    }

    func testDecodeEmptyString() {
        let decoded = Codec.decode("")
        XCTAssertEqual(decoded.reconstructedPath, "")
        XCTAssertEqual(decoded.form, .relative)
    }

    // MARK: Decode — Windows drive form (both C and non-C)

    func testDecodeWindowsDriveForm() {
        let decoded = Codec.decode("C--Users-Alice-project")
        XCTAssertEqual(decoded.reconstructedPath, "C:\\Users\\Alice\\project")
        XCTAssertEqual(decoded.form, .windowsDrive)
        XCTAssertEqual(decoded.style, .windows)
        XCTAssertEqual(decoded.driveLetter, "C")
    }

    func testDecodeWindowsDriveRoot() {
        let decoded = Codec.decode("C--")
        XCTAssertEqual(decoded.reconstructedPath, "C:\\")
        XCTAssertEqual(decoded.driveLetter, "C")
    }

    func testDecodeNonCDriveLetters() {
        XCTAssertEqual(Codec.decode("D--Work-app").reconstructedPath, "D:\\Work\\app")
        XCTAssertEqual(Codec.decode("Z--src").reconstructedPath, "Z:\\src")
        XCTAssertEqual(Codec.decode("D--Work-app").driveLetter, "D")
        XCTAssertEqual(Codec.decode("Z--src").driveLetter, "Z")
    }

    // MARK: Decode — UNC form + the root ambiguity

    func testDecodeUNCUnderExplicitWindowsStyle() {
        let decoded = Codec.decode("--server-share-project", style: .windows)
        XCTAssertEqual(decoded.reconstructedPath, "\\\\server\\share\\project")
        XCTAssertEqual(decoded.form, .windowsUNC)
        XCTAssertEqual(decoded.style, .windows)
    }

    func testDoubleDashPrefixIsAmbiguousUnderAuto() {
        // `--server-share` is a POSIX `/.server/share` OR a Windows UNC
        // `\\server\share`. `.auto` picks POSIX and flags the ambiguity.
        let auto = Codec.decode("--server-share")
        XCTAssertEqual(auto.form, .posixAbsolute)
        XCTAssertTrue(auto.isAmbiguous)
        XCTAssertEqual(auto.reconstructedPath, "//server/share")
        XCTAssertEqual(auto.displayPath, "/server/share")

        // An explicit style resolves it deterministically, no ambiguity.
        let windows = Codec.decode("--server-share", style: .windows)
        XCTAssertEqual(windows.reconstructedPath, "\\\\server\\share")
        XCTAssertFalse(windows.isAmbiguous)
    }

    // MARK: Canonical round-trip invariant — always holds

    func testCanonicalRoundTripHoldsForEveryForm() {
        let names = [
            "-Users-albertonunez-Documents-Developer-BurnBar",
            "-Users-albertonunez--hermes-hermes-agent",
            "C--Users-Alice-project",
            "C--",
            "D--Work-my-project",
            "Z--src-App-2-0",
            "--server-share-project",
            "C--Users-Jos--proyecto",
            "-",
            "",
            "project-sub",
            "-Users-a-My-Project"
        ]
        for name in names {
            for style in Codec.PathStyle.allCases {
                XCTAssertTrue(
                    Codec.canonicalRoundTrips(name, style: style),
                    "encode(decode(\(name), \(style))) must equal \(name)"
                )
            }
        }
    }

    // MARK: Clean round-trip — holds for clean paths, documented loss otherwise

    func testCleanPathsRoundTripExactly() {
        XCTAssertTrue(Codec.cleanlyRoundTrips("/Users/alberto/project", style: .posix))
        XCTAssertTrue(Codec.cleanlyRoundTrips("C:\\Users\\Alice\\project", style: .windows))
        XCTAssertTrue(Codec.cleanlyRoundTrips("Z:\\src\\App", style: .windows))
        XCTAssertTrue(Codec.cleanlyRoundTrips("\\\\server\\share\\dir", style: .windows))
    }

    func testLossyPathsDoNotRoundTripButStayCanonical() {
        // Dots, spaces, underscores, literal hyphens, and non-ASCII are lossy: the
        // strong identity fails, but the canonical invariant still holds because
        // the re-encoding of the decoded path reproduces the directory name.
        let lossy = [
            ("/Users/a/.config", Codec.PathStyle.posix),
            ("/Users/a/My Project", .posix),
            ("/Users/a/snake_case", .posix),
            ("/Users/a/dash-name", .posix),
            ("C:\\Users\\José", .windows)
        ]
        for (path, style) in lossy {
            XCTAssertFalse(
                Codec.cleanlyRoundTrips(path, style: style),
                "\(path) is lossy and must not claim a clean round-trip"
            )
            XCTAssertTrue(
                Codec.canonicalRoundTrips(Codec.encode(path), style: style),
                "\(path) must still satisfy the canonical invariant"
            )
        }
    }

    // MARK: Form resolution

    func testFormResolutionUnderAuto() {
        XCTAssertEqual(Codec.resolveForm("-Users-a", style: .auto), .posixAbsolute)
        XCTAssertEqual(Codec.resolveForm("C--Users", style: .auto), .windowsDrive)
        XCTAssertEqual(Codec.resolveForm("project-sub", style: .auto), .relative)
        // A single trailing dash after a letter is NOT treated as a drive under
        // auto (too ambiguous with a relative `a-b`).
        XCTAssertEqual(Codec.resolveForm("a-b", style: .auto), .relative)
    }

    func testFormResolutionUnderExplicitStyles() {
        XCTAssertEqual(Codec.resolveForm("a-b", style: .windows), .windowsDrive) // `a:` drive
        XCTAssertEqual(Codec.resolveForm("--host-share", style: .windows), .windowsUNC)
        XCTAssertEqual(Codec.resolveForm("-Users-a", style: .posix), .posixAbsolute)
        XCTAssertEqual(Codec.resolveForm("rel-path", style: .posix), .relative)
    }

    // MARK: Fixture schema (the capture format for VAL-P0-PATH-022)

    func testFixtureCorpusLoadsAndValidates() throws {
        let data = try loadFixtureData()
        let set = try ClaudeCodeProjectPathFixtureSet.decode(from: data)

        XCTAssertEqual(set.schemaVersion, ClaudeCodeProjectPathFixtureSet.currentSchemaVersion)
        XCTAssertFalse(set.fixtures.isEmpty)

        // Every captured row must be internally consistent: re-encoding its
        // recorded cwd must reproduce its directory name.
        let mismatches = set.capturedRowMismatches()
        XCTAssertTrue(mismatches.isEmpty, "captured rows disagree with encoder: \(mismatches)")

        // At least one real captured macOS row and at least one pending Windows
        // row (the VAL-P0-PATH-022 handoff) must exist.
        XCTAssertTrue(set.fixtures.contains { $0.captured && $0.style == .posix })
        XCTAssertTrue(set.fixtures.contains { !$0.captured && $0.style == .windows })
    }

    func testFixtureDecoderRoundTripsEveryRowCanonically() throws {
        let data = try loadFixtureData()
        let set = try ClaudeCodeProjectPathFixtureSet.decode(from: data)
        for fixture in set.fixtures {
            XCTAssertTrue(
                Codec.canonicalRoundTrips(fixture.encodedDirectoryName, style: fixture.style),
                "fixture \(fixture.encodedDirectoryName) failed canonical round-trip"
            )
        }
    }

    func testFixtureSchemaReEncodesStably() throws {
        let data = try loadFixtureData()
        let set = try ClaudeCodeProjectPathFixtureSet.decode(from: data)
        let reEncoded = try set.encoded()
        let reDecoded = try ClaudeCodeProjectPathFixtureSet.decode(from: reEncoded)
        XCTAssertEqual(set, reDecoded)
    }

    // MARK: Helpers

    private func loadFixtureData() throws -> Data {
        let bundle = Bundle(for: ClaudeCodePathsBundleMarker.self)
        let resource = "claude-code-project-path-fixtures"
        let url = bundle.url(forResource: resource, withExtension: "json")
            ?? bundle.url(forResource: resource, withExtension: "json", subdirectory: "ClaudeCodePaths")
            ?? bundle.url(forResource: resource, withExtension: "json", subdirectory: "Fixtures/ClaudeCodePaths")
        let resolved = try XCTUnwrap(url, "claude-code-project-path-fixtures.json not bundled")
        return try Data(contentsOf: resolved)
    }
}
