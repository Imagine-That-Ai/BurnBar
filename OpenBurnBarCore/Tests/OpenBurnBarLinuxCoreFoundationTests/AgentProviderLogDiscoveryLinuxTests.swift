import Foundation
import XCTest
@testable import OpenBurnBarCore

#if os(Linux)
final class AgentProviderLogDiscoveryLinuxTests: XCTestCase {
    func testResolveLogSourceUsesLinuxXDGStylePathsForVSCodeProviders() {
        let cline = AgentProviderLogDiscovery.resolveLogSource(
            for: .cline,
            environment: ["HOME": "/home/linux-fixture"]
        )
        XCTAssertTrue(cline.logicalPath.contains(".config/Code/User/globalStorage"))
        XCTAssertEqual(
            cline.resolvedPath,
            "/home/linux-fixture/.config/Code/User/globalStorage/saoudrizwan.claude-dev/tasks"
        )
        XCTAssertEqual(cline.filePattern, "*.json")
    }

    func testResolveLogSourceUsesInjectedHomeForHeadlessLinuxFixtures() {
        let codex = AgentProviderLogDiscovery.resolveLogSource(
            for: .codex,
            environment: ["HOME": "/tmp/openburnbar-xdg-home"]
        )

        XCTAssertEqual(codex.resolvedPath, "/tmp/openburnbar-xdg-home/.codex")
        XCTAssertEqual(codex.sessionIdentityKey, "Codex|/tmp/openburnbar-xdg-home/.codex")
    }

    func testSessionIdentityKeyUsesProviderAndStandardizedResolvedDirectory() {
        let a = AgentProviderLogDiscovery.sessionIdentityKey(provider: .codex, resolvedPath: "/home/evidence/.codex")
        let b = AgentProviderLogDiscovery.sessionIdentityKey(provider: .codex, resolvedPath: "/home/evidence/.codex/")
        XCTAssertNotEqual(a, b, "Trailing slash normalization is not applied inside sessionIdentityKey; callers must pass standardized paths")
        let key = AgentProviderLogDiscovery.sessionIdentityKey(
            provider: .xAI,
            resolvedPath: "/home/evidence/.grok/sessions"
        )
        XCTAssertEqual(key, "xAI|/home/evidence/.grok/sessions")
    }

    func testSymlinkedHomeExpansionDoesNotSilentlyRewriteSessionKeyWithoutRealpath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("obb-provider-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("real-codex", isDirectory: true)
        let link = root.appendingPathComponent("link-codex", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let env = ["HOME": root.path]
        let viaLink = AgentProviderLogDiscovery.resolveLogSource(for: .codex, environment: env)
        // logical path is still ~/.codex — identity tracks standardized expanded logical path, not symlink target
        XCTAssertEqual(viaLink.resolvedPath, root.appendingPathComponent(".codex").path)
        XCTAssertTrue(viaLink.sessionIdentityKey.hasPrefix("Codex|"))
    }

    func testPartialLogFilePatternStillDocumentsCodexSQLite() {
        let pattern = AgentProviderLogDiscovery.filePattern(for: .codex)
        XCTAssertEqual(pattern, "state_5.sqlite")
    }

    func testRotationScenarioKeepsDirectoryScopedIdentity() {
        let dir = "/home/evidence/.claude/projects"
        let before = AgentProviderLogDiscovery.sessionIdentityKey(provider: .claudeCode, resolvedPath: dir)
        let after = AgentProviderLogDiscovery.sessionIdentityKey(provider: .claudeCode, resolvedPath: dir)
        XCTAssertEqual(before, after, "Rotating files under the log root must not change session identity when resolved directory is stable")
    }
}
#endif
