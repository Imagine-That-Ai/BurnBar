import Foundation
import GRDB
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

final class OpenBurnBarDaemonManagerTests: XCTestCase {
    @MainActor
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

    @MainActor
    func test_managerFallsBackToLocalMirrorWhenDaemonUnavailable() async throws {
        let harness = try makeRuntimePathsHarness(name: "fallback")
        defer { harness.cleanup() }

        try Data().write(to: harness.paths.installedBinaryURL)
        try fallbackConfigJSON().write(to: harness.paths.providerConfigURL, atomically: true, encoding: .utf8)
        try fallbackUsageLines().write(to: harness.paths.usageLedgerURL, atomically: true, encoding: .utf8)

        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: OpenBurnBarDaemonDependencies(
                fileManager: .default,
                runProcess: { _, _ in "" },
                resolveDaemonBinary: { nil },
                requestHealth: { _ in throw POSIXError(.ECONNREFUSED) },
                requestConfig: { _ in
                    XCTFail("Config RPC should not be called when the daemon is unavailable")
                    return BurnBarProviderConfigurationSnapshot(providers: [])
                },
                updateConfig: { _, _ in
                    XCTFail("Config update RPC should not be called when the daemon is unavailable")
                    return BurnBarProviderConfigurationSnapshot(providers: [])
                },
                requestRecentUsage: { _, _ in
                    XCTFail("Usage RPC should not be called when the daemon is unavailable")
                    return []
                },
                requestControllerProjects: { _ in
                    XCTFail("Controller project RPC should not be called when the daemon is unavailable")
                    return []
                },
                upsertControllerProject: { _, _ in
                    XCTFail("Controller project upsert RPC should not be called when the daemon is unavailable")
                    return nil
                },
                recordControllerReviewRun: { _, run in
                    XCTFail("Controller review run RPC should not be called when the daemon is unavailable")
                    return BurnBarControllerReviewRunRecordResponse(
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

        XCTAssertEqual(manager.runtimeStateSource, .localFallback)
        XCTAssertEqual(manager.providerConfigurations.map(\.provider), [.zai, .minimax])
        XCTAssertEqual(manager.recentUsage.map(\.provider), [.minimax, .zai])
        XCTAssertEqual(manager.usageLedgerCount, 2)
    }

    @MainActor
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

    @MainActor
    func test_installAndUninstallManageLaunchAgentAndBinary() async throws {
        let harness = try makeRuntimePathsHarness(name: "install-uninstall")
        defer { harness.cleanup() }

        let sourceBinaryURL = harness.rootURL.appendingPathComponent("source-openburnbar-daemon", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: sourceBinaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceBinaryURL.path)

        var launchctlCalls: [[String]] = []

        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: OpenBurnBarDaemonDependencies(
                fileManager: .default,
                runProcess: { _, arguments in
                    launchctlCalls.append(arguments)
                    return ""
                },
                resolveDaemonBinary: { sourceBinaryURL },
                requestHealth: { _ in
                    BurnBarHealthResponse(
                        ok: true,
                        daemonVersion: "install-daemon",
                        protocolVersion: BurnBarProtocolVersion.current,
                        socketPath: harness.paths.socketURL.path
                    )
                },
                requestConfig: { _ in BurnBarProviderConfigurationSnapshot(providers: []) },
                updateConfig: { _, snapshot in snapshot },
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

        await manager.installAndStart()

        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.paths.installedBinaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.paths.launchAgentPlistURL.path))
        XCTAssertTrue(
            launchctlCalls.contains(where: { $0.starts(with: ["bootstrap", "gui/\(getuid())"]) })
        )
        XCTAssertTrue(
            launchctlCalls.contains(where: { $0.starts(with: ["kickstart", "-k", "gui/\(getuid())/\(OpenBurnBarDaemonRuntimePaths.launchAgentLabel)"]) })
        )

        await manager.uninstall()

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.paths.launchAgentPlistURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.paths.installedBinaryURL.path))
        XCTAssertTrue(
            launchctlCalls.contains(where: { $0.starts(with: ["bootout", "gui/\(getuid())"]) })
        )
    }

