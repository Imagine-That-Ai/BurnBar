import Foundation
import GRDB
import XCTest
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBar

final class OpenBurnBarDaemonManagerTests: XCTestCase {
    @MainActor
    func test_computerUseRuntimeUsesManagerOwnedDependencies() throws {
        let harness = try makeRuntimePathsHarness(name: "computer-use-dependencies")
        defer { harness.cleanup() }
        let defaultsSuite = "OpenBurnBarDaemonManagerTests.computer-use.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let budgetStatusStore = ComputerUseBudgetStatusStore(isSignedInProvider: { false })
        let quotaUsageStore = ComputerUseQuotaUsageStore()
        let meteringRecorder = ComputerUseCloudMeteringRecorderSpy()
        defer {
            budgetStatusStore.stopListening()
            quotaUsageStore.stopListening()
        }
        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: daemonDependencies(resolveDaemonBinary: { nil }),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default),
            computerUseBudgetStatusStore: budgetStatusStore,
            computerUseQuotaUsageStore: quotaUsageStore,
            computerUseCloudMeteringRecorder: meteringRecorder
        )

        XCTAssertIdentical(manager.computerUseBudgetStatusStore, budgetStatusStore)
        XCTAssertIdentical(manager.computerUseQuotaUsageStore, quotaUsageStore)
        XCTAssertIdentical(manager.computerUseCloudMeteringRecorder as AnyObject, meteringRecorder)

        let controller = ComputerUseRuntimeController(
            accountManager: AccountManager(),
            settingsManager: SettingsManager(defaults: defaults),
            daemonManager: manager
        )

        XCTAssertNotNil(budgetStatusStore.onEnvelopeChanged)
        XCTAssertNotNil(budgetStatusStore.onAvailabilityChanged)
        XCTAssertNotNil(quotaUsageStore.onStateChanged)
        XCTAssertIdentical(controller.coordinator.cloudMeteringRecorder as AnyObject?, meteringRecorder)
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
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: harness.paths.daemonDirectory
                    .appendingPathComponent(OpenBurnBarDaemonManager.projectCodeMemoryResourceDirectoryName, isDirectory: true)
                    .appendingPathComponent(OpenBurnBarDaemonManager.projectCodeMemorySecretCorpusFileName, isDirectory: false)
                    .path
            )
        )
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
    func test_installedDaemonBinaryNeedsRefreshDetectsStaleInstalledDaemon() async throws {
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

    @MainActor
    func test_installFilesRejectsDaemonBinaryWhenSignatureValidationFails() async throws {
        let harness = try makeRuntimePathsHarness(name: "daemon-signature-reject")
        defer { harness.cleanup() }

        let sourceBinaryURL = harness.rootURL.appendingPathComponent("source-openburnbar-daemon", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: sourceBinaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceBinaryURL.path)

        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: daemonDependencies(
                resolveDaemonBinary: { sourceBinaryURL },
                validateDaemonBinary: { url in
                    throw NSError(
                        domain: "OpenBurnBarDaemonManagerTests",
                        code: 42,
                        userInfo: [NSLocalizedDescriptionKey: "rejected \(url.lastPathComponent)"]
                    )
                }
            ),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        )

        XCTAssertThrowsError(try manager.installFilesIfNeeded()) { error in
            guard case OpenBurnBarDaemonManagerError.daemonBinarySignatureInvalid = error else {
                return XCTFail("Expected daemonBinarySignatureInvalid, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.paths.installedBinaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.paths.launchAgentPlistURL.path))
    }

    func test_daemonBinaryResolverPrefersBundledHelperOverBuildProductSibling() async throws {
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
    func test_setPreferredProviderCredentialSlot_refreshesProviderConfigurations() async throws {
        let harness = try makeRuntimePathsHarness(name: "preferred-slot-refresh")
        defer { harness.cleanup() }

        let icloudSlot = BurnBarProviderCredentialSlot(
            slotID: "icloud",
            label: "iCloud",
            isEnabled: true
        )
        let gmailSlot = BurnBarProviderCredentialSlot(
            slotID: "gmail",
            label: "Gmail",
            isEnabled: true
        )
        var configSnapshot = BurnBarProviderConfigurationSnapshot(
            providers: [
                BurnBarProviderSettings(
                    providerID: "anthropic",
                    isEnabled: true,
                    baseURL: "https://api.anthropic.com/v1",
                    preferredModelIDs: ["claude-opus-4-1"],
                    preferredCredentialSlotID: "icloud",
                    credentialSlots: [icloudSlot, gmailSlot]
                )
            ]
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
                        daemonVersion: "test-daemon",
                        protocolVersion: BurnBarProtocolVersion.current,
                        socketPath: harness.paths.socketURL.path
                    )
                },
                requestConfig: { _ in configSnapshot },
                updateConfig: { _, snapshot in
                    configSnapshot = snapshot
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
        XCTAssertEqual(manager.providerConfigurations.first?.preferredCredentialSlotID, "icloud")

        try await manager.setPreferredProviderCredentialSlotOrThrow(
            providerID: "anthropic",
            slotID: "gmail"
        )

        XCTAssertEqual(configSnapshot.providerSettings(id: "anthropic")?.preferredCredentialSlotID, "gmail")
        XCTAssertEqual(
            manager.providerConfigurations.first?.preferredCredentialSlotID,
            "gmail",
            "The Accounts modal reads providerConfigurations; preference writes must refresh it immediately."
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
        // Core-decomposition P-02: the Kernel resource bundle is staged alongside the Core bundle.
        let sourceKernelBundleURL = harness.rootURL.appendingPathComponent(
            OpenBurnBarDaemonManager.kernelResourceBundleName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sourceKernelBundleURL, withIntermediateDirectories: true)

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
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.paths.daemonDirectory.appendingPathComponent(OpenBurnBarDaemonManager.kernelResourceBundleName).path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: harness.paths.daemonDirectory
                    .appendingPathComponent(OpenBurnBarDaemonManager.projectCodeMemoryResourceDirectoryName, isDirectory: true)
                    .appendingPathComponent(OpenBurnBarDaemonManager.projectCodeMemorySecretCorpusFileName, isDirectory: false)
                    .path
            )
        )
        XCTAssertTrue(
            launchctlCalls.contains(where: { $0.starts(with: ["kickstart", "-k", "gui/\(getuid())/\(OpenBurnBarDaemonRuntimePaths.launchAgentLabel)"]) })
        )
    }

    @MainActor
    func test_refreshInstalledDaemonIfNeededRepairsMissingLaunchAgent() async throws {
        let harness = try makeRuntimePathsHarness(name: "refresh-missing-launch-agent")
        defer { harness.cleanup() }

        let sourceBinaryURL = harness.rootURL.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: sourceBinaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceBinaryURL.path)

        let sourceBundleURL = harness.rootURL.appendingPathComponent(
            OpenBurnBarDaemonManager.resourceBundleName,
            isDirectory: true
        )
        // Core-decomposition P-02: the Kernel resource bundle is staged alongside the Core bundle.
        let sourceKernelBundleURL = harness.rootURL.appendingPathComponent(
            OpenBurnBarDaemonManager.kernelResourceBundleName,
            isDirectory: true
        )
        let sourceCorpusURL = harness.rootURL
            .appendingPathComponent(OpenBurnBarDaemonManager.projectCodeMemoryResourceDirectoryName, isDirectory: true)
            .appendingPathComponent(OpenBurnBarDaemonManager.projectCodeMemorySecretCorpusFileName, isDirectory: false)
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceKernelBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceCorpusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"version":"test","patterns":[]}"#.write(to: sourceCorpusURL, atomically: true, encoding: .utf8)

        try FileManager.default.copyItem(at: sourceBinaryURL, to: harness.paths.installedBinaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.paths.installedBinaryURL.path)
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceBinaryURL.path)
        if let sourceModifiedAt = sourceAttributes[.modificationDate] as? Date {
            try FileManager.default.setAttributes(
                [.modificationDate: sourceModifiedAt],
                ofItemAtPath: harness.paths.installedBinaryURL.path
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.paths.launchAgentPlistURL.path))

        var launchctlCalls: [[String]] = []
        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: daemonDependencies(
                runProcess: { _, arguments in
                    launchctlCalls.append(arguments)
                    return ""
                },
                resolveDaemonBinary: { sourceBinaryURL }
            ),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default),
            daemonSocketAuthTokenStore: makeTestKeychainStore()
        )

        let didRefresh = await manager.refreshInstalledDaemonIfNeededForCurrentAppBuild()

        XCTAssertTrue(didRefresh, manager.lastError ?? "refresh should be triggered by a missing LaunchAgent plist")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: harness.paths.launchAgentPlistURL.path),
            manager.lastError ?? "repair should recreate the missing LaunchAgent plist"
        )
        XCTAssertFalse(
            manager.installedDaemonBinaryNeedsRefresh(),
            manager.lastError ?? "fresh binary plus recreated LaunchAgent should not need another refresh"
        )
        XCTAssertTrue(
            launchctlCalls.contains(where: { $0.starts(with: ["bootstrap", "gui/\(getuid())"]) }),
            manager.lastError ?? "repair should bootstrap the recreated LaunchAgent"
        )
        XCTAssertTrue(
            launchctlCalls.contains(where: { $0.starts(with: ["kickstart", "-k", "gui/\(getuid())/\(OpenBurnBarDaemonRuntimePaths.launchAgentLabel)"]) }),
            manager.lastError ?? "repair should kickstart the recreated LaunchAgent"
        )
    }

    @MainActor
    func test_refreshInstalledDaemonIfNeededRepairsMissingLaunchAgentUsingInstalledBinaryFallback() async throws {
        let harness = try makeRuntimePathsHarness(name: "refresh-missing-launch-agent-installed-fallback")
        defer { harness.cleanup() }

        try "#!/bin/sh\nexit 0\n".write(
            to: harness.paths.installedBinaryURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: harness.paths.installedBinaryURL.path
        )

        let installedBundleURL = harness.paths.daemonDirectory.appendingPathComponent(
            OpenBurnBarDaemonManager.resourceBundleName,
            isDirectory: true
        )
        // Core-decomposition P-02: the Kernel resource bundle is pre-staged in the
        // installed daemon directory alongside the Core bundle so the fallback install path
        // (resolveDaemonBinary == nil) resolves both bundles at their installed locations.
        let installedKernelBundleURL = harness.paths.daemonDirectory.appendingPathComponent(
            OpenBurnBarDaemonManager.kernelResourceBundleName,
            isDirectory: true
        )
        let installedCorpusURL = harness.paths.daemonDirectory
            .appendingPathComponent(OpenBurnBarDaemonManager.projectCodeMemoryResourceDirectoryName, isDirectory: true)
            .appendingPathComponent(OpenBurnBarDaemonManager.projectCodeMemorySecretCorpusFileName, isDirectory: false)
        try FileManager.default.createDirectory(at: installedBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installedKernelBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installedCorpusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"version":"test","patterns":[]}"#.write(to: installedCorpusURL, atomically: true, encoding: .utf8)

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.paths.launchAgentPlistURL.path))

        var launchctlCalls: [[String]] = []
        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: daemonDependencies(
                runProcess: { _, arguments in
                    launchctlCalls.append(arguments)
                    return ""
                },
                resolveDaemonBinary: { nil }
            ),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default),
            daemonSocketAuthTokenStore: makeTestKeychainStore()
        )

        let didRefresh = await manager.refreshInstalledDaemonIfNeededForCurrentAppBuild()

        XCTAssertTrue(didRefresh, manager.lastError ?? "missing LaunchAgent should refresh from installed binary fallback")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: harness.paths.launchAgentPlistURL.path),
            manager.lastError ?? "repair should recreate the missing LaunchAgent plist"
        )
        XCTAssertFalse(
            manager.installedDaemonBinaryNeedsRefresh(),
            manager.lastError ?? "installed binary fallback plus recreated LaunchAgent should not need another refresh"
        )
        XCTAssertTrue(
            launchctlCalls.contains(where: { $0.starts(with: ["bootstrap", "gui/\(getuid())"]) }),
            manager.lastError ?? "repair should bootstrap the recreated LaunchAgent"
        )
        XCTAssertTrue(
            launchctlCalls.contains(where: { $0.starts(with: ["kickstart", "-k", "gui/\(getuid())/\(OpenBurnBarDaemonRuntimePaths.launchAgentLabel)"]) }),
            manager.lastError ?? "repair should kickstart the recreated LaunchAgent"
        )
    }

    @MainActor
    func test_rotateDaemonSocketAuthTokenRecreatesStaleRuntimeKeychainItem() throws {
        let harness = try makeRuntimePathsHarness(name: "socket-token-keychain-recreate")
        defer { harness.cleanup() }

        let backend = FirstSetFailsThenDeletesKeychainBackend()
        let store = KeychainStore(
            service: "tests.daemon-runtime.\(UUID().uuidString)",
            legacyServices: [],
            backend: backend
        )
        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: daemonDependencies(resolveDaemonBinary: { nil }),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default),
            daemonSocketAuthTokenStore: store
        )

        let token = try manager.rotateDaemonSocketAuthToken()

        XCTAssertFalse(token.isEmpty)
        XCTAssertEqual(backend.setCallCount, 2)
        XCTAssertEqual(backend.deleteCallCount, 1)
        XCTAssertEqual(try store.string(for: OpenBurnBarDaemonManager.daemonSocketAuthTokenAccount), token)
        XCTAssertEqual(
            try String(contentsOf: harness.paths.socketAuthTokenFileURL, encoding: .utf8),
            token
        )
    }

    @MainActor
    func test_rotateDaemonSocketAuthTokenFallsBackToPrivateTokenFileWhenKeychainUnavailable() throws {
        let harness = try makeRuntimePathsHarness(name: "socket-token-file-fallback")
        defer { harness.cleanup() }

        let store = KeychainStore(
            service: "tests.daemon-runtime.\(UUID().uuidString)",
            legacyServices: [],
            backend: FailingWriteKeychainBackend()
        )
        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: daemonDependencies(resolveDaemonBinary: { nil }),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default),
            daemonSocketAuthTokenStore: store
        )

        let token = try manager.rotateDaemonSocketAuthToken()

        XCTAssertFalse(token.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: harness.paths.socketAuthTokenFileURL, encoding: .utf8),
            token
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: harness.paths.socketAuthTokenFileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600)
        XCTAssertEqual(
            OpenBurnBarDaemonSocketClient.readDaemonSocketAuthToken(
                from: store,
                tokenFileURL: harness.paths.socketAuthTokenFileURL
            ),
            token
        )
    }

    @MainActor
    func test_writeLaunchAgentPlistUsesPrivateDaemonSocketTokenFileOnly() throws {
        let harness = try makeRuntimePathsHarness(name: "launch-agent-socket-token-file")
        defer { harness.cleanup() }

        try FileManager.default.createDirectory(
            at: harness.paths.daemonDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: harness.paths.launchAgentPlistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: harness.paths.installedBinaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.paths.installedBinaryURL.path)

        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: daemonDependencies(resolveDaemonBinary: { nil }),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        )

        try manager.writeLaunchAgentPlist()

        let token = try String(contentsOf: harness.paths.socketAuthTokenFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let plistData = try Data(contentsOf: harness.paths.launchAgentPlistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        let environment = try XCTUnwrap(plist["EnvironmentVariables"] as? [String: String])

        XCTAssertFalse(token.isEmpty)
        XCTAssertNil(environment["OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN"])
        XCTAssertNil(environment["BURNBAR_DAEMON_SOCKET_AUTH_TOKEN"])
        XCTAssertTrue(arguments.contains("--socket-auth-token-file"))
        XCTAssertTrue(arguments.contains(harness.paths.socketAuthTokenFileURL.path))
        XCTAssertFalse(arguments.contains(token), "daemon socket token must stay out of argv")
        XCTAssertFalse(environment.values.contains(token), "daemon socket token must stay out of the LaunchAgent environment")
    }

    func test_usageSync_readsProviderConfigurationSnapshot() async throws {
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

    func test_usageSync_keepsCatalogOnlyProviderIdentityUnmappedForBranding() async throws {
        let harness = try makeRuntimePathsHarness(name: "catalog-provider-branding")
        defer { harness.cleanup() }

        let configJSON = """
        {
          "providers" : [
            {
              "baseURL" : "https://api.cohere.com/v1",
              "isEnabled" : true,
              "preferredModelIDs" : [
                "command-a"
              ],
              "providerID" : "cohere"
            }
          ]
        }
        """
        try configJSON.write(to: harness.paths.providerConfigURL, atomically: true, encoding: .utf8)

        let service = OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        let snapshot = service.refreshState()
        let configuration = try XCTUnwrap(snapshot.providerConfigurations.first)

        XCTAssertEqual(configuration.providerID, "cohere")
        XCTAssertNil(configuration.provider)
        XCTAssertEqual(configuration.displayName, "Cohere")
        XCTAssertEqual(configuration.brand.bundledLogoCandidates.first, "CohereLogo")
    }

    @MainActor
    func test_providerQuotaRefreshDoesNotMarkDaemonOwnedSlotMissingWhenAppSecretMirrorIsAbsent() async throws {
        let harness = try makeRuntimePathsHarness(name: "daemon-owned-quota-slot")
        defer { harness.cleanup() }

        let slotID = "daemon-owned-\(UUID().uuidString)"
        let slot = BurnBarProviderCredentialSlot(
            slotID: slotID,
            label: "Daemon Plan",
            isEnabled: true,
            status: .ready,
            lastQuotaRemainingPercent: 0.42,
            lastStatusMessage: "Last daemon quota snapshot"
        )
        let configSnapshot = BurnBarProviderConfigurationSnapshot(
            providers: [
                BurnBarProviderSettings(
                    providerID: "minimax",
                    isEnabled: true,
                    baseURL: "https://api.minimax.io/v1",
                    preferredModelIDs: ["minimax-m2.7-highspeed"],
                    preferredCredentialSlotID: slotID,
                    credentialSlots: [slot]
                )
            ]
        )

        let manager = OpenBurnBarDaemonManager(
            settingsManager: makeSettingsManager(),
            paths: harness.paths,
            dependencies: daemonDependencies(resolveDaemonBinary: { nil }),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        )
        var refreshedSnapshot = configSnapshot

        let didMutate = try await manager.applyProviderCredentialSlotQuotaRefresh(
            to: &refreshedSnapshot,
            providerID: "minimax",
            secretLookup: { _ in nil },
            fetchSnapshot: { _, _ in
                XCTFail("Daemon-owned slots without an app-side mirror must not trigger a quota fetch.")
                throw OpenBurnBarDaemonManagerError.rpcError("Unexpected quota fetch")
            }
        )

        XCTAssertFalse(didMutate)
        let configuration = try XCTUnwrap(refreshedSnapshot.providerSettings(id: "minimax"))
        let refreshedSlot = try XCTUnwrap(configuration.credentialSlots.first)
        XCTAssertEqual(refreshedSlot.slotID, slotID)
        XCTAssertEqual(refreshedSlot.status, .ready)
        XCTAssertEqual(refreshedSlot.lastStatusMessage, "Last daemon quota snapshot")
        XCTAssertEqual(refreshedSlot.lastQuotaRemainingPercent, 0.42)
    }

    @MainActor
    func test_providerQuotaRefreshStoresWeeklyResetForRouterDrainOrdering() async throws {
        let harness = try makeRuntimePathsHarness(name: "weekly-quota-reset-router")
        defer { harness.cleanup() }

        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let hourlyReset = now.addingTimeInterval(2 * 60 * 60)
        let monthlyReset = now.addingTimeInterval(10 * 60 * 60)
        let weeklyReset = now.addingTimeInterval(2 * 24 * 60 * 60)
        let configSnapshot = BurnBarProviderConfigurationSnapshot(
            providers: [
                BurnBarProviderSettings(
                    providerID: "kimi",
                    isEnabled: true,
                    baseURL: "https://api.moonshot.ai/v1",
                    preferredModelIDs: ["kimi-k2"],
                    preferredCredentialSlotID: "kimi-work",
                    credentialSlots: [
                        BurnBarProviderCredentialSlot(
                            slotID: "kimi-work",
                            label: "Kimi Work",
                            isEnabled: true,
                            status: .ready
                        )
                    ]
                )
            ]
        )
        let manager = OpenBurnBarDaemonManager(
            settingsManager: makeSettingsManager(),
            paths: harness.paths,
            dependencies: daemonDependencies(resolveDaemonBinary: { nil }),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        )
        var refreshedSnapshot = configSnapshot

        let didMutate = try await manager.applyProviderCredentialSlotQuotaRefresh(
            to: &refreshedSnapshot,
            providerID: "kimi",
            secretLookup: { account in
                XCTAssertEqual(account, "provider.kimi.slot.kimi-work.apiKey")
                return "kimi-api-key"
            },
            fetchSnapshot: { provider, apiKey in
                XCTAssertEqual(provider, .kimi)
                XCTAssertEqual(apiKey, "kimi-api-key")
                return ProviderQuotaSnapshot(
                    provider: .kimi,
                    fetchedAt: now,
                    source: .officialAPI,
                    confidence: .exact,
                    managementURL: nil,
                    statusMessage: "fresh",
                    buckets: [
                        ProviderQuotaBucket(
                            key: "kimi-primary",
                            label: "5-hour window",
                            windowKind: .rollingHours,
                            usedValue: 65,
                            limitValue: 100,
                            remainingValue: 35,
                            usedPercent: 65,
                            resetsAt: hourlyReset,
                            unit: .requests,
                            isEstimated: false
                        ),
                        ProviderQuotaBucket(
                            key: "kimi-monthly",
                            label: "30-day quota",
                            windowKind: .rollingDays,
                            usedValue: 30,
                            limitValue: 100,
                            remainingValue: 70,
                            usedPercent: 30,
                            resetsAt: monthlyReset,
                            unit: .requests,
                            isEstimated: false
                        ),
                        ProviderQuotaBucket(
                            key: "kimi-secondary",
                            label: "Weekly quota",
                            windowKind: .rollingDays,
                            usedValue: 20,
                            limitValue: 100,
                            remainingValue: 80,
                            usedPercent: 20,
                            resetsAt: weeklyReset,
                            unit: .requests,
                            isEstimated: false
                        )
                    ]
                )
            },
            now: { now }
        )

        XCTAssertTrue(didMutate)
        let configuration = try XCTUnwrap(refreshedSnapshot.providerSettings(id: "kimi"))
        let refreshedSlot = try XCTUnwrap(configuration.credentialSlots.first)
        XCTAssertEqual(refreshedSlot.lastQuotaRemainingPercent, 35)
        XCTAssertEqual(refreshedSlot.lastQuotaResetsAt, weeklyReset)
        XCTAssertEqual(refreshedSlot.status, .ready)
    }

    func test_usageSync_importsDaemonUsageIntoLocalShape() async throws {
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

    func test_usageSync_runtimeSnapshotPreservesExecutionSourceAttribution() throws {
        let harness = try makeRuntimePathsHarness(name: "runtime-execution-source")
        defer { harness.cleanup() }

        let event = BurnBarUsageEvent(
            providerID: "codex",
            modelID: "gpt-5.6-codex",
            inputTokens: 100,
            outputTokens: 20,
            cacheReadTokens: 10,
            cost: 1,
            recordedAt: Date(timeIntervalSince1970: 1_784_592_000),
            sessionID: "daemon-source-session",
            projectName: "OpenBurnBar",
            executionSourceID: "cursor",
            executionSourceName: "Cursor",
            executionSourceKind: .ide,
            executionSourceConfidence: .derivedExact
        )
        let service = OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)

        let snapshot = service.runtimeSnapshot(
            from: BurnBarProviderConfigurationSnapshot(providers: []),
            usageEvents: [event]
        )
        let usage = try XCTUnwrap(snapshot.importedUsages.first)

        XCTAssertEqual(usage.executionSourceID, "cursor")
        XCTAssertEqual(usage.executionSourceName, "Cursor")
        XCTAssertEqual(usage.executionSourceKind, .ide)
        XCTAssertEqual(usage.executionSourceConfidence, .derivedExact)
    }

    /// A daemon event that explicitly says `.subscription` must reach the store
    /// saying `.subscription`. Dropping the stamp here let the write-time
    /// fallback re-derive `.api` from `usageSource == .daemon`, so plan-covered
    /// work was billed as real wallet spend in Spend Lens.
    func test_usageSync_runtimeSnapshotPreservesStampedBillingKind() throws {
        let harness = try makeRuntimePathsHarness(name: "runtime-billing-kind")
        defer { harness.cleanup() }

        func event(sessionID: String, billingKind: BurnBarBillingKind?) -> BurnBarUsageEvent {
            BurnBarUsageEvent(
                providerID: "codex",
                modelID: "gpt-5.6-codex",
                inputTokens: 100,
                outputTokens: 20,
                cacheReadTokens: 10,
                cost: 1,
                recordedAt: Date(timeIntervalSince1970: 1_784_592_000),
                sessionID: sessionID,
                projectName: "OpenBurnBar",
                billingKind: billingKind
            )
        }
        let service = OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)

        let snapshot = service.runtimeSnapshot(
            from: BurnBarProviderConfigurationSnapshot(providers: []),
            usageEvents: [
                event(sessionID: "sub-route", billingKind: .subscription),
                event(sessionID: "api-route", billingKind: .api),
                event(sessionID: "legacy-route", billingKind: nil)
            ]
        )

        let imported = Dictionary(
            uniqueKeysWithValues: snapshot.importedUsages.map { ($0.sessionId, $0.billingKind) }
        )
        XCTAssertEqual(imported["sub-route"], .subscription)
        XCTAssertEqual(imported["api-route"], .api)
        // Unstamped legacy rows keep resolving through the provider classifier;
        // "codex" is not an API-key daemon slot, so it stays honestly unknown
        // and the store's `.daemon` fallback classifies it exactly as before.
        XCTAssertEqual(imported["legacy-route"], .unknown)
    }

    /// Same guarantee on the on-disk ledger path (`refreshState`), which is the
    /// conversion the app actually runs when the daemon socket is unavailable.
    func test_usageSync_ledgerImportPreservesStampedBillingKind() async throws {
        let harness = try makeRuntimePathsHarness(name: "ledger-billing-kind")
        defer { harness.cleanup() }

        let encoder = JSONEncoder()
        func line(key: String, sessionID: String, billingKind: BurnBarBillingKind?) throws -> String {
            try encodedUsageRecordLine(
                idempotencyKey: key,
                event: BurnBarUsageEvent(
                    providerID: "codex",
                    modelID: "gpt-5.6-codex",
                    inputTokens: 80,
                    outputTokens: 40,
                    cacheReadTokens: 0,
                    cost: 0.5,
                    recordedAt: Date(timeIntervalSince1970: 1_784_592_100),
                    sessionID: sessionID,
                    projectName: "OpenBurnBar",
                    billingKind: billingKind
                ),
                encoder: encoder
            )
        }
        try [
            line(key: "ledger-sub", sessionID: "ledger-sub-route", billingKind: .subscription),
            line(key: "ledger-api", sessionID: "ledger-api-route", billingKind: .api),
            line(key: "ledger-legacy", sessionID: "ledger-legacy-route", billingKind: nil)
        ]
        .joined(separator: "\n")
        .appending("\n")
        .write(to: harness.paths.usageLedgerURL, atomically: true, encoding: .utf8)

        var inserted: [TokenUsage] = []
        let service = OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        _ = service.refreshState(insertUsages: { inserted.append(contentsOf: $0) })

        let imported = Dictionary(uniqueKeysWithValues: inserted.map { ($0.sessionId, $0.billingKind) })
        XCTAssertEqual(imported["ledger-sub-route"], .subscription)
        XCTAssertEqual(imported["ledger-api-route"], .api)
        XCTAssertEqual(imported["ledger-legacy-route"], .unknown)
    }

    func test_usageSync_importsHermesLedgerRowsAsHermesProvider() async throws {
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

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if uploadCalls == 1, try await store.fetchUnsynced().count == 2 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(uploadCalls, 1)
        let unsyncedUsageCount = try await store.fetchUnsynced().count
        XCTAssertEqual(unsyncedUsageCount, 2)
    }

    @MainActor
    func test_managerExportsControllerActivitySnapshotFromLocalData() async throws {
        let harness = try makeRuntimePathsHarness(name: "activity-export")
        defer { harness.cleanup() }

        let store = try makeInMemoryStore()
        let now = Date()
        try await store.insert([
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
        XCTAssertFalse(store.debugHasLoadedUsagePresentationForTesting)
        try await store.upsertConversation(
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
        XCTAssertFalse(
            store.debugHasLoadedUsagePresentationForTesting,
            "Controller export must not force the dashboard aggregate snapshot"
        )
    }

    @MainActor
    func test_controllerActivityExport_coalescesConcurrentRequestsAndOmitsTranscriptPayloads() async throws {
        let harness = try makeRuntimePathsHarness(name: "activity-export-single-flight")
        defer { harness.cleanup() }

        let tracer = OpenBurnBarQueryTracer.shared
        let queue = try DatabaseQueue(configuration: .withQueryTracing())
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let now = Date()
        try await store.upsertConversation(
            ConversationRecord(
                id: "conversation-large-payload",
                provider: .codex,
                sessionId: "session-large-payload",
                projectName: "Large Payload Project",
                startTime: now.addingTimeInterval(-120),
                endTime: now.addingTimeInterval(-60),
                messageCount: 2,
                userWordCount: 2,
                assistantWordCount: 2,
                keyFiles: [String(repeating: "f", count: 8_192)],
                keyCommands: [String(repeating: "c", count: 8_192)],
                keyTools: [String(repeating: "t", count: 8_192)],
                inferredTaskTitle: "Keep the controller export light",
                lastAssistantMessage: String(repeating: "assistant-body", count: 32_768),
                fullText: String(repeating: "transcript-body", count: 131_072),
                indexedAt: now.addingTimeInterval(-60),
                fileModifiedAt: now.addingTimeInterval(-60),
                summary: "The compact summary must remain available.",
                summaryTitle: "Compact activity",
                summaryUpdatedAt: now.addingTimeInterval(-60)
            )
        )

        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: daemonDependencies(resolveDaemonBinary: { nil }),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        )
        manager.dataStore = store

        tracer.resetLog()
        async let firstExport: Void = manager.exportControllerActivitySnapshot()
        async let secondExport: Void = manager.exportControllerActivitySnapshot()
        _ = await (firstExport, secondExport)

        let activityQueries = tracer.queryLog.filter { query in
            let sql = query.sql.uppercased()
            return sql.contains("FROM CONVERSATIONS")
                && sql.contains("SUMMARYTITLE")
                && sql.contains("INFERREDTASKTITLE")
        }
        XCTAssertEqual(
            activityQueries.count,
            1,
            "Concurrent startup health refreshes must share one controller-activity conversation read"
        )
        let activitySQL = try XCTUnwrap(activityQueries.first?.sql.uppercased())
        XCTAssertFalse(activitySQL.contains("FULLTEXT"))
        XCTAssertFalse(activitySQL.contains("LASTASSISTANTMESSAGE"))
        XCTAssertFalse(activitySQL.contains("KEYFILES"))
        XCTAssertFalse(activitySQL.contains("KEYCOMMANDS"))
        XCTAssertFalse(activitySQL.contains("KEYTOOLS"))

        let data = try Data(contentsOf: harness.paths.controllerActivitySnapshotURL)
        let snapshot = try JSONDecoder().decode(BurnBarControllerActivitySnapshot.self, from: data)
        let project = try XCTUnwrap(snapshot.projects.first)
        XCTAssertEqual(project.projectSlug, "large-payload-project")
        XCTAssertEqual(project.latestConversationID, "conversation-large-payload")
        XCTAssertEqual(project.latestConversationSummary, "The compact summary must remain available.")
        XCTAssertEqual(project.latestConversationTitle, "Compact activity")
    }

    func test_slug_collapsesPunctuationWithoutRepeatedHyphens() {
        XCTAssertEqual(OpenBurnBarDaemonManager.slug(for: "  Apollo / Mission!!  "), "apollo-mission")
        XCTAssertEqual(OpenBurnBarDaemonManager.slug(for: "---"), "")
        XCTAssertEqual(OpenBurnBarDaemonManager.slug(for: "~"), "")
        XCTAssertEqual(OpenBurnBarDaemonManager.slug(for: "日本語"), "")
        XCTAssertEqual(OpenBurnBarDaemonManager.slug(for: "   "), "")
        XCTAssertEqual(
            OpenBurnBarDaemonManager.slug(for: String(repeating: "A", count: 120)),
            String(repeating: "a", count: 96)
        )
    }

    func test_buildControllerActivitySnapshot_groupsTenThousandConversationsInLinearTime() {
        let now = Date()
        let sessionCount = 10_000
        let projectCount = 100
        let conversations: [ConversationActivitySummary] = (0..<sessionCount).map { index in
            let projectName = "Project \(index / (sessionCount / projectCount) + 1)"
            return ConversationActivitySummary(
                id: "perf-conversation-\(index)",
                sessionId: "perf-session-\(index)",
                projectName: projectName,
                startTime: now.addingTimeInterval(-Double(index + 1)),
                endTime: now.addingTimeInterval(-Double(index)),
                indexedAt: now.addingTimeInterval(-Double(index)),
                inferredTaskTitle: "Perf \(index)",
                summary: nil,
                summaryTitle: nil
            )
        }

        // The previous nested filter×slug path was O(projects × conversations)
        // (~1M slug calls) and hung the main actor. Linear grouping must finish
        // well under a second even in Debug.
        let started = CFAbsoluteTimeGetCurrent()
        let snapshot = OpenBurnBarDaemonManager.buildControllerActivitySnapshot(
            conversations: conversations,
            recentUsages: []
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(snapshot.projects.count, projectCount)
        XCTAssertLessThan(elapsed, 1.0, "Expected O(n) snapshot build; took \(elapsed)s")
        XCTAssertEqual(snapshot.projects.first?.displayName, "Project 1")
    }

    func test_buildControllerActivitySnapshot_mergesUsageAndConversationProjects() {
        let now = Date()
        let conversation = ConversationActivitySummary(
            id: "conv-alpha",
            sessionId: "session-alpha",
            projectName: "Alpha",
            startTime: now.addingTimeInterval(-120),
            endTime: now.addingTimeInterval(-60),
            indexedAt: now.addingTimeInterval(-60),
            inferredTaskTitle: "Alpha work",
            summary: nil,
            summaryTitle: nil
        )
        let usage = TokenUsage(
            provider: .codex,
            sessionId: "usage-beta",
            projectName: "Beta",
            model: "gpt-5",
            inputTokens: 10,
            outputTokens: 5,
            costUSD: 0.01,
            startTime: now.addingTimeInterval(-30),
            endTime: now
        )

        let snapshot = OpenBurnBarDaemonManager.buildControllerActivitySnapshot(
            conversations: [conversation],
            recentUsages: [usage],
            generatedAt: now
        )

        XCTAssertEqual(Set(snapshot.projects.map(\.projectSlug)), Set(["alpha", "beta"]))
        XCTAssertEqual(snapshot.activeProjectSlug, "beta")
        XCTAssertEqual(snapshot.projects.first(where: { $0.projectSlug == "beta" })?.sessionCountLast7Days, 1)
    }

    @MainActor
    func test_managerExportsProjectsBeyondLegacyActivityWindowForTenThousandSessionMigration() async throws {
        let harness = try makeRuntimePathsHarness(name: "activity-export-10k-migration")
        defer { harness.cleanup() }

        let store = try makeInMemoryStore()
        let now = Date()
        let sessionCount = 10_000
        let projectCount = 100

        // Keep the dataset compact while exercising the full migration input:
        // 10k distinct sessions span 100 inferred projects. Project 100 is
        // intentionally older than the legacy newest-80 conversation window.
        for index in 0..<sessionCount {
            let projectName = "Project \(index / (sessionCount / projectCount) + 1)"
            try await store.upsertConversation(
                ConversationRecord(
                    id: "migration-conversation-\(index)",
                    provider: .zai,
                    sessionId: "migration-session-\(index)",
                    projectName: projectName,
                    startTime: now.addingTimeInterval(-Double(index + 1)),
                    endTime: now.addingTimeInterval(-Double(index)),
                    messageCount: 1,
                    userWordCount: 1,
                    assistantWordCount: 1,
                    keyFiles: [],
                    keyCommands: [],
                    keyTools: [],
                    inferredTaskTitle: "Migration session \(index)",
                    lastAssistantMessage: "",
                    fullText: "Migration session \(index)",
                    fileModifiedAt: now.addingTimeInterval(-Double(index))
                )
            )
        }

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

        manager.attach(dataStore: store)
        await manager.refreshHealth()

        let data = try Data(contentsOf: harness.paths.controllerActivitySnapshotURL)
        let snapshot = try JSONDecoder().decode(BurnBarControllerActivitySnapshot.self, from: data)
        XCTAssertEqual(snapshot.projects.count, projectCount)
        XCTAssertTrue(
            snapshot.projects.contains(where: { $0.displayName == "Project 100" }),
            "10k-session migration must preserve projects outside the legacy 80-conversation window"
        )
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

    // MARK: - Support-directory hardening (replaces a fail-open `try?`)

    func test_resolveSupportDirectory_returnsPreparedURLOnSuccessWithoutFallback() {
        let preparedURL = URL(fileURLWithPath: "/tmp/openburnbar-prepared-\(UUID().uuidString)", isDirectory: true)
        var fallbackInvoked = false

        let resolved = OpenBurnBarDaemonRuntimePaths.resolveSupportDirectory(
            prepare: { preparedURL },
            fallback: {
                fallbackInvoked = true
                return URL(fileURLWithPath: "/tmp/should-not-be-used", isDirectory: true)
            }
        )

        XCTAssertEqual(resolved, preparedURL)
        XCTAssertFalse(
            fallbackInvoked,
            "When the hardening migration succeeds, the unhardened fallback path must never be consulted."
        )
    }

    func test_resolveSupportDirectory_degradesToFallbackAndObservesFailureWhenMigrationThrows() {
        let fallbackURL = URL(fileURLWithPath: "/tmp/openburnbar-fallback-\(UUID().uuidString)", isDirectory: true)
        var prepareInvoked = false
        var fallbackInvoked = false

        struct PermissionHardeningFailure: Error {}

        let resolved = OpenBurnBarDaemonRuntimePaths.resolveSupportDirectory(
            prepare: {
                prepareInvoked = true
                throw PermissionHardeningFailure()
            },
            fallback: {
                fallbackInvoked = true
                return fallbackURL
            }
        )

        XCTAssertTrue(prepareInvoked, "The hardening migration must be attempted before any fallback.")
        XCTAssertTrue(
            fallbackInvoked,
            "A migration/permission failure must take the catch path (which logs) and resolve the fallback, not silently swallow the error."
        )
        XCTAssertEqual(
            resolved,
            fallbackURL,
            "Optionality and the degraded-path URL must be preserved: a thrown migration still yields the canonical support directory."
        )
    }

    func test_liveRuntimePaths_resolveAroundTheCanonicalSupportDirectory() {
        // `.live()` must keep producing a coherent, daemon-rooted path tree even
        // when nothing is injected — the hardening seam must not change the shape
        // of the runtime paths it returns.
        let paths = OpenBurnBarDaemonRuntimePaths.live()

        XCTAssertEqual(
            paths.daemonDirectory.deletingLastPathComponent().standardizedFileURL,
            paths.supportDirectory.standardizedFileURL
        )
        XCTAssertEqual(paths.daemonDirectory.lastPathComponent, "daemon")
        XCTAssertEqual(
            paths.socketURL.deletingLastPathComponent().standardizedFileURL,
            paths.supportDirectory.standardizedFileURL
        )
        XCTAssertEqual(
            paths.installedBinaryURL.deletingLastPathComponent().standardizedFileURL,
            paths.daemonDirectory.standardizedFileURL
        )
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

    private func daemonDependencies(
        runProcess: @escaping @Sendable (String, [String]) throws -> String = { _, _ in "" },
        resolveDaemonBinary: @escaping () -> URL?,
        validateDaemonBinary: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) -> OpenBurnBarDaemonDependencies {
        OpenBurnBarDaemonDependencies(
            fileManager: .default,
            runProcess: runProcess,
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
            },
            validateDaemonBinary: validateDaemonBinary
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

    func test_resourceBundleResolverFindsBundleInSiblingResourcesDirectory() async throws {
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

    // Core-decomposition P-02: catalog.json moved into OpenBurnBarKernel, so the daemon must also
    // locate the Kernel resource bundle. Covers the resolveKernelResourceBundle wrapper across the
    // sibling-Resources candidate root (mirrors the Core-bundle resolver test above).
    func test_kernelResourceBundleResolverFindsBundleInSiblingResourcesDirectory() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BurnBarDaemonKernelResolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let productsURL = rootURL.appendingPathComponent("Build/Products/Debug", isDirectory: true)
        let daemonURL = productsURL.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false)
        let kernelBundleURL = productsURL
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(OpenBurnBarDaemonManager.kernelResourceBundleName, isDirectory: true)
        let fakeAppBundleURL = productsURL.appendingPathComponent("OpenBurnBar.app", isDirectory: true)

        try FileManager.default.createDirectory(at: kernelBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeAppBundleURL, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: daemonURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemonURL.path)

        let resolved = OpenBurnBarDaemonBinaryResolver.resolveKernelResourceBundle(
            nearBinaryURL: daemonURL,
            appBundleURL: fakeAppBundleURL,
            fileManager: .default
        )

        XCTAssertEqual(resolved?.standardizedFileURL, kernelBundleURL.standardizedFileURL)

        // A tree with no Kernel bundle staged resolves to nil (fail-open, not a crash).
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BurnBarDaemonKernelResolverEmpty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        let emptyDaemonURL = emptyRoot.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: emptyDaemonURL, atomically: true, encoding: .utf8)
        let unresolved = OpenBurnBarDaemonBinaryResolver.resolveKernelResourceBundle(
            nearBinaryURL: emptyDaemonURL,
            appBundleURL: emptyRoot.appendingPathComponent("OpenBurnBar.app", isDirectory: true),
            fileManager: .default
        )
        XCTAssertNil(unresolved)
    }

    @MainActor
    func test_installFilesMirrorsAppFrameworksForInstalledDaemonRpath() async throws {
        let harness = try makeRuntimePathsHarness(name: "installed-daemon-frameworks")
        defer { harness.cleanup() }

        let appBundleURL = harness.rootURL.appendingPathComponent("OpenBurnBar.app", isDirectory: true)
        let helpersURL = appBundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let resourcesURL = appBundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let appFrameworksURL = appBundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let sourceBinaryURL = helpersURL.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false)
        let sourceSQLCipherURL = appFrameworksURL
            .appendingPathComponent("SQLCipher.framework", isDirectory: true)
            .appendingPathComponent("Versions/A/SQLCipher", isDirectory: false)
        let sourceResourceBundleURL = resourcesURL.appendingPathComponent(
            OpenBurnBarDaemonManager.resourceBundleName,
            isDirectory: true
        )
        // Core-decomposition P-02: the Kernel resource bundle is staged alongside the Core bundle.
        let sourceKernelResourceBundleURL = resourcesURL.appendingPathComponent(
            OpenBurnBarDaemonManager.kernelResourceBundleName,
            isDirectory: true
        )
        let sourceCorpusURL = resourcesURL
            .appendingPathComponent(OpenBurnBarDaemonManager.projectCodeMemoryResourceDirectoryName, isDirectory: true)
            .appendingPathComponent(OpenBurnBarDaemonManager.projectCodeMemorySecretCorpusFileName, isDirectory: false)

        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceSQLCipherURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceResourceBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceKernelResourceBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceCorpusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: sourceBinaryURL, atomically: true, encoding: .utf8)
        try Data([0x53, 0x51, 0x4c, 0x43]).write(to: sourceSQLCipherURL)
        try #"{"version":"test","patterns":[]}"#.write(to: sourceCorpusURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceBinaryURL.path)

        let manager = OpenBurnBarDaemonManager(
            paths: harness.paths,
            dependencies: daemonDependencies(resolveDaemonBinary: { sourceBinaryURL }),
            usageSyncService: OpenBurnBarDaemonUsageSyncService(paths: harness.paths, fileManager: .default)
        )

        try manager.installFilesIfNeeded()

        let installedSQLCipherURL = harness.paths.frameworksDirectory
            .appendingPathComponent("SQLCipher.framework", isDirectory: true)
            .appendingPathComponent("Versions/A/SQLCipher", isDirectory: false)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: installedSQLCipherURL.path),
            "Install must mirror app-bundled frameworks to \(harness.paths.frameworksDirectory.path) for @executable_path/../Frameworks."
        )
    }

    func test_projectCodeMemoryCorpusResolverFindsBundledAppResource() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BurnBarDaemonCorpusResolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let productsURL = rootURL.appendingPathComponent("Build/Products/Debug", isDirectory: true)
        let daemonURL = productsURL.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false)
        let appResourcesURL = productsURL
            .appendingPathComponent("OpenBurnBar.app/Contents/Resources", isDirectory: true)
        let corpusURL = appResourcesURL
            .appendingPathComponent(OpenBurnBarDaemonManager.projectCodeMemoryResourceDirectoryName, isDirectory: true)
            .appendingPathComponent(OpenBurnBarDaemonManager.projectCodeMemorySecretCorpusFileName, isDirectory: false)
        let fakeAppBundleURL = productsURL.appendingPathComponent("OpenBurnBar.app", isDirectory: true)

        try FileManager.default.createDirectory(at: corpusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: daemonURL, atomically: true, encoding: .utf8)
        try #"{"version":"test","patterns":[]}"#.write(to: corpusURL, atomically: true, encoding: .utf8)

        let resolved = OpenBurnBarDaemonBinaryResolver.resolveProjectCodeMemorySecretCorpus(
            nearBinaryURL: daemonURL,
            appBundleURL: fakeAppBundleURL,
            fileManager: .default
        )

        XCTAssertEqual(resolved?.standardizedFileURL, corpusURL.standardizedFileURL)
    }
}

