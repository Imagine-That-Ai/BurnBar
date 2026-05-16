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

    func testResolveExecutablePrefersLoginShellVersionManagerPathOverNewestScannedNVMVersion() throws {
        let fileManager = FileManager.default
        let tempHome = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-cli-resolution-\(UUID().uuidString)", isDirectory: true)
        temporaryRoots.append(tempHome)

        let activeNVMPath = tempHome
            .appendingPathComponent(".nvm/versions/node/v20.20.2/bin/codex")
        let newerBrokenNVMPath = tempHome
            .appendingPathComponent(".nvm/versions/node/v24.14.0/bin/codex")
        let fakeShellPath = tempHome.appendingPathComponent("fake-login-shell")

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
                "PATH": "\(activeNVMPath.deletingLastPathComponent().path):\(newerBrokenNVMPath.deletingLastPathComponent().path)",
                "SHELL": fakeShellPath.path
            ]
        }
        CLILaunchAdapter.clearExecutableResolutionCache()

        XCTAssertEqual(
            CLILaunchAdapter.resolveExecutable(for: .codex)?.path,
            activeNVMPath.path
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
