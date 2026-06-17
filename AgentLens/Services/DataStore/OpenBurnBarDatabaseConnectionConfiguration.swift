import GRDB

extension OpenBurnBarDatabase {
    static let legacyChatThreadID = "openburnbar-chat-legacy"

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
