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

    /// Writes `snapshot` atomically (tmp + rename). Throws on failure; the
    /// destination file is never partially replaced and the tmp file is
    /// removed on failure so no `.tmp` litter survives.
    public func write(snapshot: BurnBarFleetSnapshot) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot)

        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let temporaryPath = temporaryURL.path
        do {
            try data.write(to: URL(fileURLWithPath: temporaryPath))
            try Self.atomicReplace(from: temporaryPath, to: fileURL.path)
        } catch {
            try? FileManager.default.removeItem(atPath: temporaryPath)
            throw error
        }
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
}
