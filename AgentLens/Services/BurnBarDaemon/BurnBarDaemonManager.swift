import BurnBarCore
import CryptoKit
import Foundation
import Observation

struct BurnBarDaemonRuntimePaths: Hashable {
    static let launchAgentLabel = "com.burnbar.daemon"

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

    static func live(fileManager: FileManager = .default) -> BurnBarDaemonRuntimePaths {
        let supportDirectory = (try? BurnBarMigration.prepareSupportDirectory(fileManager: fileManager))
            ?? BurnBarAppPaths.live(fileManager: fileManager).supportDirectory
        let daemonDirectory = supportDirectory.appendingPathComponent("daemon", isDirectory: true)
        let homeDirectory = fileManager.homeDirectoryForCurrentUser

        return BurnBarDaemonRuntimePaths(
            supportDirectory: supportDirectory,
            daemonDirectory: daemonDirectory,
            installedBinaryURL: daemonDirectory.appendingPathComponent("BurnBarDaemon", isDirectory: false),
            socketURL: supportDirectory.appendingPathComponent("burnbar-daemon.sock", isDirectory: false),
            logURL: daemonDirectory.appendingPathComponent("burnbar-daemon.log", isDirectory: false),
            launchAgentPlistURL: homeDirectory
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("\(launchAgentLabel).plist", isDirectory: false)
        )
    }
}

struct BurnBarDaemonHealthSnapshot: Equatable {
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

enum BurnBarDaemonStatus: Equatable {
    case checking
    case notInstalled
    case healthy(BurnBarDaemonHealthSnapshot)
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

enum BurnBarDaemonRuntimeStateSource: Equatable {
    case daemonRPC
    case localFallback

    var detailText: String {
        switch self {
        case .daemonRPC:
            return "Live daemon state over BurnBar RPC."
        case .localFallback:
            return "Using the local BurnBar mirror because the daemon is unavailable."
        }
    }
}

struct BurnBarDaemonDependencies {
    let fileManager: FileManager
    let runProcess: (String, [String]) throws -> String
    let resolveDaemonBinary: () -> URL?
    let requestHealth: (URL) throws -> BurnBarHealthResponse
    let requestConfig: (URL) throws -> BurnBarProviderConfigurationSnapshot
    let updateConfig: (URL, BurnBarProviderConfigurationSnapshot) throws -> BurnBarProviderConfigurationSnapshot
    let requestRecentUsage: (URL, Int) throws -> [BurnBarUsageEvent]

    static func live(fileManager: FileManager = .default) -> BurnBarDaemonDependencies {
        BurnBarDaemonDependencies(
            fileManager: fileManager,
            runProcess: BurnBarDaemonProcessRunner.run,
            resolveDaemonBinary: {
                BurnBarDaemonBinaryResolver.resolve(
                    appBundleURL: Bundle.main.bundleURL,
                    fileManager: fileManager
                )
            },
            requestHealth: { socketURL in
                try BurnBarDaemonSocketClient.health(at: socketURL)
            },
            requestConfig: { socketURL in
                try BurnBarDaemonSocketClient.config(at: socketURL)
            },
            updateConfig: { socketURL, snapshot in
                try BurnBarDaemonSocketClient.updateConfig(snapshot, at: socketURL)
            },
            requestRecentUsage: { socketURL, limit in
                try BurnBarDaemonSocketClient.recentUsage(at: socketURL, limit: limit)
            }
        )
    }
}

enum BurnBarDaemonManagerError: Error, LocalizedError {
    case daemonBinaryUnavailable
    case launchctlFailed(String)
    case timedOutWaitingForHealth
    case emptyResponse
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .daemonBinaryUnavailable:
            return "BurnBarDaemon binary is not available in the current build products."
        case .launchctlFailed(let message):
            return "launchctl failed: \(message)"
        case .timedOutWaitingForHealth:
            return "Timed out waiting for BurnBarDaemon to become healthy."
        case .emptyResponse:
            return "BurnBarDaemon returned an empty response."
        case .rpcError(let message):
            return "BurnBarDaemon RPC error: \(message)"
        }
    }
}

