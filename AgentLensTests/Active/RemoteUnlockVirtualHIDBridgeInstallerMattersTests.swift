#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
@testable import OpenBurnBar

/// `appleScriptLiteral` quotes the privileged install script that is run via
/// `do shell script <literal> with administrator privileges`. A previous
/// `try?` swallowed any encode failure and fell back to the empty literal
/// `""`, which would have run an *empty* command with administrator privileges
/// while the installer believed the full script executed — a silent,
/// dangerous degradation. These tests pin the fail-closed contract: the helper
/// produces a correct, round-trippable AppleScript literal and never silently
/// collapses a real script to the empty literal.
@MainActor
final class RemoteUnlockVirtualHIDBridgeInstallerMattersTests: XCTestCase {
    /// JSON string syntax is a strict subset of AppleScript's string literal
    /// syntax, so decoding the literal back through JSON recovers the original
    /// value verbatim. If escaping were wrong (or collapsed to `""`), the
    /// round-trip would not equal the input.
    private func roundTrip(_ literal: String) throws -> String {
        let data = try XCTUnwrap(literal.data(using: .utf8))
        return try JSONDecoder().decode(String.self, from: data)
    }

    func test_appleScriptLiteral_roundTripsPlainScript() throws {
        let script = "mkdir -p '/Library/Application Support/OpenBurnBar/RemoteUnlock'"
        let literal = try RemoteUnlockVirtualHIDBridgeInstaller.appleScriptLiteral(script)
        XCTAssertEqual(try roundTrip(literal), script)
    }

    func test_appleScriptLiteral_neverCollapsesRealScriptToEmptyLiteral() throws {
        let script = """
        set -e
        cp '/tmp/staged' '/Library/Application Support/OpenBurnBar/RemoteUnlock/bridge'
        launchctl bootstrap system '/Library/LaunchDaemons/com.openburnbar.virtual-hid-bridge.plist'
        """
        let literal = try RemoteUnlockVirtualHIDBridgeInstaller.appleScriptLiteral(script)
        XCTAssertNotEqual(literal, "\"\"", "a non-empty script must never produce the empty AppleScript literal")
        XCTAssertEqual(try roundTrip(literal), script, "the full multi-line script must survive escaping verbatim")
    }

    func test_appleScriptLiteral_escapesQuotesAndBackslashes() throws {
        let script = #"echo "hello \world\" && rm -rf '/tmp/x'"#
        let literal = try RemoteUnlockVirtualHIDBridgeInstaller.appleScriptLiteral(script)
        // The literal must itself be a quoted string whose interior quotes and
        // backslashes are escaped, so it can't prematurely terminate the
        // `do shell script "..."` argument.
        XCTAssertTrue(literal.hasPrefix("\""), "literal must be quote-delimited")
        XCTAssertTrue(literal.hasSuffix("\""), "literal must be quote-delimited")
        XCTAssertTrue(literal.contains("\\\""), "embedded double quotes must be backslash-escaped")
        XCTAssertEqual(try roundTrip(literal), script, "escaping must be lossless")
    }

    func test_appleScriptLiteral_escapesNewlinesSoControlCharsCannotBreakOut() throws {
        let script = "line-one\nline-two"
        let literal = try RemoteUnlockVirtualHIDBridgeInstaller.appleScriptLiteral(script)
        // A raw newline inside the AppleScript literal would split the
        // interpolated argument; JSON encoding renders it as the two-character
        // escape sequence \n instead.
        XCTAssertFalse(literal.dropFirst().dropLast().contains("\n"), "raw newlines must be escaped inside the literal")
        XCTAssertTrue(literal.contains("\\n"), "newlines must be encoded as the \\n escape")
        XCTAssertEqual(try roundTrip(literal), script)
    }
}
#endif