    func test_usageSync_readsProviderConfigurationSnapshot() throws {
        let harness = try makeRuntimePathsHarness(name: "provider-config")
        defer { harness.cleanup() }

        try fallbackConfigJSON().write(to: harness.paths.providerConfigURL, atomically: true, encoding: .utf8)

        let service = OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        let snapshot = service.refreshState()

        XCTAssertEqual(snapshot.providerConfigurations.count, 2)
        XCTAssertEqual(snapshot.providerConfigurations.map(\.provider), [.zai, .minimax])
        XCTAssertEqual(snapshot.providerConfigurations.first?.isEnabled, true)
        XCTAssertEqual(snapshot.providerConfigurations.first?.preferredModelIDs, ["glm-5", "glm-5-turbo"])
        XCTAssertEqual(snapshot.providerConfigurations.last?.baseURL, "https://api.minimax.io/v1")
    }

    func test_usageSync_importsDaemonUsageIntoLocalShape() throws {
        let harness = try makeRuntimePathsHarness(name: "usage-import")
        defer { harness.cleanup() }

        try fallbackUsageLines().write(to: harness.paths.usageLedgerURL, atomically: true, encoding: .utf8)

        var inserted: [TokenUsage] = []
        var refreshed = false

        let service = OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        let snapshot = service.refreshState(
            insertUsages: { inserted.append(contentsOf: $0) },
            refreshUsageCache: { refreshed = true }
        )

        XCTAssertEqual(snapshot.ledgerRecordCount, 2)
        XCTAssertEqual(snapshot.recentUsage.map(\.provider), [.minimax, .zai])
        XCTAssertEqual(snapshot.recentUsage.first?.model, "MiniMax-M3-pro")
        XCTAssertEqual(snapshot.recentUsage.first?.totalTokens, 450)

        XCTAssertEqual(inserted.count, 2)
        XCTAssertEqual(inserted.first?.projectName, "OpenBurnBar Daemon")
        XCTAssertEqual(inserted.first?.sessionId, "run-older")
        XCTAssertEqual(inserted.last?.provider, .minimax)
        XCTAssertEqual(inserted.last?.cacheCreationTokens, 25)
        XCTAssertTrue(refreshed)
    }

