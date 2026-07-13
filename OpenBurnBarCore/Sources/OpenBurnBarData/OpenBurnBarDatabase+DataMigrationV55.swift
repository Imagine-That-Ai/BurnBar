import GRDB

extension OpenBurnBarDatabase {
    /// `v55_search_chunks_fts_rowid` — parity mirror of the app-side migration
    /// (`AgentLens/Services/DataStore/OpenBurnBarDatabase+MigrationV55.swift`).
    /// The Windows/Linux open-side reuses the same encrypted SQLite file the Mac
    /// writes, so this shared-schema data layer must reach the identical endpoint:
    /// the `ftsRowid` mapping column on `search_chunks` plus the content-gated FTS
    /// update triggers. `search_chunks_fts` keys (`chunkID`, `documentID`) are
    /// UNINDEXED FTS5 columns, so deleting by them full-scans the whole FTS
    /// content table; recording the FTS rowid keeps deletes O(log n).
    static func registerSearchChunksFTSRowidMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v55_search_chunks_fts_rowid") { db in
            // Every block is guarded on table existence: real databases
            // migrated through v21+ always have these tables, but synthetic
            // ledgers (test seeds that fake grdb_migrations over a minimal
            // schema) may not, and each optimization is independently safe
            // to skip.

            if try db.tableExists("search_chunks") {
                try db.execute(sql: "ALTER TABLE search_chunks ADD COLUMN ftsRowid INTEGER")

                // Backfill in a single pass over the FTS5 shadow content table
                // (`id` = fts rowid, `c0` = first declared column, chunkID;
                // `c3` = chunkText). Reading the shadow table directly avoids
                // the virtual-table row materialization.
                if try db.tableExists("search_chunks_fts_content") {
                    try db.execute(
                        sql: """
                        CREATE TEMP TABLE search_chunks_fts_rowid_map AS
                        SELECT id AS ftsRowid, c0 AS chunkID, c3 AS chunkText FROM search_chunks_fts_content
                        """
                    )
                    try db.execute(
                        sql: "CREATE INDEX search_chunks_fts_rowid_map_idx ON search_chunks_fts_rowid_map(chunkID)"
                    )
                    try db.execute(
                        sql: """
                        UPDATE search_chunks
                        SET ftsRowid = (
                            SELECT m.ftsRowid FROM search_chunks_fts_rowid_map AS m
                            WHERE m.chunkID = search_chunks.id
                            ORDER BY
                                CASE WHEN m.chunkText = search_chunks.text THEN 0 ELSE 1 END,
                                m.ftsRowid DESC
                            LIMIT 1
                        )
                        """
                    )
                    try db.execute(
                        sql: """
                        DELETE FROM search_chunks_fts WHERE rowid IN (
                            SELECT m.ftsRowid FROM search_chunks_fts_rowid_map AS m
                            WHERE NOT EXISTS (
                                SELECT 1 FROM search_chunks AS c
                                WHERE c.id = m.chunkID AND c.ftsRowid = m.ftsRowid
                            )
                        )
                        """
                    )
                    try db.execute(sql: "DROP TABLE search_chunks_fts_rowid_map")
                }
            }

            if try db.tableExists("search_documents"), try db.tableExists("search_documents_fts") {
                try db.execute(sql: "DROP TRIGGER IF EXISTS search_documents_fts_au")
                try db.execute(sql: """
                    CREATE TRIGGER search_documents_fts_au AFTER UPDATE ON search_documents
                    WHEN old.title IS NOT new.title
                      OR old.subtitle IS NOT new.subtitle
                      OR old.bodyPreview IS NOT new.bodyPreview
                      OR old.projectName IS NOT new.projectName
                      OR old.provider IS NOT new.provider
                    BEGIN
                        DELETE FROM search_documents_fts WHERE documentID = old.id;
                        INSERT INTO search_documents_fts(documentID, title, subtitle, bodyPreview, projectName, provider)
                        VALUES (
                            new.id,
                            COALESCE(new.title, ''),
                            COALESCE(new.subtitle, ''),
                            COALESCE(new.bodyPreview, ''),
                            COALESCE(new.projectName, ''),
                            COALESCE(new.provider, '')
                        );
                    END
                    """)
            }

            if try db.tableExists("conversations"), try db.tableExists("conversations_fts") {
                try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_au")
                try db.execute(
                    sql: """
                    CREATE TRIGGER conversations_au AFTER UPDATE ON conversations
                    WHEN old.inferredTaskTitle IS NOT new.inferredTaskTitle
                      OR old.fullText IS NOT new.fullText
                    BEGIN
                        DELETE FROM conversations_fts WHERE rowid = old.rowid;
                        INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                        VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                    END
                    """
                )
            }
        }
    }
}
