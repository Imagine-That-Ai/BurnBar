import Foundation
import GRDB
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

final class OpenBurnBarDaemonManagerTests: XCTestCase {
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

    @MainActor
    func test_installedDaemonBinaryNeedsRefreshDetectsStaleInstalledDaemon() throws {
        let harness = try makeRuntimePathsHarness(name: "stale-daemon")
        defer { harness.cleanup() }

        let sourceBinaryURL = harness.rootURL.appendingPathComponent("source-openburnbar-daemon", isDirectory: false)
        try "#!/bin/sh\nexit 0\necho fresh\n".write(to: sourceBinaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceBinaryURL.path)

        try "#!/bin/sh\nexit 0\n".write(to: harness.paths.installedBinaryURL, atomically: true, encoding: .utf8)

        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: daemonDependencies(resolveDaemonBinary: { sourceBinaryURL }),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        )

        XCTAssertTrue(manager.installedDaemonBinaryNeedsRefresh())

        try FileManager.default.removeItem(at: harness.paths.installedBinaryURL)
        try FileManager.default.copyItem(at: sourceBinaryURL, to: harness.paths.installedBinaryURL)
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceBinaryURL.path)
        if let sourceModifiedAt = sourceAttributes[.modificationDate] as? Date {
            try FileManager.default.setAttributes(
                [.modificationDate: sourceModifiedAt],
                ofItemAtPath: harness.paths.installedBinaryURL.path
            )
        }

        XCTAssertFalse(manager.installedDaemonBinaryNeedsRefresh())
    }

    func test_daemonBinaryResolverPrefersBundledHelperOverBuildProductSibling() throws {
        let harness = try makeRuntimePathsHarness(name: "binary-resolver-helper")
        defer { harness.cleanup() }

        let appBundleURL = harness.rootURL.appendingPathComponent("OpenBurnBar.app", isDirectory: true)
        let helpersURL = appBundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)

        let helperURL = helpersURL.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false)
        try "#!/bin/sh\necho bundled\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let siblingURL = appBundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("OpenBurnBarDaemon", isDirectory: false)
        try "#!/bin/sh\necho sibling\n".write(to: siblingURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: siblingURL.path)

        XCTAssertEqual(
            OpenBurnBarDaemonBinaryResolver.resolve(appBundleURL: appBundleURL, fileManager: .default),
            helperURL
        )
    }

    @MainActor
    func test_refreshInstalledDaemonIfNeededRepairsStaleInstalledDaemon() async throws {
        let harness = try makeRuntimePathsHarness(name: "refresh-stale-daemon")
        defer { harness.cleanup() }

        let sourceBinaryURL = harness.rootURL.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false)
        try "#!/bin/sh\nexit 0\necho fresh\n".write(to: sourceBinaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceBinaryURL.path)
        let sourceBundleURL = harness.rootURL.appendingPathComponent(
            OpenBurnBarDaemonManager.resourceBundleName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)

        try "#!/bin/sh\nexit 0\necho stale\n".write(to: harness.paths.installedBinaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.paths.installedBinaryURL.path)

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
                        daemonVersion: "fresh-daemon",
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

        let didRefresh = await manager.refreshInstalledDaemonIfNeededForCurrentAppBuild()
        XCTAssertTrue(didRefresh)
        XCTAssertFalse(manager.installedDaemonBinaryNeedsRefresh())
        XCTAssertEqual(
            try Data(contentsOf: harness.paths.installedBinaryURL),
            try Data(contentsOf: sourceBinaryURL)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.paths.daemonDirectory.appendingPathComponent(OpenBurnBarDaemonManager.resourceBundleName).path))
        XCTAssertTrue(
            launchctlCalls.contains(where: { $0.starts(with: ["kickstart", "-k", "gui/\(getuid())/\(OpenBurnBarDaemonRuntimePaths.launchAgentLabel)"]) })
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

    func test_providerQuotaRefreshDoesNotMarkDaemonOwnedSlotMissingWhenAppSecretMirrorIsAbsent() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager+ProviderConfig.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("New provider slots are daemon-owned."),
            "Quota refresh must treat app-side keychain misses as unknown daemon-owned credentials, not missing credentials."
        )
        XCTAssertFalse(
            source.contains("} else {\n                        slot.status = .missingSecret\n                        slot.lastStatusMessage = \"Missing API key\""),
            "The post-save quota refresh path must not overwrite daemon-owned credential slots as missing when the app-side mirror is empty."
        )
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

    func test_usageSync_importsHermesLedgerRowsAsHermesProvider() throws {
        let harness = try makeRuntimePathsHarness(name: "hermes-import")
        defer { harness.cleanup() }

        let encoder = JSONEncoder()
        let event = BurnBarUsageEvent(
            providerID: "hermes",
            modelID: "minimax-m2.7-highspeed",
            inputTokens: 320,
            outputTokens: 110,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 24,
            cost: 0.0145,
            recordedAt: Date(timeIntervalSince1970: 1_773_700_000),
            sessionID: "hermes-mobile-session",
            projectName: "Hermes (proxy)",
            confidence: .exact
        )
        let estimate = BurnBarUsageEvent(
            providerID: "hermes",
            modelID: "minimax-m2.7-highspeed",
            inputTokens: 60,
            outputTokens: 24,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            recordedAt: Date(timeIntervalSince1970: 1_773_700_500),
            sessionID: "hermes-mobile-session",
            projectName: "Hermes (proxy)",
            confidence: .lowConfidenceEstimate
        )

        let exactLine = try encodedUsageRecordLine(
            idempotencyKey: "hermes-exact",
            event: event,
            encoder: encoder
        )
        let estimateLine = try encodedUsageRecordLine(
            idempotencyKey: "hermes-estimate",
            event: estimate,
            encoder: encoder
        )
        try [exactLine, estimateLine]
            .joined(separator: "\n")
            .appending("\n")
            .write(to: harness.paths.usageLedgerURL, atomically: true, encoding: .utf8)

        var inserted: [TokenUsage] = []
        let service = OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        _ = service.refreshState(insertUsages: { inserted.append(contentsOf: $0) })

        XCTAssertEqual(inserted.count, 2)
        let exact = try XCTUnwrap(inserted.first { $0.sessionId == "hermes-mobile-session" && $0.provenanceConfidence == .exact })
        XCTAssertEqual(exact.provider, .hermes)
        XCTAssertEqual(exact.projectName, "Hermes (proxy)")
        XCTAssertEqual(exact.reasoningTokens, 24)
        XCTAssertEqual(exact.provenanceMethod, .providerLog)

        let estimateRow = try XCTUnwrap(inserted.first { $0.provenanceConfidence == .lowConfidenceEstimate })
        XCTAssertEqual(estimateRow.provider, .hermes)
        XCTAssertEqual(estimateRow.projectName, "Hermes (proxy)")
        XCTAssertEqual(estimateRow.provenanceMethod, .heuristicEstimate)
    }

    @MainActor
    func test_managerUploadsPendingUsageAfterDaemonImport() async throws {
        let harness = try makeRuntimePathsHarness(name: "daemon-import-cloud-upload")
        defer { harness.cleanup() }

        try fallbackUsageLines().write(to: harness.paths.usageLedgerURL, atomically: true, encoding: .utf8)
        let store = try makeInMemoryStore()
        var uploadCalls = 0

        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: OpenBurnBarDaemonDependencies(
                fileManager: .default,
                runProcess: { _, _ in "" },
                resolveDaemonBinary: { nil },
                requestHealth: { _ in throw POSIXError(.ECONNREFUSED) },
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
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default),
            uploadPendingUsageAfterImport: { uploadCalls += 1 }
        )

        manager.dataStore = store
        await manager.refreshHealth()

        XCTAssertEqual(uploadCalls, 1)
        XCTAssertEqual(try store.fetchUnsynced().count, 2)
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

    private func daemonDependencies(resolveDaemonBinary: @escaping () -> URL?) -> OpenBurnBarDaemonDependencies {
        OpenBurnBarDaemonDependencies(
            fileManager: .default,
            runProcess: { _, _ in "" },
            resolveDaemonBinary: resolveDaemonBinary,
            requestHealth: { _ in
                BurnBarHealthResponse(
                    ok: true,
                    daemonVersion: "test-daemon",
                    protocolVersion: BurnBarProtocolVersion.current,
                    socketPath: "/tmp/openburnbar-test.sock"
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
        )
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


    private func makeRuntimePathsHarness(name: String) throws -> RuntimePathsHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BurnBarDaemonManagerTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let supportDirectory = rootURL.appendingPathComponent("support", isDirectory: true)
        let daemonDirectory = supportDirectory.appendingPathComponent("daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonDirectory, withIntermediateDirectories: true)
        let paths = OpenBurnBarDaemonRuntimePaths(
            supportDirectory: supportDirectory,
            daemonDirectory: daemonDirectory,
            installedBinaryURL: daemonDirectory.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false),
            socketURL: supportDirectory.appendingPathComponent("openburnbar-daemon.sock", isDirectory: false),
            logURL: daemonDirectory.appendingPathComponent("openburnbar-daemon.log", isDirectory: false),
            launchAgentPlistURL: rootURL.appendingPathComponent("Library/LaunchAgents/com.openburnbar.daemon.plist", isDirectory: false)
        )
        return RuntimePathsHarness(rootURL: rootURL, paths: paths)
    }
private struct RuntimePathsHarness {
    let rootURL: URL
    let paths: OpenBurnBarDaemonRuntimePaths

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
