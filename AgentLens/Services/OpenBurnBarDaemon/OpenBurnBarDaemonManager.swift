import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import CryptoKit
import Foundation
import Observation
import UserNotifications

struct OpenBurnBarDaemonRuntimePaths: Hashable {
    static let launchAgentLabel = "com.openburnbar.daemon"

    let supportDirectory: URL
    let daemonDirectory: URL
    let installedBinaryURL: URL
    let socketURL: URL
    let logURL: URL
    let launchAgentPlistURL: URL

    var providerConfigURL: URL {
        supportDirectory.appendingPathComponent("provider-config.json", isDirectory: false)
    }

    var usageLedgerURL: URL {
        supportDirectory.appendingPathComponent("usage-events.jsonl", isDirectory: false)
    }

    var controllerActivitySnapshotURL: URL {
        supportDirectory.appendingPathComponent("controller-activity-snapshot.json", isDirectory: false)
    }

    var heartbeatURL: URL {
        daemonDirectory.appendingPathComponent("openburnbar-daemon.heartbeat.json", isDirectory: false)
    }

    static func live(fileManager: FileManager = .default) -> OpenBurnBarDaemonRuntimePaths {
        let supportDirectory = (try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager))
            ?? OpenBurnBarAppPaths.live(fileManager: fileManager).supportDirectory
        let daemonDirectory = supportDirectory.appendingPathComponent("daemon", isDirectory: true)
        let homeDirectory = fileManager.homeDirectoryForCurrentUser

        return OpenBurnBarDaemonRuntimePaths(
            supportDirectory: supportDirectory,
            daemonDirectory: daemonDirectory,
            installedBinaryURL: daemonDirectory.appendingPathComponent("OpenBurnBarDaemon", isDirectory: false),
            socketURL: supportDirectory.appendingPathComponent("openburnbar-daemon.sock", isDirectory: false),
            logURL: daemonDirectory.appendingPathComponent("openburnbar-daemon.log", isDirectory: false),
            launchAgentPlistURL: homeDirectory
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("\(launchAgentLabel).plist", isDirectory: false)
        )
    }
}

struct OpenBurnBarDaemonHealthSnapshot: Equatable {
    let isHealthy: Bool
    let daemonVersion: String
    let protocolVersion: Int
    let socketPath: String
    let versionMismatch: Bool

    init(
        response: BurnBarHealthResponse,
        expectedProtocolVersion: Int = BurnBarProtocolVersion.current
    ) {
        self.isHealthy = response.ok && response.protocolVersion == expectedProtocolVersion
        self.daemonVersion = response.daemonVersion
        self.protocolVersion = response.protocolVersion
        self.socketPath = response.socketPath ?? ""
        self.versionMismatch = response.protocolVersion != expectedProtocolVersion
    }
}

enum OpenBurnBarDaemonStatus: Equatable {
    case checking
    case notInstalled
    case healthy(OpenBurnBarDaemonHealthSnapshot)
    case unhealthy(String)

    var label: String {
        switch self {
        case .checking:
            return "Checking daemon"
        case .notInstalled:
            return "Not installed"
        case .healthy:
            return "Healthy"
        case .unhealthy:
            return "Needs repair"
        }
    }
}

enum OpenBurnBarDaemonRuntimeStateSource: Equatable {
    case daemonRPC
    case localFallback

    var detailText: String {
        switch self {
        case .daemonRPC:
            return "Live daemon state over OpenBurnBar RPC."
        case .localFallback:
            return "Using the local OpenBurnBar mirror because the daemon is unavailable."
        }
    }
}

