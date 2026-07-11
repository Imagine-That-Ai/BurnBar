import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A cross-process, file-backed admission ledger for Computer Use.
///
/// Firestore remains the fleet reconciliation plane, but network delivery is
/// never timely enough to be the only daily-cap authority. Both the app and
/// daemon reserve an idempotency key here before dispatch. A duplicate call ID
/// therefore cannot execute twice, and a restart cannot reset accepted usage.
/// AUDIT(@unchecked Sendable): all process-local access is guarded by `processLock`;
/// the file lock provides the matching cross-process exclusion.
/// sendable-allowlist: nslock-protected-storage
public final class ComputerUseLocalQuotaLedger: @unchecked Sendable {
    public enum LedgerError: Error, Equatable, Sendable {
        case invalidDayKey
        case lockUnavailable
        case corruptLedger
        case quotaExceeded
    }

    public enum ActionClass: String, Codable, Hashable, Sendable {
        case browser
        case system
    }

    public struct Reservation: Equatable, Sendable {
        public let inserted: Bool
        public let usage: ComputerUseQuotaUsage

        public init(inserted: Bool, usage: ComputerUseQuotaUsage) {
            self.inserted = inserted
            self.usage = usage
        }
    }

    private struct DayLedger: Codable {
        static let schemaVersion = 1

        var schemaVersion: Int
        var dayKey: String
        var acceptedActionIDs: Set<String>
        var startedSessionIDs: Set<String>
        var completedSessionIDs: Set<String>
        var usage: ComputerUseQuotaUsage

        init(dayKey: String) {
            self.schemaVersion = Self.schemaVersion
            self.dayKey = dayKey
            self.acceptedActionIDs = []
            self.startedSessionIDs = []
            self.completedSessionIDs = []
            self.usage = ComputerUseQuotaUsage(dayKey: dayKey)
        }
    }

