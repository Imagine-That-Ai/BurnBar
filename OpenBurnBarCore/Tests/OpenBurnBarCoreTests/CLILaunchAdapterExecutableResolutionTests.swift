#if os(macOS)
import XCTest
@testable import OpenBurnBarCore
// P-15b: CLILaunchAdapter's Foundation-pure resolution surface (and its internal
// test seams environmentProvider/homeDirectoryProvider/
// allowsAmbientUserManagedExecutableFallback/ambientFallbackExecutableSearchDirectories)
// moved to OpenBurnBarKernel; @testable reaches those internals (public members flow via
// the @_exported umbrella). OpenBurnBarLaunchServices stays for the launch-coordinator
// half also exercised here.
@testable import OpenBurnBarKernel
@testable import OpenBurnBarLaunchServices

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

    func testResolveExecutableUsesPinnedCodexPathAndRejectsAmbientFallbacks() throws {
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

        let resolvedPath = try XCTUnwrap(CLILaunchAdapter.resolveExecutable(for: .codex)?.path)
        XCTAssertTrue(
            [
                "/usr/local/bin/codex",
                "/opt/homebrew/bin/codex",
                localBinPath.path
            ].contains(resolvedPath),
            "Codex resolution must choose an explicitly trusted install path."
        )
        XCTAssertFalse(
            [activeNVMPath.path, newerBrokenNVMPath.path].contains(resolvedPath),
            "Codex resolution must not choose ambient version-manager candidates."
        )
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

        let explicitPaths = SwitcherCLIProfileType.codex.trustedExecutablePaths.map {
            CLILaunchAdapter.expandPath($0, homeDirectory: home)
        }
        XCTAssertTrue(explicitPaths.contains("\(home)/.local/bin/codex"))
        XCTAssertTrue(explicitPaths.contains("\(home)/.codex/bin/codex"))
        XCTAssertFalse(explicitPaths.contains { $0.contains("/.nvm/") })
    }

    func testJunieSearchPolicyIncludesJunieManagedBinDirectory() {
        let home = "/tmp/openburnbar-cli-resolution-home"
        let explicitPaths = SwitcherCLIProfileType.junie.trustedExecutablePaths.map {
            CLILaunchAdapter.expandPath($0, homeDirectory: home)
        }

        XCTAssertTrue(SwitcherCLIProfileType.junie.trustedExecutablePaths.contains("$HOME/.junie/bin/junie"))
        XCTAssertTrue(explicitPaths.contains("\(home)/.junie/bin/junie"))
        XCTAssertTrue(CLILaunchAdapter.ambientFallbackExecutableSearchDirectories(
            for: .junie,
            homeDirectory: home
        ).contains("\(home)/.junie/bin"))
    }

    func testCLILaunchErrorUsesLocalizedDescriptions() {
        let error: Error = CLILaunchError.executableNotFound(.codex)
        XCTAssertEqual(
            error.localizedDescription,
            "Codex executable not found. Install Codex to use CLI profile switching."
        )
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

        _ = CLILaunchAdapter.resolvePinnedExecutable(for: .codex)
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