struct OpenBurnBarDaemonDependencies: Sendable {
    let fileManager: FileManager
    let runProcess: @Sendable (String, [String]) throws -> String
    let resolveDaemonBinary: @Sendable () -> URL?
    let requestHealth: @Sendable (URL) throws -> BurnBarHealthResponse
    let requestConfig: @Sendable (URL) throws -> BurnBarProviderConfigurationSnapshot
    let updateConfig: @Sendable (URL, BurnBarProviderConfigurationSnapshot) throws -> BurnBarProviderConfigurationSnapshot
    let requestRecentUsage: @Sendable (URL, Int) throws -> [BurnBarUsageEvent]
    let requestControllerProjects: @Sendable (URL) throws -> [BurnBarReviewProjectSnapshot]
    let upsertControllerProject: @Sendable (URL, BurnBarReviewProjectSnapshot) throws -> BurnBarReviewProjectSnapshot?
    let recordControllerReviewRun: @Sendable (URL, BurnBarReviewRunSnapshot) throws -> BurnBarControllerReviewRunRecordResponse

    let validateDaemonBinary: @Sendable (URL) throws -> Void

    init(
        fileManager: FileManager,
        runProcess: @escaping @Sendable (String, [String]) throws -> String,
        resolveDaemonBinary: @escaping @Sendable () -> URL?,
        requestHealth: @escaping @Sendable (URL) throws -> BurnBarHealthResponse,
        requestConfig: @escaping @Sendable (URL) throws -> BurnBarProviderConfigurationSnapshot,
        updateConfig: @escaping @Sendable (URL, BurnBarProviderConfigurationSnapshot) throws -> BurnBarProviderConfigurationSnapshot,
        requestRecentUsage: @escaping @Sendable (URL, Int) throws -> [BurnBarUsageEvent],
        requestControllerProjects: @escaping @Sendable (URL) throws -> [BurnBarReviewProjectSnapshot],
        upsertControllerProject: @escaping @Sendable (URL, BurnBarReviewProjectSnapshot) throws -> BurnBarReviewProjectSnapshot?,
        recordControllerReviewRun: @escaping @Sendable (URL, BurnBarReviewRunSnapshot) throws -> BurnBarControllerReviewRunRecordResponse,
        validateDaemonBinary: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.runProcess = runProcess
        self.resolveDaemonBinary = resolveDaemonBinary
        self.requestHealth = requestHealth
        self.requestConfig = requestConfig
        self.updateConfig = updateConfig
        self.requestRecentUsage = requestRecentUsage
        self.requestControllerProjects = requestControllerProjects
        self.upsertControllerProject = upsertControllerProject
        self.recordControllerReviewRun = recordControllerReviewRun
        self.validateDaemonBinary = validateDaemonBinary
    }

    static func live(fileManager: FileManager = .default) -> OpenBurnBarDaemonDependencies {
        OpenBurnBarDaemonDependencies(
            fileManager: fileManager,
            runProcess: { executable, arguments in
                try OpenBurnBarDaemonProcessRunner.run(executable: executable, arguments: arguments)
            },
            resolveDaemonBinary: {
                OpenBurnBarDaemonBinaryResolver.resolve(
                    appBundleURL: Bundle.main.bundleURL,
                    fileManager: fileManager
                )
            },
            requestHealth: { socketURL in
                try OpenBurnBarDaemonSocketClient.health(at: socketURL)
            },
            requestConfig: { socketURL in
                try OpenBurnBarDaemonSocketClient.config(at: socketURL)
            },
            updateConfig: { socketURL, snapshot in
                try OpenBurnBarDaemonSocketClient.updateConfig(snapshot, at: socketURL)
            },
            requestRecentUsage: { socketURL, limit in
                try OpenBurnBarDaemonSocketClient.recentUsage(at: socketURL, limit: limit)
            },
            requestControllerProjects: { socketURL in
                try OpenBurnBarDaemonSocketClient.controllerProjects(at: socketURL)
            },
            upsertControllerProject: { socketURL, project in
                try OpenBurnBarDaemonSocketClient.upsertControllerProject(project, at: socketURL)
            },
            recordControllerReviewRun: { socketURL, run in
                try OpenBurnBarDaemonSocketClient.recordControllerReviewRun(run, at: socketURL)
            },
            validateDaemonBinary: { url in
                #if os(macOS)
                try OpenBurnBarPrivilegedTrust.validateStaticCode(at: url)
                #else
                _ = url
                #endif
            }
        )
    }
}

