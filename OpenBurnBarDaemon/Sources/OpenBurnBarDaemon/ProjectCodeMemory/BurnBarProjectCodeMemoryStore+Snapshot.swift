import Foundation
import OpenBurnBarCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

extension BurnBarProjectCodeMemoryStore {
    static let maximumDatabaseSnapshotBytes = 512 * 1_024 * 1_024
    private static let snapshotChunkBytes = 1_048_576

    func databaseSnapshot(
        _ request: BurnBarProjectCodeDatabaseSnapshotRequest
    ) throws -> BurnBarProjectCodeDatabaseSnapshotResponse {
        try databaseSync {
            let limit = try validatedSnapshotLimit(request.maxBytes)
            let destination = try validatedSnapshotDestination(request.destinationPath)
            try requireEncryptedDatabaseForSnapshot()
            guard destination.path != URL(fileURLWithPath: databasePath).standardizedFileURL.path else {
                throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotInvalidPath(destination.path)
            }
            guard FileManager.default.fileExists(atPath: destination.path) == false else {
                throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotInvalidPath(
                    "destination already exists: \(destination.path)"
                )
            }

            try checkpointWAL()
            let source = try secureDatabaseFile(URL(fileURLWithPath: databasePath), maxBytes: limit)
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".openburnbar-snapshot-\(UUID().uuidString)")
            do {
                try FileManager.default.copyItem(at: source, to: temporary)
                try setOwnerOnlyPermissions(temporary)
                try synchronizeFile(temporary)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotFailed("export: \(error)")
            }

            let digest = try fileSHA256(destination)
            let bytes = try fileByteCount(destination)
            return BurnBarProjectCodeDatabaseSnapshotResponse(
                traceID: TraceContextBridge.currentContext().traceID,
                snapshotPath: destination.path,
                byteCount: bytes,
                sha256: digest,
                schemaVersion: Self.schemaVersion,
                databaseEncrypted: true,
                integrityCheck: "ok",
                createdAt: Self.isoNow()
            )
        }
    }

    /// Restores a validated encrypted snapshot into the live daemon-owned store.
    /// The old file is retained until the replacement opens and passes an
    /// integrity check; any failure reopens the old file before surfacing.
    func restoreDatabaseSnapshot(
        _ request: BurnBarProjectCodeDatabaseRestoreRequest
    ) throws -> BurnBarProjectCodeDatabaseRestoreResponse {
        try databaseSync {
            let limit = try validatedSnapshotLimit(request.maxBytes)
            let source = try secureDatabaseFile(
                try validatedSnapshotSource(request.snapshotPath),
                maxBytes: limit
            )
            try requireEncryptedDatabaseForSnapshot()
            let active = URL(fileURLWithPath: databasePath).standardizedFileURL
            guard source.path != active.path else {
                throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotInvalidPath(
                    "snapshot must not be the active database"
                )
            }
            try validateEncryptedDatabaseFile(at: source.path)
            let digest = try fileSHA256(source)
            let bytes = try fileByteCount(source)
            try validateEncryptedDatabaseIntegrity(at: source.path)

            let rollback = active.deletingLastPathComponent()
                .appendingPathComponent(".openburnbar-restore-rollback-\(UUID().uuidString)")
            stopWatchersForRestore()
            try checkpointWAL()
            do {
                try FileManager.default.copyItem(at: active, to: rollback)
                try replaceActiveDatabase(with: source, active: active)
                guard let reopened = try openEncryptedDatabase(at: active.path) else {
                    throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotFailed("restored database could not be reopened")
                }
                db = reopened
                try validateHandleIntegrity(reopened)
                try? FileManager.default.removeItem(at: rollback)
            } catch {
                if let reopened = db {
                    sqlite3_close(reopened)
                }
                db = nil
                try? FileManager.default.removeItem(at: active)
                if FileManager.default.fileExists(atPath: rollback.path) {
                    try? FileManager.default.moveItem(at: rollback, to: active)
                }
                db = try? openEncryptedDatabase(at: active.path)
                throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotFailed("restore: \(error)")
            }

            return BurnBarProjectCodeDatabaseRestoreResponse(
                traceID: TraceContextBridge.currentContext().traceID,
                restoredPath: active.path,
                byteCount: bytes,
                sha256: digest,
                schemaVersion: Self.schemaVersion,
                databaseEncrypted: true,
                integrityCheck: "ok",
                restoredAt: Self.isoNow()
            )
        }
    }

    private func validatedSnapshotLimit(_ requested: Int) throws -> Int {
        guard requested > 0, requested <= Self.maximumDatabaseSnapshotBytes else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotTooLarge(requested)
        }
        return requested
    }

    private func requireEncryptedDatabaseForSnapshot() throws {
        guard BurnBarDaemonDatabaseCipher.isCipherAvailable() else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotUnavailable(
                "SQLCipher codec is not linked into this daemon"
            )
        }
        guard BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: databasePath) else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotUnavailable(
                "the active project-code store is not encrypted"
            )
        }
        guard db != nil else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotUnavailable("database handle is closed")
        }
    }

    private func validatedSnapshotDestination(_ rawPath: String) throws -> URL {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty == false, path.hasPrefix("/"), path.contains("\0") == false else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotInvalidPath(rawPath)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathComponents.contains("..") == false,
              url.path == URL(fileURLWithPath: path).path else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotInvalidPath(path)
        }
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path),
              isDirectory(parent),
              parent.resolvingSymlinksInPath().path == parent.path else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotInvalidPath(
                "parent directory must exist and must not be a symlink: \(parent.path)"
            )
        }
        return url
    }

    private func validatedSnapshotSource(_ rawPath: String) throws -> URL {
        let url = try validatedSnapshotDestination(rawPath)
        guard FileManager.default.fileExists(atPath: url.path), isSymbolicLink(url) == false else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotInvalidPath(url.path)
        }
        return url
    }

    private func secureDatabaseFile(_ url: URL, maxBytes: Int) throws -> URL {
        guard isSymbolicLink(url) == false else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotPermissions(url.path)
        }
        let bytes = try fileByteCount(url)
        guard bytes <= maxBytes else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotTooLarge(bytes)
        }
        try requireOwnerOnlyPermissions(url)
        return url
    }

    private func requireOwnerOnlyPermissions(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotPermissions(url.path)
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o077 == 0 else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotPermissions(
                "require mode 0600 or tighter: \(url.path)"
            )
        }
    }

    private func setOwnerOnlyPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func fileByteCount(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotFailed("could not read file size")
        }
        return number.intValue
    }

    private func checkpointWAL() throws {
        guard db != nil else { throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotUnavailable("database handle is closed") }
        try execute("PRAGMA wal_checkpoint(TRUNCATE)", [])
    }

    private func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: Self.snapshotChunkBytes), chunk.isEmpty == false {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func validateEncryptedDatabaseFile(at path: String) throws {
        guard BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: path) else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotUnavailable("snapshot is not encrypted")
        }
    }

    private func validateEncryptedDatabaseIntegrity(at path: String) throws {
        guard let handle = try openEncryptedDatabase(at: path) else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotFailed("snapshot could not be opened")
        }
        defer { sqlite3_close(handle) }
        try validateHandleIntegrity(handle)
    }

    private func validateHandleIntegrity(_ handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotFailed("integrity check could not start")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0),
              String(cString: value) == "ok" else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotFailed("integrity check failed")
        }
    }

    private func openEncryptedDatabase(at path: String) throws -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        do {
            try BurnBarDaemonDatabaseCipher.applyKeyIfAvailable(to: handle)
            return handle
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    private func stopWatchersForRestore() {
        stopProjectWatchersForSnapshot()
    }

    private func replaceActiveDatabase(with source: URL, active: URL) throws {
        guard let old = db else {
            throw BurnBarProjectCodeMemoryStoreError.databaseSnapshotUnavailable("database handle is closed")
        }
        sqlite3_close(old)
        db = nil
        for suffix in ["", "-wal", "-shm"] {
            let path = active.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
        let temporary = active.deletingLastPathComponent()
            .appendingPathComponent(".openburnbar-restore-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            try setOwnerOnlyPermissions(temporary)
            try synchronizeFile(temporary)
            try FileManager.default.moveItem(at: temporary, to: active)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
