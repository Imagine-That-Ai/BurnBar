import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// The app hands the consented Memory Pro policy to the daemon through the
/// provider-config snapshot and keeps the daemon's membership cache fresh; both
/// paths are exercised with injected daemon closures, never a socket.
@MainActor
final class MemoryCloudModelsPolicyHandoffTests: XCTestCase {

    private final class DaemonState: @unchecked Sendable {
        var snapshot = BurnBarProviderConfigurationSnapshot(providers: [])
        var updates = 0
        var restores = 0
        var healthy = true
    }

    private func makeManager(
        name: String,
        settings: SettingsManager,
        state: DaemonState
    ) throws -> OpenBurnBarDaemonManager {
        let harness = try makeMemoryProRuntimePaths(name: name)
        return OpenBurnBarDaemonManager(
            settingsManager: settings,
            paths: harness.paths,
            dependencies: OpenBurnBarDaemonDependencies(
                fileManager: .default,
                runProcess: { _, _ in "" },
                resolveDaemonBinary: { nil },
                requestHealth: { _ in
                    guard state.healthy else { throw OpenBurnBarDaemonManagerError.rpcError("daemon down") }
                    return BurnBarHealthResponse(
                        ok: true,
                        daemonVersion: "test-daemon",
                        protocolVersion: BurnBarProtocolVersion.current,
                        socketPath: harness.paths.socketURL.path
                    )
                },
                requestConfig: { _ in state.snapshot },
                updateConfig: { _, snapshot in
                    state.snapshot = snapshot
                    state.updates += 1
                    return snapshot
                },
                requestRecentUsage: { _, _ in [] },
                requestControllerProjects: { _ in [] },
                upsertControllerProject: { _, project in project },
                recordControllerReviewRun: { _, run in
                    BurnBarControllerReviewRunRecordResponse(
                        run: run,
                        summary: BurnBarControllerSummary(
                            updatedAt: Date(),
                            counts: BurnBarControllerCounts(
                                projectCount: 0,
                                pendingQuestionCount: 0,
                                openFollowupCount: 0,
                                activeMissionCount: 0,
                                staleProjectCount: 0
                            ),
                            freshness: .missing
                        )
                    )
                },
                membershipRestore: { _ in
                    state.restores += 1
                    return BurnBarMembershipRestoreResponse(ok: true, membership: nil, error: nil)
                }
            )
        )
    }

    func testEnablingWritesTheEgressPolicyIntoTheDaemonSnapshot() async throws {
        let settings = makeSettingsManager(defaults: makeIsolatedDefaults())
        let state = DaemonState()
        let manager = try makeManager(name: "memory-egress-enable", settings: settings, state: state)
        settings.memoryConsentGranted = true
        settings.cliAssistantAllowed = true
        settings.memory.cloudModelsEnabled = true
        settings.memory.cloudModelsConsentedProviderIDs = [.openrouter, .claudeCLI]
        settings.memory.cloudModelsRequireNoRetention = true
        settings.memory.cloudModelsDailyCapUSD = 3.0

        await manager.updateMemoryEgressPolicy()

        XCTAssertEqual(state.updates, 1)
        let written = state.snapshot.memoryEgress
        XCTAssertTrue(written.enabled)
        XCTAssertEqual(written.consentedProviderIDs, ["openrouter"])
        XCTAssertEqual(written.consentedCLIProviderIDs, ["claude_cli"])
        XCTAssertEqual(written.allowedModelIDsByPurpose, [:])
        XCTAssertTrue(written.requireNoRetention)
        XCTAssertEqual(written.dailyCapUSD, 3.0)
        XCTAssertNotNil(written.updatedAt)
        XCTAssertNil(manager.lastError)

        settings.memory.cloudModelsEnabled = false
        await manager.updateMemoryEgressPolicy()
        XCTAssertEqual(state.updates, 2)
        XCTAssertFalse(state.snapshot.memoryEgress.enabled)
        XCTAssertEqual(state.snapshot.memoryEgress.consentedProviderIDs, ["openrouter"], "disabling keeps the list")
    }

    func testUnhealthyDaemonSkipsTheWriteAndReportsIt() async throws {
        let settings = makeSettingsManager(defaults: makeIsolatedDefaults())
        let state = DaemonState()
        state.healthy = false
        let manager = try makeManager(name: "memory-egress-unhealthy", settings: settings, state: state)
        settings.memoryConsentGranted = true
        settings.memory.cloudModelsEnabled = true

        await manager.updateMemoryEgressPolicy()

        XCTAssertEqual(state.updates, 0)
        XCTAssertNotNil(manager.lastError)
    }

    func testMembershipRefreshIsRateLimitedToOncePerMinute() async throws {
        let settings = makeSettingsManager(defaults: makeIsolatedDefaults())
        let state = DaemonState()
        let manager = try makeManager(name: "memory-membership", settings: settings, state: state)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        await manager.refreshDaemonMembershipCache(reason: "launch", now: start)
        await manager.refreshDaemonMembershipCache(reason: "storekit", now: start.addingTimeInterval(30))
        XCTAssertEqual(state.restores, 1, "a second refresh inside 60 s is coalesced")
        await manager.refreshDaemonMembershipCache(reason: "storekit", now: start.addingTimeInterval(61))
        XCTAssertEqual(state.restores, 2)
        XCTAssertNil(manager.lastError)
    }
}

// MARK: - Runtime paths under a temporary directory (mirrors OpenBurnBarDaemonManagerTests)

private struct MemoryProRuntimePathsHarness {
    let rootURL: URL
    let paths: OpenBurnBarDaemonRuntimePaths
}

private func makeMemoryProRuntimePaths(name: String) throws -> MemoryProRuntimePathsHarness {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("BurnBarMemoryProTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let supportDirectory = rootURL.appendingPathComponent("support", isDirectory: true)
    let daemonDirectory = supportDirectory.appendingPathComponent("daemon", isDirectory: true)
    try FileManager.default.createDirectory(at: daemonDirectory, withIntermediateDirectories: true)
    let paths = OpenBurnBarDaemonRuntimePaths(
        supportDirectory: supportDirectory,
        daemonDirectory: daemonDirectory,
        frameworksDirectory: supportDirectory.appendingPathComponent("Frameworks", isDirectory: true),
        installedBinaryURL: daemonDirectory.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false),
        socketURL: supportDirectory.appendingPathComponent("openburnbar-daemon.sock", isDirectory: false),
        logURL: daemonDirectory.appendingPathComponent("openburnbar-daemon.log", isDirectory: false),
        launchAgentPlistURL: rootURL.appendingPathComponent("Library/LaunchAgents/com.openburnbar.daemon.plist", isDirectory: false)
    )
    return MemoryProRuntimePathsHarness(rootURL: rootURL, paths: paths)
}
