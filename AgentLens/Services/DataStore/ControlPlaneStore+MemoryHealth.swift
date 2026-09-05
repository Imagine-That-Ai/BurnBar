import Foundation
@preconcurrency import GRDB
import OpenBurnBarKernel

// MARK: - App-producible memory-health inputs

/// One link of the `memory_audit` hash chain: the seq it sits at, the hash it
/// claims its predecessor had, and its own hash.
struct MemoryAuditChainLink: Equatable, Sendable {
    let seq: Int
    let prevHash: String?
    let hash: String
}

/// Everything the health card can measure WITHOUT the engine.
///
/// Deliberately no doctor findings: `burnbar_memory_doctor` runs inside the
/// engine, against the engine's own store, and nothing in this process can run
/// it. The card says so rather than presenting an absence as a clean bill.
struct MemoryHealthLocalSnapshot: Equatable, Sendable {
    /// The tail of the audit chain, oldest first. Bounded — see
    /// `ControlPlaneStore.memoryAuditChainWindow` — so opening Settings never
    /// walks an unbounded ledger.
    let auditChainLinks: [MemoryAuditChainLink]
    /// Rows still waiting for a human in the review inbox.
    let pendingReviewCount: Int
    /// When `memory_facts` was last pulled down for this account.
    let lastMemoryFactsPullAt: Date?
    /// When the device-sync consent marker was last rewritten. Nil when device
    /// sync is not consented on this Mac, which is not a fault.
    let deviceSyncMarkerRefreshedAt: Date?
}

extension ControlPlaneStore {

    /// How many audit links the health check walks. The chain is global rather
    /// than per-memory, so an unbounded walk would grow without limit; the check
    /// is honest about being a tail check.
    static let memoryAuditChainWindow = 500

    /// Reads every health input the app can produce on its own.
    ///
    /// - Parameter accountUid: the signed-in member, for the `memory_facts`
    ///   watermark. Nil when nobody is signed in — the pull age is then simply
    ///   absent, which the card renders as "—" rather than as "never".
    func memoryHealthLocalSnapshot(accountUid: String?) async throws -> MemoryHealthLocalSnapshot {
        try await dbQueue.read { db -> MemoryHealthLocalSnapshot in
            // Ordered by seq DESC to take the TAIL, then reversed so the walk
            // reads oldest-first the way the chain was written.
            let linkRows = try Row.fetchAll(
                db,
                sql: """
                SELECT seq, prev_hash, hash
                FROM memory_audit
                ORDER BY seq DESC
                LIMIT ?
                """,
                arguments: [Self.memoryAuditChainWindow]
            )
            let links: [MemoryAuditChainLink] = linkRows.reversed().map { row in
                MemoryAuditChainLink(
                    seq: row["seq"] ?? 0,
                    prevHash: row["prev_hash"],
                    hash: row["hash"] ?? ""
                )
            }

            let pending = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agent_memories WHERE review_status = 'quarantined'"
            ) ?? 0

            var lastPull: Date?
            if let accountUid {
                lastPull = try Date.fetchOne(
                    db,
                    sql: """
                    SELECT lastProcessedRemoteUpdateAt FROM remote_sync_watermarks
                    WHERE accountUid = ? AND collectionKind = ?
                    """,
                    arguments: [accountUid, RemoteSyncCollectionKind.memoryFacts.rawValue]
                )
            }

            let markerRefreshedAt = try Date.fetchOne(
                db,
                sql: """
                SELECT \(BurnBarMemoryDeviceSyncMarker.refreshedAtColumn)
                FROM \(BurnBarMemoryDeviceSyncMarker.tableName)
                WHERE \(BurnBarMemoryDeviceSyncMarker.kindColumn) = ?
                ORDER BY \(BurnBarMemoryDeviceSyncMarker.refreshedAtColumn) DESC
                LIMIT 1
                """,
                arguments: [BurnBarMemoryDeviceSyncMarker.collectionKind]
            )

            return MemoryHealthLocalSnapshot(
                auditChainLinks: links,
                pendingReviewCount: pending,
                lastMemoryFactsPullAt: lastPull,
                deviceSyncMarkerRefreshedAt: markerRefreshedAt
            )
        }
    }
}
