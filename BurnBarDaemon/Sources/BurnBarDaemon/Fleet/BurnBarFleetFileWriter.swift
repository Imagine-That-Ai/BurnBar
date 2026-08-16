import BurnBarCore
import Darwin
import Foundation

/// Atomic writer for the well-known `fleet-snapshot.json` file.
///
/// Every write goes to `fleet-snapshot.json.tmp` first, then a POSIX
/// `rename(2)` atomically replaces the destination. A reader can therefore
/// only ever observe a complete file (the preceding complete generation
/// during the short replace window — never a partial write), and no `.tmp`
/// file remains after a completed write (VAL-FLEET-012 / VAL-API-005).
///
/// The payload is the exact JSON of the last completed snapshot — identical
/// to the last completed RPC response payload (VAL-API-004). On failure the
/// last-good file is left byte-identical and the failure is surfaced through
/// `persistenceHealth` (VAL-FLEET-021).
public struct BurnBarFleetFileWriter: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The deterministic temporary path used for the atomic replace.
    public var temporaryURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(BurnBarFleetPersistenceConstants.snapshotTemporaryFileName)
    }

    private var commitMarkerURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).commit")
    }

    private var previousURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).previous")
    }

    /// Installs a recoverable file generation. The marker is written before
    /// rename, so a crash after rename but before SQLite commit is
    /// distinguishable from a completed generation on restart.
    public func prepare(snapshot: BurnBarFleetSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: previousURL)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.copyItem(at: fileURL, to: previousURL)
        }
        let marker = CommitMarker(generatedAt: snapshot.generatedAt.timeIntervalSince1970)
        try JSONEncoder().encode(marker).write(to: commitMarkerURL)
        do {
            try data.write(to: temporaryURL)
            try Self.atomicReplace(from: temporaryURL.path, to: fileURL.path)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            try? fileManager.removeItem(at: commitMarkerURL)
            try? fileManager.removeItem(at: previousURL)
            throw error
        }
    }

    /// Completes the two-phase file/store commit and removes recovery
    /// metadata. This is intentionally called only after SQLite succeeds.
    public func commitPrepared() throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: commitMarkerURL)
        try? fileManager.removeItem(at: previousURL)
        try? fileManager.removeItem(at: temporaryURL)
    }

    /// Reconciles a marker left by SIGKILL. The destination is accepted only
    /// when it is byte-identical to the latest committed SQLite payload;
    /// otherwise the previous complete file is restored.
    public func reconcile(committedPayload: String?) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: commitMarkerURL.path) else {
            try? fileManager.removeItem(at: temporaryURL)
            return
        }
        let committedData = committedPayload?.data(using: .utf8)
        let destination = try? Data(contentsOf: fileURL)
        if let committedData, destination == committedData {
            try commitPrepared()
            return
        }
        if fileManager.fileExists(atPath: previousURL.path) {
            try Self.atomicReplace(from: previousURL.path, to: fileURL.path)
        } else {
            try? fileManager.removeItem(at: fileURL)
        }
        try commitPrepared()
    }

    /// Writes `snapshot` atomically (tmp + rename). Throws on failure; the
    /// destination file is never partially replaced and the tmp file is
    /// removed on failure so no `.tmp` litter survives.
    public func write(snapshot: BurnBarFleetSnapshot) throws {
        try prepare(snapshot: snapshot)
        try commitPrepared()
    }

    /// `rename(2)`: atomic on the same filesystem. Replaces the destination
    /// in one step — a concurrent reader sees either the old or the new
    /// complete file, never a partial one.
    private static func atomicReplace(from sourcePath: String, to destinationPath: String) throws {
        let result = sourcePath.withCString { source in
            destinationPath.withCString { destination in
                rename(source, destination)
            }
        }
        guard result == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private struct CommitMarker: Codable {
        let generatedAt: TimeInterval
    }
}
