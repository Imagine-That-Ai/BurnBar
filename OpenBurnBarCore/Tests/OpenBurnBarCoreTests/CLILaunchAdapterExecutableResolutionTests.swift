#if os(macOS)
import XCTest
@testable import OpenBurnBarCore

final class CLILaunchAdapterExecutableResolutionTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        CLILaunchAdapter.executableResolver = nil
        CLILaunchAdapter.environmentProvider = { ProcessInfo.processInfo.environment }
        CLILaunchAdapter.homeDirectoryProvider = { FileManager.default.homeDirectoryForCurrentUser.path }
        CLILaunchAdapter.clearExecutableResolutionCache()
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        super.tearDown()
    }

    func testResolveExecutableRejectsCodexUserWritableFallbacks() throws {
        let fileManager = FileManager.default
        let tempHome = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-cli-resolution-\(UUID().uuidString)", isDirectory: true)
        temporaryRoots.append(tempHome)

        let localBinPath = tempHome
            .appendingPathComponent(".local/bin/codex")
        let activeNVMPath = tempHome
            .appendingPathComponent(".nvm/versions/node/v20.20.2/bin/codex")
        let newerBrokenNVMPath = tempHome
            .appendingPathComponent(".nvm/versions/node/v24.14.0/bin/codex")
        let fakeShellPath = tempHome.appendingPathComponent("fake-login-shell")

        try makeExecutableFile(at: localBinPath)
        try makeExecutableFile(at: activeNVMPath)
        try makeExecutableFile(at: newerBrokenNVMPath)
        try makeExecutableFile(
            at: fakeShellPath,
            contents: """
            #!/bin/sh
            printf '%s\\n' '\(activeNVMPath.path)'
            """
        )

        CLILaunchAdapter.homeDirectoryProvider = { tempHome.path }
        CLILaunchAdapter.environmentProvider = {
            [
                "HOME": tempHome.path,
                "PATH": [
                    localBinPath.deletingLastPathComponent().path,
                    activeNVMPath.deletingLastPathComponent().path,
                    newerBrokenNVMPath.deletingLastPathComponent().path
                ].joined(separator: ":"),
                "SHELL": fakeShellPath.path
            ]
        }
        CLILaunchAdapter.clearExecutableResolutionCache()

        if let resolvedPath = CLILaunchAdapter.resolveExecutable(for: .codex)?.path {
            XCTAssertFalse(
                [localBinPath.path, activeNVMPath.path, newerBrokenNVMPath.path].contains(resolvedPath),
                "Codex resolution must not choose user-writable PATH or version-manager candidates."
            )
        }
    }

    func testCodexSearchPolicyExcludesAmbientUserManagedDirectories() {
        let home = "/tmp/openburnbar-cli-resolution-home"
        XCTAssertFalse(CLILaunchAdapter.allowsAmbientUserManagedExecutableFallback(for: .codex))
        XCTAssertTrue(CLILaunchAdapter.ambientFallbackExecutableSearchDirectories(
            for: .codex,
            homeDirectory: home
        ).isEmpty)
        XCTAssertTrue(CLILaunchAdapter.ambientFallbackExecutableSearchDirectories(
            for: .claude,
            homeDirectory: home
        ).contains("\(home)/.local/bin"))
        XCTAssertFalse(CLILaunchAdapter.trustedExecutableSearchDirectories(
            for: .codex,
            environment: ["PATH": "\(home)/.local/bin:\(home)/.nvm/versions/node/v20/bin"],
            homeDirectory: home
        ).contains(where: { $0.hasPrefix(home) }))
    }

    func testPinnedCodexResolutionDoesNotInvokeLoginShell() throws {
        let fileManager = FileManager.default
        let tempHome = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-pinned-resolution-\(UUID().uuidString)", isDirectory: true)
        temporaryRoots.append(tempHome)

        let shellMarker = tempHome.appendingPathComponent("login-shell-ran")
        let fakeShellPath = tempHome.appendingPathComponent("fake-login-shell")
        try makeExecutableFile(
            at: fakeShellPath,
            contents: """
            #!/bin/sh
            /usr/bin/touch "\(shellMarker.path)"
            printf '%s\\n' '\(tempHome.appendingPathComponent(".local/bin/codex").path)'
            """
        )

        CLILaunchAdapter.homeDirectoryProvider = { tempHome.path }
        CLILaunchAdapter.environmentProvider = {
            [
                "HOME": tempHome.path,
                "PATH": tempHome.appendingPathComponent(".local/bin").path,
                "SHELL": fakeShellPath.path
            ]
        }
        CLILaunchAdapter.clearExecutableResolutionCache()

        XCTAssertNil(CLILaunchAdapter.resolvePinnedExecutable(for: .codex))
        XCTAssertFalse(
            fileManager.fileExists(atPath: shellMarker.path),
            "Pinned Codex resolution must not execute login-shell startup files."
        )
    }

    private func makeExecutableFile(
        at url: URL,
        contents: String = "#!/bin/sh\nexit 0\n"
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
#endif
