import Foundation
import XCTest
@testable import OpenBurnBarLogParsers

/// Windows-port Phase-2 parser path-remap (`LogPathPlatform`). Proves the macOS
/// `~/…` logical provider log directories resolve to the correct Windows roots
/// (`%USERPROFILE%` / `%APPDATA%` / `%LOCALAPPDATA%`), and that the POSIX branch is
/// a byte-for-byte pass-through so macOS parser path resolution is unchanged.
///
/// The Windows branch is driven with an injected `os: .windows` + `environment`,
/// so these vectors run (and byte-assert) on the macOS host — the same resolver
/// the Windows parser-parity CI gate exercises natively.
final class LogPathPlatformTests: XCTestCase {

    private static let windowsEnv: [String: String] = [
        "USERPROFILE": "C:\\Users\\Runner",
        "APPDATA": "C:\\Users\\Runner\\AppData\\Roaming",
        "LOCALAPPDATA": "C:\\Users\\Runner\\AppData\\Local"
    ]

    private func resolveWindows(_ mac: String, env: [String: String]? = nil) -> String {
        LogPathPlatform.resolveLogDirectory(mac, os: .windows, environment: env ?? Self.windowsEnv)
    }

    // MARK: - ~/.foo family -> %USERPROFILE%\.foo

    func testDotHomeFamilyRemapsUnderUserProfile() {
        XCTAssertEqual(resolveWindows("~/.claude/projects"), "C:\\Users\\Runner\\.claude\\projects")
        XCTAssertEqual(resolveWindows("~/.codex"), "C:\\Users\\Runner\\.codex")
        XCTAssertEqual(resolveWindows("~/.factory/sessions"), "C:\\Users\\Runner\\.factory\\sessions")
        XCTAssertEqual(resolveWindows("~/.cursor-agent/sessions"), "C:\\Users\\Runner\\.cursor-agent\\sessions")
        XCTAssertEqual(resolveWindows("~/.grok/sessions"), "C:\\Users\\Runner\\.grok\\sessions")
    }

    // MARK: - ~/Library/Application Support/X -> %APPDATA%\X

    func testApplicationSupportRemapsUnderRoamingAppData() {
        XCTAssertEqual(
            resolveWindows("~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks"),
            "C:\\Users\\Runner\\AppData\\Roaming\\Code\\User\\globalStorage\\saoudrizwan.claude-dev\\tasks"
        )
        XCTAssertEqual(
            resolveWindows("~/Library/Application Support/Windsurf - Next/User/globalStorage"),
            "C:\\Users\\Runner\\AppData\\Roaming\\Windsurf - Next\\User\\globalStorage"
        )
        XCTAssertEqual(
            resolveWindows("~/Library/Application Support/dev.warp.Warp-Stable"),
            "C:\\Users\\Runner\\AppData\\Roaming\\dev.warp.Warp-Stable"
        )
    }

    func testBareApplicationSupportResolvesToAppDataRoot() {
        XCTAssertEqual(
            resolveWindows("~/Library/Application Support"),
            "C:\\Users\\Runner\\AppData\\Roaming"
        )
    }

    // MARK: - ~/.local/share/X (XDG) -> %LOCALAPPDATA%\X

    func testXDGDataDirRemapsUnderLocalAppData() {
        XCTAssertEqual(
            resolveWindows("~/.local/share/goose/sessions"),
            "C:\\Users\\Runner\\AppData\\Local\\goose\\sessions"
        )
        XCTAssertEqual(
            resolveWindows("~/.local/share/opencode"),
            "C:\\Users\\Runner\\AppData\\Local\\opencode"
        )
    }

    // MARK: - Environment fallbacks (documented degrade paths)

    func testAppDataFallbackDerivesFromUserProfileWhenUnset() {
        let env = ["USERPROFILE": "C:\\Users\\Fallback"]
        XCTAssertEqual(
            LogPathPlatform.resolveLogDirectory("~/Library/Application Support/X", os: .windows, environment: env),
            "C:\\Users\\Fallback\\AppData\\Roaming\\X"
        )
    }

    func testLocalAppDataFallbackDerivesFromUserProfileWhenUnset() {
        let env = ["USERPROFILE": "C:\\Users\\Fallback"]
        XCTAssertEqual(
            LogPathPlatform.resolveLogDirectory("~/.local/share/goose", os: .windows, environment: env),
            "C:\\Users\\Fallback\\AppData\\Local\\goose"
        )
    }

    func testUserProfileFallsBackToHomeDriveAndPath() {
        let env = ["HOMEDRIVE": "D:", "HOMEPATH": "\\Users\\HD"]
        XCTAssertEqual(
            LogPathPlatform.resolveLogDirectory("~/.codex", os: .windows, environment: env),
            "D:\\Users\\HD\\.codex"
        )
    }

    // MARK: - POSIX pass-through (macOS parity guard)

    func testPosixBranchIsByteForBytePassThrough() {
        let logicalDirs = [
            "~/.claude/projects",
            "~/Library/Application Support/Code/User/globalStorage/x/tasks",
            "~/.local/share/goose/sessions",
            "~/.codex"
        ]
        for dir in logicalDirs {
            XCTAssertEqual(
                LogPathPlatform.resolveLogDirectory(dir, os: .posix, environment: [:]),
                dir,
                "POSIX resolve must return the logical form unchanged"
            )
        }
    }

    // MARK: - Host detection

    func testCurrentHostMatchesCompileTarget() {
        #if os(Windows)
        XCTAssertEqual(LogPathPlatform.current, .windows)
        #else
        XCTAssertEqual(LogPathPlatform.current, .posix)
        #endif
    }

    // MARK: - No doubled or trailing separators at the join

    func testJoinNeverProducesDoubledOrTrailingSeparators() {
        // Trailing slash on the logical dir must not survive as a trailing `\`.
        XCTAssertEqual(resolveWindows("~/.codex/"), "C:\\Users\\Runner\\.codex")
        // A base with a trailing backslash must not double at the joint.
        let env = ["USERPROFILE": "C:\\Users\\Runner\\"]
        XCTAssertEqual(
            LogPathPlatform.resolveLogDirectory("~/.codex", os: .windows, environment: env),
            "C:\\Users\\Runner\\.codex"
        )
    }
}
