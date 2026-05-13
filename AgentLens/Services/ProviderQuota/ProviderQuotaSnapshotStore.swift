import Foundation
import OpenBurnBarCore

enum ProviderQuotaPersistenceTarget: String, CaseIterable, Sendable {
    case snapshots
    case routingEvents
    case codexRolloutScanCache

    var label: String {
        switch self {
        case .snapshots:
            return "provider quota snapshot store"
        case .routingEvents:
            return "provider routing event trail"
        case .codexRolloutScanCache:
            return "Codex rollout scan cache"
        }
    }
}

enum ProviderQuotaPersistenceLoadResult<Value> {
    case missing
    case loaded(Value)
    case failed(target: ProviderQuotaPersistenceTarget, message: String)
}

struct ProviderQuotaSnapshotStore {
    let appPaths: OpenBurnBarAppPaths
    let fileManager: FileManager

    func loadPersistedSnapshots() -> ProviderQuotaPersistenceLoadResult<(snapshots: [AgentProvider: ProviderQuotaSnapshot], accountSnapshots: [String: ProviderQuotaSnapshot], lastFetch: Date?)> {
        guard fileManager.fileExists(atPath: appPaths.providerQuotaSnapshotsURL.path) else {
            return .missing
        }
        do {
            let data = try Data(contentsOf: appPaths.providerQuotaSnapshotsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshots = try decoder.decode([ProviderQuotaSnapshot].self, from: data)
            let dict = snapshots.reduce(into: [AgentProvider: ProviderQuotaSnapshot]()) { result, snapshot in
                guard let existing = result[snapshot.provider] else {
                    result[snapshot.provider] = snapshot
                    return
                }
                if snapshot.fetchedAt > existing.fetchedAt {
                    result[snapshot.provider] = snapshot
                }
            }
            let accountSnapshots = Dictionary(
                snapshots.map { (Self.accountSnapshotKey($0), $0) },
                uniquingKeysWith: { lhs, rhs in lhs.fetchedAt >= rhs.fetchedAt ? lhs : rhs }
            )
            let lastFetch = snapshots.map(\.fetchedAt).max()
            return .loaded((dict, accountSnapshots, lastFetch))
        } catch {
            return .failed(
                target: .snapshots,
                message: "OpenBurnBar could not load the persisted \(ProviderQuotaPersistenceTarget.snapshots.label): \(error.localizedDescription)"
            )
        }
    }

    func persistSnapshots(
        _ snapshotsByProvider: [AgentProvider: ProviderQuotaSnapshot],
        accountSnapshots: [String: ProviderQuotaSnapshot] = [:]
    ) {
        do {
            try ensureParentDirectory(for: appPaths.providerQuotaSnapshotsURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let snapshots = Array(
                (Array(snapshotsByProvider.values) + Array(accountSnapshots.values))
                    .reduce(into: [String: ProviderQuotaSnapshot]()) { result, snapshot in
                        let key = Self.accountSnapshotKey(snapshot)
                        guard let existing = result[key] else {
                            result[key] = snapshot
                            return
                        }
                        if snapshot.fetchedAt >= existing.fetchedAt {
                            result[key] = snapshot
                        }
                    }
                    .values
            )
            let data = try encoder.encode(
                snapshots.sorted {
                    if $0.provider.displayName != $1.provider.displayName {
                        return $0.provider.displayName < $1.provider.displayName
                    }
                    return Self.accountSnapshotKey($0) < Self.accountSnapshotKey($1)
                }
            )
            try data.write(to: appPaths.providerQuotaSnapshotsURL, options: .atomic)
        } catch {
            AppLogger.dataStore.silentFailure("ProviderQuotaService: Failed to persist snapshots", error: error)
        }
    }

    static func accountSnapshotKey(_ snapshot: ProviderQuotaSnapshot) -> String {
        if let accountID = snapshot.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty {
            return "\(snapshot.providerID.rawValue):\(accountID)"
        }
        return "\(snapshot.providerID.rawValue):\(snapshot.sourceId)"
    }

    func loadPersistedRoutingEvents(limit: Int? = nil) -> ProviderQuotaPersistenceLoadResult<[ProviderRoutingDecisionEvent]> {
        guard fileManager.fileExists(atPath: appPaths.providerRoutingEventsURL.path) else {
            return .missing
        }
        do {
            let data = try Data(contentsOf: appPaths.providerRoutingEventsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let events = try decoder.decode([ProviderRoutingDecisionEvent].self, from: data)
            let sorted = events.sorted { $0.occurredAt < $1.occurredAt }
            if let limit {
                return .loaded(Array(sorted.suffix(limit)))
            }
            return .loaded(sorted)
        } catch {
            return .failed(
                target: .routingEvents,
                message: "OpenBurnBar could not load the persisted \(ProviderQuotaPersistenceTarget.routingEvents.label): \(error.localizedDescription)"
            )
        }
    }

    func persistRoutingEvents(_ events: [ProviderRoutingDecisionEvent], limit: Int? = nil) {
        do {
            try ensureParentDirectory(for: appPaths.providerRoutingEventsURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let sorted = events.sorted { $0.occurredAt < $1.occurredAt }
            let persisted = limit.map { Array(sorted.suffix($0)) } ?? sorted
            let data = try encoder.encode(persisted)
            try data.write(to: appPaths.providerRoutingEventsURL, options: .atomic)
        } catch {
            AppLogger.dataStore.silentFailure("ProviderQuotaService: Failed to persist routing events", error: error)
        }
    }

    func loadPersistedCodexRolloutScanCache() -> ProviderQuotaPersistenceLoadResult<CodexRolloutScanCache> {
        guard fileManager.fileExists(atPath: appPaths.codexRolloutScanCacheURL.path) else {
            return .missing
        }
        do {
            let data = try Data(contentsOf: appPaths.codexRolloutScanCacheURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return .loaded(try decoder.decode(CodexRolloutScanCache.self, from: data))
        } catch {
            return .failed(
                target: .codexRolloutScanCache,
                message: "OpenBurnBar could not load the persisted \(ProviderQuotaPersistenceTarget.codexRolloutScanCache.label): \(error.localizedDescription)"
            )
        }
    }

    func persistCodexRolloutScanCache(_ cache: CodexRolloutScanCache) {
        do {
            try ensureParentDirectory(for: appPaths.codexRolloutScanCacheURL)
            var updatedCache = cache
            updatedCache.lastUpdatedAt = Date()

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(updatedCache)
            try data.write(to: appPaths.codexRolloutScanCacheURL, options: .atomic)
        } catch {
            AppLogger.dataStore.silentFailure("ProviderQuotaService: Failed to persist codex scan cache", error: error)
        }
    }

    func ensureParentDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func readJSONObject(from url: URL) throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any]
    }

    func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    func modificationDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}
