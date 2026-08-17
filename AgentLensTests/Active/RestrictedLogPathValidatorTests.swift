import XCTest
@testable import OpenBurnBar

// MARK: - Restricted log path validation (OPUS-F-010)
//
// Verifies that custom log paths are validated against known-safe roots after
// tilde expansion and canonicalization. The original implementation compared an
// expanded candidate against still-tilde-prefixed roots, so every custom path
// was over-rejected; this suite locks the corrected behavior.

final class RestrictedLogPathValidatorTests: XCTestCase {
    private var restrictedValidator: RestrictedLogPathValidator!
    private var unrestrictedValidator: RestrictedLogPathValidator!

    override func setUp() {
        super.setUp()
        restrictedValidator = RestrictedLogPathValidator(restrictedMode: true)
        unrestrictedValidator = RestrictedLogPathValidator(restrictedMode: false)
    }

    // MARK: Unrestricted mode

    func testUnrestrictedMode_allowsCustomPath() {
        XCTAssertEqual(
            unrestrictedValidator.resolvePath(customPath: "/any/path", providerDefault: "/default"),
            "/any/path"
        )
    }

    func testUnrestrictedMode_fallsBackToDefaultWhenNoCustomPath() {
        XCTAssertEqual(
            unrestrictedValidator.resolvePath(customPath: nil, providerDefault: "/default"),
            "/default"
        )
    }

    // MARK: Restricted mode — known roots

    func testRestrictedMode_allowsKnownFactoryRoot() {
        let home = NSHomeDirectory()
        let path = "~/.factory/sessions"
        XCTAssertEqual(
            restrictedValidator.resolvePath(customPath: path, providerDefault: "/default"),
            path
        )
        XCTAssertEqual(
            restrictedValidator.resolvePath(customPath: "\(home)/.factory/sessions", providerDefault: "/default"),
            "\(home)/.factory/sessions"
        )
    }

    func testRestrictedMode_allowsKnownClaudeRoot() {
        XCTAssertEqual(
            restrictedValidator.resolvePath(customPath: "~/.claude/projects", providerDefault: "/default"),
            "~/.claude/projects"
        )
    }

    func testRestrictedMode_allowsKnownGrokRoot() {
        XCTAssertEqual(
            restrictedValidator.resolvePath(customPath: "~/.grok/sessions", providerDefault: "/default"),
            "~/.grok/sessions"
        )
    }

    func testRestrictedMode_allowsKnownOpenBurnBarRoot() {
        XCTAssertEqual(
            restrictedValidator.resolvePath(
                customPath: "~/Library/Application Support/OpenBurnBar/logs",
                providerDefault: "/default"
            ),
            "~/Library/Application Support/OpenBurnBar/logs"
        )
    }

    // MARK: Restricted mode — rejected paths

    func testRestrictedMode_rejectsUnknownRoot() {
        XCTAssertNil(
            restrictedValidator.resolvePath(customPath: "/var/log/custom.log", providerDefault: "/default"),
            "Custom path outside known roots must be rejected and fall back to default"
        )
    }

    func testRestrictedMode_rejectsPathWithTraversal() {
        XCTAssertNil(
            restrictedValidator.resolvePath(customPath: "~/.factory/../.ssh/config", providerDefault: "/default"),
            "Traversal must be canonicalized and rejected"
        )
    }

    func testRestrictedMode_rejectsKnownRootLookalikePrefix() {
        XCTAssertNil(
            restrictedValidator.resolvePath(customPath: "~/.factoryevil/sessions", providerDefault: "/default"),
            "Known roots must match on a path boundary, not a raw string prefix"
        )
    }

    // MARK: Fallback behavior

    func testRestrictedMode_returnsDefaultWhenCustomPathRejected() {
        XCTAssertNil(
            restrictedValidator.resolvePath(customPath: "/var/log", providerDefault: "/default"),
            "Rejected custom path should return nil so caller can fall back to default"
        )
    }

    func testRestrictedMode_returnsDefaultWhenNoCustomPath() {
        XCTAssertEqual(
            restrictedValidator.resolvePath(customPath: nil, providerDefault: "/default"),
            "/default"
        )
    }
}
