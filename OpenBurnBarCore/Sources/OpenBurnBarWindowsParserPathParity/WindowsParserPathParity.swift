// SPDX-License-Identifier: AGPL-3.0-only
//
// OpenBurnBar — Windows Port Phase-2 Parser Path-Remap Parity Gate (G2)
// ====================================================================
//
// The Windows-run, assertion-gated proof that the parser **path layer** resolves
// byte-identically on Windows and macOS — the first, fully-portable half of the
// G2 "byte-identical parser output vs the Mac golden" headline
// (`docs/windows-port/PARSER_OUTPUT_CONTRACT.md`).
//
// What this executable proves, on the real Windows runner:
//
//   1. The Claude Code `~/.claude/projects` directory-name codec
//      (`ClaudeCodeProjectPathCodec`, PATH-021) reproduces the committed capture
//      corpus BYTE-FOR-BYTE — every `encode(cwd) == encodedDirectoryName`, the
//      `C--Users-…` / `-Users-…` / UNC decode, and the canonical round-trip — on
//      `x86_64/aarch64-unknown-windows-msvc`, the same bytes macOS validates.
//
//   2. The provider log-directory root remap (`LogPathPlatform`) maps every macOS
//      `~/…` logical log directory to the correct Windows base
//      (`%USERPROFILE%` / `%APPDATA%` / `%LOCALAPPDATA%`) — asserted against an
//      inline golden using a DETERMINISTIC injected environment, so the diff is
//      host-independent and byte-exact on any runner.
//
//   3. The POSIX branch is a pass-through: `resolveLogDirectory(x, os: .posix)`
//      returns `x` unchanged, so macOS parser path resolution is provably byte-for-byte
//      unchanged by the remap.
//
// Why the path layer is the deliverable here (scope honesty): the 16 production
// parsers themselves still live in the macOS app layer (`AgentLens/…`) and some
// (e.g. HermesParser) link GRDB, which is pruned off-Apple, so the full
// token/cost/model/session byte-diff cannot run on Windows until the parsers are
// lifted into the Engine (a later, separately-scoped port — see
// `docs/windows-port/HANDOFF.md` §"Phase 2"). This gate proves the portable path
// contract those parsers depend on, which is the concrete path-remap deliverable
// of this phase; the token/cost half rides the parser port.
//
// Assertion-backed by design (mirrors the Phase-1 walking skeleton): `expect(…)`
// is a hard gate in debug AND release — a failed assertion writes to stderr and
// exits non-zero, so `swift run` / CI turn red on any regression. It never relies
// on `assert`, which release builds strip.
//
// macOS run  : swift run --package-path OpenBurnBarCore \
//                        --cache-path OpenBurnBarCore/.spm-cache \
//                        OpenBurnBarWindowsParserPathParity
// Windows run: `.github/workflows/openburnbar-engine-windows.yml` (both the
//              x86_64 and aarch64 legs), after the Engine build.

import Foundation
import OpenBurnBarCore

@main
enum WindowsParserPathParity {

    // MARK: Committed Claude Code path-capture corpus (bundled resource)

    /// One row of `Fixtures/claude-code-project-path-fixtures.json` (the shared
    /// PATH-021 corpus, byte-identical to `AgentLensTests/Fixtures/ClaudeCodePaths/`).
    private struct PathFixture: Decodable {
        let encodedDirectoryName: String
        let sourcePath: String?
        let style: ClaudeCodeProjectPathCodec.PathStyle
        let captured: Bool
    }

    private struct PathFixtureFile: Decodable {
        let fixtures: [PathFixture]
    }

    // MARK: Deterministic Windows environment (host-independent golden)

    private static let windowsEnvironment: [String: String] = [
        "USERPROFILE": "C:\\Users\\Runner",
        "APPDATA": "C:\\Users\\Runner\\AppData\\Roaming",
        "LOCALAPPDATA": "C:\\Users\\Runner\\AppData\\Local"
    ]

    /// The path-remap golden: each provider's macOS `~/…` logical log directory and
    /// the Windows path it MUST resolve to under `windowsEnvironment`. Covers all
    /// three tilde-root families (dot-home, `Library/Application Support`,
    /// `.local/share`) drawn from real `AgentProvider.logDirectory` values.
    private static let remapGolden: [(mac: String, windows: String)] = [
        // ~/.foo family -> %USERPROFILE%\.foo
        ("~/.claude/projects", "C:\\Users\\Runner\\.claude\\projects"),
        ("~/.codex", "C:\\Users\\Runner\\.codex"),
        ("~/.factory/sessions", "C:\\Users\\Runner\\.factory\\sessions"),
        ("~/.hermes/sessions", "C:\\Users\\Runner\\.hermes\\sessions"),
        ("~/.gemini/tmp", "C:\\Users\\Runner\\.gemini\\tmp"),
        ("~/.cursor-agent/sessions", "C:\\Users\\Runner\\.cursor-agent\\sessions"),
        // ~/Library/Application Support/X -> %APPDATA%\X (Roaming)
        (
            "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks",
            "C:\\Users\\Runner\\AppData\\Roaming\\Code\\User\\globalStorage\\saoudrizwan.claude-dev\\tasks"
        ),
        (
            "~/Library/Application Support/Windsurf - Next/User/globalStorage",
            "C:\\Users\\Runner\\AppData\\Roaming\\Windsurf - Next\\User\\globalStorage"
        ),
        (
            "~/Library/Application Support/dev.warp.Warp-Stable",
            "C:\\Users\\Runner\\AppData\\Roaming\\dev.warp.Warp-Stable"
        ),
        // ~/.local/share/X (XDG) -> %LOCALAPPDATA%\X
        ("~/.local/share/goose/sessions", "C:\\Users\\Runner\\AppData\\Local\\goose\\sessions"),
        ("~/.local/share/opencode", "C:\\Users\\Runner\\AppData\\Local\\opencode")
    ]