    private let directory: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let processLock = NSLock()

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.lockURL = directory.appendingPathComponent("ledger.lock", isDirectory: false)
        self.fileManager = fileManager
    }

    /// Shared default used by both the app and daemon. Environment overrides
    /// keep tests and portable daemon installs on the same authority directory.
    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        let supportDirectory: URL
        if let override = environment["OPENBURNBAR_DAEMON_SUPPORT_DIR"]
            ?? environment["BURNBAR_DAEMON_SUPPORT_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            supportDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            #if os(Linux)
            if let xdgDataHome = environment["XDG_DATA_HOME"],
               !xdgDataHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                supportDirectory = URL(fileURLWithPath: xdgDataHome, isDirectory: true)
                    .appendingPathComponent("openburnbar", isDirectory: true)
            } else {
                supportDirectory = fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/share/openburnbar", isDirectory: true)
            }
            #elseif os(Windows)
            let appData = environment["APPDATA"].flatMap { value -> URL? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed, isDirectory: true)
            }
            supportDirectory = (appData ?? fileManager.homeDirectoryForCurrentUser)
                .appendingPathComponent("OpenBurnBar", isDirectory: true)
            #else
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            supportDirectory = applicationSupport
                .appendingPathComponent("OpenBurnBar", isDirectory: true)
            #endif
        }
        return supportDirectory
            .appendingPathComponent("computer-use", isDirectory: true)
            .appendingPathComponent("quota-ledger", isDirectory: true)
    }

    public static func dayKeyUTC(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public func usage(dayKey: String) throws -> ComputerUseQuotaUsage {
        try withExclusiveLock {
            try load(dayKey: dayKey).usage
        }
    }

    /// Persists the monotonic maximum of local and server-reconciled usage.
    /// A delayed snapshot can raise local authority but can never lower it.
    @discardableResult
    public func reconcile(_ authoritativeUsage: ComputerUseQuotaUsage) throws -> ComputerUseQuotaUsage {
        try withExclusiveLock {
            var ledger = try load(dayKey: authoritativeUsage.dayKey)
            let merged = ledger.usage.monotonicMaximum(with: authoritativeUsage)
            if merged != ledger.usage {
                ledger.usage = merged
                try persist(ledger)
            }
            return merged
        }
    }

    /// Reserves an action before dispatch. `inserted == false` is a replay and
    /// callers must not dispatch it again.
    public func reserveAction(
        idempotencyKey: String,
        actionClass: ActionClass,
        originatedFromPhone: Bool,
        exemptFromMeteredCap: Bool? = nil,
        authoritativeUsage: ComputerUseQuotaUsage? = nil,
        maximumMeteredActions: Int? = nil,
        recordedAt: Date = Date()
    ) throws -> Reservation {
        let dayKey = Self.dayKeyUTC(for: recordedAt)
        let actionID = ComputerUseAuditHasher.current.hash(data: Data(idempotencyKey.utf8))
        let shouldExemptFromMeteredCap = exemptFromMeteredCap ?? originatedFromPhone
        return try withExclusiveLock {
            var ledger = try load(dayKey: dayKey)
            let priorUsage = ledger.usage
            if let authoritativeUsage, authoritativeUsage.dayKey == dayKey {
                ledger.usage = ledger.usage.monotonicMaximum(with: authoritativeUsage)
            }
            if ledger.acceptedActionIDs.contains(actionID) {
                return Reservation(inserted: false, usage: ledger.usage)
            }
            if !shouldExemptFromMeteredCap,
               let maximumMeteredActions,
               ledger.usage.totalMeteredActionsExecuted >= max(0, maximumMeteredActions) {
                if ledger.usage != priorUsage { try persist(ledger) }
                throw LedgerError.quotaExceeded
            }
            ledger.acceptedActionIDs.insert(actionID)
            switch actionClass {
            case .browser:
                ledger.usage.browserActionsExecuted += 1
            case .system:
                ledger.usage.systemActionsExecuted += 1
            }
            if shouldExemptFromMeteredCap {
                ledger.usage.phoneControlIntentsExecuted += 1
            }
            ledger.usage.updatedAt = recordedAt
            try persist(ledger)
            return Reservation(inserted: true, usage: ledger.usage)
        }
    }

    /// Rolls back a reservation that never reached dispatch. This is bounded
    /// to the exact idempotency key and is safe to retry after a crash.
    @discardableResult
    public func rollbackAction(
        idempotencyKey: String,
        actionClass: ActionClass,
        exemptFromMeteredCap: Bool = false,
        recordedAt: Date = Date()
    ) throws -> Reservation {
        let dayKey = Self.dayKeyUTC(for: recordedAt)
        let actionID = ComputerUseAuditHasher.current.hash(data: Data(idempotencyKey.utf8))
        return try withExclusiveLock {
            var ledger = try load(dayKey: dayKey)
            guard ledger.acceptedActionIDs.remove(actionID) != nil else {
                return Reservation(inserted: false, usage: ledger.usage)
            }
            switch actionClass {
            case .browser:
                ledger.usage.browserActionsExecuted = max(0, ledger.usage.browserActionsExecuted - 1)
            case .system:
                ledger.usage.systemActionsExecuted = max(0, ledger.usage.systemActionsExecuted - 1)
            }
            if exemptFromMeteredCap {
                ledger.usage.phoneControlIntentsExecuted = max(0, ledger.usage.phoneControlIntentsExecuted - 1)
            }
            ledger.usage.updatedAt = recordedAt
            try persist(ledger)
            return Reservation(inserted: true, usage: ledger.usage)
        }
    }

    public func reserveSession(
        idempotencyKey: String,
        authoritativeUsage: ComputerUseQuotaUsage? = nil,
        maximumSessions: Int? = nil,
        startedAt: Date = Date()
    ) throws -> Reservation {
        let dayKey = Self.dayKeyUTC(for: startedAt)
        let sessionID = ComputerUseAuditHasher.current.hash(data: Data(idempotencyKey.utf8))
        return try withExclusiveLock {
            var ledger = try load(dayKey: dayKey)
            let priorUsage = ledger.usage
            if let authoritativeUsage, authoritativeUsage.dayKey == dayKey {
                ledger.usage = ledger.usage.monotonicMaximum(with: authoritativeUsage)
            }
            if ledger.startedSessionIDs.contains(sessionID) {
                return Reservation(inserted: false, usage: ledger.usage)
            }
            if let maximumSessions,
               ledger.usage.sessionsStarted >= max(0, maximumSessions) {
                if ledger.usage != priorUsage { try persist(ledger) }
                throw LedgerError.quotaExceeded
            }
            ledger.startedSessionIDs.insert(sessionID)
            ledger.usage.sessionsStarted += 1
            ledger.usage.updatedAt = startedAt
            try persist(ledger)
            return Reservation(inserted: true, usage: ledger.usage)
        }
    }

    public func completeSession(
        idempotencyKey: String,
        startedAt: Date? = nil,
        endedAt: Date = Date()
    ) throws -> Reservation {
        let dayKey = Self.dayKeyUTC(for: endedAt)
        let sessionID = ComputerUseAuditHasher.current.hash(data: Data(idempotencyKey.utf8))
        return try withExclusiveLock {
            var ledger = try load(dayKey: dayKey)
            guard ledger.completedSessionIDs.insert(sessionID).inserted else {
                return Reservation(inserted: false, usage: ledger.usage)
            }
            ledger.usage.sessionsCompleted += 1
            if let startedAt {
                ledger.usage.totalSessionSeconds += max(0, Int(endedAt.timeIntervalSince(startedAt)))
            }
            ledger.usage.updatedAt = endedAt
            try persist(ledger)
            return Reservation(inserted: true, usage: ledger.usage)
        }
    }

    private func load(dayKey: String) throws -> DayLedger {
        let url = try ledgerURL(dayKey: dayKey)
        guard fileManager.fileExists(atPath: url.path) else {
            return DayLedger(dayKey: dayKey)
        }
        do {
            let decoded = try JSONDecoder().decode(DayLedger.self, from: Data(contentsOf: url))
            guard decoded.schemaVersion == DayLedger.schemaVersion, decoded.dayKey == dayKey else {
                throw LedgerError.corruptLedger
            }
            return decoded
        } catch let error as LedgerError {
            throw error
        } catch {
            throw LedgerError.corruptLedger
        }
    }

    private func persist(_ ledger: DayLedger) throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(ledger)
        let url = try ledgerURL(dayKey: ledger.dayKey)
        try data.write(to: url, options: .atomic)
        #if !os(Windows)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }

    private func ledgerURL(dayKey: String) throws -> URL {
        guard dayKey.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw LedgerError.invalidDayKey
        }
        return directory.appendingPathComponent("\(dayKey).json", isDirectory: false)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if !os(Windows)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #endif
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        try ensureDirectory()

        #if canImport(Darwin) || canImport(Glibc)
        let descriptor = lockURL.path.withCString { path in
            #if canImport(Darwin)
            Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            #else
            Glibc.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            #endif
        }
        guard descriptor >= 0 else { throw LedgerError.lockUnavailable }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw LedgerError.lockUnavailable }
        defer { _ = flock(descriptor, LOCK_UN) }
        #endif

        return try body()
    }
}

