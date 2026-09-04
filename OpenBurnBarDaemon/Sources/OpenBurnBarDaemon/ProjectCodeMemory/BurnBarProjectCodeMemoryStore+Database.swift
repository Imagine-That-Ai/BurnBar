import Foundation
import OpenBurnBarEngine
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

extension BurnBarProjectCodeMemoryStore {
    enum SQLiteBind {
        case text(String)
        case int(Int)
        case int64(Int64)
        case double(Double)
        case blob(Data)
        case null
    }

    struct CodeChunk {
        let text: String
        let startOffset: Int
        let endOffset: Int
        let contentHash: String
    }

    struct SQLiteCompactionDecision {
        let shouldCompact: Bool
        let pageCount: Int
        let freelistCount: Int
        let pageSize: Int

        var reclaimableBytes: Int {
            freelistCount * pageSize
        }
    }

    struct ExtractedSymbol {
        let id: String
        let projectID: String
        let artifactID: String
        let blobSHA: String
        let name: String
        let kind: String
        let range: BurnBarProjectCodeRange
        let confidenceTier: String
        let tierEvidenceJSON: String?
    }

    struct StaticParserRequest: Encodable {
        let requestId: String
        let filePath: String
        let language: String?
        let blobSha: String
        let text: String
        let rootPath: String?
        let operation: String?
        let position: StaticParserPosition?

        init(
            requestId: String,
            filePath: String,
            language: String?,
            blobSha: String,
            text: String,
            rootPath: String? = nil,
            operation: String? = nil,
            position: StaticParserPosition? = nil
        ) {
            self.requestId = requestId
            self.filePath = filePath
            self.language = language
            self.blobSha = blobSha
            self.text = text
            self.rootPath = rootPath
            self.operation = operation
            self.position = position
        }
    }

    struct StaticParserPosition: Encodable {
        let line: Int
        let character: Int
    }

    struct StaticParserResponse: Decodable {
        let filePath: String
        let language: String
        let blobSha: String
        let ok: Bool
        let hasParseError: Bool
        let symbols: [StaticParserSymbol]
        let references: [StaticParserReference]?
        let errors: [String]
    }

    struct StaticParserSymbol: Decodable {
        let name: String
        let kind: String
        let startLine: Int
        let endLine: Int
        let confidenceTier: String
        let evidence: StaticParserTierEvidence
    }

    struct StaticParserReference: Decodable {
        let filePath: String
        let startLine: Int
        let endLine: Int
        let startCharacter: Int
        let endCharacter: Int
        let confidenceTier: String
    }

    struct StaticParserTierEvidence: Decodable {
        let parser: String?
        let language: String?
        let blobSha: String?
        let shaMatch: Bool?
        let lspResponded: Bool?
    }