    static func main() throws {
        var passCount = 0

        // Hard gate — active in debug AND release (never stripped like `assert`).
        func expect(_ condition: Bool, _ message: String) {
            if condition {
                passCount += 1
                print("  PASS  \(message)")
            } else {
                FileHandle.standardError.write(Data("  FAIL  \(message)\n".utf8))
                exit(1)
            }
        }

        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("  FAIL  \(message)\n".utf8))
            exit(1)
        }

        print("== OpenBurnBar Windows-Port Phase-2 Parser Path-Remap Parity ==")
        print("  host: \(LogPathPlatform.current == .windows ? "windows" : "posix")")

        // MARK: - Section 1 — Claude Code path codec byte-parity over the corpus
        print("\n[1] Claude Code project-path codec (PATH-021) over the committed corpus")
        guard let fixtureURL = Bundle.module.url(
            forResource: "claude-code-project-path-fixtures",
            withExtension: "json"
        ) else {
            fail("could not locate bundled claude-code-project-path-fixtures.json in Bundle.module")
        }
        let fixtureData = try Data(contentsOf: fixtureURL)
        let corpus = try JSONDecoder().decode(PathFixtureFile.self, from: fixtureData)
        expect(!corpus.fixtures.isEmpty, "path-capture corpus is non-empty (\(corpus.fixtures.count) vectors)")

        for fixture in corpus.fixtures {
            let dir = fixture.encodedDirectoryName

            // 1a. Ground-truth encode: encode(sourcePath) == encodedDirectoryName.
            //     Holds for EVERY row by construction (captured + modeled alike).
            if let source = fixture.sourcePath {
                let reEncoded = ClaudeCodeProjectPathCodec.encode(source)
                expect(
                    reEncoded == dir,
                    "encode(\(source.debugDescription)) == \(dir.debugDescription)\(fixture.captured ? " [captured]" : "")"
                )
            }

            // 1b. Canonical round-trip: encode(decode(dir).reconstructedPath) == dir.
            //     ALWAYS true; the invariant the decoder is built around.
            expect(
                ClaudeCodeProjectPathCodec.canonicalRoundTrips(dir, style: fixture.style),
                "canonical round-trip holds for \(dir.debugDescription) (style: \(fixture.style.rawValue))"
            )

            // 1c. Decode under the fixture's declared style resolves the expected
            //     structural form (drive / UNC / posix-absolute), proving the
            //     `C--Users-…` vs `-Users-…` disambiguation is byte-stable here.
            let decoded = ClaudeCodeProjectPathCodec.decode(dir, style: fixture.style)
            switch fixture.style {
            case .windows:
                let isWindowsForm = decoded.form == .windowsDrive || decoded.form == .windowsUNC
                expect(isWindowsForm, "\(dir.debugDescription) decodes to a Windows form under .windows (\(decoded.form.rawValue))")
            case .posix:
                let isPosixForm = decoded.form == .posixAbsolute || decoded.form == .relative
                expect(isPosixForm, "\(dir.debugDescription) decodes to a POSIX form under .posix (\(decoded.form.rawValue))")
            case .auto:
                break
            }
        }

        // MARK: - Section 2 — provider log-directory root remap byte-golden
        print("\n[2] LogPathPlatform Windows root remap vs inline golden (deterministic env)")
        for entry in remapGolden {
            let resolved = LogPathPlatform.resolveLogDirectory(
                entry.mac,
                os: .windows,
                environment: windowsEnvironment
            )
            expect(
                resolved == entry.windows,
                "remap \(entry.mac.debugDescription) -> \(entry.windows.debugDescription) (got \(resolved.debugDescription))"
            )
        }

        // MARK: - Section 3 — POSIX pass-through invariant (macOS parity guard)
        print("\n[3] POSIX branch is a byte-for-byte pass-through")
        for entry in remapGolden {
            let posix = LogPathPlatform.resolveLogDirectory(entry.mac, os: .posix, environment: [:])
            expect(posix == entry.mac, "posix pass-through leaves \(entry.mac.debugDescription) unchanged")
        }

        // MARK: - Section 4 — live-host smoke (real env on this runner)
        print("\n[4] Live-host resolve smoke (\(LogPathPlatform.current == .windows ? "windows" : "posix"))")
        let liveClaude = LogPathPlatform.resolveLogDirectory("~/.claude/projects")
        if LogPathPlatform.current == .windows {
            // On the real Windows runner the resolved root is absolute and carries
            // the `.claude\projects` tail — proves the live %USERPROFILE% wiring.
            expect(
                liveClaude.contains("\\.claude\\projects") && !liveClaude.hasPrefix("~"),
                "live Windows resolve of ~/.claude/projects is an absolute path ending \\.claude\\projects (got \(liveClaude.debugDescription))"
            )
        } else {
            expect(
                liveClaude == "~/.claude/projects",
                "live POSIX resolve of ~/.claude/projects is the unchanged logical form (got \(liveClaude.debugDescription))"
            )
        }

        print("\n== PARSER PATH-REMAP PARITY GREEN ==")
        print("  \(passCount) assertions passed across codec corpus + root remap + posix pass-through")
    }
}
