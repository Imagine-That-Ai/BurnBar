import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class OpenBurnBarSwitcherShellTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        CLILaunchAdapter.executableResolver = nil
    }

    func testShellExecutorFallsBackAfterQuotaExhaustion() async throws {
        let executableURL = try makeExecutable(named: "codex-test")
        CLILaunchAdapter.executableResolver = { _ in executableURL }

        let primary = cliProfile(id: "primary", label: "Work", sortKey: 1, cliType: .codex)
        let fallback = cliProfile(id: "fallback", label: "Personal", sortKey: 2, cliType: .codex)
        let store = TestSwitcherProfileStore(profiles: [primary, fallback], activeProfileID: primary.id)
        let credentials = TestCredentialStore(values: [
            "\(primary.id):codex": "sk-work",
            "\(fallback.id):codex": "sk-personal",
        ])
        let runner = TestTerminalRunner(results: [
            .init(terminationStatus: 1, quotaExhaustedDetail: "5-hour limit reached", capturedOutput: "5-hour limit reached"),
            .init(terminationStatus: 0, quotaExhaustedDetail: nil, capturedOutput: "")
        ])

        let statusRecorder = TestStatusRecorder()
        let executor = BurnBarCLIShellExecutor(
            profileStore: store,
            credentialStore: credentials,
            terminalRunner: runner,
            environmentProvider: { ["TERM": "xterm-256color", "CUSTOM": "1"] },
            statusWriter: { statusRecorder.append($0) }
        )

        let result = try await executor.execute(
            BurnBarCLIShellLaunchRequest(
                cliType: .codex,
                forwardedArguments: ["chat", "--model", "gpt-5"],
                requestedProfileID: nil
            )
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.launchedProfileID, fallback.id)
        XCTAssertEqual(result.attemptedProfileIDs, [primary.id, fallback.id])
        XCTAssertTrue(result.fallbackTriggered)

        let invocations = await runner.invocationsSnapshot()
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].arguments, ["chat", "--model", "gpt-5"])
        XCTAssertEqual(invocations[0].environment["OPENAI_API_KEY"], "sk-work")
        XCTAssertEqual(invocations[1].environment["OPENAI_API_KEY"], "sk-personal")
        XCTAssertTrue(statusRecorder.snapshot().joined().contains("Trying Personal"))
    }

    func testShellExecutorHonorsRequestedProfileOverride() async throws {
        let executableURL = try makeExecutable(named: "claude-test")
        CLILaunchAdapter.executableResolver = { _ in executableURL }

        let first = cliProfile(id: "first", label: "Team", sortKey: 1, cliType: .claude)
        let second = cliProfile(id: "second", label: "Personal", sortKey: 2, cliType: .claude)
        let store = TestSwitcherProfileStore(profiles: [first, second], activeProfileID: first.id)
        let runner = TestTerminalRunner(results: [
            .init(terminationStatus: 0, quotaExhaustedDetail: nil, capturedOutput: "")
        ])

        let executor = BurnBarCLIShellExecutor(
            profileStore: store,
            credentialStore: TestCredentialStore(values: [:]),
            terminalRunner: runner,
            environmentProvider: { ["TERM": "xterm-256color"] },
            statusWriter: { _ in }
        )

        let result = try await executor.execute(
            BurnBarCLIShellLaunchRequest(
                cliType: .claude,
                forwardedArguments: ["--print", "hello"],
                requestedProfileID: second.id
            )
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.launchedProfileID, second.id)
        XCTAssertEqual(result.attemptedProfileIDs, [second.id])
        let invocations = await runner.invocationsSnapshot()
        XCTAssertEqual(invocations.first?.environment["ANTHROPIC_API_KEY"], nil)
    }

    func testRunnerInvokeRoutesExecCommandThroughShellExecutor() async throws {
        let shellExecutor = TestShellExecutor()
        let runner = BurnBarCLIRunner(
            client: FakeCLIClient(),
            shellExecutor: shellExecutor,
            shellShimInstaller: TestShimInstaller()
        )

        let result = try await runner.invoke(
            arguments: ["exec", "codex", "--profile-id", "profile-123", "--", "chat", "--model", "gpt-5"],
            invokedExecutablePath: "/tmp/OpenBurnBarCLI"
        )

        XCTAssertEqual(result.exitCode, 0)
        let requests = await shellExecutor.requestsSnapshot()
        XCTAssertEqual(requests, [
            BurnBarCLIShellLaunchRequest(
                cliType: .codex,
                forwardedArguments: ["chat", "--model", "gpt-5"],
                requestedProfileID: "profile-123"
            )
        ])
    }

    func testRunnerInvokeUsesArgv0ShimRouting() async throws {
        let shellExecutor = TestShellExecutor()
        let runner = BurnBarCLIRunner(
            client: FakeCLIClient(),
            shellExecutor: shellExecutor,
            shellShimInstaller: TestShimInstaller()
        )

        let result = try await runner.invoke(
            arguments: ["--verbose"],
            invokedExecutablePath: "/tmp/codex"
        )

        XCTAssertEqual(result.exitCode, 0)
        let requests = await shellExecutor.requestsSnapshot()
        XCTAssertEqual(requests.first?.cliType, .codex)
        XCTAssertEqual(requests.first?.forwardedArguments, ["--verbose"])
    }

    func testShimInstallerWritesExecutableWrappers() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-shim-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let installer = BurnBarCLIShellShimInstaller(installDirectory: tempDirectory)
        let result = try installer.installShims(invokedExecutablePath: "/tmp/OpenBurnBarCLI")

        XCTAssertEqual(result.installDirectory, tempDirectory)
        XCTAssertEqual(Set(result.installedCommands), Set(["codex", "claude", "opencode"]))

        let codexShim = tempDirectory.appendingPathComponent("codex")
        let contents = try String(contentsOf: codexShim, encoding: .utf8)
        XCTAssertTrue(contents.contains("exec \"/tmp/OpenBurnBarCLI\" exec codex \"$@\""))
    }

    private func cliProfile(
        id: String,
        label: String,
        sortKey: Int,
        cliType: SwitcherCLIProfileType
    ) -> SwitcherProfileRecord {
        SwitcherProfileRecord(
            id: id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: label),
            sortKey: sortKey,
            createdAt: Date(timeIntervalSince1970: TimeInterval(sortKey)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(sortKey))
        )
    }

    private func makeExecutable(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

private final class TestSwitcherProfileStore: BurnBarSwitcherProfileStoreProviding, Sendable {
    private let profiles: [SwitcherProfileRecord]
    private let activeProfileIDValue: String?

    init(profiles: [SwitcherProfileRecord], activeProfileID: String?) {
        self.profiles = profiles
        self.activeProfileIDValue = activeProfileID
    }

    func fetchProfile(id: String) -> SwitcherProfileRecord? {
        profiles.first(where: { $0.id == id })
    }

    func fetchAllProfiles() -> [SwitcherProfileRecord] {
        profiles
    }

    func fetchActiveProfileID() -> String? {
        activeProfileIDValue
    }

    func setActiveProfileID(_ profileID: String?) {}

    func updateProfile(_ profile: SwitcherProfileRecord) {}
}

private struct TestCredentialStore: BurnBarSwitcherCredentialProviding {
    let values: [String: String]

    func apiKey(forProfileID profileID: String, cliType: SwitcherCLIProfileType) -> String? {
        values["\(profileID):\(cliType.rawValue)"]
    }
}

private final class TestStatusRecorder: Sendable {
    private let state = Locked<[String]>([])

    func append(_ value: String) {
        state.withLock { $0.append(value) }
    }

    func snapshot() -> [String] {
        state.read()
    }
}

private final class TestTerminalRunner: BurnBarCLITerminalRunning, Sendable {
    struct Invocation: Equatable {
        let cliType: SwitcherCLIProfileType
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let workingDirectory: String?
    }
    private let state: State

    init(results: [BurnBarCLITerminalRunResult]) {
        self.state = State(results: results)
    }

    func run(
        cliType: SwitcherCLIProfileType,
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?
    ) async throws -> BurnBarCLITerminalRunResult {
        let invocation = Invocation(
            cliType: cliType,
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
        return await state.record(invocation)
    }

    func invocationsSnapshot() async -> [Invocation] {
        await state.snapshotInvocations()
    }

    actor State {
        private var results: [BurnBarCLITerminalRunResult]
        private var invocations: [Invocation] = []

        init(results: [BurnBarCLITerminalRunResult]) {
            self.results = results
        }

        func record(_ invocation: Invocation) -> BurnBarCLITerminalRunResult {
            invocations.append(invocation)
            return results.removeFirst()
        }

        func snapshotInvocations() -> [Invocation] {
            invocations
        }
    }
}

private final class TestShellExecutor: BurnBarCLIShellExecuting, Sendable {
    private let state = State()

    func execute(_ request: BurnBarCLIShellLaunchRequest) async throws -> BurnBarCLIShellExecutionResult {
        await state.append(request)
        return BurnBarCLIShellExecutionResult(
            exitCode: 0,
            launchedProfileID: request.requestedProfileID,
            attemptedProfileIDs: [],
            fallbackTriggered: false
        )
    }

    func requestsSnapshot() async -> [BurnBarCLIShellLaunchRequest] {
        await state.snapshot()
    }

    actor State {
        private var requests: [BurnBarCLIShellLaunchRequest] = []

        func append(_ request: BurnBarCLIShellLaunchRequest) {
            requests.append(request)
        }

        func snapshot() -> [BurnBarCLIShellLaunchRequest] {
            requests
        }
    }
}

private struct TestShimInstaller: BurnBarCLIShellShimInstalling {
    func installShims(invokedExecutablePath: String) throws -> BurnBarCLIShellShimInstallResult {
        BurnBarCLIShellShimInstallResult(
            installDirectory: URL(fileURLWithPath: "/tmp"),
            installedCommands: []
        )
    }
}
