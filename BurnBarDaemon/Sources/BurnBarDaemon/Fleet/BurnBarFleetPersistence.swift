import BurnBarCore
import Foundation

/// Shared constants and helpers for the daemon-owned fleet persistence layer
/// (fleet.sqlite store + atomic well-known-file writer).
///
/// The top-level `persistenceHealth` field on every snapshot is the single
/// documented surface for both the SQLite store and the well-known-file
/// writer (VAL-FLEET-021). Typed degradation never stops the RPC path: reads
/// keep serving the last completed snapshot while the store/file writer
/// report their failure.
public enum BurnBarFleetPersistenceConstants {
    /// Default fleet-event retention: exactly 24 hours.
    public static let defaultEventRetentionSeconds: TimeInterval = 24 * 60 * 60
    /// Completed snapshot payloads retained in `fleet_snapshots`
    /// (240 ≈ 1 hour at the default 15s cadence).
    public static let defaultSnapshotRetentionCount = 240
    /// The well-known file name (also used to detect tmp litter).
    public static let snapshotFileName = "fleet-snapshot.json"
    /// The atomic-write temp name; must never remain after a completed write.
    public static let snapshotTemporaryFileName = "fleet-snapshot.json.tmp"
}

/// Reason strings for `persistenceHealth` degradation. Reasons are non-empty
/// and non-secret; they surface in snapshots and logs.
public enum BurnBarFleetPersistenceReason {
    /// The fleet.sqlite store could not be opened or migrated.
    public static func storeUnavailable(_ detail: String) -> String {
        "fleet.sqlite store unavailable: \(detail)"
    }

    /// The latest snapshot could not be persisted to fleet.sqlite.
    public static func storeWriteFailed(_ detail: String) -> String {
        "fleet.sqlite snapshot write failed: \(detail)"
    }

    /// The store was not trusted and was rebuilt after corruption, schema
    /// mismatch, or external deletion (deletion discards orchestration
    /// history and re-initializes designation to none — disclosed in docs).
    public static func storeRebuilt(_ detail: String) -> String {
        "fleet.sqlite was rebuilt (orchestration history discarded): \(detail)"
    }

    /// The well-known file could not be written atomically.
    public static func fileWriteFailed(_ detail: String) -> String {
        "fleet-snapshot.json write failed: \(detail)"
    }
}