enum OpenBurnBarDaemonManagerError: Error, LocalizedError {
    case daemonBinaryUnavailable
    case daemonBinarySignatureInvalid(path: String, reason: String)
    case daemonResourceBundleUnavailable(expectedPath: String)
    case launchctlFailed(String)
    case timedOutWaitingForHealth(logTail: String?, logFilePath: String)
    case daemonSocketAuthTokenUnavailable
    case emptyResponse
    case rpcError(String)
    case rpcTimedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .daemonBinaryUnavailable:
            return "OpenBurnBarDaemon binary is not available in the current build products."
        case let .daemonBinarySignatureInvalid(path, reason):
            return "OpenBurnBarDaemon binary failed code-signature verification at \(path): \(reason)"
        case .daemonResourceBundleUnavailable(let expectedPath):
            return """
            OpenBurnBarDaemon resources are missing (OpenBurnBarCore_OpenBurnBarCore.bundle).
            Expected bundle at: \(expectedPath)
            Rebuild OpenBurnBar and run Install again.
            """
        case .launchctlFailed(let message):
            return "launchctl failed: \(message)"
        case .timedOutWaitingForHealth(let logTail, let logFilePath):
            var message = "Timed out waiting for OpenBurnBarDaemon to become healthy."
            if let tail = logTail?.trimmingCharacters(in: .whitespacesAndNewlines), !tail.isEmpty {
                message += "\n\n\(tail)"
            } else {
                message += " Rebuild the OpenBurnBar scheme (OpenBurnBarDaemon helper must exist), or check \(logFilePath)."
            }
            return message
        case .daemonSocketAuthTokenUnavailable:
            return "OpenBurnBar couldn't load a daemon socket auth token from the Keychain."
        case .emptyResponse:
            return "OpenBurnBarDaemon returned an empty response."
        case .rpcError(let message):
            return "OpenBurnBarDaemon RPC error: \(message)"
        case .rpcTimedOut(let seconds):
            return "OpenBurnBarDaemon RPC timed out after \(seconds) seconds."
        }
    }
}

/// UI-bound daemon supervisor. I/O paths use `daemonRPC` / `daemonProcess` off the main actor.
@Observable
@MainActor
final class OpenBurnBarDaemonManager {
    static let shared = OpenBurnBarDaemonManager(settingsManager: .shared)
    static let daemonSocketAuthTokenAccount = OpenBurnBarIdentity.daemonSocketAuthTokenAccount
    static let controllerRuntimeSecrets = KeychainStore(
        service: OpenBurnBarIdentity.controllerRuntimeKeychainService,
        legacyServices: OpenBurnBarIdentity.legacyControllerRuntimeKeychainServices
    )
    static let providerRuntimeSecrets = KeychainStore(
        service: OpenBurnBarIdentity.cursorConnectorKeychainService,
        legacyServices: OpenBurnBarIdentity.legacyCursorConnectorKeychainServices
    )

    /// Supervisor configuration exposed for diagnostics / testing.
    static let supervisorConfig = OpenBurnBarDaemonSupervisorConfig()

    let paths: OpenBurnBarDaemonRuntimePaths
    let dependencies: OpenBurnBarDaemonDependencies
    let usageSyncService: OpenBurnBarDaemonUsageSyncService
    let settingsManager: SettingsManager
    weak var dataStore: DataStore?
    private var uploadPendingUsageAfterImport: (() async -> Void)?

