import Foundation
import GRDB
import OpenBurnBarCore
#if os(macOS)
import LocalAuthentication
import Security
#endif

public enum BurnBarSwitcherShellError: LocalizedError, Equatable {
    case unsupportedCLI(String)
    case missingRequestedProfile(String)
    case requestedProfileMismatch(expected: SwitcherCLIProfileType, actual: SwitcherCLIProfileType?)
    case noProfilesConfigured(SwitcherCLIProfileType)
    case terminalSpawnFailed(String)
    case terminalExited(Int32, detail: String?)
    case quotaExhausted(String)
    case shimInstallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedCLI(let name):
            return "Unsupported CLI '\(name)'."
        case .missingRequestedProfile(let profileID):
            return "Switcher profile '\(profileID)' was not found."
        case .requestedProfileMismatch(let expected, let actual):
            return "Requested profile does not match \(expected.displayName). Found \(actual?.displayName ?? "unknown")."
        case .noProfilesConfigured(let cliType):
            return "No \(cliType.displayName) switcher profiles are configured yet."
        case .terminalSpawnFailed(let detail):
            return "Failed to start supervised terminal session: \(detail)"
        case .terminalExited(let status, let detail):
            if let detail, !detail.isEmpty {
                return detail
            }
            return "CLI exited with status \(status)."
        case .quotaExhausted(let detail):
            return detail
        case .shimInstallFailed(let detail):
            return "Failed to install shell shims: \(detail)"
        }
    }
}

public struct BurnBarCLIShellExecutionResult: Equatable, Sendable {
    public let exitCode: Int32
    public let launchedProfileID: String?
    public let attemptedProfileIDs: [String]
    public let fallbackTriggered: Bool

    public init(
        exitCode: Int32,
        launchedProfileID: String?,
        attemptedProfileIDs: [String],
        fallbackTriggered: Bool
    ) {
        self.exitCode = exitCode
        self.launchedProfileID = launchedProfileID
        self.attemptedProfileIDs = attemptedProfileIDs
        self.fallbackTriggered = fallbackTriggered
    }
}

public struct BurnBarCLIShellLaunchRequest: Equatable, Sendable {
    public let cliType: SwitcherCLIProfileType
    public let forwardedArguments: [String]
    public let requestedProfileID: String?

    public init(
        cliType: SwitcherCLIProfileType,
        forwardedArguments: [String],
        requestedProfileID: String? = nil
    ) {
        self.cliType = cliType
        self.forwardedArguments = forwardedArguments
        self.requestedProfileID = requestedProfileID
    }
}

public protocol BurnBarCLIShellExecuting: Sendable {
    func execute(_ request: BurnBarCLIShellLaunchRequest) async throws -> BurnBarCLIShellExecutionResult
}

public protocol BurnBarSwitcherProfileStoreProviding: SwitcherProfileStoreAdapter {}

public final class BurnBarSwitcherSQLiteProfileStore: BurnBarSwitcherProfileStoreProviding, Sendable {
    private let dbQueue: any DatabaseWriter
    private let logger = BurnBarDaemonLogger(category: "switcher-profile-store")

    public init(databaseURL: URL = BurnBarDaemonPaths.supportDirectoryURL.appendingPathComponent("openburnbar.sqlite")) throws {
        self.dbQueue = try DatabasePool(path: databaseURL.path, configuration: Self.databaseConfiguration())
    }

