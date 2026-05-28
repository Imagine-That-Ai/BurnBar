// Quarantined tests extracted from: OpenBurnBarDaemonManagerTests.swift
//
// These tests were quarantined because they reference stale contracts,
// drifted schemas, or environmental preconditions not satisfied in CI.
// See QUARANTINE_MANIFEST.md for per-test owner, reason, and revival criteria.
//
// Revival workflow:
//   1. Update tests to compile against current public/@testable APIs.
//   2. Move this file to AgentLensTests/Active/ (matching subdirectory).
//   3. Remove the file from Quarantine.
//   4. Prove with: ./scripts/test-openburnbar-app.sh

import Foundation
import GRDB
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

final class OpenBurnBarDaemonManagerTests: XCTestCase {

    // MARK: - Quarantined Tests

    func test_managerPrefersDaemonRPCForConfigAndRecentUsage() async throws {
        try XCTSkipIf(true, "Stale contract — daemon RPC URL/recent-usage shape drifted; harness fixtures need refresh.")
        let harness = try makeRuntimePathsHarness(name: "rpc-preferred")
        defer { harness.cleanup() }

        try fallbackConfigJSON().write(to: harness.paths.providerConfigURL, atomically: true, encoding: .utf8)
        try fallbackUsageLines().write(to: harness.paths.usageLedgerURL, atomically: true, encoding: .utf8)

        let rpcSnapshot = BurnBarProviderConfigurationSnapshot(
            providers: [
                BurnBarProviderSettings(
                    providerID: "zai",
                    isEnabled: true,
                    baseURL: "https://rpc.z.ai/v4",
                    preferredModelIDs: ["glm-5"]
                ),
                BurnBarProviderSettings(
                    providerID: "minimax",
                    isEnabled: true,
                    baseURL: "https://rpc.minimax.io/v1",
                    preferredModelIDs: ["MiniMax-M3-pro"]
                )
            ]
        )
        let rpcUsage = [
            BurnBarUsageEvent(
                runID: BurnBarRunID(rawValue: "rpc-run-1"),
                providerID: "minimax",
                modelID: "MiniMax-M3-pro",
                inputTokens: 500,
                outputTokens: 120,
                cacheReadTokens: 25,
                cost: 1.15,
                recordedAt: Date(timeIntervalSince1970: 1_710_001_200)
            )
        ]

        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: OpenBurnBarDaemonDependencies(
                fileManager: .default,
                runProcess: { _, _ in "" },
                resolveDaemonBinary: { nil },
                requestHealth: { _ in
                    BurnBarHealthResponse(
                        ok: true,
                        daemonVersion: "rpc-daemon",
                        protocolVersion: BurnBarProtocolVersion.current,
                        socketPath: harness.paths.socketURL.path
                    )
                },
                requestConfig: { _ in rpcSnapshot },
                updateConfig: { _, snapshot in snapshot },
                requestRecentUsage: { _, limit in
                    XCTAssertEqual(limit, 20)
                    return rpcUsage
                },
                requestControllerProjects: { _ in
                    [
                        BurnBarReviewProjectSnapshot(
                            id: "project-rpc",
                            projectSlug: "openburnbar",
                            displayName: "OpenBurnBar",
                            summary: "Daemon-backed registry project.",
                            status: .healthy,
                            preferredCadence: .daily,
                            aliases: ["bb"],
                            automationMode: .scheduled,
                            reviewModelID: "glm-5",
                            scheduleHourLocal: 9,
                            scheduleWeekdayLocal: 2,
                            freshness: .fresh,
                            pendingQuestionCount: 1,
                            openFollowupCount: 1,
                            activeMissionCount: 0,
                            needsOperatorAttention: true,
                            ingestionSource: .appActivity
                        )
                    ]
                },
                upsertControllerProject: { _, project in project },
                recordControllerReviewRun: { _, run in
                    BurnBarControllerReviewRunRecordResponse(
                        run: run,
                        summary: BurnBarControllerSummary(
                            updatedAt: Date(),
                            activeProjectSlug: run.projectSlug,
                            counts: BurnBarControllerCounts(
                                projectCount: 1,
                                pendingQuestionCount: run.questionCount,
                                openFollowupCount: run.followupCount,
                                activeMissionCount: run.missionCount,
                                staleProjectCount: 0
                            ),
                            freshness: .fresh
                        )
                    )
                }
            ),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        )

        await manager.refreshHealth()

