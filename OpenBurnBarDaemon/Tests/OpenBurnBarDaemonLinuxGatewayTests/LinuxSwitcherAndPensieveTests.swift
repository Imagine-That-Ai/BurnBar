#if os(Linux)
import Foundation
@testable import OpenBurnBarDaemon
import OpenBurnBarCore
import XCTest

final class LinuxSwitcherAndPensieveTests: XCTestCase {
    func testSwitcherExecutesFromInjectedPathAndStripsDaemonSecrets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-switcher-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let output = root.appendingPathComponent("arguments.txt")
        let executable = root.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ -n "${OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN:-}" ]; then exit 92; fi
        printf '%s\n' "$@" > "${OPENBURNBAR_TEST_OUTPUT}"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let executor = BurnBarCLIShellExecutor(profileStore: EmptyLinuxSwitcherProfileStore()) {
            [
                "PATH": root.path,
                "OPENBURNBAR_TEST_OUTPUT": output.path,
                "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN": "must-not-leak"
            ]
        }
        let result = try await executor.execute(
            BurnBarCLIShellLaunchRequest(cliType: .codex, forwardedArguments: ["--version", "value with spaces"])
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.launchedProfileID, "linux-path-codex")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "--version\nvalue with spaces\n")
    }

    func testShimInstallerQuotesExecutablePathAndSetsExecutableMode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-shims-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try BurnBarCLIShellShimInstaller(installDirectory: root)
            .installShims(invokedExecutablePath: "/opt/Open Burn'Bar/openburnbar-cli")

        XCTAssertEqual(result.installedCommands, ["codex", "claude", "gemini", "opencode", "goose", "droid", "pi"])
        let codex = root.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: codex.path))
        let contents = try String(contentsOf: codex, encoding: .utf8)
        XCTAssertTrue(contents.contains("'/opt/Open Burn'\\''Bar/openburnbar-cli'"))
        XCTAssertTrue(contents.contains("switcher run --cli codex -- \"$@\""))
    }

    func testPensieveWatcherWritesPrivateManifestAndStopsIdempotently() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-pensieve-\(UUID().uuidString)", isDirectory: true)
        let watched = root.appendingPathComponent("docs", isDirectory: true)
        let queue = root.appendingPathComponent("queue", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try "parity proof".write(
            to: watched.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let watcher = PensieveKnowledgeWatcher(
            roots: [PensieveWatchRoot(url: watched, sourceKind: .repoDocs, includedExtensions: ["md"])],
            queueDirectoryURL: queue,
            vaultKeyProvider: { Data(repeating: 7, count: 32) },
            debounceInterval: 0.02,
            backstopInterval: 60
        )
        watcher.start()
        watcher.start()
        try waitUntil(timeout: 3) { watcher.lastEnqueuedCount == 1 }

        let manifestDirectory = queue.appendingPathComponent("change-manifests", isDirectory: true)
        let manifests = try FileManager.default.contentsOfDirectory(
            at: manifestDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(manifests.count, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: manifests[0].path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0, 0o600)
        watcher.stop()
        watcher.stop()
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("condition did not become true before timeout")
    }
}

private final class EmptyLinuxSwitcherProfileStore: BurnBarSwitcherProfileStoreProviding, @unchecked Sendable {
    func fetchProfile(id: String) -> SwitcherProfileRecord? { nil }
    func fetchAllProfiles() -> [SwitcherProfileRecord] { [] }
    func fetchActiveProfileID() -> String? { nil }
    func setActiveProfileID(_ profileID: String?) {}
    func updateProfile(_ profile: SwitcherProfileRecord) {}
}
#endif