    func databaseSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: projectCodeMemoryQueueKey) == dbQueueID {
            return try work()
        }
        return try dbQueue.sync(execute: work)
    }

    func bootstrapSchema() throws {
        // Compatibility bridge only. The canonical app schema owner is the GRDB
        // migrator (`v50_project_code_memory_schema` and successors). Keep this
        // bootstrap for daemon-only fixtures and self-healing older installs, but
        // land new Project Code Memory tables/columns in the canonical migrator
        // before mirroring them here.
        try execute("PRAGMA journal_mode = WAL", [])
        try execute("PRAGMA foreign_keys = ON", [])
        try execute("PRAGMA auto_vacuum = INCREMENTAL", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS search_documents (
                id TEXT PRIMARY KEY,
                sourceKind TEXT NOT NULL,
                sourceID TEXT NOT NULL,
                sourceVersionID TEXT NOT NULL DEFAULT '',
                provider TEXT,
                projectName TEXT,
                title TEXT NOT NULL,
                subtitle TEXT,
                bodyPreview TEXT,
                sourceUpdatedAt TEXT,
                indexedAt TEXT NOT NULL,
                contentHash TEXT,
                createdAt TEXT NOT NULL,
                updatedAt TEXT NOT NULL
            )
            """,
            []
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS search_chunks (
                id TEXT PRIMARY KEY,
                documentID TEXT NOT NULL,
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
                createdAt TEXT NOT NULL,
                updatedAt TEXT NOT NULL
            )
            """,
            []
        )
        try ensureColumn(table: "search_chunks", column: "ftsRowid", definition: "INTEGER")
        try execute(
            "CREATE INDEX IF NOT EXISTS search_chunks_document_fts_rowid_idx ON search_chunks(documentID, ftsRowid)",
            []
        )
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS search_chunks_fts USING fts5(
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
            CREATE TABLE IF NOT EXISTS chunk_embeddings (
                chunkID TEXT NOT NULL,
                embeddingVersionID TEXT NOT NULL,
                vectorBlob BLOB NOT NULL,
                createdAt TEXT NOT NULL,
                updatedAt TEXT NOT NULL,
                PRIMARY KEY (chunkID, embeddingVersionID)
            )
            """,
            []
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS agent_memories (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                scope TEXT NOT NULL,
                confidence REAL NOT NULL,
                body_ref TEXT NOT NULL,
                body_redacted TEXT NOT NULL,
                tags_json TEXT NOT NULL,
                source_path TEXT,
                valid_from TEXT NOT NULL,
                valid_to TEXT,
                superseded_by TEXT,
                review_status TEXT NOT NULL DEFAULT 'approved',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            []
        )
        // Older daemon databases predate the review lifecycle. Existing rows were
        // already durable memories, so they are approved when upgraded; newly
        // extracted candidates explicitly opt into quarantined status.
        try ensureColumn(table: "agent_memories", column: "review_status", definition: "TEXT NOT NULL DEFAULT 'approved'")
        // Mirrors the canonical migrator's v51 column. `code` is the shipped
        // default: only rows the Memory MCP engine mirrors are marked `agent`,
        // and only those may reach the blind sync lane.
        try ensureColumn(table: "agent_memories", column: "source_kind", definition: "TEXT NOT NULL DEFAULT 'code'")
        try execute(
            "CREATE INDEX IF NOT EXISTS agent_memories_review_status_idx ON agent_memories(project_id, review_status, updated_at)",
            []
        )
        try execute("CREATE INDEX IF NOT EXISTS agent_memories_project_idx ON agent_memories(project_id, scope, updated_at)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS memory_embedding_refs (
                memory_id TEXT NOT NULL,
                embedding_version_id TEXT NOT NULL,
                dimension INTEGER NOT NULL,
                vector BLOB NOT NULL,
                norm REAL NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY (memory_id, embedding_version_id)
            )
            """,
            []
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS memory_embedding_refs_version_idx ON memory_embedding_refs(embedding_version_id, dimension)",
            []
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS memory_quarantine_bodies (
                memory_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                body TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS agent_memory_bodies (
                memory_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                engine_memory_id TEXT NOT NULL,
                body TEXT NOT NULL,
                body_hash TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS agent_memory_bodies_engine_idx
            ON agent_memory_bodies(engine_memory_id)
            """,
            []
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS memory_quarantine_bodies_project_idx ON memory_quarantine_bodies(project_id)",
            []
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS memory_salience (
                memory_id TEXT PRIMARY KEY,
                salience REAL NOT NULL,
                hit_count INTEGER NOT NULL DEFAULT 0,
                last_reinforced_at TEXT,
                corroboration INTEGER NOT NULL DEFAULT 1,
                source_trust REAL NOT NULL,
                computed_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            []
        )
        // agent_memories_fts was a vestigial body-search index that can never be
        // populated: the redacted-index invariant keeps memory bodies out of the agent
        // index entirely (they live only in project_memory_snapshots). Drop it rather
        // than ship a dead index that implies FTS coverage it cannot provide.
        try execute("DROP TABLE IF EXISTS agent_memories_fts", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS memory_audit (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                ts TEXT NOT NULL,
                actor TEXT NOT NULL,
                action TEXT NOT NULL,
                domain TEXT NOT NULL,
                project_id TEXT,
                subject_id TEXT,
                labels_json TEXT NOT NULL,
                prev_hash TEXT,
                hash TEXT NOT NULL
            )
            """,
            []
        )
        try execute("CREATE INDEX IF NOT EXISTS memory_audit_project_idx ON memory_audit(project_id, seq)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS pcm_projects (
                project_id TEXT PRIMARY KEY,
                identity_version INTEGER NOT NULL,
                identity_fingerprint TEXT NOT NULL,
                project_name TEXT NOT NULL,
                primary_path TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS pcm_projects_fingerprint_idx ON pcm_projects(identity_fingerprint)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS pcm_project_aliases (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                alias_path TEXT NOT NULL,
                path_hash TEXT NOT NULL,
                first_seen_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                FOREIGN KEY(project_id) REFERENCES pcm_projects(project_id) ON DELETE CASCADE
            )
            """,
            []
        )
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS pcm_project_aliases_path_hash_idx ON pcm_project_aliases(path_hash)", [])
        try execute("CREATE INDEX IF NOT EXISTS pcm_project_aliases_project_idx ON pcm_project_aliases(project_id)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS code_artifacts (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                blob_sha TEXT NOT NULL,
                content_hash TEXT,
                commit_sha TEXT,
                lang TEXT,
                byte_count INTEGER NOT NULL,
                mtime REAL NOT NULL,
                indexed_at TEXT NOT NULL
            )
            """,
            []
        )
        try ensureColumn(table: "code_artifacts", column: "content_hash", definition: "TEXT")
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS code_artifacts_project_path_idx ON code_artifacts(project_id, file_path)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS pcm_file_manifest (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                artifact_id TEXT,
                blob_sha TEXT,
                content_hash TEXT,
                byte_count INTEGER NOT NULL DEFAULT 0,
                mtime REAL NOT NULL DEFAULT 0,
                lang TEXT,
                ignored_reason TEXT,
                secret_labels_json TEXT NOT NULL DEFAULT '[]',
                parser_tier TEXT,
                indexed_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS pcm_file_manifest_project_path_idx ON pcm_file_manifest(project_id, file_path)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS code_symbols (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                artifact_id TEXT NOT NULL,
                blob_sha TEXT NOT NULL,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                range_json TEXT NOT NULL,
                confidence_tier TEXT NOT NULL,
                tier_evidence_json TEXT,
                indexed_at TEXT NOT NULL
            )
            """,
            []
        )
        try ensureColumn(table: "code_symbols", column: "tier_evidence_json", definition: "TEXT")
        try execute("CREATE INDEX IF NOT EXISTS code_symbols_project_name_idx ON code_symbols(project_id, name)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS code_references (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                from_artifact_id TEXT NOT NULL,
                to_symbol_id TEXT NOT NULL,
                range_json TEXT NOT NULL,
                blob_sha TEXT NOT NULL,
                confidence_tier TEXT NOT NULL,
                indexed_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute("CREATE INDEX IF NOT EXISTS code_references_symbol_idx ON code_references(project_id, to_symbol_id)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS code_call_edges (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                caller_symbol_id TEXT NOT NULL,
                callee_symbol_id TEXT NOT NULL,
                confidence_tier TEXT NOT NULL,
                indexed_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute("CREATE INDEX IF NOT EXISTS code_call_edges_project_idx ON code_call_edges(project_id, caller_symbol_id)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS code_diagnostics_cache (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                tool TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                blob_sha TEXT,
                cached_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute("CREATE INDEX IF NOT EXISTS code_diagnostics_cache_project_idx ON code_diagnostics_cache(project_id, file_path)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS code_chunk_embeddings (
                chunk_id TEXT NOT NULL,
                project_id TEXT NOT NULL,
                embedding_version TEXT NOT NULL,
                dimension INTEGER NOT NULL,
                vector TEXT NOT NULL,
                PRIMARY KEY (chunk_id, embedding_version)
            )
            """,
            []
        )
        try execute("CREATE INDEX IF NOT EXISTS code_chunk_embeddings_project_idx ON code_chunk_embeddings(project_id, embedding_version)", [])
        try execute(
            """
            CREATE TABLE IF NOT EXISTS code_index_checkpoints (
                project_id TEXT PRIMARY KEY,
                project_root TEXT NOT NULL,
                last_commit_sha TEXT,
                indexed_at TEXT NOT NULL,
                artifact_count INTEGER NOT NULL,
                chunk_count INTEGER NOT NULL,
                rejected_count INTEGER NOT NULL,
                storage_byte_count INTEGER NOT NULL DEFAULT 0,
                storage_budget_bytes INTEGER NOT NULL DEFAULT 0,
                vacuumed_at TEXT
            )
            """,
            []
        )
        try ensureColumn(table: "code_index_checkpoints", column: "storage_byte_count", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "code_index_checkpoints", column: "storage_budget_bytes", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn(table: "code_index_checkpoints", column: "vacuumed_at", definition: "TEXT")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS project_memory_snapshots (
                projectSlug TEXT PRIMARY KEY,
                projectDisplayName TEXT NOT NULL,
                snapshotJSON TEXT NOT NULL,
                contentHash TEXT NOT NULL,
                sourceSessionCount INTEGER NOT NULL DEFAULT 0,
                sourceConversationCount INTEGER NOT NULL DEFAULT 0,
                generatedAt TEXT NOT NULL,
                schemaVersion INTEGER NOT NULL,
                updatedAt TEXT NOT NULL
            )
            """,
            []
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS project_memory_snapshots_updated_idx ON project_memory_snapshots(updatedAt)",
            []
        )
        try migrateLegacyPlaintextAgentMemories()
    }
}
