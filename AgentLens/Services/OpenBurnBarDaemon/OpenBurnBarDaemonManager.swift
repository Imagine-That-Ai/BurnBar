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
    private static let controllerRuntimeSecrets = KeychainStore(
        service: OpenBurnBarIdentity.controllerRuntimeKeychainService,
        legacyServices: OpenBurnBarIdentity.legacyControllerRuntimeKeychainServices
    )

    private let paths: OpenBurnBarDaemonRuntimePaths
    private let dependencies: OpenBurnBarDaemonDependencies
    private let usageSyncService: OpenBurnBarDaemonUsageSyncService
    private weak var dataStore: DataStore?

    private(set) var status: OpenBurnBarDaemonStatus = .checking
    private(set) var lastError: String?
    private(set) var isBusy = false
    private(set) var providerConfigurations: [OpenBurnBarDaemonProviderConfiguration] = []
    private(set) var recentUsage: [OpenBurnBarDaemonRecentUsage] = []
    private(set) var recentEvents: [String] = []
    private(set) var usageLedgerCount = 0
    private(set) var runtimeStateSource: OpenBurnBarDaemonRuntimeStateSource = .localFallback
    private(set) var controllerProjects: [BurnBarReviewProjectSnapshot] = []
    private(set) var connectorPlaneSnapshot: BurnBarConnectorPlaneSnapshot?
    private(set) var browserToolingSnapshot: BurnBarBrowserToolingSnapshot?

    init(
        paths: OpenBurnBarDaemonRuntimePaths = .live(),
        dependencies: OpenBurnBarDaemonDependencies = .live(),
        usageSyncService: OpenBurnBarDaemonUsageSyncService? = nil
    ) {
        self.paths = paths
        self.dependencies = dependencies
        self.usageSyncService = usageSyncService ?? OpenBurnBarDaemonUsageSyncService(paths: paths)
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

    func attach(dataStore: DataStore) {
        self.dataStore = dataStore
        OpenBurnBarDaemonLocalNotificationRelay.shared.start()
        exportControllerActivitySnapshot()
        refreshRuntimeSnapshot()
    }

    func updateProviderConfiguration(
        providerID: String,
        isEnabled: Bool? = nil,
        baseURL: String? = nil,
        preferredModelIDs: [String]? = nil
    ) async {
        guard case .healthy = status else {
            lastError = "OpenBurnBar daemon must be healthy before provider settings can be updated."
            return
        }

        await performBusyWork {
            var snapshot = try dependencies.requestConfig(paths.socketURL)
            guard let index = snapshot.providers.firstIndex(where: { $0.providerID == providerID }) else {
                throw OpenBurnBarDaemonManagerError.rpcError("Provider '\(providerID)' is not available in daemon config.")
            }

            var settings = snapshot.providers[index]
            if let isEnabled {
                settings.isEnabled = isEnabled
            }
            if let baseURL {
                settings.baseURL = baseURL
            }
            if let preferredModelIDs {
                settings.preferredModelIDs = preferredModelIDs
            }
            snapshot.providers[index] = settings

            _ = try dependencies.updateConfig(paths.socketURL, snapshot)
        }
    }

    func refreshHealth() async {
        exportControllerActivitySnapshot()
        status = .checking
        do {
            let response = try dependencies.requestHealth(paths.socketURL)
            let snapshot = OpenBurnBarDaemonHealthSnapshot(response: response)
            if snapshot.versionMismatch {
                status = .unhealthy("Daemon protocol version \(snapshot.protocolVersion) does not match OpenBurnBarCore \(BurnBarProtocolVersion.current).")
            } else {
                status = .healthy(snapshot)
            }
            lastError = nil
        } catch {
            if isInstalled {
                status = .unhealthy(error.localizedDescription)
                lastError = error.localizedDescription
            } else {
                status = .notInstalled
                lastError = nil
            }
        }
        refreshRuntimeSnapshot()
    }

    func installAndStart() async {
        await performBusyWork {
            try installFilesIfNeeded()
            try writeLaunchAgentPlist()
            try bootoutIfNeeded()
            try runLaunchctl(["bootstrap", launchctlDomain, paths.launchAgentPlistURL.path])
            try runLaunchctl(["kickstart", "-k", "\(launchctlDomain)/\(OpenBurnBarDaemonRuntimePaths.launchAgentLabel)"])
            try await awaitHealthy()
        }
    }

    func repair() async {
        await performBusyWork {
            try installFilesIfNeeded()
            try writeLaunchAgentPlist()
            try bootoutIfNeeded()
            try runLaunchctl(["bootstrap", launchctlDomain, paths.launchAgentPlistURL.path])
            try runLaunchctl(["kickstart", "-k", "\(launchctlDomain)/\(OpenBurnBarDaemonRuntimePaths.launchAgentLabel)"])
            try await awaitHealthy()
        }
    }

    func uninstall() async {
        await performBusyWork {
            try bootoutIfNeeded()
            if dependencies.fileManager.fileExists(atPath: paths.launchAgentPlistURL.path) {
                try dependencies.fileManager.removeItem(at: paths.launchAgentPlistURL)
            }
            if dependencies.fileManager.fileExists(atPath: paths.installedBinaryURL.path) {
                try dependencies.fileManager.removeItem(at: paths.installedBinaryURL)
            }
            if dependencies.fileManager.fileExists(atPath: paths.socketURL.path) {
                try dependencies.fileManager.removeItem(at: paths.socketURL)
            }
            status = .notInstalled
            lastError = nil
        }
    }

    private var launchctlDomain: String {
        "gui/\(getuid())"
    }

    private var isInstalled: Bool {
        dependencies.fileManager.fileExists(atPath: paths.launchAgentPlistURL.path)
            || dependencies.fileManager.fileExists(atPath: paths.installedBinaryURL.path)
    }

    private func performBusyWork(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try await operation()
            await refreshHealth()
        } catch {
            status = .unhealthy(error.localizedDescription)
            lastError = error.localizedDescription
            refreshRuntimeSnapshot()
        }
    }

    private func refreshRuntimeSnapshot() {
        if case .healthy = status {
            do {
                let configSnapshot = try dependencies.requestConfig(paths.socketURL)
                let usageEvents = try dependencies.requestRecentUsage(paths.socketURL, 20)
                let projects = try dependencies.requestControllerProjects(paths.socketURL)
                let snapshot = usageSyncService.runtimeSnapshot(
                    from: configSnapshot,
                    usageEvents: usageEvents,
                    insertUsage: dataStore.map { store in
                        { usage in
                            try store.insert(usage)
                        }
                    },
                    refreshUsageCache: dataStore.map { store in
                        { store.refresh() }
                    }
                )

                providerConfigurations = snapshot.providerConfigurations
                recentUsage = snapshot.recentUsage
                usageLedgerCount = snapshot.ledgerRecordCount
                recentEvents = loadRecentDaemonEvents()
                controllerProjects = projects
                runtimeStateSource = .daemonRPC
                return
            } catch {
                runtimeStateSource = .localFallback
            }
        }

        let snapshot = usageSyncService.refreshState(
            insertUsage: dataStore.map { store in
                { usage in
                    try store.insert(usage)
                }
            },
            refreshUsageCache: dataStore.map { store in
                { store.refresh() }
            }
        )

        providerConfigurations = snapshot.providerConfigurations
        recentUsage = snapshot.recentUsage
        usageLedgerCount = snapshot.ledgerRecordCount
        recentEvents = loadRecentDaemonEvents()
        controllerProjects = []
        runtimeStateSource = .localFallback
    }

    private func loadRecentDaemonEvents(limit: Int = 6) -> [String] {
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
    private func daemonLogTailForDiagnostics(maxCharacters: Int = 2000) -> String? {
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

    static let resourceBundleName = "OpenBurnBarCore_OpenBurnBarCore.bundle"
    static let legacyResourceBundleNames = ["BurnBarCore_BurnBarCore.bundle"]

    private func installFilesIfNeeded() throws {
        try dependencies.fileManager.createDirectory(at: paths.daemonDirectory, withIntermediateDirectories: true)
        try dependencies.fileManager.createDirectory(
            at: paths.launchAgentPlistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let sourceBinaryURL = dependencies.resolveDaemonBinary() ?? paths.installedBinaryURL
        guard dependencies.fileManager.isExecutableFile(atPath: sourceBinaryURL.path) else {
            throw OpenBurnBarDaemonManagerError.daemonBinaryUnavailable
        }

        if sourceBinaryURL.standardizedFileURL != paths.installedBinaryURL.standardizedFileURL {
            if dependencies.fileManager.fileExists(atPath: paths.installedBinaryURL.path) {
                try dependencies.fileManager.removeItem(at: paths.installedBinaryURL)
            }
            try dependencies.fileManager.copyItem(at: sourceBinaryURL, to: paths.installedBinaryURL)
            try dependencies.fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: paths.installedBinaryURL.path
            )
        }

        // Copy the OpenBurnBarCore resource bundle next to the daemon binary so that
        // SPM's Bundle.module (which checks Bundle.main.bundleURL for CLI tools)
        // can find it at runtime.
        let installedBundleURL = paths.daemonDirectory.appendingPathComponent(Self.resourceBundleName)
        if let sourceBundleURL = OpenBurnBarDaemonBinaryResolver.resolveResourceBundle(
            nearBinaryURL: sourceBinaryURL,
            appBundleURL: Bundle.main.bundleURL,
            fileManager: dependencies.fileManager
        ), sourceBundleURL.standardizedFileURL != installedBundleURL.standardizedFileURL {
            if dependencies.fileManager.fileExists(atPath: installedBundleURL.path) {
                try dependencies.fileManager.removeItem(at: installedBundleURL)
            }
            try dependencies.fileManager.copyItem(at: sourceBundleURL, to: installedBundleURL)
        }

        guard dependencies.fileManager.fileExists(atPath: installedBundleURL.path) else {
            throw OpenBurnBarDaemonManagerError.daemonResourceBundleUnavailable(
                expectedPath: installedBundleURL.path
            )
        }
    }

    private func writeLaunchAgentPlist() throws {
        let indexDbPath = OpenBurnBarAppPaths.live(fileManager: dependencies.fileManager).databaseURL.path
        let plist: [String: Any] = [
            "Label": OpenBurnBarDaemonRuntimePaths.launchAgentLabel,
            "ProgramArguments": [
                paths.installedBinaryURL.path,
                "--socket-path", paths.socketURL.path,
                "--index-database-path", indexDbPath
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "WorkingDirectory": paths.daemonDirectory.path,
            "StandardOutPath": paths.logURL.path,
            "StandardErrorPath": paths.logURL.path
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: paths.launchAgentPlistURL, options: .atomic)
    }

    private func bootoutIfNeeded() throws {
        do {
            _ = try dependencies.runProcess("/bin/launchctl", ["bootout", launchctlDomain, paths.launchAgentPlistURL.path])
        } catch {
            // Ignore if the service was not loaded yet.
        }
    }

    private func runLaunchctl(_ arguments: [String]) throws {
        do {
            _ = try dependencies.runProcess("/bin/launchctl", arguments)
        } catch {
            throw OpenBurnBarDaemonManagerError.launchctlFailed(error.localizedDescription)
        }
    }

    private func awaitHealthy(timeoutSeconds: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let response = try? dependencies.requestHealth(paths.socketURL),
               response.ok,
               response.protocolVersion == BurnBarProtocolVersion.current {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw OpenBurnBarDaemonManagerError.timedOutWaitingForHealth(
            logTail: daemonLogTailForDiagnostics(),
            logFilePath: paths.logURL.path
        )
    }

    func fetchControllerRuntimeSnapshot() async throws -> OpenBurnBarControllerRuntimeSnapshot {
        try OpenBurnBarDaemonSocketClient.controllerRuntimeSnapshot(at: paths.socketURL)
    }

    func answerControllerQuestion(
        questionID: String,
        answer: String,
        selectedOptionID: String? = nil
    ) async throws -> OpenBurnBarControllerRuntimeSnapshot? {
        try OpenBurnBarDaemonSocketClient.answerControllerQuestion(
            questionID: questionID,
            answer: answer,
            selectedOptionID: selectedOptionID,
            at: paths.socketURL
        )
    }

    func completeControllerFollowup(
        followupID: String
    ) async throws -> OpenBurnBarControllerRuntimeSnapshot? {
        try OpenBurnBarDaemonSocketClient.completeControllerFollowup(
            followupID: followupID,
            at: paths.socketURL
        )
    }

    func snoozeControllerFollowup(
        followupID: String,
        until: Date
    ) async throws -> OpenBurnBarControllerRuntimeSnapshot? {
        try OpenBurnBarDaemonSocketClient.snoozeControllerFollowup(
            followupID: followupID,
            until: until,
            at: paths.socketURL
        )
    }

    func scheduleControllerFollowupCalendar(
        followupID: String,
        title: String?,
        start: Date,
        durationMinutes: Int
    ) async throws -> OpenBurnBarControllerRuntimeSnapshot? {
        try OpenBurnBarDaemonSocketClient.scheduleControllerFollowupCalendar(
            followupID: followupID,
            title: title,
            start: start,
            durationMinutes: durationMinutes,
            at: paths.socketURL
        )
    }

    func refreshControllerProjects() async throws -> [BurnBarReviewProjectSnapshot] {
        guard case .healthy = status else {
            controllerProjects = []
            return []
        }

        exportControllerActivitySnapshot()
        let projects = try dependencies.requestControllerProjects(paths.socketURL)
        controllerProjects = projects
        return projects
    }

    func refreshOperationalToolPlane() async {
        guard case .healthy = status else {
            connectorPlaneSnapshot = nil
            browserToolingSnapshot = nil
            return
        }

        do {
            connectorPlaneSnapshot = try OpenBurnBarDaemonSocketClient.connectorPlane(at: paths.socketURL)
            browserToolingSnapshot = try OpenBurnBarDaemonSocketClient.browserTooling(at: paths.socketURL)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateConnectorConfig(
        _ config: BurnBarConnectorConfigMutation,
        secret: String? = nil,
        replaceSecret: Bool = false
    ) async throws -> BurnBarConnectorPlaneSnapshot {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before updating connectors.")
        }

        let snapshot = try OpenBurnBarDaemonSocketClient.updateConnectorConfig(
            BurnBarConnectorConfigUpdateRequest(
                config: config,
                secret: secret,
                replaceSecret: replaceSecret
            ),
            at: paths.socketURL
        )
        connectorPlaneSnapshot = snapshot
        return snapshot
    }

    func performConnectorAction(
        kind: BurnBarConnectorKind,
        action: BurnBarConnectorActionKind = .testConnection
    ) async throws -> BurnBarConnectorActionResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before testing connectors.")
        }

        let response = try OpenBurnBarDaemonSocketClient.performConnectorAction(
            BurnBarConnectorActionRequest(kind: kind, action: action),
            at: paths.socketURL
        )
        connectorPlaneSnapshot = try? OpenBurnBarDaemonSocketClient.connectorPlane(at: paths.socketURL)
        return response
    }

    func updateBrowserTooling(
        _ request: BurnBarBrowserToolingUpdateRequest
    ) async throws -> BurnBarBrowserToolingSnapshot {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before updating browser tooling.")
        }

        let snapshot = try OpenBurnBarDaemonSocketClient.updateBrowserTooling(request, at: paths.socketURL)
        browserToolingSnapshot = snapshot
        return snapshot
    }

    func performBrowserAction(
        _ request: BurnBarBrowserActionRequest
    ) async throws -> BurnBarBrowserActionResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before using browser tooling.")
        }

        let response = try OpenBurnBarDaemonSocketClient.performBrowserAction(request, at: paths.socketURL)
        browserToolingSnapshot = try? OpenBurnBarDaemonSocketClient.browserTooling(at: paths.socketURL)
        return response
    }

    func saveControllerProject(
        _ project: BurnBarReviewProjectSnapshot
    ) async throws -> BurnBarReviewProjectSnapshot? {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before saving controller projects.")
        }

        let saved = try dependencies.upsertControllerProject(paths.socketURL, project)
        _ = try await refreshControllerProjects()
        return saved
    }

    func launchControllerReview(
        projectSlug: String,
        cadence: BurnBarControllerReviewCadence,
        origin: BurnBarControllerReviewRunOrigin = .projects,
        triggeredBy: String = "operator"
    ) async throws -> BurnBarControllerReviewRunRecordResponse {
        guard case .healthy = status else {
            throw OpenBurnBarDaemonManagerError.rpcError("OpenBurnBar daemon must be healthy before launching controller reviews.")
        }

        let summary: String
        switch origin {
        case .dashboard:
            summary = "Triggered from the OpenBurnBar dashboard."
        case .projects:
            summary = "Triggered from the OpenBurnBar projects registry."
        case .telegram:
            summary = "Triggered from the OpenBurnBar Telegram bridge."
        case .scheduled:
            summary = "Triggered from OpenBurnBar's scheduled review loop."
        case .ingestion:
            summary = "Triggered while ingesting OpenBurnBar activity."
        case .manual:
            summary = "Triggered manually from OpenBurnBar."
        }

        let response = try dependencies.recordControllerReviewRun(
            paths.socketURL,
            BurnBarReviewRunSnapshot(
                id: "review-\(UUID().uuidString)",
                projectSlug: projectSlug,
                cadence: cadence,
                recordedAt: Date(),
                summary: summary,
                questionCount: 0,
                followupCount: 0,
                missionCount: 0,
                origin: origin,
                triggeredBy: triggeredBy
            )
        )
        _ = try await refreshControllerProjects()
        return response
    }

    func syncControllerNotificationConfiguration(
        from settingsManager: SettingsManager
    ) async throws {
        let trimmedToken = settingsManager.controllerTelegramBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChatID = settingsManager.controllerTelegramChatID.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedToken.isEmpty {
            try Self.controllerRuntimeSecrets.delete(account: OpenBurnBarIdentity.controllerTelegramBotTokenAccount)
        } else {
            try Self.controllerRuntimeSecrets.set(
                trimmedToken,
                for: OpenBurnBarIdentity.controllerTelegramBotTokenAccount
            )
        }

        guard case .healthy = status else { return }

        let config = BurnBarNotificationConfig(
            defaultSnoozeMinutes: settingsManager.controllerDefaultSnoozeMinutes,
            nudgeHoursLocal: [9, 13, 17],
            local: BurnBarLocalNotificationConfig(
                isEnabled: settingsManager.controllerLocalNotificationsEnabled,
                quietHoursStart: 22,
                quietHoursEnd: 7
            ),
            telegram: BurnBarTelegramNotificationConfig(
                isEnabled: settingsManager.controllerTelegramEnabled,
                botTokenConfigured: trimmedToken.isEmpty == false,
                botToken: trimmedToken.isEmpty ? nil : trimmedToken,
                botTokenHint: trimmedToken.isEmpty ? nil : Self.telegramTokenHint(for: trimmedToken),
                chatID: trimmedChatID.isEmpty ? nil : trimmedChatID
            ),
            calendar: BurnBarCalendarNotificationConfig(
                isEnabled: settingsManager.controllerCalendarIntegrationEnabled,
                defaultDurationMinutes: settingsManager.controllerCalendarDefaultMinutes,
                defaultCalendarName: "OpenBurnBar Ops"
            )
        )

        _ = try OpenBurnBarDaemonSocketClient.updateNotificationConfig(config, at: paths.socketURL)
    }

    private func exportControllerActivitySnapshot() {
        guard let dataStore else { return }

        do {
            let snapshot = try makeControllerActivitySnapshot(from: dataStore)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try dependencies.fileManager.createDirectory(
                at: paths.controllerActivitySnapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: paths.controllerActivitySnapshotURL, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func makeControllerActivitySnapshot(
        from dataStore: DataStore
    ) throws -> BurnBarControllerActivitySnapshot {
        let conversations = try dataStore.fetchConversations(limit: 250)
        let start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let recentUsages = dataStore.usages(in: start...Date())

        let allProjectNames = Set(
            conversations.map(\.projectName).filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            + recentUsages.map(\.projectName).filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        )

        let projects = allProjectNames.compactMap { projectName -> BurnBarControllerActivityProject? in
            let slug = Self.slug(for: projectName)
            guard slug.isEmpty == false else { return nil }

            let projectConversations = conversations
                .filter { Self.slug(for: $0.projectName) == slug }
                .sorted { Self.activityDate(for: $0) > Self.activityDate(for: $1) }
            let projectUsages = recentUsages
                .filter { Self.slug(for: $0.projectName) == slug }
                .sorted { $0.endTime > $1.endTime }

            let latestConversation = projectConversations.first
            let latestActivityAt = max(
                latestConversation.map(Self.activityDate(for:)) ?? .distantPast,
                projectUsages.first?.endTime ?? .distantPast
            )
            let summary = latestConversation?.summary?.nonEmpty
                ?? latestConversation?.summaryTitle?.nonEmpty
                ?? latestConversation.map { $0.inferredTaskTitle.nonEmpty }.flatMap { $0 }
                ?? "Recent OpenBurnBar activity is available for review."

            return BurnBarControllerActivityProject(
                projectSlug: slug,
                displayName: projectName,
                summary: summary,
                latestActivityAt: latestActivityAt == .distantPast ? nil : latestActivityAt,
                latestConversationID: latestConversation?.id,
                latestConversationSessionID: latestConversation.map { BurnBarSessionID(rawValue: $0.sessionId) },
                latestConversationTitle: latestConversation?.summaryTitle?.nonEmpty
                    ?? latestConversation.map { $0.inferredTaskTitle.nonEmpty }.flatMap { $0 },
                latestConversationSummary: latestConversation?.summary?.nonEmpty,
                latestQuestionPrompt: nil,
                sessionCountLast7Days: Set(projectUsages.map(\.sessionId)).count,
                totalCostLast7Days: projectUsages.reduce(0) { $0 + $1.cost },
                totalTokensLast7Days: projectUsages.reduce(0) { $0 + $1.totalTokens }
            )
        }
        .sorted { ($0.latestActivityAt ?? .distantPast) > ($1.latestActivityAt ?? .distantPast) }

        return BurnBarControllerActivitySnapshot(
            generatedAt: Date(),
            activeProjectSlug: projects.first?.projectSlug,
            projects: projects
        )
    }

    private static func telegramTokenHint(for token: String) -> String {
        guard token.count > 8 else { return token }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    private static func slug(for projectName: String) -> String {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }

        let scalars = trimmed.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(String(scalar))
            }
            return "-"
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? trimmed.lowercased().replacingOccurrences(of: " ", with: "-") : collapsed
    }

    private static func activityDate(for conversation: ConversationRecord) -> Date {
        conversation.endTime ?? conversation.startTime ?? conversation.indexedAt
    }

}

/// Subscribes to `NSDistributedNotificationCenter` posts from the per-user daemon and mirrors them into
/// standard UserNotifications from the real app process (menu bar `.app`), avoiding helper-tool issues
/// and any `osascript` subprocess.
private final class OpenBurnBarDaemonLocalNotificationRelay: NSObject {
    static let shared = OpenBurnBarDaemonLocalNotificationRelay()

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDistributed(_:)),
            name: OpenBurnBarDistributedNotifications.daemonLocalNotificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func handleDistributed(_ notification: Notification) {
        guard
            let title = notification.userInfo?[OpenBurnBarDistributedNotifications.titleKey] as? String,
            let body = notification.userInfo?[OpenBurnBarDistributedNotifications.bodyKey] as? String
        else {
            return
        }
        Task {
            await Self.deliverUserNotification(title: title, body: body)
        }
    }

    private static func deliverUserNotification(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

enum OpenBurnBarDaemonProcessRunner {
    static func run(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            throw OpenBurnBarDaemonManagerError.launchctlFailed(error.isEmpty ? output : error)
        }

        return output
    }
}

enum OpenBurnBarDaemonBinaryResolver {
    static func resolve(appBundleURL: URL, fileManager: FileManager) -> URL? {
        let candidates = [
            appBundleURL.appendingPathComponent("Contents/Helpers/OpenBurnBarDaemon", isDirectory: false),
            appBundleURL.deletingLastPathComponent().appendingPathComponent("OpenBurnBarDaemon", isDirectory: false),
            appBundleURL.deletingLastPathComponent().appendingPathComponent("BurnBarDaemonExecutable", isDirectory: false)
        ]

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Locates the OpenBurnBarCore resource bundle that must be installed alongside the daemon binary.
    static func resolveResourceBundle(
        nearBinaryURL: URL,
        appBundleURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let binaryDirectory = nearBinaryURL.deletingLastPathComponent()
        let appParent = appBundleURL.deletingLastPathComponent()
        let bundleNames = [
            OpenBurnBarDaemonManager.resourceBundleName,
            OpenBurnBarDaemonManager.legacyResourceBundleNames[0],
        ]
        let candidates = bundleNames.flatMap { bundleName in
            [
                binaryDirectory.appendingPathComponent(bundleName),
                binaryDirectory.appendingPathComponent("Resources").appendingPathComponent(bundleName),
                appBundleURL.appendingPathComponent("Contents/Resources/\(bundleName)"),
                appBundleURL.appendingPathComponent("Contents/Frameworks/\(bundleName)"),
                appParent.appendingPathComponent(bundleName),
                appParent.appendingPathComponent("PackageFrameworks").appendingPathComponent(bundleName),
            ]
        }
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}


struct OpenBurnBarDaemonProviderConfiguration: Equatable, Identifiable {
    let providerID: String
    let provider: AgentProvider
    let isEnabled: Bool
    let baseURL: String
    let preferredModelIDs: [String]

    var id: String { providerID }
    var displayName: String { provider.displayName }
}

struct OpenBurnBarDaemonRecentUsage: Equatable, Identifiable {
    let idempotencyKey: String
    let provider: AgentProvider
    let model: String
    let totalTokens: Int
    let cost: Double
    let recordedAt: Date

    var id: String { idempotencyKey }
}

struct OpenBurnBarDaemonRuntimeSnapshot: Equatable {
    static let empty = OpenBurnBarDaemonRuntimeSnapshot(
        providerConfigurations: [],
        recentUsage: [],
        ledgerRecordCount: 0
    )

    let providerConfigurations: [OpenBurnBarDaemonProviderConfiguration]
    let recentUsage: [OpenBurnBarDaemonRecentUsage]
    let ledgerRecordCount: Int
}

final class OpenBurnBarDaemonUsageSyncService {
    private let paths: OpenBurnBarDaemonRuntimePaths
    private let fileManager: FileManager
    private let decoder = JSONDecoder()

    init(
        paths: OpenBurnBarDaemonRuntimePaths = .live(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.fileManager = fileManager
    }

    @discardableResult
    func refreshState(
        insertUsage: ((TokenUsage) throws -> Void)? = nil,
        refreshUsageCache: (() -> Void)? = nil
    ) -> OpenBurnBarDaemonRuntimeSnapshot {
        let usageRecords = loadUsageRecords()
        let importedUsages = usageRecords.compactMap { tokenUsage(from: $0) }

        if let insertUsage, !importedUsages.isEmpty {
            for usage in importedUsages {
                try? insertUsage(usage)
            }
            refreshUsageCache?()
        }

        return OpenBurnBarDaemonRuntimeSnapshot(
            providerConfigurations: providerConfigurations(from: loadProviderConfigurationSnapshot()),
            recentUsage: usageRecords
                .compactMap { recentUsage(from: $0) }
                .sorted { $0.recordedAt > $1.recordedAt }
                .prefix(6)
                .map { $0 },
            ledgerRecordCount: importedUsages.count
        )
    }

    @discardableResult
    func runtimeSnapshot(
        from configSnapshot: BurnBarProviderConfigurationSnapshot,
        usageEvents: [BurnBarUsageEvent],
        insertUsage: ((TokenUsage) throws -> Void)? = nil,
        refreshUsageCache: (() -> Void)? = nil
    ) -> OpenBurnBarDaemonRuntimeSnapshot {
        let importedUsages = usageEvents.compactMap { tokenUsage(from: $0) }

        if let insertUsage, !importedUsages.isEmpty {
            for usage in importedUsages {
                try? insertUsage(usage)
            }
            refreshUsageCache?()
        }

        return OpenBurnBarDaemonRuntimeSnapshot(
            providerConfigurations: providerConfigurations(from: configSnapshot),
            recentUsage: usageEvents
                .compactMap { recentUsage(from: $0) }
                .sorted { $0.recordedAt > $1.recordedAt }
                .prefix(6)
                .map { $0 },
            ledgerRecordCount: importedUsages.count
        )
    }

    private func loadProviderConfigurationSnapshot() -> BurnBarProviderConfigurationSnapshot {
        guard fileManager.fileExists(atPath: paths.providerConfigURL.path) else {
            return BurnBarProviderConfigurationSnapshot(providers: [])
        }

        guard
            let data = try? Data(contentsOf: paths.providerConfigURL),
            let snapshot = try? decoder.decode(StoredProviderConfigurationSnapshot.self, from: data)
        else {
            return BurnBarProviderConfigurationSnapshot(providers: [])
        }

        return BurnBarProviderConfigurationSnapshot(
            providers: snapshot.providers.map { settings in
                BurnBarProviderSettings(
                    providerID: settings.providerID,
                    isEnabled: settings.isEnabled,
                    baseURL: settings.baseURL,
                    preferredModelIDs: settings.preferredModelIDs
                )
            }
        )
    }

    private func providerConfigurations(
        from snapshot: BurnBarProviderConfigurationSnapshot
    ) -> [OpenBurnBarDaemonProviderConfiguration] {
        snapshot.providers
            .compactMap { settings in
                guard let provider = agentProvider(for: settings.providerID) else { return nil }
                return OpenBurnBarDaemonProviderConfiguration(
                    providerID: settings.providerID,
                    provider: provider,
                    isEnabled: settings.isEnabled,
                    baseURL: settings.baseURL,
                    preferredModelIDs: settings.preferredModelIDs
                )
            }
            .sorted { providerSortOrder($0.provider) < providerSortOrder($1.provider) }
    }

    private func loadUsageRecords() -> [StoredUsageRecord] {
        guard fileManager.fileExists(atPath: paths.usageLedgerURL.path) else {
            return []
        }

        guard let fileContents = try? String(contentsOf: paths.usageLedgerURL, encoding: .utf8) else {
            return []
        }

        return fileContents
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                try? decoder.decode(StoredUsageRecord.self, from: Data(line.utf8))
            }
    }

    private func tokenUsage(from event: BurnBarUsageEvent) -> TokenUsage? {
        guard let provider = agentProvider(for: event.providerID) else {
            return nil
        }

        let sessionID = event.runID?.rawValue ?? "\(provider.rawValue.lowercased())-\(event.recordedAt.timeIntervalSince1970)"
        let identityValue = event.runID?.rawValue ?? "\(event.providerID)|\(event.modelID)|\(event.recordedAt.timeIntervalSince1970)"
        return TokenUsage(
            id: deterministicUUID(for: identityValue),
            provider: provider,
            sessionId: sessionID,
            projectName: "OpenBurnBar Daemon",
            model: event.modelID,
            inputTokens: event.inputTokens,
            outputTokens: event.outputTokens,
            cacheCreationTokens: event.cacheCreationTokens,
            cacheReadTokens: event.cacheReadTokens,
            costUSD: event.cost,
            startTime: event.recordedAt,
            endTime: event.recordedAt,
            usageSource: .daemon,
            provenanceMethod: .daemonBridge,
            provenanceConfidence: .exact
        )
    }

    private func tokenUsage(from record: StoredUsageRecord) -> TokenUsage? {
        guard let provider = agentProvider(for: record.event.providerID) else {
            return nil
        }

        let sessionID = record.event.runID?.rawValue ?? record.idempotencyKey
        return TokenUsage(
            id: deterministicUUID(for: record.idempotencyKey),
            provider: provider,
            sessionId: sessionID,
            projectName: "OpenBurnBar Daemon",
            model: record.event.modelID,
            inputTokens: record.event.inputTokens,
            outputTokens: record.event.outputTokens,
            cacheCreationTokens: record.event.cacheCreationTokens,
            cacheReadTokens: record.event.cacheReadTokens,
            costUSD: record.event.cost,
            startTime: record.event.recordedAt,
            endTime: record.event.recordedAt,
            usageSource: .daemon,
            provenanceMethod: .daemonBridge,
            provenanceConfidence: .exact
        )
    }

    private func recentUsage(from event: BurnBarUsageEvent) -> OpenBurnBarDaemonRecentUsage? {
        guard let provider = agentProvider(for: event.providerID) else {
            return nil
        }

        return OpenBurnBarDaemonRecentUsage(
            idempotencyKey: event.runID?.rawValue ?? "\(event.providerID)|\(event.modelID)|\(event.recordedAt.timeIntervalSince1970)",
            provider: provider,
            model: event.modelID,
            totalTokens: event.inputTokens + event.outputTokens + event.cacheCreationTokens + event.cacheReadTokens,
            cost: event.cost,
            recordedAt: event.recordedAt
        )
    }

    private func recentUsage(from record: StoredUsageRecord) -> OpenBurnBarDaemonRecentUsage? {
        guard let provider = agentProvider(for: record.event.providerID) else {
            return nil
        }

        return OpenBurnBarDaemonRecentUsage(
            idempotencyKey: record.idempotencyKey,
            provider: provider,
            model: record.event.modelID,
            totalTokens: record.event.inputTokens + record.event.outputTokens + record.event.cacheCreationTokens + record.event.cacheReadTokens,
            cost: record.event.cost,
            recordedAt: record.event.recordedAt
        )
    }

    private func deterministicUUID(for value: String) -> UUID {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        let bytes = Array(digest)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func agentProvider(for providerID: String) -> AgentProvider? {
        switch providerID.lowercased() {
        case "zai":
            return .zai
        case "minimax":
            return .minimax
        default:
            return nil
        }
    }

    private func providerSortOrder(_ provider: AgentProvider) -> Int {
        switch provider {
        case .zai:
            return 0
        case .minimax:
            return 1
        default:
            return Int.max
        }
    }
}

private struct StoredProviderConfigurationSnapshot: Codable {
    let providers: [StoredProviderSettings]
}

private struct StoredProviderSettings: Codable {
    let providerID: String
    let isEnabled: Bool
    let baseURL: String
    let preferredModelIDs: [String]
}

private struct StoredUsageRecord: Codable {
    let idempotencyKey: String
    let event: BurnBarUsageEvent
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
