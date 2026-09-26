import Foundation
import OpenBurnBarEngine
#if !os(Linux)
import GRDB
#endif

// MARK: - Switcher Active Profile App Lane (Wave 2.1c-v)

/// The daemon-owned write path for the app lane of `switcher_active_profile`
/// (ADR-005).
///
/// The app finalizes every write locally — the per-provider mirror lookup
/// and the fallback selection are computed against its local reads of the
/// app-owned `switcher_profiles` table — and this lane applies the resulting
/// sets verbatim inside one transaction per apply. The daemon assigns the
/// `updatedAt` stamps (`Date()` bound through GRDB, exactly as the app's
/// pre-cutover writes did), so no timestamps ride the wire.
///
/// The pre-existing `setActiveProfileID` setters delegate here, so this lane
/// is the single choke point for every daemon-side write to the table: RPC
/// callers get throwing semantics (validation failures surface as
/// `invalidParams` at the handler), while the legacy void setters keep their
/// silent-failure contract for the CLI launch path.
///
/// Linux serves the same contract from its in-memory store (uniform
/// validation, uniform response shape); only durability differs, matching
/// the Linux store's documented PATH-discovery posture.
extension BurnBarSwitcherSQLiteProfileStore {
    enum ActiveProfileLaneError: Error, LocalizedError {
        case invalidRequest(String)

        var errorDescription: String? {
            switch self {
            case .invalidRequest(let detail):
                return "Invalid switcher active-profile request: \(detail)"
            }
        }
    }

    /// Fail-closed bound on one apply: the only multi-set caller is the
    /// global setter (global pointer + per-provider mirror), so a batch past
    /// this is a runaway caller, not a switch. Rejected before any write, so
    /// no partial apply is possible.
    static let activeProfileLaneMaxSetsPerApply = 2

    /// A validated apply: sets with normalized provider spellings plus the
    /// optional clear. Normalization is a no-op for well-behaved callers (the
    /// app sends `ProviderID.rawValue`, already normalized) and keeps direct
    /// socket callers from storing denormalized spellings beside them.
    struct ValidatedActiveProfileApply {
        struct ValidatedSet {
            let profileID: String?
            let providerID: String?
        }

        let sets: [ValidatedSet]
        let clearProfileID: String?
    }

    static func validateActiveProfileApply(
        _ request: BurnBarSwitcherActiveProfileApplyRequest
    ) throws -> ValidatedActiveProfileApply {
        guard request.sets.isEmpty == false || request.clearProfileID != nil else {
            throw ActiveProfileLaneError.invalidRequest("apply carries no sets or clear")
        }
        guard request.sets.count <= activeProfileLaneMaxSetsPerApply else {
            throw ActiveProfileLaneError.invalidRequest(
                "sets count \(request.sets.count) exceeds \(activeProfileLaneMaxSetsPerApply)"
            )
        }
        if let clearID = request.clearProfileID, clearID.isEmpty {
            throw ActiveProfileLaneError.invalidRequest("clearProfileID is empty")
        }
        let sets = try request.sets.map { set -> ValidatedActiveProfileApply.ValidatedSet in
            if let profileID = set.profileID, profileID.isEmpty {
                throw ActiveProfileLaneError.invalidRequest("set profileID is empty (clearing is spelled nil)")
            }
            let providerID = try set.providerID.map { raw -> String in
                let normalized = ProviderID.normalize(raw)
                guard normalized.isEmpty == false else {
                    throw ActiveProfileLaneError.invalidRequest("set providerID is empty")
                }
                return normalized
            }
            return ValidatedActiveProfileApply.ValidatedSet(profileID: set.profileID, providerID: providerID)
        }
        return ValidatedActiveProfileApply(sets: sets, clearProfileID: request.clearProfileID)
    }
}

