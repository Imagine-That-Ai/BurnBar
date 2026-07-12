import Foundation
import OpenBurnBarCore

/// Durable high-water marks for phone-signed Computer Use approval counters.
/// A corrupt existing store is distinguishable from first run so callers can
/// fail closed instead of silently resetting replay authority after restart.
public final class DaemonComputerUseApprovalReplayCounterStore: Sendable {
    public enum LoadOutcome: Sendable {
        case absent
        case loaded([String: UInt64])
        case unreadable
    }

    public enum CommitOutcome: Sendable, Equatable {
        case committed(UInt64)
        case replay(lastSeen: UInt64)
    }

    private struct Snapshot: Codable {
        let version: Int
        let counters: [String: UInt64]
    }

    // Approval and session-grant verifiers share one counter file and therefore
    // must also share one in-process read-modify-write lock for that file.
    private static let fileStates = Locked([String: Locked<[String: UInt64]>]())

    private let fileURL: URL?
    private let state: Locked<[String: UInt64]>

    public init(fileURL: URL? = nil) {
        let canonicalFileURL = fileURL?.standardizedFileURL
        self.fileURL = canonicalFileURL
        if let canonicalFileURL {
            self.state = Self.fileStates.withLock { states in
                let key = canonicalFileURL.path
                if let existing = states[key] {
                    return existing
                }
                let created = Locked([String: UInt64]())
                states[key] = created
                return created
            }
        } else {
            self.state = Locked([String: UInt64]())
        }
    }

    public static func production() -> DaemonComputerUseApprovalReplayCounterStore {
        DaemonComputerUseApprovalReplayCounterStore(
            fileURL: BurnBarDaemonPaths.supportDirectoryURL
                .appendingPathComponent("security", isDirectory: true)
                .appendingPathComponent("computer-use-approval-counters.json", isDirectory: false)
        )
    }

    public func loadOutcome() -> LoadOutcome {
        state.withLock { memory in
            guard let fileURL else { return .loaded(memory) }
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
            do {
                let snapshot = try Self.read(fileURL)
                memory = snapshot
                return .loaded(snapshot)
            } catch {
                return .unreadable
            }
        }
    }

    public func commit(peerNodeID: String, counter: UInt64) throws -> CommitOutcome {
        try state.withLock { memory in
            let normalizedPeer = peerNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedPeer.isEmpty == false, counter > 0 else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            var counters: [String: UInt64]
            if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                counters = try Self.read(fileURL)
            } else {
                counters = memory
            }
            let lastSeen = counters[normalizedPeer] ?? 0
            guard counter > lastSeen else {
                return CommitOutcome.replay(lastSeen: lastSeen)
            }
            counters[normalizedPeer] = counter
            if let fileURL {
                try Self.write(counters, to: fileURL)
            }
            memory = counters
            return CommitOutcome.committed(counter)
        }
    }

    private static func read(_ fileURL: URL) throws -> [String: UInt64] {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.version == 1,
              snapshot.counters.keys.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return snapshot.counters
    }

    private static func write(_ counters: [String: UInt64], to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Snapshot(version: 1, counters: counters))
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