    var status: OpenBurnBarDaemonStatus = .checking
    var lastError: String?
    var isBusy = false
    var routerMode: ProviderRouterMode = .providerFamilyFailover
    var providerConfigurations: [OpenBurnBarDaemonProviderConfiguration] = []
    var recentUsage: [OpenBurnBarDaemonRecentUsage] = []
    var recentEvents: [String] = []
    var usageLedgerCount = 0
    var runtimeStateSource: OpenBurnBarDaemonRuntimeStateSource = .localFallback
    var controllerProjects: [BurnBarReviewProjectSnapshot] = []
    var connectorPlaneSnapshot: BurnBarConnectorPlaneSnapshot?
    var browserToolingSnapshot: BurnBarBrowserToolingSnapshot?
    /// Supervision state tracks consecutive health-check failures and crash-loop
    /// detection. The daemon manager reads this to decide when to back off
    /// health probes and when to surface a "needs repair" prompt.
    var supervisionState: OpenBurnBarDaemonSupervisionState = .idle

    init(
        settingsManager: SettingsManager = .shared,
        paths: OpenBurnBarDaemonRuntimePaths = .live(),
        dependencies: OpenBurnBarDaemonDependencies = .live(),
        usageSyncService: OpenBurnBarDaemonUsageSyncService? = nil,
        uploadPendingUsageAfterImport: (() async -> Void)? = nil
    ) {
        self.settingsManager = settingsManager
        self.paths = paths
        self.dependencies = dependencies
        self.usageSyncService = usageSyncService ?? OpenBurnBarDaemonUsageSyncService(paths: paths)
        self.uploadPendingUsageAfterImport = uploadPendingUsageAfterImport
    }