@MainActor
private final class ComputerUseCloudMeteringRecorderSpy: ComputerUseCloudMeteringRecording {
    func recordSessionStart(
        userID: String,
        request: ComputerUseSessionStartRequest,
        response: ComputerUseSessionStartResponse,
        macAppVersion: String
    ) async throws {}

    func recordAction(
        userID: String,
        invocation: BurnBarToolInvocation,
        response: ComputerUseInvokeResponse
    ) async throws {}

    func recordSessionEnd(
        userID: String,
        sessionID: String,
        endedAt: Date,
        reason: ComputerUseEndReason,
        state: ComputerUseSessionState?,
        auditHeadHashHex: String?
    ) async throws {}
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
            frameworksDirectory: supportDirectory.appendingPathComponent("Frameworks", isDirectory: true),
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

private final class FirstSetFailsThenDeletesKeychainBackend: KeychainStoreBackend, @unchecked Sendable {
    private var storage: [String: [String: Data]] = [:]
    private(set) var setCallCount = 0
    private(set) var deleteCallCount = 0

    func set(_ value: Data, service: String, account: String) throws {
        setCallCount += 1
        if setCallCount == 1 {
            throw KeychainStoreError.unhandled(errSecAuthFailed)
        }
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        deleteCallCount += 1
        storage[service]?[account] = nil
    }
}
