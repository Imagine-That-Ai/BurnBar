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
/// identical (VAL-API-004).
///
/// Payload parity rule (single documented rule, pinned in
/// `docs/fleet/BURNBAR_FLEET_SIGNALS.md`): **the store persists exactly the
/// same snapshot payload that RPC/file serve for that generation, including
/// `persistenceHealth`.** The well-known file is written first with the final
/// health; the store row is then written with that same payload. When the
/// store write fails, no row exists for that generation (the latest row
/// remains the previous generation) and the failure is surfaced through the
/// served snapshot's `persistenceHealth` — RPC and file always agree, and a
/// sqlite consumer reading the latest row never observes a health that
/// contradicts the served generation. During a writer failure the file
/// intentionally lags (last-good generation, byte-identical) per
/// VAL-FLEET-021 while RPC and the store row agree on the current generation.
///
/// Rebuild-window semantics: after a delete+recreate the store reports
/// `degraded(storeRebuilt)` until the first successful persist publishes the
/// recovery snapshot (RPC + file + store row all carry the degraded health);
/// the degradation clears on the NEXT successful persist after that
/// publication (VAL-HARD-012/013).
///
/// Transition-baseline semantics: `lastPersistedSnapshot` advances ONLY after
/// the store write + event insertion succeed (they run in one transaction).
/// A failed persist never advances the baseline, so a later running-to-idle
/// transition is never lost across a failure.
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
            try fileWriter.reconcile(committedPayload: try store.latestSnapshotPayload())
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
        Self.mergedHealth([combinedHealth, store.currentHealth()])
    }

    /// Reconciles the configured store path with the database handle before
    /// a build. SQLite can keep writing to an unlinked inode after an
    /// external `fleet.sqlite` deletion, so this check must happen while the
    /// daemon remains open rather than waiting for the next process restart.
    /// A successful rebuild also updates the health before the control store
    /// is read, allowing it to discard cached designation/directives.
    public func prepareForBuild() {
        if !store.isOpen {
            do {
                combinedHealth = try store.open()
            } catch {
                combinedHealth = .degraded(
                    reason: BurnBarFleetPersistenceReason.storeUnavailable("\(error)")
                )
            }
            return
        }
        do {
            try store.recoverIfStorePathChanged()
            combinedHealth = store.currentHealth()
        } catch {
            combinedHealth = .degraded(
                reason: BurnBarFleetPersistenceReason.storeUnavailable("\(error)")
            )
        }
    }

    /// Persists one completed snapshot and returns the snapshot to serve
    /// (with the post-persist health embedded). Failures are absorbed into
    /// `persistenceHealth` (typed, non-empty reason) — they never throw into
    /// the ticker and never stop RPC serving. A fully successful persist
    /// clears degradation.
    ///
    /// Ordering (parity rule): the well-known file is written FIRST with the
    /// base health, then the store row is written with that same payload.
    /// When the store write fails, the file is re-written with the final
    /// degraded health so RPC and file stay field-for-field identical; the
    /// store keeps the previous generation as its latest row (a failed
    /// persist never leaves a row for the failed generation). The transition
    /// baseline advances only when the store transaction (snapshot + events)
    /// succeeds.
    @discardableResult
    public func persist(snapshot: BurnBarFleetSnapshot) -> BurnBarFleetSnapshot {
        do {
            try BurnBarFleetStore.validateSnapshot(snapshot)
        } catch {
            combinedHealth = .degraded(reason: "invalid snapshot payload: \(error)")
            return snapshot.withPersistenceHealth(combinedHealth)
        }
        // Transition events: compare against the previous persisted snapshot
        // (fixed-roster model). The first persist records no transitions —
        // there is no prior state to transition from.
        let transitions = lastPersistedSnapshot.map { Self.deriveTransitions(from: $0, to: snapshot) } ?? []

        // Base health: the store's current health (includes any pending
        // rebuild window from a delete+recreate).
        var healths: [BurnBarFleetPersistenceHealth] = [store.currentHealth()]
        var finalSnapshot = snapshot.withPersistenceHealth(Self.mergedHealth(healths))

        do {
            try fileWriter.prepare(snapshot: finalSnapshot)
            Self.pauseAfterFileRenameIfRequested()
        } catch {
            healths.append(.degraded(reason: BurnBarFleetPersistenceReason.fileWriteFailed("\(error)")))
            finalSnapshot = snapshot.withPersistenceHealth(Self.mergedHealth(healths))
        }

        do {
            _ = try store.persistSnapshotAndTransitions(finalSnapshot, transitions: transitions)
            try? fileWriter.commitPrepared()
            // The store write + event insertion succeeded: the baseline
            // advances to this generation.
            lastPersistedSnapshot = finalSnapshot
        } catch {
            // The store row for this generation does not exist; the latest
            // row remains the previous generation (documented parity rule).
            // The baseline does NOT advance, so the next successful persist
            // recomputes the transitions against the last persisted state.
            healths.append(.degraded(reason: BurnBarFleetPersistenceReason.storeWriteFailed("\(error)")))
            finalSnapshot = snapshot.withPersistenceHealth(Self.mergedHealth(healths))
            // Roll back the uncommitted file generation before attempting a
            // compensating store row. A restart must never promote a file
            // whose SQLite generation was not committed.
            try? fileWriter.reconcile(committedPayload: try? store.latestSnapshotPayload())
            // Compensating write: keep the file in parity with the served
            // snapshot. When the file writer is also down, the file stays at
            // the last-good generation (byte-identical) and RPC remains the
            // only current-generation surface (degraded).
            do {
                try fileWriter.prepare(snapshot: finalSnapshot)
                _ = try store.persistSnapshotAndTransitions(finalSnapshot, transitions: transitions)
                try fileWriter.commitPrepared()
                lastPersistedSnapshot = finalSnapshot
            } catch {
                try? fileWriter.reconcile(committedPayload: try? store.latestSnapshotPayload())
            }
        }

        combinedHealth = finalSnapshot.persistenceHealth
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
        do {
            lastPersistedSnapshot = try store.latestSnapshot()
        } catch {
            // A readable row with malformed snapshot JSON is a corrupt
            // persistence store, not an empty baseline. Rebuild through the
            // typed recovery path so the next snapshot discloses the loss
            // instead of silently dropping transition history.
            lastPersistedSnapshot = nil
            do {
                try store.rebuildDatabase(reason: "stored snapshot payload was malformed")
                combinedHealth = store.currentHealth()
            } catch {
                combinedHealth = .degraded(
                    reason: BurnBarFleetPersistenceReason.storeUnavailable("\(error)")
                )
            }
        }
    }

    /// Derives the fixed-roster transitions between two snapshots. The store
    /// records `status_changed` only when the status differs and
    /// `confidence_changed` only when the confidence differs.
    private static func deriveTransitions(
        from previous: BurnBarFleetSnapshot,
        to current: BurnBarFleetSnapshot
    ) -> [BurnBarFleetTransition] {
        var previousByID: [BurnBarFleetAgentID: BurnBarFleetAgent] = [:]
        for agent in previous.agents {
            previousByID[agent.id] = agent
        }
        var transitions: [BurnBarFleetTransition] = []
        for agent in current.agents {
            guard let prior = previousByID[agent.id] else { continue }
            transitions.append(
                BurnBarFleetTransition(
                    agentID: agent.id,
                    fromStatus: prior.status,
                    toStatus: agent.status,
                    fromConfidence: prior.confidence,
                    toConfidence: agent.confidence,
                    at: current.generatedAt
                )
            )
        }
        return transitions
    }

    /// Merges health states: `.ok` when every input is `.ok`, otherwise
    /// `degraded` with the non-empty reasons joined by "; ".
    private static func mergedHealth(_ healths: [BurnBarFleetPersistenceHealth]) -> BurnBarFleetPersistenceHealth {
        var reasons: [String] = []
        for health in healths {
            if case .degraded(let reason) = health {
                if !reasons.contains(reason) {
                    reasons.append(reason)
                }
            }
        }
        return reasons.isEmpty ? .ok : .degraded(reason: reasons.joined(separator: "; "))
    }

    /// Test-only crash-window seam. It pauses after the atomic destination
    /// rename and before the SQLite transaction, allowing a harness-owned
    /// SIGKILL to exercise the commit marker reconciliation protocol.
    private static func pauseAfterFileRenameIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment[
            "BURNBAR_FLEET_PAUSE_AFTER_FILE_RENAME_SECONDS"
        ],
        let seconds = TimeInterval(raw),
        seconds > 0
        else { return }
        Thread.sleep(forTimeInterval: seconds)
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
