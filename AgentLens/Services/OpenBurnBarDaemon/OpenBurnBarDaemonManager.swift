import OpenBurnBarCore
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

struct OpenBurnBarDaemonDependencies {
    let fileManager: FileManager
    let runProcess: (String, [String]) throws -> String
    let resolveDaemonBinary: () -> URL?
    let requestHealth: (URL) throws -> BurnBarHealthResponse
    let requestConfig: (URL) throws -> BurnBarProviderConfigurationSnapshot
    let updateConfig: (URL, BurnBarProviderConfigurationSnapshot) throws -> BurnBarProviderConfigurationSnapshot
    let requestRecentUsage: (URL, Int) throws -> [BurnBarUsageEvent]
    let requestControllerProjects: (URL) throws -> [BurnBarReviewProjectSnapshot]
    let upsertControllerProject: (URL, BurnBarReviewProjectSnapshot) throws -> BurnBarReviewProjectSnapshot?
    let recordControllerReviewRun: (URL, BurnBarReviewRunSnapshot) throws -> BurnBarControllerReviewRunRecordResponse

    static func live(fileManager: FileManager = .default) -> OpenBurnBarDaemonDependencies {
        OpenBurnBarDaemonDependencies(
            fileManager: fileManager,
            runProcess: OpenBurnBarDaemonProcessRunner.run,
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
            }
        )
    }
}

enum OpenBurnBarDaemonManagerError: Error, LocalizedError {
    case daemonBinaryUnavailable
    case daemonResourceBundleUnavailable(expectedPath: String)
    case launchctlFailed(String)
    case timedOutWaitingForHealth(logTail: String?, logFilePath: String)
    case daemonSocketAuthTokenUnavailable
    case emptyResponse
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .daemonBinaryUnavailable:
            return "OpenBurnBarDaemon binary is not available in the current build products."
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
        }
    }
}

@Observable
@MainActor
final class OpenBurnBarDaemonManager {
    static let shared = OpenBurnBarDaemonManager()
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
    func daemonRPC<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility) {
            try work()
        }.value
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
            return message
        }
    }

    func attach(dataStore: DataStore, cloudSyncService: CloudSyncService? = nil) {
        self.dataStore = dataStore
        if let cloudSyncService {
            uploadPendingUsageAfterImport = { [weak cloudSyncService] in
                await cloudSyncService?.uploadPending()
            }
        }
        OpenBurnBarDaemonLocalNotificationRelay.shared.start()
        exportControllerActivitySnapshot()
        Task {
            await refreshInstalledDaemonIfNeededForCurrentAppBuild()
            await refreshHealth()
            await repairProviderCredentialSlotSecrets()
        }
    }

    @discardableResult
    func refreshInstalledDaemonIfNeededForCurrentAppBuild() async -> Bool {
        guard !isBusy, installedDaemonBinaryNeedsRefresh() else {
            return false
        }
        lastError = "Updating the OpenBurnBar daemon to match this app build."
        await repair()
        return true
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

        exportControllerActivitySnapshot()
        status = .checking
        let socketURL = paths.socketURL
        do {
            let response = try await daemonRPC {
                try OpenBurnBarDaemonSocketClient.health(at: socketURL)
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
                status = .unhealthy(error.localizedDescription)
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
            do {
                let (configSnapshot, usageEvents, projects) = try await daemonRPC {
                    let config = try OpenBurnBarDaemonSocketClient.config(at: socketURL)
                    let usage = try OpenBurnBarDaemonSocketClient.recentUsage(at: socketURL, limit: 20)
                    let projects = try OpenBurnBarDaemonSocketClient.controllerProjects(at: socketURL)
                    return (config, usage, projects)
                }
                let snapshot = usageSyncService.runtimeSnapshot(
                    from: configSnapshot,
                    usageEvents: usageEvents,
                    insertUsages: dataStore.map { store in
                        { usages in
                            try store.insert(usages)
                        }
                    },
                    refreshUsageCache: dataStore.map { store in
                        { Task { await store.refresh() } }
                    }
                )

                routerMode = configSnapshot.routerMode
                providerConfigurations = snapshot.providerConfigurations
                recentUsage = snapshot.recentUsage
                usageLedgerCount = snapshot.ledgerRecordCount
                recentEvents = loadRecentDaemonEvents()
                controllerProjects = projects
                runtimeStateSource = .daemonRPC
                await uploadImportedUsageIfNeeded(snapshot)
                return
            } catch {
                runtimeStateSource = .localFallback
            }
        }

        let snapshot = usageSyncService.refreshState(
            insertUsages: dataStore.map { store in
                { usages in
                    try store.insert(usages)
                }
            },
            refreshUsageCache: dataStore.map { store in
                { Task { await store.refresh() } }
            }
        )

        routerMode = .providerFamilyFailover
        providerConfigurations = snapshot.providerConfigurations
        recentUsage = snapshot.recentUsage
        usageLedgerCount = snapshot.ledgerRecordCount
        recentEvents = loadRecentDaemonEvents()
        controllerProjects = []
        runtimeStateSource = .localFallback
        await uploadImportedUsageIfNeeded(snapshot)
    }

    private func uploadImportedUsageIfNeeded(_ snapshot: OpenBurnBarDaemonRuntimeSnapshot) async {
        guard snapshot.ledgerRecordCount > 0, let uploadPendingUsageAfterImport else { return }
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
