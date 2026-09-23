import Foundation
@testable import OpenBurnBarDaemon

/// Wave 2.1c-iv test support: replaces the daemon bootstrap's search
/// tables with the migrator's exact DDL so the lane tests run against
/// the same shape production has.
///
/// The distinction matters: the bootstrap declares the date columns as
/// TEXT while the migrator declares them DATETIME (GRDB persists `Date`
/// as REAL doubles), and the migrator owns the unique
/// `(documentID, ordinal)` index the atomicity test leans on, plus the
/// `search_documents_fts` triggers the daemon's writes must flow through
/// exactly as the app's pre-cutover writes did.
extension BurnBarProjectCodeMemoryStore {
    func searchIndexTestCompleteSchema() throws {
        try execute("DROP TABLE IF EXISTS search_chunks_fts", [])
        try execute("DROP TABLE IF EXISTS search_chunks", [])
        try execute("DROP TABLE IF EXISTS search_documents", [])
        try execute(
            """
            CREATE TABLE search_documents (
                id TEXT PRIMARY KEY,
                sourceKind TEXT NOT NULL,
                sourceID TEXT NOT NULL,
                sourceVersionID TEXT NOT NULL DEFAULT '',
                provider TEXT,
                projectName TEXT,
                title TEXT NOT NULL,
                subtitle TEXT,
                bodyPreview TEXT,
                sourceUpdatedAt DATETIME,
                indexedAt DATETIME NOT NULL,
                contentHash TEXT,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL
            )
            """,
            []
        )
        try execute(
            """
            CREATE UNIQUE INDEX search_documents_source_lookup_idx
                ON search_documents (sourceKind, sourceID, sourceVersionID)
            """,
            []
        )
        try execute(
            """
            CREATE TABLE search_chunks (
                id TEXT PRIMARY KEY,
                documentID TEXT NOT NULL REFERENCES search_documents (id) ON DELETE CASCADE,
                sourceKind TEXT NOT NULL,
                sourceID TEXT NOT NULL,
                sourceVersionID TEXT NOT NULL DEFAULT '',
                ordinal INTEGER NOT NULL,
                startOffset INTEGER NOT NULL,
                endOffset INTEGER NOT NULL,
                messageStartOffset INTEGER,
                messageEndOffset INTEGER,
                sectionPath TEXT,
                text TEXT NOT NULL,
                contentHash TEXT,
                ftsRowid INTEGER,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL
            )
            """,
            []
        )
        try execute(
            """
            CREATE UNIQUE INDEX search_chunks_unique_document_ordinal_idx
                ON search_chunks (documentID, ordinal)
            """,
            []
        )
        try execute(
            """
            CREATE VIRTUAL TABLE search_chunks_fts USING fts5(
                chunkID UNINDEXED,
                documentID UNINDEXED,
                title,
                chunkText,
                projectName,
                provider,
                tokenize='porter unicode61'
            )
            """,
            []
        )
        try execute(
            """
            CREATE VIRTUAL TABLE search_documents_fts USING fts5(
                documentID UNINDEXED,
                title,
                subtitle,
                bodyPreview,
                projectName,
                provider,
                tokenize='porter unicode61'
            )
            """,
            []
        )
        try execute(
            """
            CREATE TRIGGER search_documents_fts_ai AFTER INSERT ON search_documents BEGIN
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
            """,
            []
        )
        try execute(
            """
            CREATE TRIGGER search_documents_fts_ad AFTER DELETE ON search_documents BEGIN
                DELETE FROM search_documents_fts WHERE documentID = old.id;
            END
            """,
            []
        )
        try execute(
            """
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
            """,
            []
        )
    }
}
