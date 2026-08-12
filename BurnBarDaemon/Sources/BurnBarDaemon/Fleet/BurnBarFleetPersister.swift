import BurnBarCore
import Foundation

/// Coordinates the daemon-owned fleet persistence surfaces on every tick:
/// - persists the latest snapshot VERBATIM into `fleet.sqlite` (the payload
///   is the exact JSON of the served snapshot — its `cadenceSeconds` is
///   already the configured cadence, never re-stamped);
/// - records fixed-roster transition events (`status_changed` always,
///   `confidence_changed` when confidence changes) with exact agent/from/to;
/// - atomically writes `fleet-snapshot.json` (tmp + rename, no `.tmp` litter);
/// - surfaces typed degradation through the snapshot's top-level
///   `persistenceHealth` while RPC keeps serving the last completed snapshot
///   and the last-good file stays byte-identical (VAL-FLEET-021).
///
/// The persister is the single owner of `persistenceHealth`: the fleet
/// service asks it for the current health on every build and the builder
/// embeds it in the snapshot. Store/file-writer failures are never hidden in
/// per-agent `probeHealth`.
///
/// Health semantics: the snapshot is built with the health from the previous
/// persist, then persisted. The returned snapshot carries the post-persist
/// health (re-embedded), and the well-known file is written with that same
/// final payload — so the file and the RPC payload are always field-for-field
/// identical (VAL-API-004). The `fleet_snapshots` row carries the payload as
/// written to the store (its health field reflects the store's state at that
/// moment); the two differ only in the `persistenceHealth` field and only
/// when health transitions on that tick.
public final class BurnBarFleetPersister {
    public let store: BurnBarFleetStore
    public let fileWriter: BurnBarFleetFileWriter

    private var combinedHealth: BurnBarFleetPersistenceHealth = .ok
    private var lastPersistedSnapshot: BurnBarFleetSnapshot?

    public init(store: BurnBarFleetStore, fileWriter: BurnBarFleetFileWriter) {
        self.store = store
        self.fileWriter = fileWriter
    }

    /// Opens the store (creating/migrating as needed). Corruption is detected
    /// and recovered (delete + recreate) with typed degradation surfaced via
    /// `persistenceHealth` — the daemon never crashes over a corrupt store.
    /// A non-corrupt open failure also degrades health (typed
    /// `storeUnavailable`) before the error is rethrown.
    public func open() throws {
        do {
            combinedHealth = try store.open()
        } catch {
            combinedHealth = .degraded(reason: BurnBarFleetPersistenceReason.storeUnavailable("\(error)"))
            throw error
        }
    }

    public func close() {
        store.close()
    }

    /// The current combined persistence health (store + file writer).
    public func persistenceHealth() -> BurnBarFleetPersistenceHealth {
        combinedHealth
    }

    /// Persists one completed snapshot and returns the snapshot to serve
    /// (with the post-persist health embedded). Failures are absorbed into
    /// `persistenceHealth` (typed, non-empty reason) — they never throw into
    /// the ticker and never stop RPC serving. A fully successful persist
    /// clears degradation.
    @discardableResult
    public func persist(snapshot: BurnBarFleetSnapshot) -> BurnBarFleetSnapshot {
        var degradedReasons: [String] = []

        do {
            _ = try store.persistLatestSnapshot(snapshot)
        } catch {
            degradedReasons.append(BurnBarFleetPersistenceReason.storeWriteFailed("\(error)"))
        }

        // Transition events: compare against the previous persisted snapshot
        // (fixed-roster model). The first persist records no transitions —
        // there is no prior state to transition from.
        if let previous = lastPersistedSnapshot {
            degradedReasons.append(contentsOf: recordTransitions(from: previous, to: snapshot))
        }
        lastPersistedSnapshot = snapshot

        combinedHealth = degradedReasons.isEmpty
            ? .ok
            : .degraded(reason: degradedReasons.joined(separator: "; "))

        var finalSnapshot = snapshot.withPersistenceHealth(combinedHealth)

        do {
            try fileWriter.write(snapshot: finalSnapshot)
        } catch {
            degradedReasons.append(BurnBarFleetPersistenceReason.fileWriteFailed("\(error)"))
            combinedHealth = .degraded(reason: degradedReasons.joined(separator: "; "))
            finalSnapshot = snapshot.withPersistenceHealth(combinedHealth)
        }

        return finalSnapshot
    }

    /// The last snapshot successfully persisted (used to seed transition
    /// baselines after a daemon restart).
    public var lastPersisted: BurnBarFleetSnapshot? {
        lastPersistedSnapshot
    }

    /// Loads the last persisted snapshot from the store at startup so
    /// transition baselines survive daemon restarts.
    public func loadLastPersistedSnapshot() {
        lastPersistedSnapshot = try? store.latestSnapshot()
    }

    private func recordTransitions(from previous: BurnBarFleetSnapshot, to current: BurnBarFleetSnapshot) -> [String] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.agents.map { ($0.id, $0) })
        var failures: [String] = []
        for agent in current.agents {
            guard let prior = previousByID[agent.id] else { continue }
            do {
                try store.recordTransition(
                    agentID: agent.id,
                    fromStatus: prior.status,
                    toStatus: agent.status,
                    fromConfidence: prior.confidence,
                    toConfidence: agent.confidence,
                    at: current.generatedAt
                )
            } catch {
                // A transition-record failure degrades the store health; the
                // snapshot itself still persists.
                failures.append(
                    BurnBarFleetPersistenceReason.storeWriteFailed("transition record: \(error)")
                )
            }
        }
        return failures
    }
}

extension BurnBarFleetSnapshot {
    /// Returns a copy of this snapshot with a different `persistenceHealth`
    /// (all other fields identical).
    func withPersistenceHealth(_ health: BurnBarFleetPersistenceHealth) -> BurnBarFleetSnapshot {
        BurnBarFleetSnapshot(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            cadenceSeconds: cadenceSeconds,
            machine: machine,
            agents: agents,
            repos: repos,
            runningCount: runningCount,
            countsByAgent: countsByAgent,
            orchestrator: orchestrator,
            probeHealth: probeHealth,
            persistenceHealth: health
        )
    }
}
