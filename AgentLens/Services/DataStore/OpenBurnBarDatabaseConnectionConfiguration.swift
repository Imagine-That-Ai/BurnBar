import Foundation
import GRDB

extension OpenBurnBarDatabase {
    static let legacyChatThreadID = "openburnbar-chat-legacy"

    /// Production `DatabasePool` knobs. EQP on a migrated on-disk pool showed
    /// unsynced rows already use `token_usage_sync_pending_idx`; the chart /
    /// dashboard intersection predicate is not covering-indexable without a
    /// new migration. Extra readers hide WAL write-lock stalls instead.
    enum PoolTuning {
        static let maximumReaderCount = 8
        static let busyTimeoutSeconds: TimeInterval = 5
    }

    static func applyPoolTuning(_ config: inout Configuration) {
        config.maximumReaderCount = PoolTuning.maximumReaderCount
        config.busyMode = .timeout(PoolTuning.busyTimeoutSeconds)
    }

    /// Post-open WAL mode configuration (idempotent).
    /// WAL is automatically enabled by GRDB's DatabasePool, but we explicitly
    /// tune the checkpoint threshold for our workload.
    static func configureWALMode(_ dbQueue: any DatabaseWriter) throws {
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
        }
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
    }
}
