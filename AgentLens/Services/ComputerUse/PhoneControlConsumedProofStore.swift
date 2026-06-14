import Foundation
import os

/// File-backed record of consumed single-use local-auth proof IDs.
///
/// SECURITY (L9): the validator marks each local-auth proof ID single-use, but the
/// in-memory set reset on restart, so "single-use" was only per-process. A proof is
/// valid for at most the request TTL, so persisting consumed IDs (with their expiry)
/// closes the restart reuse window for the proof itself — belt-and-suspenders behind
/// the persisted, strictly-monotonic replay counter. Expired entries are pruned on
/// every load/record so the file stays bounded.
public final class PhoneControlConsumedProofStore: Sendable {
    private static let logger = Logger(subsystem: "com.openburnbar.app", category: "PhoneControlConsumedProofStore")

    private struct SnapshotFile: Codable {
        var version: Int
        var proofs: [String: Date] // proofId -> expiresAt
        var updatedAt: Date
    }

    private static let currentVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.openburnbar.phoneControl.consumedProofStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL = PhoneControlConsumedProofStore.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public static func defaultStore() -> PhoneControlConsumedProofStore {
        PhoneControlConsumedProofStore()
    }

    /// Returns the set of proof IDs that are still within their validity window.
    /// Expired entries are pruned from disk as a side effect.
    public func loadActiveProofIds(now: Date = Date()) -> Set<String> {
        queue.sync {
            let stored = readUnlockedOrEmpty()
            let active = stored.filter { $0.value > now }
            if active.count != stored.count {
                writeUnlockedBestEffort(active)
            }
            return Set(active.keys)
        }
    }

    /// Persist a newly consumed proof ID with its expiry (best-effort). Prunes
    /// expired entries while writing.
    public func record(proofId: String, expiresAt: Date, now: Date = Date()) {
        guard proofId.isEmpty == false else { return }
        queue.sync {
            var stored = readUnlockedOrEmpty()
            stored = stored.filter { $0.value > now }
            stored[proofId] = expiresAt
            writeUnlockedBestEffort(stored)
        }
    }

    // Persistence is best-effort by design: a read/write failure degrades to the
    // in-memory replay set (pre-L9 behavior), never blocks proof validation, but
    // must be visible in the log rather than silently swallowed.
    private func readUnlockedOrEmpty() -> [String: Date] {
        do {
            return try readUnlocked()
        } catch {
            Self.logger.error("Failed to read consumed-proof snapshot: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private func writeUnlockedBestEffort(_ proofs: [String: Date]) {
        do {
            try writeUnlocked(proofs)
        } catch {
            Self.logger.error("Failed to persist consumed-proof snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readUnlocked() throws -> [String: Date] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        let snapshot = try decoder.decode(SnapshotFile.self, from: data)
        return snapshot.proofs.filter { $0.key.isEmpty == false }
    }

    private func writeUnlocked(_ proofs: [String: Date]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let snapshot = SnapshotFile(
            version: Self.currentVersion,
            proofs: proofs.filter { $0.key.isEmpty == false },
            updatedAt: Date()
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Self.logger.warning("Could not tighten consumed-proof file permissions: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("com.openburnbar.AgentLens", isDirectory: true)
            .appendingPathComponent("phone-control-consumed-proofs.json", isDirectory: false)
    }
}