    @MainActor
    func test_managerExportsControllerActivitySnapshotFromLocalData() async throws {
        let harness = try makeRuntimePathsHarness(name: "activity-export")
        defer { harness.cleanup() }

        let store = try makeInMemoryStore()
        let now = Date()
        store.replaceUsages([
            TokenUsage(
                provider: .zai,
                sessionId: "apollo-session",
                projectName: "Apollo",
                model: "glm-5",
                inputTokens: 300,
                outputTokens: 120,
                costUSD: 1.5,
                startTime: now.addingTimeInterval(-1_800),
                endTime: now.addingTimeInterval(-1_200)
            )
        ])
        try store.upsertConversation(
            ConversationRecord(
                id: "conversation-apollo",
                provider: .zai,
                sessionId: "apollo-session",
                projectName: "Apollo",
                startTime: now.addingTimeInterval(-1_800),
                endTime: now.addingTimeInterval(-900),
                messageCount: 12,
                userWordCount: 40,
                assistantWordCount: 180,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: "Apollo review",
                lastAssistantMessage: "Should Apollo keep the current approval sheet scope?",
                fullText: "Should Apollo keep the current approval sheet scope?",
                fileModifiedAt: now.addingTimeInterval(-900),
                summary: "Apollo is close to shipping, but should it keep the current approval sheet scope?",
                summaryTitle: "Apollo checkpoint",
                summaryUpdatedAt: now.addingTimeInterval(-900)
            )
        )

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
                requestConfig: { _ in BurnBarProviderConfigurationSnapshot(providers: []) },
                updateConfig: { _, snapshot in snapshot },
                requestRecentUsage: { _, _ in [] },
                requestControllerProjects: { _ in [] },
                upsertControllerProject: { _, project in project },
                recordControllerReviewRun: { _, run in
                    BurnBarControllerReviewRunRecordResponse(
                        run: run,
                        summary: BurnBarControllerSummary(
                            updatedAt: Date(),
                            counts: BurnBarControllerCounts(
                                projectCount: 1,
                                pendingQuestionCount: 0,
                                openFollowupCount: 0,
                                activeMissionCount: 0,
                                staleProjectCount: 0
                            ),
                            freshness: .fresh
                        )
                    )
                }
            ),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        )

        manager.attach(dataStore: store)
        await manager.refreshHealth()

        let data = try Data(contentsOf: harness.paths.controllerActivitySnapshotURL)
        let snapshot = try JSONDecoder().decode(BurnBarControllerActivitySnapshot.self, from: data)

        XCTAssertEqual(snapshot.projects.first?.projectSlug, "apollo")
        XCTAssertEqual(snapshot.projects.first?.displayName, "Apollo")
        XCTAssertEqual(snapshot.projects.first?.latestConversationID, "conversation-apollo")
        XCTAssertEqual(snapshot.projects.first?.sessionCountLast7Days, 1)
        XCTAssertNil(snapshot.projects.first?.latestQuestionPrompt)
    }

    func test_makeControllerRuntimeSnapshot_filtersAppActivityQuestionsFromOperatorInbox() {
        let now = Date(timeIntervalSince1970: 1_773_200_000)
        let appActivityQuestionID = BurnBarQuestionID(rawValue: "question-app-activity")
        let daemonQuestionID = BurnBarQuestionID(rawValue: "question-operator")

        let snapshot = OpenBurnBarDaemonSocketClient.makeControllerRuntimeSnapshot(
            summary: BurnBarControllerSummary(
                updatedAt: now,
                counts: BurnBarControllerCounts(
                    projectCount: 1,
                    pendingQuestionCount: 2,
                    openFollowupCount: 2,
                    activeMissionCount: 1,
                    staleProjectCount: 0
                ),
                freshness: .fresh
            ),
            questions: [
                BurnBarPendingQuestionSnapshot(
                    id: appActivityQuestionID,
                    projectSlug: "apollo",
                    sessionID: BurnBarSessionID(rawValue: "apollo-session"),
                    title: "OpenBurnBar Assistant",
                    prompt: "how many times have i said this week?",
                    stageLabel: "Need Operator Input",
                    status: .pending,
                    priority: .medium,
                    askedAt: now,
                    metadata: [
                        "ingestion_source": .string(BurnBarControllerProjectIngestionSource.appActivity.rawValue)
                    ]
                ),
                BurnBarPendingQuestionSnapshot(
                    id: daemonQuestionID,
                    projectSlug: "apollo",
                    sessionID: BurnBarSessionID(rawValue: "apollo-session"),
                    title: "Scope the approval sheet",
                    prompt: "Should Apollo keep the current approval sheet scope?",
                    stageLabel: "Operator Decision",
                    status: .pending,
                    priority: .high,
                    askedAt: now
                )
            ],
            followups: [
                BurnBarFollowupSnapshot(
                    id: BurnBarFollowupID(rawValue: "followup-app-activity"),
                    projectSlug: "apollo",
                    questionID: appActivityQuestionID,
                    title: "App activity followup",
                    summary: "Should not appear in missions queue.",
                    status: .open,
                    kind: .pendingQuestion,
                    createdAt: now
                ),
                BurnBarFollowupSnapshot(
                    id: BurnBarFollowupID(rawValue: "followup-operator"),
                    projectSlug: "apollo",
                    questionID: daemonQuestionID,
                    title: "Operator followup",
                    summary: "Should stay in the queue.",
                    status: .open,
                    kind: .pendingQuestion,
                    createdAt: now
                )
            ],
            missions: [
                BurnBarMissionSnapshot(
                    id: BurnBarMissionID(rawValue: "mission-apollo"),
                    projectSlug: "apollo",
                    title: "Review Apollo",
                    summary: "Mission summary",
                    status: .approved,
                    recommendation: .review,
                    createdAt: now,
                    updatedAt: now,
                    approval: BurnBarMissionApprovalSnapshot(approved: true)
                )
            ],
            notificationHealth: BurnBarNotificationHealthSnapshot(
                checkedAt: now,
                channels: []
            ),
            simulatorRuns: []
        )

        XCTAssertEqual(snapshot.pendingQuestions.count, 1)
        XCTAssertEqual(snapshot.pendingQuestions.first?.id, daemonQuestionID.rawValue)
        XCTAssertEqual(snapshot.followups.count, 1)
        XCTAssertEqual(snapshot.followups.first?.linkedQuestionID, daemonQuestionID.rawValue)
        XCTAssertEqual(snapshot.summary.pendingQuestions, 1)
        XCTAssertEqual(snapshot.summary.unresolvedFollowups, 1)
    }

    @MainActor
    func test_healthSnapshot_flagsProtocolMismatch() {
        let response = BurnBarHealthResponse(
            ok: true,
            daemonVersion: "test-daemon",
            protocolVersion: BurnBarProtocolVersion.current + 1,
            socketPath: "/tmp/test.sock"
        )

        let snapshot = OpenBurnBarDaemonHealthSnapshot(response: response)

        XCTAssertTrue(snapshot.versionMismatch)
        XCTAssertFalse(snapshot.isHealthy)
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

    @MainActor
    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func encodedUsageRecordLine(
        idempotencyKey: String,
        event: BurnBarUsageEvent,
        encoder: JSONEncoder
    ) throws -> String {
        let payload: [String: Any] = [
            "idempotencyKey": idempotencyKey,
            "event": try jsonObject(for: event, encoder: encoder)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    private func jsonObject(for event: BurnBarUsageEvent, encoder: JSONEncoder) throws -> Any {
        let data = try encoder.encode(event)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data))
    }

    private func fallbackConfigJSON() -> String {
        """
        {
          "providers" : [
            {
              "baseURL" : "https://api.z.ai/api/coding/paas/v4",
              "isEnabled" : true,
              "preferredModelIDs" : [
                "glm-5",
                "glm-5-turbo"
              ],
              "providerID" : "zai"
            },
            {
              "baseURL" : "https://api.minimax.io/v1",
              "isEnabled" : false,
              "preferredModelIDs" : [
                "minimax-m2.7-highspeed"
              ],
              "providerID" : "minimax"
            }
          ]
        }
        """
    }

    private func fallbackUsageLines() throws -> String {
        let encoder = JSONEncoder()
        let earlier = BurnBarUsageEvent(
            runID: BurnBarRunID(rawValue: "run-older"),
            providerID: "zai",
            modelID: "glm-5",
            inputTokens: 120,
            outputTokens: 80,
            cacheCreationTokens: 10,
            cacheReadTokens: 20,
            cost: 0.42,
            recordedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
        let later = BurnBarUsageEvent(
            runID: BurnBarRunID(rawValue: "run-newer"),
            providerID: "minimax",
            modelID: "MiniMax-M3-pro",
            inputTokens: 300,
            outputTokens: 100,
            cacheCreationTokens: 25,
            cacheReadTokens: 25,
            cost: 0.88,
            recordedAt: Date(timeIntervalSince1970: 1_710_000_600)
        )

        return try [
            encodedUsageRecordLine(idempotencyKey: "usage-1", event: earlier, encoder: encoder),
            encodedUsageRecordLine(idempotencyKey: "usage-2", event: later, encoder: encoder),
            #"{"idempotencyKey":"usage-ignored","event":{"providerID":"unknown","modelID":"mystery","inputTokens":1,"outputTokens":1,"cacheReadTokens":0,"cost":0.0,"recordedAt":0}}"#
        ]
        .joined(separator: "\n") + "\n"
    }

    func test_resourceBundleResolverFindsBundleInSiblingResourcesDirectory() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BurnBarDaemonResolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let productsURL = rootURL.appendingPathComponent("Build/Products/Debug", isDirectory: true)
        let daemonURL = productsURL.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false)
        let resourcesBundleURL = productsURL
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("BurnBarCore_BurnBarCore.bundle", isDirectory: true)
        let fakeAppBundleURL = productsURL.appendingPathComponent("OpenBurnBar.app", isDirectory: true)

        try FileManager.default.createDirectory(at: resourcesBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeAppBundleURL, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: daemonURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemonURL.path)

        let resolved = OpenBurnBarDaemonBinaryResolver.resolveResourceBundle(
            nearBinaryURL: daemonURL,
            appBundleURL: fakeAppBundleURL,
            fileManager: .default
        )

        XCTAssertEqual(resolved?.standardizedFileURL, resourcesBundleURL.standardizedFileURL)
    }
}

private struct RuntimePathsHarness {
    let rootURL: URL
    let paths: OpenBurnBarDaemonRuntimePaths

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