    /// Unix socket RPC uses blocking `connect`/`read` loops. Must not run on the main actor or the UI hangs.
    nonisolated func daemonRPC<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        async let result: T = work()
        return try await result
    }

    /// Process launch and `waitUntilExit` are blocking Foundation calls. Keep them off the main actor.
    func daemonProcess(_ executable: String, _ arguments: [String]) async throws -> String {
        let dependencies = self.dependencies
        return try await Self.daemonProcessOffMain(executable, arguments, dependencies: dependencies)
    }

    /// Daemon binary refresh checks can hash multi-megabyte build products. Keep that off the main actor.
    func daemonNeedsRefreshCheck() async -> Bool {
        let paths = self.paths
        let dependencies = self.dependencies
        return await Self.daemonNeedsRefreshCheckOffMain(paths: paths, dependencies: dependencies)
    }

    // MARK: - Off-Main Helpers

    private nonisolated static func daemonProcessOffMain(
        _ executable: String,
        _ arguments: [String],
        dependencies: OpenBurnBarDaemonDependencies
    ) async throws -> String {
        async let result: String = dependencies.runProcess(executable, arguments)
        return try await result
    }

    private nonisolated static func daemonNeedsRefreshCheckOffMain(
        paths: OpenBurnBarDaemonRuntimePaths,
        dependencies: OpenBurnBarDaemonDependencies
    ) async -> Bool {
        async let result: Bool = Self.installedDaemonBinaryNeedsRefresh(paths: paths, dependencies: dependencies)
        return await result
    }

    var socketPathDisplay: String {
        paths.socketURL.path
    }

    var detailText: String {
        switch status {
        case .checking:
            return "Checking the local OpenBurnBar daemon over its Unix socket."
        case .notInstalled:
            return "Install the per-user daemon so OpenBurnBar has a long-lived local control plane."
        case .healthy(let snapshot):
            let protocolNote = snapshot.versionMismatch ? "Protocol mismatch" : "Protocol \(snapshot.protocolVersion)"
            return "Daemon \(snapshot.daemonVersion) is responding on \(snapshot.socketPath). \(protocolNote)."
        case .unhealthy(let message):
            if supervisionState.isCrashLoop {
                return "Daemon crash loop detected (\(supervisionState.consecutiveFailures) failures in \(Int(Self.supervisorConfig.failureDetectionWindow))s). \(message)"
            }
            return message
        }
    }

    var isDaemonHeartbeatStale: Bool {
        OpenBurnBarDaemonHeartbeatReader.isStale(
            snapshot: readDaemonHeartbeatSnapshot()
        )
    }

    func readDaemonHeartbeatSnapshot() -> OpenBurnBarDaemonHeartbeatSnapshot? {
        OpenBurnBarDaemonHeartbeatReader.readSnapshot(from: paths.heartbeatURL)
    }

    func attach(dataStore: DataStore, cloudSyncService: CloudSyncService? = nil) {
        self.dataStore = dataStore
        if let cloudSyncService {
            uploadPendingUsageAfterImport = { [weak cloudSyncService] in
                await cloudSyncService?.uploadPending()
            }
        }
        Task { @MainActor in
            OpenBurnBarDaemonLocalNotificationRelay.shared.start()
        }
        Task {
            await refreshInstalledDaemonIfNeededForCurrentAppBuild()
            await refreshHealth()
            await repairProviderCredentialSlotSecrets()
        }
    }

    @discardableResult
    func refreshInstalledDaemonIfNeededForCurrentAppBuild() async -> Bool {
        guard !isBusy, await daemonNeedsRefreshCheck() else {
            return false
        }
        lastError = "Updating the OpenBurnBar daemon to match this app build."
        await repair()
        return true
    }

    func runResume(
        sessionID: String,
        targetHarness: String?,
        targetModel: String? = nil,
        mode: BurnBarResumeMode = .open
    ) async throws -> BurnBarRunResumeResponse {
        if case .healthy = status {
            // Keep the current health snapshot.
        } else {
            await forceRefreshHealth()
        }
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before resuming a session.")
        }

        let socketURL = paths.socketURL
        let request = BurnBarRunResumeRequest(
            sessionID: sessionID,
            targetHarness: targetHarness,
            targetModel: targetModel,
            mode: mode
        )
        return try await daemonRPC {
            try OpenBurnBarDaemonSocketClient.runResume(request, at: socketURL)
        }
    }

    /// Force a health re-probe even if the supervisor is in crash-loop backoff.
    /// Used before daemon operations so a stale crash-loop state doesn't block
    /// the user from adding provider plans when the daemon is actually healthy.
    func forceRefreshHealth() async {
        supervisionState = .idle
        await refreshHealth()
    }

    func refreshHealth() async {
        // Crash-loop backoff: skip health probe if supervisor says not yet.
        if !OpenBurnBarDaemonSupervisor.shouldProbeNow(
            state: supervisionState,
            config: Self.supervisorConfig
        ) {
            return
        }

        exportControllerActivitySnapshotIfStale()
        status = .checking
        let socketURL = paths.socketURL
        let requestHealth = dependencies.requestHealth
        do {
            let response = try await daemonRPC {
                try requestHealth(socketURL)
            }
            let snapshot = OpenBurnBarDaemonHealthSnapshot(response: response)
            if snapshot.versionMismatch {
                status = .unhealthy("Daemon protocol version \(snapshot.protocolVersion) does not match OpenBurnBarCore \(BurnBarProtocolVersion.current).")
                supervisionState = OpenBurnBarDaemonSupervisor.advance(
                    from: supervisionState,
                    daemonIsHealthy: false,
                    daemonIsInstalled: true,
                    config: Self.supervisorConfig
                )
            } else {
                status = .healthy(snapshot)
                supervisionState = .healthy
                if await refreshInstalledDaemonIfNeededForCurrentAppBuild() {
                    return
                }
            }
            lastError = nil
        } catch {
            if isInstalled {
                if await refreshInstalledDaemonIfNeededForCurrentAppBuild() {
                    return
                }
                let heartbeatDetail = isDaemonHeartbeatStale
                    ? "Daemon heartbeat is stale."
                    : "Daemon heartbeat is current."
                status = .unhealthy("\(error.localizedDescription) \(heartbeatDetail)")
                lastError = error.localizedDescription
                supervisionState = OpenBurnBarDaemonSupervisor.advance(
                    from: supervisionState,
                    daemonIsHealthy: false,
                    daemonIsInstalled: true,
                    config: Self.supervisorConfig
                )
            } else {
                status = .notInstalled
                lastError = nil
                supervisionState = .idle
            }
        }
        await refreshRuntimeSnapshot()
    }

    func refreshRuntimeSnapshot() async {
        if case .healthy = status {
            let socketURL = paths.socketURL
            let requestConfig = dependencies.requestConfig
            let requestRecentUsage = dependencies.requestRecentUsage
            let requestControllerProjects = dependencies.requestControllerProjects
            do {
                let (configSnapshot, usageEvents, projects) = try await daemonRPC {
                    let config = try requestConfig(socketURL)
                    let usage = try requestRecentUsage(socketURL, 20)
                    let projects = try requestControllerProjects(socketURL)
                    return (config, usage, projects)
                }
                let snapshot = usageSyncService.runtimeSnapshot(
                    from: configSnapshot,
                    usageEvents: usageEvents
                )

                routerMode = configSnapshot.routerMode
                providerConfigurations = snapshot.providerConfigurations
                recentUsage = snapshot.recentUsage
                usageLedgerCount = snapshot.ledgerRecordCount
                recentEvents = loadRecentDaemonEvents()
                controllerProjects = projects
                runtimeStateSource = .daemonRPC
                scheduleImportedUsagePersistence(snapshot.importedUsages)
                return
            } catch {
                runtimeStateSource = .localFallback
            }
        }

        let snapshot = usageSyncService.refreshState()

        routerMode = .providerFamilyFailover
        providerConfigurations = snapshot.providerConfigurations
        recentUsage = snapshot.recentUsage
        usageLedgerCount = snapshot.ledgerRecordCount
        recentEvents = loadRecentDaemonEvents()
        controllerProjects = []
        runtimeStateSource = .localFallback
        scheduleImportedUsagePersistence(snapshot.importedUsages)
    }

    private func scheduleImportedUsagePersistence(_ importedUsages: [TokenUsage]) {
        guard !importedUsages.isEmpty, let dataStore else { return }
        let actor = dataStore.actor

        Task(priority: .utility) { [weak self, weak dataStore, actor, importedUsages] in
            do {
                try await actor.insertUsages(importedUsages)
                await dataStore?.refresh()
                await self?.uploadImportedUsageIfNeeded(importedUsages.count)
            } catch {
                AppLogger.dataStore.silentFailure("OpenBurnBarDaemonManager: Failed to import daemon usage", error: error)
            }
        }
    }

    private func uploadImportedUsageIfNeeded(_ importedUsageCount: Int) async {
        guard importedUsageCount > 0, let uploadPendingUsageAfterImport else { return }
        await uploadPendingUsageAfterImport()
    }

    func performBusyWork(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try await operation()
            await refreshHealth()
        } catch {
            status = .unhealthy(error.localizedDescription)
            lastError = error.localizedDescription
            await refreshRuntimeSnapshot()
        }
    }

    func performRequiredBusyWork<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        var attempts = 0
        while isBusy && attempts < 50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }

        guard !isBusy else {
            throw OpenBurnBarDaemonManagerError.rpcError(
                "OpenBurnBar is still finishing another daemon update. Wait a moment and try Save & Connect again."
            )
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await operation()
            await refreshHealth()
            return result
        } catch {
            status = .unhealthy(error.localizedDescription)
            lastError = error.localizedDescription
            await refreshRuntimeSnapshot()
            throw error
        }
    }

    func loadRecentDaemonEvents(limit: Int = 6) -> [String] {
        guard let content = try? String(contentsOf: paths.logURL, encoding: .utf8) else {
            return []
        }

        return content
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(limit)
            .reversed()
    }

    /// Last portion of the launchd daemon log (stdout/stderr) for install/repair diagnostics.
    func daemonLogTailForDiagnostics(maxCharacters: Int = 2000) -> String? {
        guard let content = try? String(contentsOf: paths.logURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= maxCharacters {
            return trimmed
        }
        return String(trimmed.suffix(maxCharacters))
    }

    nonisolated static let resourceBundleName = "OpenBurnBarCore_OpenBurnBarCore.bundle"
    nonisolated static let legacyResourceBundleNames = ["BurnBarCore_BurnBarCore.bundle"]
}