@Observable
@MainActor
final class BurnBarDaemonManager {
    static let shared = BurnBarDaemonManager()

    private let paths: BurnBarDaemonRuntimePaths
    private let dependencies: BurnBarDaemonDependencies
    private let usageSyncService: BurnBarDaemonUsageSyncService
    private weak var dataStore: DataStore?

    private(set) var status: BurnBarDaemonStatus = .checking
    private(set) var lastError: String?
    private(set) var isBusy = false
    private(set) var providerConfigurations: [BurnBarDaemonProviderConfiguration] = []
    private(set) var recentUsage: [BurnBarDaemonRecentUsage] = []
    private(set) var recentEvents: [String] = []
    private(set) var usageLedgerCount = 0
    private(set) var runtimeStateSource: BurnBarDaemonRuntimeStateSource = .localFallback

    init(
        paths: BurnBarDaemonRuntimePaths = .live(),
        dependencies: BurnBarDaemonDependencies = .live(),
        usageSyncService: BurnBarDaemonUsageSyncService? = nil
    ) {
        self.paths = paths
        self.dependencies = dependencies
        self.usageSyncService = usageSyncService ?? BurnBarDaemonUsageSyncService(paths: paths)
    }

    var socketPathDisplay: String {
        paths.socketURL.path
    }

    var detailText: String {
        switch status {
        case .checking:
            return "Checking the local BurnBar daemon over its Unix socket."
        case .notInstalled:
            return "Install the per-user daemon so BurnBar has a long-lived local control plane."
        case .healthy(let snapshot):
            let protocolNote = snapshot.versionMismatch ? "Protocol mismatch" : "Protocol \(snapshot.protocolVersion)"
            return "Daemon \(snapshot.daemonVersion) is responding on \(snapshot.socketPath). \(protocolNote)."
        case .unhealthy(let message):
            return message
        }
    }

    func attach(dataStore: DataStore) {
        self.dataStore = dataStore
        refreshRuntimeSnapshot()
    }

