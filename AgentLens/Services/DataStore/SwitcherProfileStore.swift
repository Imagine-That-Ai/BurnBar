import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - Log Emitter

/// A closure-based log emitter that can capture log output.
/// This enables deterministic interception of production log output in tests.
public struct LogEmitter: Sendable {
    /// The underlying logger for production use
    private let logger: AppLogger
    /// Optional capture closure for test interception
    private let captureHandler: ((String) -> Void)?

    /// Creates a log emitter for production use (no capture).
    public init() {
        self.logger = AppLogger(category: "switcher")
        self.captureHandler = nil
    }

    /// Creates a log emitter with a capture handler for test use.
    /// The capture handler receives all log messages for verification.
    internal init(captureHandler: @escaping (String) -> Void) {
        self.logger = AppLogger(category: "switcher")
        self.captureHandler = captureHandler
    }

    /// Emits a log message.
    /// In production, logs via AppLogger.
    /// In tests, captures via the capture handler for verification.
    public func emit(_ message: String) {
        // Capture for test verification if handler is set
        captureHandler?(message)
        // Also emit via AppLogger for production logging
        logger.info("SwitcherProfileStore: \(message)")
    }
}

// MARK: - SwitcherProfileStore

/// CRUD store for switcher profiles.
///
/// Security properties:
/// - Stores ONLY non-sensitive launch metadata (profile identifiers, working dirs, etc.)
/// - Never stores raw OAuth tokens, passwords, cookies, or API keys
/// - Active profile state is persisted separately for atomic transitions
/// - Profile listing uses deterministic ordering via sortKey + createdAt
///
/// Log emission:
/// - Emits operational logs via LogEmitter for startup/sync flows
/// - Logs include profile IDs and non-sensitive state only
/// - No secrets, tokens, or auth data appear in any log output
/// - LogEmitter supports test capture for deterministic interception
public final class SwitcherProfileStore {
    private let dbQueue: DatabaseQueue
    private let logEmitter: LogEmitter

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        self.logEmitter = LogEmitter()
    }

    /// Internal initializer for test injection of log emitter.
    /// Allows tests to capture log output for verification.
    internal init(dbQueue: DatabaseQueue, logEmitter: LogEmitter) {
        self.dbQueue = dbQueue
        self.logEmitter = logEmitter
    }

    /// Creates a new profile with logging for startup/sync verification.
    /// Logs emit only operational state (profile ID, type, non-sensitive metadata).
    internal func createWithLogging(_ record: SwitcherProfileRecord) throws -> SwitcherProfileRecord {
        let created = try create(record)
        logEmitter.emit("Created profile id=\(created.id) targetKind=\(created.targetKind.rawValue)")
        return created
    }

    /// Fetches active profile state with logging for startup hydration verification.
    /// Logs emit only operational state (active profile ID or nil).
    internal func fetchActiveProfileStateWithLogging() throws -> SwitcherActiveProfileState {
        let state = try fetchActiveProfileState()
        if let activeID = state.activeProfileID {
            logEmitter.emit("Active profile rehydrated id=\(activeID)")
        } else {
            logEmitter.emit("Active profile rehydrated (none)")
        }
        return state
    }

    /// Sets active profile with logging for sync verification.
    /// Logs emit only operational state (profile ID or nil).
    internal func setActiveProfileWithLogging(_ profileID: String?) throws {
        try setActiveProfile(profileID)
        if let id = profileID {
            logEmitter.emit("Active profile set id=\(id)")
        } else {
            logEmitter.emit("Active profile cleared")
        }
    }

    /// Updates a profile with logging for sync verification.
    /// Logs emit only operational state.
    internal func updateWithLogging(_ record: SwitcherProfileRecord) throws -> SwitcherProfileRecord {
        let updated = try update(record)
        logEmitter.emit("Updated profile id=\(updated.id)")
        return updated
    }

    /// Deletes a profile with logging for sync verification.
    /// Logs emit only operational state.
    internal func deleteProfileWithLogging(id: String) throws {
        try deleteProfile(id: id)
        logEmitter.emit("Deleted profile id=\(id)")
    }

    // MARK: - Active Profile State

    /// Fetches the current active profile state.
    /// Performs cleanup of legacy duplicate rows if present during hydration.
    /// Uses ORDER BY updatedAt DESC to deterministically select the most recent row.
    public func fetchActiveProfileState() throws -> SwitcherActiveProfileState {
        try dbQueue.write { db in
            // Clean up legacy duplicate rows if any exist.
            // Keep only the row with the most recent updatedAt.
            // This ensures deterministic hydration even when legacy code left multiple rows.
            try db.execute(sql: """
                DELETE FROM switcher_active_profile
                WHERE rowid NOT IN (
                    SELECT rowid FROM switcher_active_profile
                    ORDER BY updatedAt DESC
                    LIMIT 1
                )
            """)

            let row = try Row.fetchOne(db, sql: "SELECT activeProfileID, updatedAt FROM switcher_active_profile LIMIT 1")
            guard let row else {
                return SwitcherActiveProfileState(activeProfileID: nil)
            }
            let activeProfileID: String? = row["activeProfileID"]
            let updatedAt: Date = Self.parseDateValue(row["updatedAt"]) ?? Date()
            return SwitcherActiveProfileState(activeProfileID: activeProfileID, updatedAt: updatedAt)
        }
    }

    /// Sets the active profile. Pass nil to clear active selection.
    /// Uses DELETE + INSERT to guarantee exactly one row in the active profile table.
    /// This avoids the non-deterministic LIMIT 1 behavior when multiple rows exist.
    public func setActiveProfile(_ profileID: String?) throws {
        try dbQueue.write { db in
            let now = Date()
            // Delete all existing rows and insert fresh - guarantees single canonical row
            try db.execute(sql: "DELETE FROM switcher_active_profile")
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (?, ?)",
                arguments: [profileID, now]
            )
        }
    }

    // MARK: - Profile CRUD

    /// Creates a new profile. Returns the created profile with generated ID and timestamps.
    /// If sortKey > 0 is passed, it is preserved; otherwise auto-increments from max existing.
    /// If createdAt is passed (non-zero date), it is preserved; otherwise uses current time.
    public func create(_ record: SwitcherProfileRecord) throws -> SwitcherProfileRecord {
        try dbQueue.write { db in
            // Determine sort key: use passed value if > 0, otherwise auto-increment
            let sortKey: Int
            if record.sortKey > 0 {
                sortKey = record.sortKey
            } else {
                let maxSortKey = try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(sortKey) FROM switcher_profiles"
                ) ?? 0
                sortKey = maxSortKey + 1
            }

            // Use passed createdAt if provided, otherwise current time
            let createdAt = record.createdAt.timeIntervalSince1970 > 0 ? record.createdAt : Date()
            let now = Date()

            try db.execute(
                sql: """
                INSERT INTO switcher_profiles (
                    id, targetKind, browserType, browserMetadataJSON,
                    cliType, cliMetadataJSON, sortKey, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    record.id,
                    record.targetKind.rawValue,
                    record.browserType?.rawValue,
                    record.browserMetadata.map { try Self.encodeJSON($0) },
                    record.cliType?.rawValue,
                    record.cliMetadata.map { try Self.encodeJSON($0) },
                    sortKey,
                    createdAt,
                    now
                ]
            )

            return SwitcherProfileRecord(
                id: record.id,
                targetKind: record.targetKind,
                browserType: record.browserType,
                browserMetadata: record.browserMetadata,
                cliType: record.cliType,
                cliMetadata: record.cliMetadata,
                sortKey: sortKey,
                createdAt: createdAt,
                updatedAt: now
            )
        }
    }

    /// Fetches a profile by ID, if it exists.
    public func fetchProfile(id: String) throws -> SwitcherProfileRecord? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM switcher_profiles WHERE id = ?", arguments: [id])
            return row.flatMap(Self.profileRecord(from:))
        }
    }

    /// Fetches all profiles ordered by sortKey ASC, createdAt ASC (deterministic).
    public func fetchAllProfiles() throws -> [SwitcherProfileRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM switcher_profiles ORDER BY sortKey ASC, createdAt ASC"
            )
            return rows.compactMap(Self.profileRecord(from:))
        }
    }

    /// Fetches all profiles of a given target kind.
    public func fetchProfiles(targetKind: SwitcherProfileTargetKind) throws -> [SwitcherProfileRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM switcher_profiles
                WHERE targetKind = ?
                ORDER BY sortKey ASC, createdAt ASC
                """,
                arguments: [targetKind.rawValue]
            )
            return rows.compactMap(Self.profileRecord(from:))
        }
    }

    /// Updates an existing profile. Returns the updated record.
    /// NOTE: sortKey and id cannot be changed; createdAt is preserved.
    public func update(_ record: SwitcherProfileRecord) throws -> SwitcherProfileRecord {
        try dbQueue.write { db in
            // Verify profile exists
            let existing = try Row.fetchOne(db, sql: "SELECT sortKey, createdAt FROM switcher_profiles WHERE id = ?", arguments: [record.id])
            guard existing != nil else {
                throw SwitcherProfileStoreError.profileNotFound(record.id)
            }
            let sortKey: Int = existing!["sortKey"]
            let createdAt: Date = Self.parseDateValue(existing!["createdAt"]) ?? Date()

            let now = Date()
            try db.execute(
                sql: """
                UPDATE switcher_profiles SET
                    targetKind = ?,
                    browserType = ?,
                    browserMetadataJSON = ?,
                    cliType = ?,
                    cliMetadataJSON = ?,
                    updatedAt = ?
                WHERE id = ?
                """,
                arguments: [
                    record.targetKind.rawValue,
                    record.browserType?.rawValue,
                    record.browserMetadata.map { try Self.encodeJSON($0) },
                    record.cliType?.rawValue,
                    record.cliMetadata.map { try Self.encodeJSON($0) },
                    now,
                    record.id
                ]
            )

            return SwitcherProfileRecord(
                id: record.id,
                targetKind: record.targetKind,
                browserType: record.browserType,
                browserMetadata: record.browserMetadata,
                cliType: record.cliType,
                cliMetadata: record.cliMetadata,
                sortKey: sortKey,
                createdAt: createdAt,
                updatedAt: now
            )
        }
    }

    /// Deletes a profile by ID.
    /// If the deleted profile was active, selects a deterministic fallback (lowest sortKey).
    public func deleteProfile(id: String) throws {
        // First check if this profile is the active one
        let state = try fetchActiveProfileState()
        let wasActive = state.activeProfileID == id

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM switcher_profiles WHERE id = ?", arguments: [id])
            // Clear active state if this was the active profile
            try db.execute(
                sql: """
                UPDATE switcher_active_profile
                SET activeProfileID = NULL, updatedAt = ?
                WHERE activeProfileID = ?
                """,
                arguments: [Date(), id]
            )
        }

        // If this was the active profile, select a fallback
        if wasActive {
            try selectFallbackActiveProfile()
        }
    }

    // MARK: - Uniqueness Validation

    /// Checks if a profile with the given display name already exists
    /// (normalized, case-insensitive). Excludes a specific profile ID if provided.
    public func existsProfileWithNormalizedName(_ name: String, excludingID: String? = nil) throws -> Bool {
        let normalized = SwitcherProfileRecord.normalizeName(name)
        return try dbQueue.read { db in
            var sql = """
                SELECT 1 FROM switcher_profiles
                WHERE (
                    LOWER(COALESCE(browserMetadataJSON, cliMetadataJSON)) LIKE ?
                    OR LOWER(cliMetadataJSON) LIKE ?
                )
                """
            var args: [any DatabaseValueConvertible] = ["%\(normalized)%", "%\(normalized)%"]

            if let excludingID {
                sql += " AND id != ?"
                args.append(excludingID)
            }

            sql += " LIMIT 1"
            return try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args)) != nil
        }
    }

    // MARK: - Fallback Active Selection

    /// After deleting the active profile, selects a deterministic fallback:
    /// the profile with the lowest sortKey (and createdAt as tiebreaker).
    /// If no profiles remain, clears active state.
    /// Uses DELETE + INSERT to guarantee exactly one row in the active profile table.
    public func selectFallbackActiveProfile() throws {
        try dbQueue.write { db in
            let fallback = try Row.fetchOne(
                db,
                sql: """
                SELECT id FROM switcher_profiles
                ORDER BY sortKey ASC, createdAt ASC
                LIMIT 1
                """
            )
            let fallbackID: String? = fallback?["id"]
            // Delete all existing rows and insert fresh - guarantees single canonical row
            try db.execute(sql: "DELETE FROM switcher_active_profile")
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (?, ?)",
                arguments: [fallbackID, Date()]
            )
        }
    }

    // MARK: - Stale Active Profile Recovery

    /// Validates that the persisted active profile ID still exists.
    /// If the active profile was deleted externally, clears the stale marker
    /// and selects a fallback. Returns the current active profile state.
    public func validateAndRecoverActiveProfile() throws -> SwitcherActiveProfileState {
        let state = try fetchActiveProfileState()
        guard let activeID = state.activeProfileID else {
            return state
        }

        let profileExists = try fetchProfile(id: activeID) != nil
        if profileExists {
            return state
        }

        // Active profile is stale — select fallback
        try selectFallbackActiveProfile()
        return try fetchActiveProfileState()
    }

    // MARK: - Row Decoding

    static func profileRecord(from row: Row) -> SwitcherProfileRecord? {
        guard
            let id: String = row["id"],
            let targetKindRaw: String = row["targetKind"],
            let targetKind = SwitcherProfileTargetKind(rawValue: targetKindRaw)
        else {
            return nil
        }

        let browserTypeRaw: String? = row["browserType"]
        let browserType = browserTypeRaw.flatMap { SwitcherBrowserProfileType(rawValue: $0) }

        let browserMetadataJSON: String? = row["browserMetadataJSON"]
        let browserMetadata = browserMetadataJSON.flatMap { decodeJSON($0, as: SwitcherBrowserProfileMetadata.self) }

        let cliTypeRaw: String? = row["cliType"]
        let cliType = cliTypeRaw.flatMap { SwitcherCLIProfileType(rawValue: $0) }

        let cliMetadataJSON: String? = row["cliMetadataJSON"]
        let cliMetadata = cliMetadataJSON.flatMap { decodeJSON($0, as: SwitcherCLIProfileMetadata.self) }

        let sortKey: Int = row["sortKey"] ?? 0
        let createdAt: Date = parseDateValue(row["createdAt"]) ?? Date()
        let updatedAt: Date = parseDateValue(row["updatedAt"]) ?? Date()

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

    // MARK: - JSON Helpers

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func decodeJSON<T: Decodable>(_ string: String, as type: T.Type) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func parseDateValue(_ value: Any?) -> Date? {
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
            if let parsed = ISO8601DateFormatter().date(from: string) { return parsed }
        }
        return nil
    }
}

// MARK: - Errors

public enum SwitcherProfileStoreError: Error, LocalizedError {
    case profileNotFound(String)
    case duplicateProfileName(String)
    case migrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .profileNotFound(let id):
            return "Switcher profile not found: \(id)"
        case .duplicateProfileName(let name):
            return "A profile with name '\(name)' already exists."
        case .migrationFailed(let reason):
            return "Switcher profile migration failed: \(reason)"
        }
    }
}
