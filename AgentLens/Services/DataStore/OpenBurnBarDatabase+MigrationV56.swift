import GRDB

extension OpenBurnBarDatabase {
    /// Stores parser input identities separately from the compact checkpoint.
    /// The normalized manifest avoids rewriting an unbounded token each tick.
    /// Rows may precede the first watermark while a byte-bounded cold scan converges.
    static func registerParserCheckpointFileManifestMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v56_parser_checkpoint_file_manifest") { db in
            guard try db.tableExists("parser_checkpoints") else { return }
            try db.create(table: "parser_checkpoint_files", ifNotExists: true) { t in
                t.column("provider", .text).notNull()
                t.column("path", .text).notNull()
                t.column("fileSizeBytes", .integer)
                t.column("modificationDate", .datetime)
                t.column("creationDate", .datetime)
                // Foundation exposes these as UInt64; TEXT preserves the full
                // range instead of overflowing SQLite's signed INTEGER.
                t.column("fileSystemNumber", .text)
                t.column("fileNumber", .text)
                t.primaryKey(["provider", "path"])
            }
        }
    }
}