#if !os(Linux)
extension BurnBarSwitcherSQLiteProfileStore {
    /// Applies one validated active-profile batch: clear-by-profile first,
    /// then the sets in order, inside a single transaction. Each set rewrites
    /// exactly one row (DELETE the scope, INSERT the new pointer), so a set
    /// also heals any legacy duplicate rows its scope accumulated — the
    /// app's pre-cutover fetch-time dedup is subsumed by this.
    ///
    /// No pre-v46 fallback: the migrator owns the `providerID` column (v46,
    /// far below the current schema version) and the daemon bootstrap
    /// self-heals it via `ensureDrainTargetColumn`, so the column is
    /// guaranteed at lane time. A database without it is a schema violation
    /// and fails loudly here (rolled back) instead of silently writing rows
    /// the per-provider readers can never match.
    func switcherActiveProfileApply(
        _ request: BurnBarSwitcherActiveProfileApplyRequest
    ) throws -> BurnBarSwitcherActiveProfileApplyResponse {
        let validated = try Self.validateActiveProfileApply(request)
        return try dbQueue.write { db in
            var rowsCleared = 0
            // Fixed order: clear first, then sets. The app never combines a
            // clear with sets in one call today; the contract pins the order
            // so any future combined caller can reason about it.
            if let clearID = validated.clearProfileID {
                // Byte-identical to the app's pre-cutover delete-profile
                // clear: every row pointing at the deleted profile, in the
                // global and per-provider scopes alike (no providerID
                // predicate — the NULL comparison would exclude globals).
                try db.execute(
                    sql: """
                    UPDATE switcher_active_profile
                    SET activeProfileID = NULL, updatedAt = ?
                    WHERE activeProfileID = ?
                    """,
                    arguments: [Date(), clearID]
                )
                rowsCleared = db.changesCount
            }
            for set in validated.sets {
                try Self.writeActiveProfilePointer(
                    db,
                    profileID: set.profileID,
                    providerID: set.providerID
                )
            }
            return BurnBarSwitcherActiveProfileApplyResponse(
                setsApplied: validated.sets.count,
                rowsCleared: rowsCleared
            )
        }
    }

    /// Rewrites the one pointer row for a scope: the global pointer when
    /// `providerID` is nil, else that provider's drain target. Mirrors the
    /// app's pre-cutover setters statement for statement.
    static func writeActiveProfilePointer(
        _ db: Database,
        profileID: String?,
        providerID: String?
    ) throws {
        let now = Date()
        if let providerID {
            try db.execute(
                sql: "DELETE FROM switcher_active_profile WHERE providerID = ?",
                arguments: [providerID]
            )
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, providerID, updatedAt) VALUES (?, ?, ?)",
                arguments: [profileID, providerID, now]
            )
        } else {
            try db.execute(sql: "DELETE FROM switcher_active_profile WHERE providerID IS NULL")
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, providerID, updatedAt) VALUES (?, NULL, ?)",
                arguments: [profileID, now]
            )
        }
    }
}
#else
extension BurnBarSwitcherSQLiteProfileStore {
    /// Linux serves the lane from the in-memory store: same validation, same
    /// response shape, same clear-before-sets order. Per-provider drain
    /// targets live in `drainTargets` so RPC semantics stay uniform across
    /// platforms; only durability differs (in-memory, like the rest of the
    /// Linux store).
    func switcherActiveProfileApply(
        _ request: BurnBarSwitcherActiveProfileApplyRequest
    ) throws -> BurnBarSwitcherActiveProfileApplyResponse {
        let validated = try Self.validateActiveProfileApply(request)
        return lock.withLock { state in
            var rowsCleared = 0
            if let clearID = validated.clearProfileID {
                if state.activeID == clearID {
                    state.activeID = nil
                    rowsCleared += 1
                }
                let clearedProviders = state.drainTargets.filter { $0.value == clearID }.map(\.key)
                for provider in clearedProviders {
                    state.drainTargets[provider] = nil
                    rowsCleared += 1
                }
            }
            for set in validated.sets {
                if let providerID = set.providerID {
                    if let profileID = set.profileID {
                        state.drainTargets[providerID] = profileID
                    } else {
                        state.drainTargets[providerID] = nil
                    }
                } else {
                    state.activeID = set.profileID
                }
            }
            return BurnBarSwitcherActiveProfileApplyResponse(
                setsApplied: validated.sets.count,
                rowsCleared: rowsCleared
            )
        }
    }
}
#endif
