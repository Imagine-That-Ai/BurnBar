import Foundation
import GRDB

extension OpenBurnBarDatabase {
    /// Migrations in this allowlist are additive, execute in GRDB's per-migration
    /// transaction, and do not rewrite or delete pre-existing user rows. They can
    /// therefore rely on transactional rollback instead of forcing a full
    /// `PRAGMA integrity_check` plus a multi-gigabyte online backup before the app
    /// can render its first frame.
    ///
    /// This is deliberately fail-closed: every unlisted future migration takes
    /// the full integrity-check + encrypted-backup lane until its data-loss risk
    /// is reviewed explicitly.
    static let additiveTransactionalMigrationIdentifiers: Set<String> = [
        "v61_usage_memory",
        "v62_war_room_originator",
        "v63_standing_orders",
        "v64_token_usage_start_time_index",
        "v65_receipts_substrate"
    ]

    enum OpenBurnBarDatabaseError: Error {
        case integrityCheckFailed(details: String)
        case backupFailed(underlying: Error)
        case migrationFailed(restoredFromBackup: Bool, underlying: Error)
    }

    static func isLikelyDatabaseCorruption(_ error: Error) -> Bool {
        guard let dbError = error as? DatabaseError else { return false }
        return dbError.resultCode == .SQLITE_CORRUPT || dbError.resultCode == .SQLITE_NOTADB
    }

    func runIntegrityCheck() throws {
        let result = try dbQueue.write { db -> String in
            try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "unknown"
        }
        guard result == "ok" else {
            AppLogger.dataStore.error("Database integrity check failed", metadata: ["details": result])
            throw OpenBurnBarDatabaseError.integrityCheckFailed(details: result)
        }
    }

    func needsBackupBeforeMigration() throws -> Bool {
        guard !isInMemoryDatabase else { return false }
        return try dbQueue.read { db in
            let userTableCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            ) ?? 0
            guard userTableCount > 0 else { return false }

            let migrator = Self.migrator
            let applied = try migrator.appliedIdentifiers(db)
            let pending = migrator.migrations.filter { !applied.contains($0) }
            return Self.requiresFullPreMigrationProtection(
                pendingMigrationIdentifiers: pending
            )
        }
    }

    static func requiresFullPreMigrationProtection(
        pendingMigrationIdentifiers: [String]
    ) -> Bool {
        pendingMigrationIdentifiers.contains {
            !additiveTransactionalMigrationIdentifiers.contains($0)
        }
    }

    func createBackupIfNeeded() throws -> URL? {
        guard !isInMemoryDatabase else { return nil }

        let dbPath = dbQueue.path
        let dbURL = URL(fileURLWithPath: dbPath)
        let supportDir = dbURL.deletingLastPathComponent()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let backupName = "\(dbURL.lastPathComponent).backup.\(timestamp)"
        let backupURL = supportDir.appendingPathComponent(backupName)

        // Ensure the database file actually exists before backing up.
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        let destinationQueue: DatabaseQueue
        do {
            destinationQueue = try openBackupDestination(at: backupURL)
        } catch {
            AppLogger.dataStore.silentFailure("Database backup: failed to open destination queue", error: error)
            throw OpenBurnBarDatabaseError.backupFailed(underlying: error)
        }
        defer {
            do {
                try destinationQueue.close()
            } catch {
                AppLogger.dataStore.silentFailure("Database backup: failed to close destination queue", error: error)
            }
        }

        do {
            try dbQueue.backup(to: destinationQueue)
            AppLogger.dataStore.info("Database backup created", metadata: ["path": backupURL.path])
        } catch {
            AppLogger.dataStore.silentFailure("Database backup: backup operation failed", error: error)
            throw OpenBurnBarDatabaseError.backupFailed(underlying: error)
        }

        pruneOldBackups(in: supportDir, keeping: 5)
        return backupURL
    }

    func restoreDatabaseFromBackup(backupURL: URL) throws {
        guard !isInMemoryDatabase else { return }

        let dbPath = dbQueue.path
        let dbURL = URL(fileURLWithPath: dbPath)
        let fileManager = FileManager.default

        if let pool = dbQueue as? DatabasePool {
            try pool.close()
        } else if let queue = dbQueue as? DatabaseQueue {
            try queue.close()
        }

        if fileManager.fileExists(atPath: dbPath) {
            try fileManager.removeItem(atPath: dbPath)
        }
        for suffix in ["-wal", "-shm"] {
            let sidecarPath = dbPath + suffix
            if fileManager.fileExists(atPath: sidecarPath) {
                try fileManager.removeItem(atPath: sidecarPath)
            }
        }

        try fileManager.copyItem(at: backupURL, to: dbURL)
        AppLogger.dataStore.info(
            "Restored database from pre-migration backup",
            metadata: ["backup_path": backupURL.path, "database_path": dbPath]
        )
    }

    private var isInMemoryDatabase: Bool {
        let path = dbQueue.path
        return path == ":memory:" || path.hasPrefix("file:")
    }

    private func openBackupDestination(at backupURL: URL) throws -> DatabaseQueue {
        if let migrationBackupConfigurationBuilder {
            return try DatabaseQueue(path: backupURL.path, configuration: try migrationBackupConfigurationBuilder())
        }
        return try DatabaseQueue(path: backupURL.path)
    }

    private func pruneOldBackups(in directory: URL, keeping max: Int) {
        let fileManager = FileManager.default
        // try?-ok(skip prune on read fail)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }

        let backups = contents
            .filter { $0.lastPathComponent.contains(".backup.") }
            .compactMap { url -> (url: URL, date: Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]), // try?-ok(skip undated backup)
                      let date = values.contentModificationDate else { return nil }
                return (url, date)
            }
            .sorted { $0.date > $1.date }

        guard backups.count > max else { return }

        for item in backups[max...] {
            do {
                try fileManager.removeItem(at: item.url)
                AppLogger.dataStore.info("Pruned old database backup", metadata: ["path": item.url.path])
            } catch {
                AppLogger.dataStore.silentFailure("Prune old database backup failed", error: error)
            }
        }
    }
}