    func updateProviderConfiguration(
        providerID: String,
        isEnabled: Bool? = nil,
        baseURL: String? = nil,
        preferredModelIDs: [String]? = nil
    ) async {
        guard case .healthy = status else {
            lastError = "BurnBar daemon must be healthy before provider settings can be updated."
            return
        }

        await performBusyWork {
            var snapshot = try dependencies.requestConfig(paths.socketURL)
            guard let index = snapshot.providers.firstIndex(where: { $0.providerID == providerID }) else {
                throw BurnBarDaemonManagerError.rpcError("Provider '\(providerID)' is not available in daemon config.")
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
        status = .checking
        do {
            let response = try dependencies.requestHealth(paths.socketURL)
            let snapshot = BurnBarDaemonHealthSnapshot(response: response)
            if snapshot.versionMismatch {
                status = .unhealthy("Daemon protocol version \(snapshot.protocolVersion) does not match BurnBarCore \(BurnBarProtocolVersion.current).")
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
            try runLaunchctl(["kickstart", "-k", "\(launchctlDomain)/\(BurnBarDaemonRuntimePaths.launchAgentLabel)"])
            try await awaitHealthy()
        }
    }

    func repair() async {
        await performBusyWork {
            try installFilesIfNeeded()
            try writeLaunchAgentPlist()
            try bootoutIfNeeded()
            try runLaunchctl(["bootstrap", launchctlDomain, paths.launchAgentPlistURL.path])
            try runLaunchctl(["kickstart", "-k", "\(launchctlDomain)/\(BurnBarDaemonRuntimePaths.launchAgentLabel)"])
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

    private func installFilesIfNeeded() throws {
        try dependencies.fileManager.createDirectory(at: paths.daemonDirectory, withIntermediateDirectories: true)
        try dependencies.fileManager.createDirectory(
            at: paths.launchAgentPlistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let sourceBinaryURL = dependencies.resolveDaemonBinary() ?? paths.installedBinaryURL
        guard dependencies.fileManager.isExecutableFile(atPath: sourceBinaryURL.path) else {
            throw BurnBarDaemonManagerError.daemonBinaryUnavailable
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
    }

    private func writeLaunchAgentPlist() throws {
        let indexDbPath = BurnBarAppPaths.live(fileManager: dependencies.fileManager).databaseURL.path
        let plist: [String: Any] = [
            "Label": BurnBarDaemonRuntimePaths.launchAgentLabel,
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
            throw BurnBarDaemonManagerError.launchctlFailed(error.localizedDescription)
        }
    }

    private func awaitHealthy(timeoutSeconds: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let response = try? dependencies.requestHealth(paths.socketURL),
               response.ok,
               response.protocolVersion == BurnBarProtocolVersion.current {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BurnBarDaemonManagerError.timedOutWaitingForHealth
    }
}

enum BurnBarDaemonProcessRunner {
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
            throw BurnBarDaemonManagerError.launchctlFailed(error.isEmpty ? output : error)
        }

        return output
    }
}

enum BurnBarDaemonBinaryResolver {
    static func resolve(appBundleURL: URL, fileManager: FileManager) -> URL? {
        let candidates = [
            appBundleURL.appendingPathComponent("Contents/Helpers/BurnBarDaemon", isDirectory: false),
            appBundleURL.deletingLastPathComponent().appendingPathComponent("BurnBarDaemon", isDirectory: false),
            appBundleURL.deletingLastPathComponent().appendingPathComponent("BurnBarDaemonExecutable", isDirectory: false)
        ]

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

enum BurnBarDaemonSocketClient {
    static func health(at socketURL: URL) throws -> BurnBarHealthResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .health),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw BurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw BurnBarDaemonManagerError.emptyResponse
        }

        return result
    }

    static func config(at socketURL: URL) throws -> BurnBarProviderConfigurationSnapshot {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarConfigResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .configGet),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw BurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw BurnBarDaemonManagerError.emptyResponse
        }

        return result.snapshot
    }

    static func updateConfig(
        _ snapshot: BurnBarProviderConfigurationSnapshot,
        at socketURL: URL
    ) throws -> BurnBarProviderConfigurationSnapshot {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarConfigResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .configUpdate,
                params: BurnBarConfigUpdateRequest(snapshot: snapshot)
            ),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw BurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw BurnBarDaemonManagerError.emptyResponse
        }

        return result.snapshot
    }

    static func recentUsage(
        at socketURL: URL,
        limit: Int = 20
    ) throws -> [BurnBarUsageEvent] {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarRecentUsageResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .usageRecent,
                params: BurnBarRecentUsageRequest(limit: limit)
            ),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw BurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw BurnBarDaemonManagerError.emptyResponse
        }

        return result.usage
    }

    static func send<Response: Codable & Sendable>(
        _ request: BurnBarRPCRequestEnvelope,
        socketURL: URL
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        try sendEncoded(request, socketURL: socketURL)
    }

    static func send<Params: Codable & Sendable, Response: Codable & Sendable>(
        _ request: BurnBarRPCRequestEnvelopeWithParams<Params>,
        socketURL: URL
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        try sendEncoded(request, socketURL: socketURL)
    }

    static func sendEncoded<Request: Encodable, Response: Codable & Sendable>(
        _ request: Request,
        socketURL: URL
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        var noSigPipe: Int32 = 1
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = try socketAddress(for: socketURL.path)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let encoder = JSONEncoder()
        let payload = try encoder.encode(request) + Data([0x0A])
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let bytesWritten = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                guard bytesWritten > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 {
                break
            }
            guard bytesRead > 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A {
                break
            }
        }

        while response.last == 0x0A || response.last == 0x0D {
            response.removeLast()
        }

        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
    }

    private static func socketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)

        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }

        return address
    }
}

struct BurnBarDaemonProviderConfiguration: Equatable, Identifiable {
    let providerID: String
    let provider: AgentProvider
    let isEnabled: Bool
    let baseURL: String
    let preferredModelIDs: [String]