public extension ComputerUseQuotaUsage {
    /// Direct phone control is tracked for operations but is not hosted
    /// Computer Use consumption, so it must not consume the metered action cap.
    var totalMeteredActionsExecuted: Int {
        max(0, totalActionsExecuted - phoneControlIntentsExecuted)
    }

    /// Combines independent authorities without allowing a delayed or
    /// maliciously lowered server snapshot to erase locally accepted usage.
    func monotonicMaximum(with other: ComputerUseQuotaUsage) -> ComputerUseQuotaUsage {
        guard dayKey == other.dayKey else { return self }
        return ComputerUseQuotaUsage(
            dayKey: dayKey,
            browserActionsExecuted: max(browserActionsExecuted, other.browserActionsExecuted),
            browserActionsRejected: max(browserActionsRejected, other.browserActionsRejected),
            systemActionsExecuted: max(systemActionsExecuted, other.systemActionsExecuted),
            systemActionsRejected: max(systemActionsRejected, other.systemActionsRejected),
            phoneControlIntentsExecuted: max(phoneControlIntentsExecuted, other.phoneControlIntentsExecuted),
            phoneControlIntentsRejected: max(phoneControlIntentsRejected, other.phoneControlIntentsRejected),
            sessionsStarted: max(sessionsStarted, other.sessionsStarted),
            sessionsCompleted: max(sessionsCompleted, other.sessionsCompleted),
            totalSessionSeconds: max(totalSessionSeconds, other.totalSessionSeconds),
            visionModelSpendUSD: max(visionModelSpendUSD, other.visionModelSpendUSD),
            updatedAt: [updatedAt, other.updatedAt].compactMap { $0 }.max()
        )
    }
}
