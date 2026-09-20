import Foundation
@preconcurrency import GRDB
import OpenBurnBarKernel

// MARK: - Memory sync observability inputs (E19, app half)

/// Everything the sync-status row reports, read from state this Mac already
/// keeps. No new table, no new counter, no new RPC — see the standing rule on
/// what an app SQLite table costs.
///
/// Every field is optional for the same reason the health card's counters are:
/// a value this Mac did not observe renders `—`, never `0`. "Nobody is signed
/// in, so there is no watermark to age" and "the watermark is at the epoch" are
/// different statements, and only one of them is a fault.
///
/// The two queries behind it — the per-kind watermark and the consent marker —
/// are the SHARED ones on `ControlPlaneStore+MemoryHealth`, so this surface and
/// the health card above it can never disagree about what they read.
struct MemorySyncObservabilitySnapshot: Equatable, Sendable {
    /// The member this snapshot was read for, or nil when nobody is signed in.
    /// Carried so the row can compare it against the member the consent marker
    /// names without reaching back into the account manager.
    let accountUid: String?

    /// `remote_sync_watermarks.lastSyncedAt` for `memory_facts` — when a pull
    /// last COMMITTED at least one document on this Mac.
    let memoryFactsWatermarkAt: Date?

    /// The same, for `memory_forget_receipts`. It has its OWN cursor because
    /// receipts are ordered by `replicatedAt` and facts by `updatedAt`
    /// (`RemoteSyncCollectionKind.memoryForgetReceipts`), so one channel can be
    /// healthy while the other is stalled — which is exactly why this row
    /// reports both instead of picking one.
    let forgetReceiptsWatermarkAt: Date?

    /// The device-sync consent marker exactly as the daemon reads it: the one
    /// row, or nothing. An ambiguous table is `absent`, never a winner.
    let deviceSyncMarker: MemoryDeviceSyncMarkerReading

    /// Rows parked in `agent_memory_inbox` that the engine has not merged yet.
    /// Nil when nobody is signed in, so the count cannot be scoped to a member.
    let parkedInboxRows: Int?

    /// Rows the engine HAS merged and that the daemon's 30-day sweep has not
    /// reclaimed yet. A window, not a lifetime total, and labelled as one.
    let mergedInboxRows: Int?

    init(
        accountUid: String? = nil,
        memoryFactsWatermarkAt: Date? = nil,
        forgetReceiptsWatermarkAt: Date? = nil,
        deviceSyncMarker: MemoryDeviceSyncMarkerReading = .absent,
        parkedInboxRows: Int? = nil,
        mergedInboxRows: Int? = nil
    ) {
        self.accountUid = accountUid
        self.memoryFactsWatermarkAt = memoryFactsWatermarkAt
        self.forgetReceiptsWatermarkAt = forgetReceiptsWatermarkAt
        self.deviceSyncMarker = deviceSyncMarker
        self.parkedInboxRows = parkedInboxRows
        self.mergedInboxRows = mergedInboxRows
    }
}

extension ControlPlaneStore {

    /// Reads both transport watermarks, the consent marker, and the two inbox
    /// counts in ONE read transaction, so the row can never render a watermark
    /// from before a sweep beside a count from after it.
    ///
    /// - Parameter accountUid: the signed-in member. Nil when nobody is signed
    ///   in — the watermarks and the inbox counts are then simply absent, which
    ///   the row renders as `—`.
    func memorySyncObservabilitySnapshot(accountUid: String?) async throws -> MemorySyncObservabilitySnapshot {
        try await dbQueue.read { db -> MemorySyncObservabilitySnapshot in
            var parked: Int?
            var merged: Int?
            if let accountUid {
                parked = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM agent_memory_inbox WHERE user_id = ? AND applied_at IS NULL",
                    arguments: [accountUid]
                )
                merged = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM agent_memory_inbox WHERE user_id = ? AND applied_at IS NOT NULL",
                    arguments: [accountUid]
                )
            }

            return MemorySyncObservabilitySnapshot(
                accountUid: accountUid,
                memoryFactsWatermarkAt: try Self.memoryRemoteSyncWatermark(
                    db,
                    accountUid: accountUid,
                    kind: .memoryFacts
                ),
                forgetReceiptsWatermarkAt: try Self.memoryRemoteSyncWatermark(
                    db,
                    accountUid: accountUid,
                    kind: .memoryForgetReceipts
                ),
                deviceSyncMarker: try Self.memoryDeviceSyncMarkerReading(db),
                parkedInboxRows: parked,
                mergedInboxRows: merged
            )
        }
    }
}
