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
    let frameworksDirectory: URL
    let installedBinaryURL: URL
    let socketURL: URL
    let logURL: URL
    let launchAgentPlistURL: URL

    var socketAuthTokenFileURL: URL {
        supportDirectory.appendingPathComponent("daemon-socket-auth-token", isDirectory: false)
    }

    /// Owner-only copy of the SQLCipher key for LaunchAgent / adhoc Debug
    /// daemons that cannot satisfy the Keychain ACL (`errSecAuthFailed`).
    var databaseEncryptionKeyFileURL: URL {
        supportDirectory.appendingPathComponent(
            "daemon-database-encryption-key",
            isDirectory: false
        )
    }

    var providerConfigURL: URL {
        supportDirectory.appendingPathComponent("provider-config.json", isDirectory: false)
    }

    var usageLedgerURL: URL {
        supportDirectory.appendingPathComponent("usage-events.jsonl", isDirectory: false)
    }

    var controllerActivitySnapshotURL: URL {
        supportDirectory.appendingPathComponent("controller-activity-snapshot.json", isDirectory: false)
    }

    /// The daemon's atomically-replaced well-known fleet snapshot file
    /// (`BurnBarDaemonPaths.defaultFleetSnapshotURL` on the daemon side).
    var fleetSnapshotFileURL: URL {
        supportDirectory.appendingPathComponent("fleet-snapshot.json", isDirectory: false)
    }

    var heartbeatURL: URL {
        daemonDirectory.appendingPathComponent("openburnbar-daemon.heartbeat.json", isDirectory: false)
    }

    /// Resolves the daemon's Application Support root, running the hardening
    /// migration first.
    ///
    /// `OpenBurnBarCore.OpenBurnBarMigration.prepareSupportDirectory` does more than hand back a
    /// URL: it migrates legacy support directories into the canonical location,
    /// creates the directory with owner-only (`0o700`) permissions, and
    /// re-enforces those permissions on an existing directory. The daemon's
    /// support tree holds the control socket, provider config (which can carry
    /// routed credentials), the usage ledger, and the installed daemon binary —
    /// so a failure to apply that hardening is a security-relevant degradation,
    /// not a no-op.
    ///
    /// We cannot fail closed by refusing to produce a path (the runtime-paths
    /// value is non-optional and every caller's `.live()` default depends on it),
    /// so we degrade to the canonical, *unhardened* support URL — but we surface
    /// the failure instead of swallowing it, turning a silent permission loss
    /// into an observable `daemon`-category event. Replaces a bare `try?` that
    /// hid migration/permission faults entirely.
    static func resolveSupportDirectory(
        prepare: () throws -> URL,
        fallback: () -> URL,
        logger: AppLogger = .daemon
    ) -> URL {
        do {
            return try prepare()
        } catch {
            logger.error(
                "openburnbar.daemon.runtimePaths.prepareSupportDirectory.failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return fallback()
        }
    }

    static func live(fileManager: FileManager = .default) -> OpenBurnBarDaemonRuntimePaths {
        let supportDirectory = resolveSupportDirectory(
            prepare: { try OpenBurnBarCore.OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager) },
            fallback: { OpenBurnBarCore.OpenBurnBarAppPaths.live(fileManager: fileManager).supportDirectory }
        )
        let daemonDirectory = supportDirectory.appendingPathComponent("daemon", isDirectory: true)
        let homeDirectory = fileManager.homeDirectoryForCurrentUser

        return OpenBurnBarDaemonRuntimePaths(
            supportDirectory: supportDirectory,
            daemonDirectory: daemonDirectory,
            frameworksDirectory: supportDirectory.appendingPathComponent("Frameworks", isDirectory: true),
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
    case daemonProjectCodeMemoryResourceUnavailable(expectedPath: String)
    case launchctlFailed(String)
    case timedOutWaitingForHealth(logTail: String?, logFilePath: String)
    case daemonSocketAuthTokenUnavailable
    case emptyResponse
    case rpcError(String)
    case rpcTimedOut(seconds: Int)
    case lifecycleStepFailed(step: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .daemonBinaryUnavailable:
            return "OpenBurnBarDaemon binary is not available in the current build products."
        case let .daemonBinarySignatureInvalid(path, reason):
            return "OpenBurnBarDaemon binary failed code-signature verification at \(path): \(reason)"
        case .daemonResourceBundleUnavailable(let expectedPath):
            return """
            OpenBurnBarDaemon resources are missing (OpenBurnBarCore_OpenBurnBarCore.bundle \
            and/or OpenBurnBarCore_OpenBurnBarKernel.bundle).
            Expected bundle at: \(expectedPath)
            Rebuild OpenBurnBar and run Install again.
            """
        case .daemonProjectCodeMemoryResourceUnavailable(let expectedPath):
            return """
            OpenBurnBarDaemon Project Code Memory resources are missing (secret-pattern-corpus.json).
            Expected corpus at: \(expectedPath)
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
            return "OpenBurnBar couldn't prepare a daemon socket auth token."
        case .emptyResponse:
            return "OpenBurnBarDaemon returned an empty response."
        case .rpcError(let message):
            return "OpenBurnBarDaemon RPC error: \(message)"
        case .rpcTimedOut(let seconds):
            return "OpenBurnBarDaemon RPC timed out after \(seconds) seconds."
        case .lifecycleStepFailed(let step, let underlying):
            return "OpenBurnBarDaemon \(step) failed: \(underlying)"
        }
    }
}

/// UI-bound daemon supervisor. I/O paths use `daemonRPC` / `daemonProcess` off the main actor.
@Observable
@MainActor
final class OpenBurnBarDaemonManager {
    static let shared = OpenBurnBarDaemonManager(settingsManager: .shared)
    static let daemonSocketAuthTokenAccount = OpenBurnBarCore.OpenBurnBarIdentity.daemonSocketAuthTokenAccount
    static let controllerRuntimeSecrets = KeychainStore(
        service: OpenBurnBarCore.OpenBurnBarIdentity.controllerRuntimeKeychainService,
        legacyServices: OpenBurnBarCore.OpenBurnBarIdentity.legacyControllerRuntimeKeychainServices
    )
    static let providerRuntimeSecrets = KeychainStore(
        service: OpenBurnBarCore.OpenBurnBarIdentity.cursorConnectorKeychainService,
        legacyServices: OpenBurnBarCore.OpenBurnBarIdentity.legacyCursorConnectorKeychainServices
            + [OpenBurnBarCore.OpenBurnBarIdentity.providerAPIKeychainService]
            + OpenBurnBarCore.OpenBurnBarIdentity.legacyProviderAPIKeychainServices
    )

    /// Supervisor configuration exposed for diagnostics / testing.
    static let supervisorConfig = OpenBurnBarDaemonSupervisorConfig()

    let paths: OpenBurnBarDaemonRuntimePaths
    let dependencies: OpenBurnBarDaemonDependencies
    let usageSyncService: OpenBurnBarDaemonUsageSyncService
    let settingsManager: SettingsManager
    let daemonSocketAuthTokenStore: KeychainStore
    let computerUseBudgetStatusStore: ComputerUseBudgetStatusStore
    let computerUseQuotaUsageStore: ComputerUseQuotaUsageStore
    let computerUseCloudMeteringRecorder: any ComputerUseCloudMeteringRecording
    weak var dataStore: DataStore?
    private var uploadPendingUsageAfterImport: (() async -> Void)?
    let computerUseCapabilityPublisherInstanceID = UUID().uuidString
    var computerUseCapabilityRevision: UInt64 = 0

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
    /// Coalesces the attach-time and startup-probe activity exports. Both
    /// startup paths can request a full health refresh within the same two
    /// seconds; without this task they race the stale-file check and each load
    /// the same 10k-conversation snapshot on a separate GRDB reader.
    @ObservationIgnored var controllerActivitySnapshotExportTask: Task<Void, Never>?
    /// Supervision state tracks consecutive health-check failures and crash-loop
    /// detection. The daemon manager reads this to decide when to back off
    /// health probes and when to surface a "needs repair" prompt.
    var supervisionState: OpenBurnBarDaemonSupervisionState = .idle

    init(
        settingsManager: SettingsManager = .shared,
        paths: OpenBurnBarDaemonRuntimePaths = .live(),
        dependencies: OpenBurnBarDaemonDependencies = .live(),
        usageSyncService: OpenBurnBarDaemonUsageSyncService? = nil,
        daemonSocketAuthTokenStore: KeychainStore = OpenBurnBarDaemonManager.controllerRuntimeSecrets,
        uploadPendingUsageAfterImport: (() async -> Void)? = nil,
        computerUseBudgetStatusStore: ComputerUseBudgetStatusStore = ComputerUseBudgetStatusStore(),
        computerUseQuotaUsageStore: ComputerUseQuotaUsageStore = ComputerUseQuotaUsageStore(),
        computerUseCloudMeteringRecorder: any ComputerUseCloudMeteringRecording = ComputerUseCloudMeteringService()
    ) {
        self.settingsManager = settingsManager
        self.paths = paths
        self.dependencies = dependencies
        self.usageSyncService = usageSyncService ?? OpenBurnBarDaemonUsageSyncService(paths: paths)
        self.daemonSocketAuthTokenStore = daemonSocketAuthTokenStore
        self.uploadPendingUsageAfterImport = uploadPendingUsageAfterImport
        self.computerUseBudgetStatusStore = computerUseBudgetStatusStore
        self.computerUseQuotaUsageStore = computerUseQuotaUsageStore
        self.computerUseCloudMeteringRecorder = computerUseCloudMeteringRecorder
    }

    /// Unix socket RPC uses blocking `connect`/`read` loops. Must not run on the
    /// main actor or Settings/Dashboard beachballs. Always hop onto a detached
    /// task — a bare `nonisolated async` body is not enough when the caller is
    /// `@MainActor` and the work never suspends before the blocking I/O.
    nonisolated func daemonRPC<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try work()
        }.value
    }

    /// Process launch and `waitUntilExit` are blocking Foundation calls. Keep them off the main actor.
    /// `nonisolated` so they run off the main actor (SE-0338); `dependencies` is a
    /// `Sendable` `let`, so it is safe to read here.
    nonisolated func daemonProcess(_ executable: String, _ arguments: [String]) async throws -> String {
        let runProcess = dependencies.runProcess
        return try runProcess(executable, arguments)
    }

    /// Daemon binary refresh checks can hash multi-megabyte build products. Keep that off the main actor.
    /// `nonisolated` so the hashing runs off the main actor (SE-0338).
    nonisolated func daemonNeedsRefreshCheck() async -> Bool {
        if dependencies.fileManager.isExecutableFile(atPath: paths.installedBinaryURL.path),
           !dependencies.fileManager.fileExists(atPath: paths.launchAgentPlistURL.path) {
            return true
        }
        return Self.installedDaemonBinaryNeedsRefresh(paths: paths, dependencies: dependencies)
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

    var localGatewayStartErrorMessage: String? {
        if let lastError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lastError.isEmpty {
            return lastError
        }
        let detail = detailText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty,
           detail.localizedCaseInsensitiveContains("gateway") {
            return detail
        }
        if case .healthy = status {
            return nil
        }
        return detail.isEmpty ? nil : detail
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
        let isFirstAttach = self.dataStore == nil
        self.dataStore = dataStore
        if let cloudSyncService {
            uploadPendingUsageAfterImport = { [weak cloudSyncService] in
                await cloudSyncService?.uploadPending()
            }
        }
        // Keep the daemon-readable SQLCipher key file fresh even on re-attach.
        // Adhoc Debug LaunchAgents often cannot read the Keychain ACL and need
        // this owner-only file to open the encrypted index (AI Inbox, search).
        _ = DatabaseEncryptionService.syncDaemonReadableKeyMaterial(
            to: paths.databaseEncryptionKeyFileURL
        )
        // Re-entering Settings → Daemon used to call attach on every visit and
        // re-fire repair + full refresh + credential Keychain sweeps, blanking
        // the sheet and beachballing the app. Only the first attach boots that
        // background work; later attaches just rebind the dataStore.
        guard isFirstAttach else { return }
        Task { @MainActor in
            OpenBurnBarDaemonLocalNotificationRelay.shared.start(settingsManager: settingsManager)
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

    /// How much work `refreshHealth` is allowed to do.
    ///
    /// - `statusOnly`: one health RPC. Safe for Settings navigation.
    /// - `full`: also may repair the installed daemon, rebuild the activity
    ///   snapshot (up to 10k conversations), and refresh runtime config. Use
    ///   from background cadence / explicit Repair — never from tab switches.
    enum HealthRefreshMode: Sendable {
        case statusOnly
        case full
    }

    func refreshHealth() async {
        await refreshHealth(mode: .full)
    }

    func refreshHealth(mode: HealthRefreshMode) async {
        // Crash-loop backoff: skip health probe if supervisor says not yet.
        if !OpenBurnBarDaemonSupervisor.shouldProbeNow(
            state: supervisionState,
            config: Self.supervisorConfig
        ) {
            return
        }

        // Probe health first so Settings/Daemon UI is not blocked behind the
        // activity-snapshot rebuild (up to 10k conversations).
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
                if mode == .full, await refreshInstalledDaemonIfNeededForCurrentAppBuild() {
                    return
                }
            }
            lastError = nil
        } catch {
            if isInstalled {
                if mode == .full, await refreshInstalledDaemonIfNeededForCurrentAppBuild() {
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
        guard mode == .full else { return }
        await exportControllerActivitySnapshotIfStale()
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

        Task(priority: .utility) { [weak self, weak dataStore, importedUsages] in
            guard let dataStore else { return }
            do {
                try await dataStore.insert(importedUsages)
                await dataStore.reloadUsagesIfChanged()
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
        guard let content = try? String(contentsOf: paths.logURL, encoding: .utf8) else { // try?-ok(diagnostic log tail)
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
        guard let content = try? String(contentsOf: paths.logURL, encoding: .utf8) else { // try?-ok(diagnostic log tail)
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
    // Core-decomposition P-02: the Kernel target gained its own resource bundle
    // (catalog.json + secret-pattern-corpus.json moved into OpenBurnBarKernel). This
    // bundle is staged IN ADDITION to the Core bundle (which still carries the
    // MiningPickIcon SVGs), never instead of it.
    nonisolated static let kernelResourceBundleName = "OpenBurnBarCore_OpenBurnBarKernel.bundle"
    nonisolated static let legacyResourceBundleNames = ["BurnBarCore_BurnBarCore.bundle"]
    nonisolated static let projectCodeMemoryResourceDirectoryName = "ProjectCodeMemory"
    nonisolated static let projectCodeMemorySecretCorpusFileName = "secret-pattern-corpus.json"
}
