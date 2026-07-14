import GRDB

extension OpenBurnBarDatabase {
    /// `v55_search_chunks_fts_rowid` — the app-side half of the 128–195% CPU-burn
    /// fix (the daemon got the mirror in PR #1384). `search_chunks_fts` keys
    /// (`chunkID`, `documentID`) are UNINDEXED FTS5 columns, so every
    /// `DELETE FROM search_chunks_fts WHERE chunkID/documentID = ?` full-scans the
    /// entire FTS content table (multi-GB of chunk text on a mature index) — once
    /// per chunk, on every incremental reindex. This migration records each chunk's
    /// FTS rowid on `search_chunks` so deletes become O(log n) rowid lookups, and
    /// gates the two whole-document re-tokenizing FTS update triggers so they only
    /// fire when the indexed content actually changes.
    static func registerSearchChunksFTSRowidMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v55_search_chunks_fts_rowid") { db in
            // Every block is guarded on table existence: real databases
            // migrated through v21+ always have these tables, but synthetic
            // ledgers (test seeds that fake grdb_migrations over a minimal
            // schema) may not, and each optimization is independently safe
            // to skip.

            // `search_chunks_fts` keys (`chunkID`, `documentID`) are UNINDEXED
            // FTS5 columns, so `DELETE FROM search_chunks_fts WHERE chunkID = ?`
            // full-scans the entire FTS content table (GBs of chunk text) — once
            // per chunk, on every incremental reindex. Record each chunk's FTS
            // rowid on `search_chunks` so deletes become O(log n) rowid lookups.
            if try db.tableExists("search_chunks") {
                try db.execute(sql: "ALTER TABLE search_chunks ADD COLUMN ftsRowid INTEGER")

                // Backfill in a single pass over the FTS5 shadow content table
                // (`id` = fts rowid, `c0` = first declared column, chunkID).
                // Reading the shadow table directly avoids the virtual-table
                // row materialization that decodes every chunk's full text.
                if try db.tableExists("search_chunks_fts_content") {
                    // Compute the text preference in the map itself. The older
                    // SQLite bundled by Linux SQLCipher cannot resolve an outer
                    // UPDATE-table column from a scalar subquery ORDER BY.
                    try db.execute(
                        sql: """
                        CREATE TEMP TABLE search_chunks_fts_rowid_map AS
                        SELECT
                            f.id AS ftsRowid,
                            f.c0 AS chunkID,
                            f.c3 AS chunkText,
                            CASE WHEN f.c3 = c.text THEN 1 ELSE 0 END AS textMatches
                        FROM search_chunks_fts_content AS f
                        LEFT JOIN search_chunks AS c ON c.id = f.c0
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
                                m.textMatches DESC,
                                m.ftsRowid DESC
                            LIMIT 1
                        )
                        """
                    )
                    // Sweep FTS rows that no live chunk maps to: orphans (chunk
                    // gone) and duplicates (a chunkID with multiple FTS rows —
                    // only the backfilled rowid stays). Both classes previously
                    // lingered as stale search hits.
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

            // The documents-FTS update trigger fired on EVERY upsert (routine
            // reindexes only bump indexedAt/contentHash), and its
            // delete-by-UNINDEXED-documentID full-scans search_documents_fts
            // each time. Only fire when indexed content actually changes.
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

            // Same churn class as the documents trigger, but bigger: every
            // conversations-row update (sync flags, counters, timestamps)
            // re-tokenized the ENTIRE fullText into conversations_fts — the
            // single largest table in the database. Re-index only when the
            // indexed content actually changes.
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