    var id: String { providerID }
    var displayName: String { provider.displayName }
}

struct BurnBarDaemonRecentUsage: Equatable, Identifiable {
    let idempotencyKey: String
    let provider: AgentProvider
    let model: String
    let totalTokens: Int
    let cost: Double
    let recordedAt: Date

    var id: String { idempotencyKey }
}

struct BurnBarDaemonRuntimeSnapshot: Equatable {
    static let empty = BurnBarDaemonRuntimeSnapshot(
        providerConfigurations: [],
        recentUsage: [],
        ledgerRecordCount: 0
    )

    let providerConfigurations: [BurnBarDaemonProviderConfiguration]
    let recentUsage: [BurnBarDaemonRecentUsage]
    let ledgerRecordCount: Int
}

final class BurnBarDaemonUsageSyncService {
    private let paths: BurnBarDaemonRuntimePaths
    private let fileManager: FileManager
    private let decoder = JSONDecoder()

    init(
        paths: BurnBarDaemonRuntimePaths = .live(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.fileManager = fileManager
    }

    @discardableResult
    func refreshState(
        insertUsage: ((TokenUsage) throws -> Void)? = nil,
        refreshUsageCache: (() -> Void)? = nil
    ) -> BurnBarDaemonRuntimeSnapshot {
        let usageRecords = loadUsageRecords()
        let importedUsages = usageRecords.compactMap { tokenUsage(from: $0) }

        if let insertUsage, !importedUsages.isEmpty {
            for usage in importedUsages {
                try? insertUsage(usage)
            }
            refreshUsageCache?()
        }

        return BurnBarDaemonRuntimeSnapshot(
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
    ) -> BurnBarDaemonRuntimeSnapshot {
        let importedUsages = usageEvents.compactMap { tokenUsage(from: $0) }

        if let insertUsage, !importedUsages.isEmpty {
            for usage in importedUsages {
                try? insertUsage(usage)
            }
            refreshUsageCache?()
        }

        return BurnBarDaemonRuntimeSnapshot(
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
    ) -> [BurnBarDaemonProviderConfiguration] {
        snapshot.providers
            .compactMap { settings in
                guard let provider = agentProvider(for: settings.providerID) else { return nil }
                return BurnBarDaemonProviderConfiguration(
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
            projectName: "BurnBar Daemon",
            model: event.modelID,
            inputTokens: event.inputTokens,
            outputTokens: event.outputTokens,
            cacheReadTokens: event.cacheReadTokens,
            costUSD: event.cost,
            startTime: event.recordedAt,
            endTime: event.recordedAt
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
            projectName: "BurnBar Daemon",
            model: record.event.modelID,
            inputTokens: record.event.inputTokens,
            outputTokens: record.event.outputTokens,
            cacheReadTokens: record.event.cacheReadTokens,
            costUSD: record.event.cost,
            startTime: record.event.recordedAt,
            endTime: record.event.recordedAt
        )
    }

    private func recentUsage(from event: BurnBarUsageEvent) -> BurnBarDaemonRecentUsage? {
        guard let provider = agentProvider(for: event.providerID) else {
            return nil
        }

        return BurnBarDaemonRecentUsage(
            idempotencyKey: event.runID?.rawValue ?? "\(event.providerID)|\(event.modelID)|\(event.recordedAt.timeIntervalSince1970)",
            provider: provider,
            model: event.modelID,
            totalTokens: event.inputTokens + event.outputTokens + event.cacheReadTokens,
            cost: event.cost,
            recordedAt: event.recordedAt
        )
    }

    private func recentUsage(from record: StoredUsageRecord) -> BurnBarDaemonRecentUsage? {
        guard let provider = agentProvider(for: record.event.providerID) else {
            return nil
        }

        return BurnBarDaemonRecentUsage(
            idempotencyKey: record.idempotencyKey,
            provider: provider,
            model: record.event.modelID,
            totalTokens: record.event.inputTokens + record.event.outputTokens + record.event.cacheReadTokens,
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