    public init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    public func fetchProfile(id: String) -> SwitcherProfileRecord? {
        do {
            return try dbQueue.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT * FROM switcher_profiles WHERE id = ?", arguments: [id])
                return row.flatMap(self.profileRecord(from:))
            }
        } catch {
            logger.silentFailure("fetch_profile", error: error)
            return nil
        }
    }

    public func fetchAllProfiles() -> [SwitcherProfileRecord] {
        do {
            return try dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM switcher_profiles ORDER BY sortKey ASC, createdAt ASC"
                )
                return rows.compactMap(self.profileRecord(from:))
            }
        } catch {
            logger.silentFailure("fetch_all_profiles", error: error)
            return []
        }
    }

    public func fetchActiveProfileID() -> String? {
        do {
            return try dbQueue.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT activeProfileID FROM switcher_active_profile
                        ORDER BY activeProfileID IS NOT NULL DESC,
                                 COALESCE(updatedAt, '1970-01-01T00:00:00Z') DESC
                        LIMIT 1
                    """
                )
                let activeProfileID: String? = row?["activeProfileID"]
                return activeProfileID
            }
        } catch {
            logger.silentFailure("fetch_active_profile_id", error: error)
            return nil
        }
    }

    public func setActiveProfileID(_ profileID: String?) {
        do {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM switcher_active_profile")
                try db.execute(
                    sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (?, ?)",
                    arguments: [profileID, Date()]
                )
            }
        } catch {
            logger.silentFailure("set_active_profile_id", error: error)
        }
    }

    public func updateProfile(_ profile: SwitcherProfileRecord) {
        let browserMetadataJSON: String?
        do {
            browserMetadataJSON = try profile.browserMetadata.map(Self.encode)
        } catch {
            logger.silentFailure("encode_browser_metadata", error: error)
            browserMetadataJSON = nil
        }
        let cliMetadataJSON: String?
        do {
            cliMetadataJSON = try profile.cliMetadata.map(Self.encode)
        } catch {
            logger.silentFailure("encode_cli_metadata", error: error)
            cliMetadataJSON = nil
        }
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE switcher_profiles
                    SET targetKind = ?,
                        browserType = ?,
                        browserMetadataJSON = ?,
                        cliType = ?,
                        cliMetadataJSON = ?,
                        updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        profile.targetKind.rawValue,
                        profile.browserType?.rawValue,
                        browserMetadataJSON,
                        profile.cliType?.rawValue,
                        cliMetadataJSON,
                        Date(),
                        profile.id
                    ]
                )
            }
        } catch {
            logger.silentFailure("update_profile", error: error)
        }
    }

    private static func databaseConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.readonly = false
        // The AgentLens app shares this SQLite file. Without a busy timeout, concurrent
        // writers immediately raise SQLITE_BUSY (error 5: "database is locked").
        configuration.busyMode = .timeout(5)
        return configuration
    }

    private func profileRecord(from row: Row) -> SwitcherProfileRecord? {
        guard
            let id: String = row["id"],
            let targetKindRaw: String = row["targetKind"],
            let targetKind = SwitcherProfileTargetKind(rawValue: targetKindRaw)
        else {
            return nil
        }

        let browserTypeRaw: String? = row["browserType"]
        let browserType = browserTypeRaw.flatMap(SwitcherBrowserProfileType.init(rawValue:))
        let browserMetadataJSON: String? = row["browserMetadataJSON"]
        let browserMetadata = decode(browserMetadataJSON, as: SwitcherBrowserProfileMetadata.self)
        let cliTypeRaw: String? = row["cliType"]
        let cliType = cliTypeRaw.flatMap(SwitcherCLIProfileType.init(rawValue:))
        let cliMetadataJSON: String? = row["cliMetadataJSON"]
        let cliMetadata = decode(cliMetadataJSON, as: SwitcherCLIProfileMetadata.self)
        let sortKey: Int = row["sortKey"] ?? 0
        let createdAt = parseDate(row["createdAt"]) ?? Date()
        let updatedAt = parseDate(row["updatedAt"]) ?? Date()

        return SwitcherProfileRecord(
            id: id,
            targetKind: targetKind,
            browserType: browserType,
            browserMetadata: browserMetadata,
            cliType: cliType,
            cliMetadata: cliMetadata,
            sortKey: sortKey,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func decode<T: Decodable>(_ string: String?, as type: T.Type) -> T? {
        guard let string,
              let data = string.data(using: .utf8) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            logger.silentFailure("decode_profile_field", error: error)
            return nil
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let timeInterval = value as? TimeInterval {
            return Date(timeIntervalSince1970: timeInterval)
        }
        if let intValue = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(intValue))
        }
        if let int64Value = value as? Int64 {
            return Date(timeIntervalSince1970: TimeInterval(int64Value))
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = value as? String {
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }
}

public protocol BurnBarSwitcherCredentialProviding: Sendable {
    func apiKey(forProfileID profileID: String, cliType: SwitcherCLIProfileType) -> String?
}

public struct BurnBarSwitcherKeychainCredentialStore: BurnBarSwitcherCredentialProviding {
    public static let service = "com.openburnbar.switcher-auth"
    private let logger = BurnBarDaemonLogger(category: "switcher-keychain")

    public init() {}

    public func apiKey(forProfileID profileID: String, cliType: SwitcherCLIProfileType) -> String? {
        let account = "switcher.\(profileID).\(cliType.rawValue).apiKey"
        do {
            return try keychainString(service: Self.service, account: account)
        } catch {
            logger.silentFailure("keychain_read", error: error)
            return nil
        }
    }

    private func keychainString(service: String, account: String) throws -> String? {
        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

        var item: CFTypeRef?
        let status = withKeychainUserInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &item)
        }

        if status == errSecItemNotFound
            || status == errSecInteractionNotAllowed
            || status == errSecUserCanceled
            || status == errSecAuthFailed {
            return nil
        }

        guard status == errSecSuccess else {
            return nil
        }

        guard let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }
}

public struct BurnBarCLITerminalRunResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let quotaExhaustedDetail: String?
    public let capturedOutput: String

    public init(
        terminationStatus: Int32,
        quotaExhaustedDetail: String?,
        capturedOutput: String
    ) {
        self.terminationStatus = terminationStatus
        self.quotaExhaustedDetail = quotaExhaustedDetail
        self.capturedOutput = capturedOutput
    }
}

public protocol BurnBarCLITerminalRunning: Sendable {
    func run(
        cliType: SwitcherCLIProfileType,
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?
    ) async throws -> BurnBarCLITerminalRunResult
}

public struct BurnBarScriptTerminalRunner: BurnBarCLITerminalRunning {
    public static let scriptExecutableURL = URL(fileURLWithPath: "/usr/bin/script")

    public init() {}

    public func run(
        cliType: SwitcherCLIProfileType,
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?
    ) async throws -> BurnBarCLITerminalRunResult {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-shell-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let transcriptURL = tempDirectory.appendingPathComponent("session.log")
        let transcriptPath = transcriptURL.path
        let mkfifoStatus = Darwin.mkfifo(transcriptPath, 0o600)
        guard mkfifoStatus == 0 else {
            throw BurnBarSwitcherShellError.terminalSpawnFailed(String(cString: strerror(errno)))
        }

        let process = Process()
        process.executableURL = Self.scriptExecutableURL
        process.arguments = ["-q", "-F", transcriptPath, executable.path] + arguments
        process.environment = environment
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let quotaRecorder = BurnBarThreadSafeQuotaRecorder()
        let supervisor = CLITerminalSessionSupervisor(cliType: cliType) { event in
            guard case .quotaExhausted(let detail, _) = event else { return }
            quotaRecorder.record(detail)
            if process.isRunning {
                process.terminate()
            }
        }

        let readHandle = try FileHandle(forReadingFrom: transcriptURL)
        let transcriptTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let data = readHandle.availableData
                guard !data.isEmpty,
                      let text = String(data: data, encoding: .utf8),
                      !text.isEmpty else {
                    return
                }
                supervisor.ingest(text, source: .stdout)
            }
        }

        defer {
            transcriptTask.cancel()
            try? readHandle.close()
            try? fileManager.removeItem(at: tempDirectory)
        }

        do {
            try process.run()
        } catch {
            throw BurnBarSwitcherShellError.terminalSpawnFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        transcriptTask.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let combinedOutput = supervisor.snapshot()
        let quotaDetail = quotaRecorder.snapshot()
            ?? CLIQuotaExhaustionClassifier.classify(for: cliType, in: combinedOutput)

        return BurnBarCLITerminalRunResult(
            terminationStatus: process.terminationStatus,
            quotaExhaustedDetail: quotaDetail,
            capturedOutput: combinedOutput
        )
    }
}

public final class BurnBarCLIShellExecutor: BurnBarCLIShellExecuting, Sendable {
    private let profileStore: any BurnBarSwitcherProfileStoreProviding
    private let credentialStore: any BurnBarSwitcherCredentialProviding
    private let terminalRunner: any BurnBarCLITerminalRunning
    private let environmentProvider: @Sendable () -> [String: String]
    private let statusWriter: @Sendable (String) -> Void

    public init(
        profileStore: any BurnBarSwitcherProfileStoreProviding,
        credentialStore: any BurnBarSwitcherCredentialProviding = BurnBarSwitcherKeychainCredentialStore(),
        terminalRunner: any BurnBarCLITerminalRunning = BurnBarScriptTerminalRunner(),
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        statusWriter: @escaping @Sendable (String) -> Void = { message in
            BurnBarCLIShellExecutor.defaultStatusWriter(message)
        }
    ) {
        self.profileStore = profileStore
        self.credentialStore = credentialStore
        self.terminalRunner = terminalRunner
        self.environmentProvider = environmentProvider
        self.statusWriter = statusWriter
    }

    public func execute(_ request: BurnBarCLIShellLaunchRequest) async throws -> BurnBarCLIShellExecutionResult {
        let forwardedArguments = try sanitizeForwardedArguments(request.forwardedArguments)
        let candidates = try candidates(for: request)

        var attemptedProfileIDs: [String] = []
        var didFallback = false
        var lastError: BurnBarSwitcherShellError?

        for (index, profile) in candidates.enumerated() {
            attemptedProfileIDs.append(profile.id)
            let configuration = try shellConfiguration(for: profile, forwardedArguments: forwardedArguments)
            let result = try await terminalRunner.run(
                cliType: request.cliType,
                executable: configuration.executable,
                arguments: configuration.arguments,
                environment: configuration.environment,
                workingDirectory: configuration.workingDirectory
            )

            if let quotaDetail = result.quotaExhaustedDetail {
                persistQuotaExhaustion(for: profile, detail: quotaDetail)
                lastError = .quotaExhausted(quotaDetail)
                let remaining = candidates.count - index - 1
                guard remaining > 0 else {
                    break
                }

                didFallback = true
                let profileName = profile.cliMetadata?.displayLabel ?? profile.displayName
                let nextProfileName = candidates[index + 1].cliMetadata?.displayLabel ?? candidates[index + 1].displayName
                statusWriter("BurnBar: \(request.cliType.displayName) hit quota on \(profileName). Trying \(nextProfileName)...\n")
                continue
            }

            if result.terminationStatus == 0 {
                clearQuotaExhaustion(for: profile)
                profileStore.setActiveProfileID(profile.id)
                return BurnBarCLIShellExecutionResult(
                    exitCode: 0,
                    launchedProfileID: profile.id,
                    attemptedProfileIDs: attemptedProfileIDs,
                    fallbackTriggered: didFallback
                )
            }

            let detail = result.capturedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = .terminalExited(result.terminationStatus, detail: detail.isEmpty ? nil : detail)
            return BurnBarCLIShellExecutionResult(
                exitCode: result.terminationStatus,
                launchedProfileID: profile.id,
                attemptedProfileIDs: attemptedProfileIDs,
                fallbackTriggered: didFallback
            )
        }

        if let lastError {
            statusWriter("BurnBar: \(lastError.localizedDescription)\n")
        }
        return BurnBarCLIShellExecutionResult(
            exitCode: EXIT_FAILURE,
            launchedProfileID: attemptedProfileIDs.last,
            attemptedProfileIDs: attemptedProfileIDs,
            fallbackTriggered: didFallback
        )
    }

    private func candidates(for request: BurnBarCLIShellLaunchRequest) throws -> [SwitcherProfileRecord] {
        let sameToolProfiles = profileStore.fetchAllProfiles()
            .filter { $0.targetKind == .cli && $0.cliType == request.cliType && !$0.isDisabled }
            .sorted { lhs, rhs in
                if lhs.sortKey == rhs.sortKey {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.sortKey < rhs.sortKey
            }

        guard !sameToolProfiles.isEmpty else {
            throw BurnBarSwitcherShellError.noProfilesConfigured(request.cliType)
        }

        if let requestedProfileID = request.requestedProfileID {
            guard let requestedProfile = sameToolProfiles.first(where: { $0.id == requestedProfileID })
                ?? profileStore.fetchProfile(id: requestedProfileID) else {
                throw BurnBarSwitcherShellError.missingRequestedProfile(requestedProfileID)
            }
            guard requestedProfile.cliType == request.cliType else {
                throw BurnBarSwitcherShellError.requestedProfileMismatch(
                    expected: request.cliType,
                    actual: requestedProfile.cliType
                )
            }
            guard !requestedProfile.isDisabled else {
                throw BurnBarSwitcherShellError.terminalSpawnFailed("Requested \(request.cliType.displayName) account is disabled.")
            }

            return [requestedProfile] + sameToolProfiles.filter { $0.id != requestedProfile.id }
        }

        guard let activeProfileID = profileStore.fetchActiveProfileID(),
              let activeProfile = sameToolProfiles.first(where: { $0.id == activeProfileID }),
              activeProfile.cliType == request.cliType,
              !activeProfile.isDisabled else {
            return sameToolProfiles
        }

        return [activeProfile] + sameToolProfiles.filter { $0.id != activeProfile.id }
    }

    private func shellConfiguration(
        for profile: SwitcherProfileRecord,
        forwardedArguments: [String]
    ) throws -> (executable: URL, arguments: [String], environment: [String: String], workingDirectory: String?) {
        switch CLILaunchAdapter.buildCLILaunch(profile: profile) {
        case .failure(let error):
            throw BurnBarSwitcherShellError.terminalSpawnFailed(error.localizedDescription)
        case .success(let configuration):
            var environment = environmentProvider()
            for (key, value) in configuration.env {
                environment[key] = value
            }

            if let cliType = profile.cliType,
               let apiKey = credentialStore.apiKey(forProfileID: profile.id, cliType: cliType),
               let envKey = authEnvironmentKey(for: cliType) {
                environment[envKey] = apiKey
            }

            return (
                executable: configuration.executable,
                arguments: configuration.args + forwardedArguments,
                environment: environment,
                workingDirectory: configuration.workingDirectory
            )
        }
    }

    private func sanitizeForwardedArguments(_ arguments: [String]) throws -> [String] {
        try arguments.map { argument in
            guard argument.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0.value == 0x09 }) else {
                throw BurnBarSwitcherShellError.terminalSpawnFailed("Shell argument contains control characters.")
            }
            return argument
        }
    }

    private func persistQuotaExhaustion(for profile: SwitcherProfileRecord, detail: String) {
        guard profile.targetKind == .cli,
              let cliType = profile.cliType else {
            return
        }

        let safeDetail = CLILaunchRedactor.redactSensitiveData(detail)
        let now = Date()
        let exhaustedUntil = exhaustionWindowEnd(from: safeDetail, now: now)
        let existingMetadata = profile.cliMetadata ?? SwitcherCLIProfileMetadata()

        let updatedProfile = SwitcherProfileRecord(
            id: profile.id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: existingMetadata.workingDirectory,
                additionalArgs: existingMetadata.additionalArgs,
                envKeysToPass: existingMetadata.envKeysToPass,
                displayLabel: existingMetadata.displayLabel,
                configDirectory: existingMetadata.configDirectory,
                accountDescription: existingMetadata.accountDescription,
                providerID: existingMetadata.providerID,
                runtimeAccountID: existingMetadata.runtimeAccountID,
                subscriptionTierID: existingMetadata.subscriptionTierID,
                modelCapabilityClassID: existingMetadata.modelCapabilityClassID,
                linkedHarnessIDs: existingMetadata.linkedHarnessIDs,
                neverAutoSwitch: existingMetadata.neverAutoSwitch,
                lastQuotaExhaustedAt: now,
                exhaustedUntil: exhaustedUntil,
                lastQuotaExhaustionDetail: safeDetail,
                isDisabled: existingMetadata.isDisabled
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt
        )

        profileStore.updateProfile(updatedProfile)
    }

    private func clearQuotaExhaustion(for profile: SwitcherProfileRecord) {
        guard profile.targetKind == .cli,
              let cliType = profile.cliType,
              let existingMetadata = profile.cliMetadata else {
            return
        }

        guard existingMetadata.lastQuotaExhaustedAt != nil
            || existingMetadata.exhaustedUntil != nil
            || existingMetadata.lastQuotaExhaustionDetail != nil else {
            return
        }

        let updatedProfile = SwitcherProfileRecord(
            id: profile.id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: existingMetadata.workingDirectory,
                additionalArgs: existingMetadata.additionalArgs,
                envKeysToPass: existingMetadata.envKeysToPass,
                displayLabel: existingMetadata.displayLabel,
                configDirectory: existingMetadata.configDirectory,
                accountDescription: existingMetadata.accountDescription,
                providerID: existingMetadata.providerID,
                runtimeAccountID: existingMetadata.runtimeAccountID,
                subscriptionTierID: existingMetadata.subscriptionTierID,
                modelCapabilityClassID: existingMetadata.modelCapabilityClassID,
                linkedHarnessIDs: existingMetadata.linkedHarnessIDs,
                neverAutoSwitch: existingMetadata.neverAutoSwitch,
                isDisabled: existingMetadata.isDisabled
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt
        )

        profileStore.updateProfile(updatedProfile)
    }

    private func exhaustionWindowEnd(from detail: String, now: Date) -> Date? {
        let normalized = detail.lowercased()
        if normalized.contains("weekly") || normalized.contains("week") {
            return now.addingTimeInterval(7 * 24 * 60 * 60)
        }
        if normalized.contains("monthly")
            || normalized.contains("month")
            || normalized.contains("credit limit") {
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month], from: now)
            if let monthStart = calendar.date(from: components),
               let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) {
                return nextMonth
            }
            return now.addingTimeInterval(30 * 24 * 60 * 60)
        }
        if normalized.contains("5-hour")
            || normalized.contains("5 hour")
            || normalized.contains("5h")
            || normalized.contains("hour window") {
            return now.addingTimeInterval(5 * 60 * 60)
        }
        return nil
    }

    private func authEnvironmentKey(for cliType: SwitcherCLIProfileType) -> String? {
        switch cliType {
        case .codex:
            return "OPENAI_API_KEY"
        case .claude:
            return "ANTHROPIC_API_KEY"
        case .opencode:
            return nil
        }
    }

    public static func defaultStatusWriter(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

public struct BurnBarCLIShellShimInstallResult: Equatable, Sendable {
    public let installDirectory: URL
    public let installedCommands: [String]
}

public protocol BurnBarCLIShellShimInstalling: Sendable {
    func installShims(invokedExecutablePath: String) throws -> BurnBarCLIShellShimInstallResult
}

// FileManager is thread-safe for path operations.
public struct BurnBarCLIShellShimInstaller: BurnBarCLIShellShimInstalling, @unchecked Sendable {
    public static let defaultInstallDirectory = BurnBarDaemonPaths.supportDirectoryURL
        .appendingPathComponent("bin", isDirectory: true)

    private let fileManager: FileManager
    private let installDirectory: URL

    public init(
        fileManager: FileManager = .default,
        installDirectory: URL = Self.defaultInstallDirectory
    ) {
        self.fileManager = fileManager
        self.installDirectory = installDirectory
    }

    public func installShims(invokedExecutablePath: String) throws -> BurnBarCLIShellShimInstallResult {
        guard !invokedExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BurnBarSwitcherShellError.shimInstallFailed("Could not resolve the OpenBurnBarCLI executable path.")
        }

        try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        let commands = SwitcherCLIProfileType.allCases.map(\.executableName)
        for command in commands {
            let shimURL = installDirectory.appendingPathComponent(command)
            let script = """
            #!/bin/sh
            exec "\(invokedExecutablePath)" exec \(command) "$@"
            """
            try script.write(to: shimURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)
        }

        return BurnBarCLIShellShimInstallResult(
            installDirectory: installDirectory,
            installedCommands: commands
        )
    }
}

private final class BurnBarThreadSafeQuotaRecorder: Sendable {
    private let state = Locked<String?>(nil)

    func record(_ detail: String) {
        state.withLock { current in
            if current == nil { current = detail }
        }
    }

    func snapshot() -> String? {
        state.read()
    }
}