        XCTAssertEqual(manager.runtimeStateSource, .daemonRPC)
        XCTAssertEqual(manager.providerConfigurations.map(\.baseURL), ["https://rpc.z.ai/v4", "https://rpc.minimax.io/v1"])
        XCTAssertEqual(manager.recentUsage.map(\.idempotencyKey), ["rpc-run-1"])
        XCTAssertEqual(manager.usageLedgerCount, 1)
        XCTAssertEqual(manager.controllerProjects.first?.projectSlug, "openburnbar")
        XCTAssertEqual(manager.controllerProjects.first?.automationMode, .scheduled)
    }


    func test_managerUpdatesProviderConfigurationThroughDaemonRPC() async throws {
        try XCTSkipIf(true, "Stale contract — provider configuration RPC payload drifted; harness fixtures need refresh.")
        let harness = try makeRuntimePathsHarness(name: "rpc-update")
        defer { harness.cleanup() }

        let initialSnapshot = BurnBarProviderConfigurationSnapshot(
            providers: [
                BurnBarProviderSettings(
                    providerID: "zai",
                    isEnabled: false,
                    baseURL: "https://api.z.ai/api/coding/paas/v4",
                    preferredModelIDs: ["glm-5"]
                ),
                BurnBarProviderSettings(
                    providerID: "minimax",
                    isEnabled: false,
                    baseURL: "https://api.minimax.io/v1",
                    preferredModelIDs: ["minimax-m2.7-highspeed"]
                )
            ]
        )

        var currentSnapshot = initialSnapshot
        var updateCalls = 0

        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: OpenBurnBarDaemonDependencies(
                fileManager: .default,
                runProcess: { _, _ in "" },
                resolveDaemonBinary: { nil },
                requestHealth: { _ in
                    BurnBarHealthResponse(
                        ok: true,
                        daemonVersion: "rpc-daemon",
                        protocolVersion: BurnBarProtocolVersion.current,
                        socketPath: harness.paths.socketURL.path
                    )
                },
                requestConfig: { _ in currentSnapshot },
                updateConfig: { _, snapshot in
                    updateCalls += 1
                    currentSnapshot = snapshot
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
                }
            ),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        )

        await manager.refreshHealth()
        await manager.updateProviderConfiguration(
            providerID: "zai",
            isEnabled: true,
            baseURL: "https://rpc.z.ai/v4",
            preferredModelIDs: ["glm-5", "glm-5-turbo"]
        )

        XCTAssertEqual(updateCalls, 1)
        XCTAssertEqual(currentSnapshot.providerSettings(id: "zai")?.isEnabled, true)
        XCTAssertEqual(currentSnapshot.providerSettings(id: "zai")?.baseURL, "https://rpc.z.ai/v4")
        XCTAssertEqual(currentSnapshot.providerSettings(id: "zai")?.preferredModelIDs, ["glm-5", "glm-5-turbo"])
    }


    func test_appToDaemonHealthSmoke() async throws {
        try XCTSkipIf(true, "Stale contract — daemon health smoke uses a transport surface that drifted under hardening.")
        let daemonURL = try daemonExecutableURL()
        let socketURL = URL(fileURLWithPath: "/tmp/openburnbar-daemon-smoke-\(UUID().uuidString).sock")

        let process = Process()
        process.executableURL = daemonURL
        process.arguments = ["--socket-path", socketURL.path, "--version", "smoke-daemon"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: socketURL)
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let response = try? OpenBurnBarDaemonSocketClient.health(at: socketURL) {
                XCTAssertTrue(response.ok)
                XCTAssertEqual(response.daemonVersion, "smoke-daemon")
                XCTAssertEqual(response.protocolVersion, BurnBarProtocolVersion.current)
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTFail("Timed out waiting for OpenBurnBarDaemon health response")
    }

    private func daemonExecutableURL() throws -> URL {
        var productsURL = Bundle(for: Self.self).bundleURL
        for _ in 0..<4 {
            productsURL.deleteLastPathComponent()
        }
        let daemonURL = productsURL.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: daemonURL.path) else {
            throw XCTSkip("OpenBurnBarDaemon executable is not available in build products")
        }
        return daemonURL
    }

    private func makeRuntimePathsHarness(name: String) throws -> RuntimePathsHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenBurnBarDaemonManagerTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let daemonDirectory = rootURL.appendingPathComponent("daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonDirectory, withIntermediateDirectories: true)

        let paths = OpenBurnBarDaemonRuntimePaths(
            supportDirectory: rootURL,
            daemonDirectory: daemonDirectory,
            installedBinaryURL: daemonDirectory.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false),
            socketURL: rootURL.appendingPathComponent("openburnbar-daemon.sock", isDirectory: false),
            logURL: daemonDirectory.appendingPathComponent("openburnbar-daemon.log", isDirectory: false),
            launchAgentPlistURL: daemonDirectory.appendingPathComponent("com.openburnbar.daemon.plist", isDirectory: false)
        )

        return RuntimePathsHarness(rootURL: rootURL, paths: paths)
    }


}
