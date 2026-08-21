import Foundation
import GRDB

extension OpenBurnBarDatabase {
    static func registerDataMigrationsV41toV51(on migrator: inout DatabaseMigrator) {

        migrator.registerMigration("v41_reprice_openai_family_cached_input") { db in
            try db.execute(sql: """
                UPDATE token_usage
                SET cost = (
                        MAX(inputTokens, 0) * CASE LOWER(model)
                            WHEN 'gpt-5.5-pro' THEN 30.0
                            WHEN 'gpt-5.4' THEN 2.5
                            WHEN 'gpt-5.4-pro' THEN 30.0
                            WHEN 'gpt-5.3-codex' THEN 1.75
                            ELSE 5.0
                        END
                        + MAX(outputTokens, 0) * CASE LOWER(model)
                            WHEN 'gpt-5.5-pro' THEN 180.0
                            WHEN 'gpt-5.4' THEN 15.0
                            WHEN 'gpt-5.4-pro' THEN 180.0
                            WHEN 'gpt-5.3-codex' THEN 14.0
                            ELSE 30.0
                        END
                        + MAX(cacheCreationTokens, 0) * CASE LOWER(model)
                            WHEN 'gpt-5.5-pro' THEN 30.0
                            WHEN 'gpt-5.4' THEN 2.5
                            WHEN 'gpt-5.4-pro' THEN 30.0
                            WHEN 'gpt-5.3-codex' THEN 1.75
                            ELSE 5.0
                        END
                        + MAX(cacheReadTokens, 0) * CASE LOWER(model)
                            WHEN 'gpt-5.5-pro' THEN 30.0
                            WHEN 'gpt-5.4' THEN 0.25
                            WHEN 'gpt-5.4-pro' THEN 30.0
                            WHEN 'gpt-5.3-codex' THEN 0.175
                            ELSE 0.5
                        END
                    ) / 1000000.0,
                    syncedAt = NULL
                WHERE LOWER(model) IN (
                    'gpt-5.5',
                    'gpt-5.5-fast',
                    'gpt-5.5-pro',
                    'gpt-5.4',
                    'gpt-5.4-pro',
                    'gpt-5.3-codex'
                )
                """)
        }

        migrator.registerMigration("v42_budget_rules_and_events") { db in
            // budget_rules — durable user-configured spending limits
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS budget_rules (
                    id TEXT PRIMARY KEY,
                    scope TEXT NOT NULL,
                    identifier TEXT,
                    providerID TEXT,
                    accountID TEXT,
                    projectName TEXT,
                    label TEXT,
                    amountUSD REAL NOT NULL,
                    period TEXT NOT NULL,
                    behavior TEXT NOT NULL,
                    fallbackCredentialIDsJSON TEXT,
                    pausedUntil DATETIME,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL,
                    syncedAt DATETIME,
                    sourceDeviceID TEXT,
                    isEnabled INTEGER NOT NULL DEFAULT 1
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_rules_scope_idx ON budget_rules(scope, isEnabled)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_rules_provider_account_idx ON budget_rules(providerID, accountID, isEnabled)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_rules_project_idx ON budget_rules(projectName, isEnabled)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_rules_synced_idx ON budget_rules(syncedAt)")

            // budget_events — append-only audit log for warnings, blocks, overrides, pauses
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS budget_events (
                    id TEXT PRIMARY KEY,
                    ruleID TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    source TEXT,
                    amountAtEvent REAL NOT NULL,
                    limitAtEvent REAL NOT NULL,
                    detailJSON TEXT,
                    occurredAt DATETIME NOT NULL,
                    syncedAt DATETIME,
                    sourceDeviceID TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_events_rule_idx ON budget_events(ruleID, occurredAt DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_events_kind_idx ON budget_events(kind, occurredAt DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS budget_events_synced_idx ON budget_events(syncedAt)")
        }

        migrator.registerMigration("v43_text_expansion_snippets") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS text_expansion_snippets (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    trigger TEXT NOT NULL,
                    body TEXT NOT NULL,
                    mode TEXT NOT NULL,
                    isEnabled INTEGER NOT NULL DEFAULT 1,
                    scopeJSON TEXT NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 1,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL,
                    deletedAt DATETIME,
                    syncedAt DATETIME,
                    sourceDeviceID TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS text_expansion_snippets_enabled_idx ON text_expansion_snippets(isEnabled, deletedAt)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS text_expansion_snippets_synced_idx ON text_expansion_snippets(syncedAt)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS text_expansion_snippets_updated_idx ON text_expansion_snippets(updatedAt)")
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS text_expansion_snippets_trigger_active_idx
                ON text_expansion_snippets(trigger)
                WHERE deletedAt IS NULL
                """)
        }

        migrator.registerMigration("v44_repair_token_accounting_duplicates") { db in
            try db.execute(sql: """
                DELETE FROM token_usage
                WHERE provider IN ('Zai', 'MiniMax', 'Ollama')
                  AND EXISTS (
                    SELECT 1
                    FROM token_usage factory
                    WHERE factory.provider = 'Factory'
                      AND factory.sessionId = token_usage.sessionId
                      AND COALESCE(factory.sourceDeviceId, '') = COALESCE(token_usage.sourceDeviceId, '')
                      AND COALESCE(factory.providerAccountID, '') = COALESCE(token_usage.providerAccountID, '')
                  )
                """)

            try db.execute(sql: """
                DELETE FROM token_usage
                WHERE EXISTS (
                    SELECT 1
                    FROM token_usage winner
                    WHERE winner.provider = token_usage.provider
                      AND winner.sessionId = token_usage.sessionId
                      AND winner.model != token_usage.model
                      AND COALESCE(winner.sourceDeviceId, '') = COALESCE(token_usage.sourceDeviceId, '')
                      AND COALESCE(winner.providerAccountID, '') = COALESCE(token_usage.providerAccountID, '')
                      AND (
                        CASE winner.provenanceConfidence
                            WHEN 'exact' THEN 4
                            WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1
                            ELSE 0
                        END
                      ) > (
                        CASE token_usage.provenanceConfidence
                            WHEN 'exact' THEN 4
                            WHEN 'derived_exact' THEN 3
                            WHEN 'high_confidence_estimate' THEN 2
                            WHEN 'low_confidence_estimate' THEN 1
                            ELSE 0
                        END
                      )
                )
                """)
        }

        migrator.registerMigration("v45_conversation_working_directory") { db in
            guard try db.tableExists("conversations") else { return }
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(conversations)")
                .compactMap { $0["name"] as? String }
            guard !columns.contains("workingDirectory") else { return }
            try db.alter(table: "conversations") { t in
                t.add(column: "workingDirectory", .text)
            }
        }

        migrator.registerMigration("v46_drain_target_per_provider") { db in
            // Per-provider drain targets: `switcher_active_profile` gains a
            // nullable `providerID`. `providerID IS NULL` remains the legacy
            // global pointer (browser launching + legacy callers); one row per
            // CLI providerID becomes that provider's drain target — the account
            // the user is burning quota from for that provider.
            guard try db.tableExists("switcher_active_profile") else { return }
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(switcher_active_profile)")
                .compactMap { $0["name"] as? String }
            if !columns.contains("providerID") {
                try db.alter(table: "switcher_active_profile") { t in
                    t.add(column: "providerID", .text)
                }
            }

            // Seed the per-provider drain target from the existing global active
            // profile so the user's current selection survives the upgrade.
            if let activeProfileID = try String.fetchOne(
                db,
                sql: """
                    SELECT activeProfileID FROM switcher_active_profile
                    WHERE activeProfileID IS NOT NULL AND providerID IS NULL
                    ORDER BY COALESCE(updatedAt, '1970-01-01T00:00:00Z') DESC
                    LIMIT 1
                """
            ),
               let cliTypeRaw = try String.fetchOne(
                   db,
                   sql: "SELECT cliType FROM switcher_profiles WHERE id = ?",
                   arguments: [activeProfileID]
               ),
               let providerID = Self.providerIDForSwitcherCLIType(cliTypeRaw) {
                let existing = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM switcher_active_profile WHERE providerID = ?",
                    arguments: [providerID]
                ) ?? 0
                if existing == 0 {
                    try db.execute(
                        sql: """
                            INSERT INTO switcher_active_profile (activeProfileID, providerID, updatedAt)
                            VALUES (?, ?, ?)
                        """,
                        arguments: [activeProfileID, providerID, Date()]
                    )
                }
            }
        }

        migrator.registerMigration("v47_conversation_tombstones") { db in
            // Cross-device delete propagation (B-DATA-2). Mirrors the proven
            // `text_expansion_snippets` soft-delete substrate: `deletedAt` marks a
            // tombstone that survives sync and propagates to other devices, while
            // `version` is a monotonic counter bumped on every mutation. The
            // counter is intentionally general — Phase-2 conflict convergence
            // (last-writer-wins by version) reuses it for non-delete updates too.
            guard try db.tableExists("conversations") else { return }
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(conversations)")
                .compactMap { $0["name"] as? String }
            if !columns.contains("deletedAt") {
                try db.alter(table: "conversations") { t in
                    t.add(column: "deletedAt", .datetime)
                }
            }
            if !columns.contains("version") {
                try db.alter(table: "conversations") { t in
                    t.add(column: "version", .integer).notNull().defaults(to: 1)
                }
            }
            // Tombstone-aware reads filter on `deletedAt IS NULL`; a covering
            // index keeps the live-conversation scans cheap and lets the GC sweep
            // locate expired tombstones without a full table scan.
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS conversations_deleted_idx ON conversations(deletedAt)")
        }

        migrator.registerMigration("v48_conversation_fts_orphan_repair") { db in
            // One-shot repair for the conversations_fts leak (C10). Historically the
            // upsert used `INSERT OR REPLACE INTO conversations`, which deletes and
            // re-inserts the row. With recursive_triggers OFF (the SQLite default)
            // the conversations_ad delete trigger does not fire on REPLACE, so the
            // prior full-text copy was never removed from the standalone
            // conversations_fts table. Every 60s refresh tick re-upserted active
            // conversations, leaking one orphaned FTS copy per tick — on the order of
            // millions of rows / gigabytes of disk on long-lived databases.
            //
            // The upsert now uses ON CONFLICT(id) DO UPDATE (stable rowid + the
            // conversations_au AFTER UPDATE trigger), so no new orphans are created.
            // This migration purges the existing orphans by clearing the standalone
            // FTS table and rebuilding it from the live conversations rows.
            guard try db.tableExists("conversations_fts") else { return }
            guard try db.tableExists("conversations") else { return }

            try db.execute(sql: "DELETE FROM conversations_fts")
            try db.execute(
                sql: """
                INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                SELECT rowid, inferredTaskTitle, fullText FROM conversations
                """
            )

            // TODO(C10): The rebuild reclaims FTS rows but not the freed pages on
            // disk; only VACUUM compacts the file. VACUUM cannot run inside a
            // migration transaction and must be guarded by a free-disk check
            // (free >= current DB size) — never unguarded. No free-disk helper
            // exists yet, so the post-migration VACUUM is deferred to a follow-up
            // that adds the guard and runs it outside the migration transaction.
        }

        migrator.registerMigration("v49_token_usage_parent_request_id") { db in
            // The Elder Wand fusion parentRequestID (`elderwand-<UUID>`) survives
            // only on the daemon read paths and was historically dropped on
            // SQLite import. This additive, nullable column lets imported daemon
            // rows carry it so the period fusion/normal partition (rows whose
            // parentRequestID LIKE 'elderwand-%') becomes a real, indexed SQL
            // query instead of a live-only RPC scan. No backfill: pre-v49 rows
            // keep NULL and read as "normal", which is correct — their fusion
            // membership was never recorded locally.
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(token_usage)")
                .compactMap { $0["name"] as? String }
            if !columns.contains("parentRequestID") {
                try db.alter(table: "token_usage") { t in
                    t.add(column: "parentRequestID", .text)
                }
            }
            // Partial index keeps the impact-screen partition cheap: only fusion
            // rows are indexed, so `WHERE parentRequestID LIKE 'elderwand-%'`
            // over a time window is a narrow index range scan, and normal rows
            // (the overwhelming majority) cost nothing to skip.
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS token_usage_parent_request_idx
                ON token_usage(parentRequestID, startTime)
                WHERE parentRequestID IS NOT NULL
                """
            )
        }

        migrator.registerMigration("v50_project_code_memory_schema") { db in
            // Project Code Memory is daemon-owned at runtime, but the shared
            // application database schema must still be declared by the canonical
            // GRDB migrator. The daemon's raw-SQLite bootstrap remains a
            // compatibility/self-heal bridge for pre-v50 databases and daemon-only
            // test fixtures; new schema changes should land here first.
            try db.execute(
                sql: """
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
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS agent_memories_project_idx
                ON agent_memories(project_id, scope, updated_at)
                """
            )
            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS agent_memories_fts USING fts5(
                    memoryID UNINDEXED,
                    projectID UNINDEXED,
                    bodyText,
                    tags,
                    tokenize='porter unicode61'
                )
                """
            )
            try db.execute(
                sql: """
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
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS pcm_projects (
                    project_id TEXT PRIMARY KEY,
                    identity_version INTEGER NOT NULL,
                    identity_fingerprint TEXT NOT NULL,
                    project_name TEXT NOT NULL,
                    primary_path TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS pcm_projects_fingerprint_idx
                ON pcm_projects(identity_fingerprint)
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS pcm_project_aliases (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    alias_path TEXT NOT NULL,
                    path_hash TEXT NOT NULL,
                    first_seen_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL,
                    FOREIGN KEY(project_id) REFERENCES pcm_projects(project_id) ON DELETE CASCADE
                )
                """
            )
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS pcm_project_aliases_path_hash_idx
                ON pcm_project_aliases(path_hash)
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS pcm_project_aliases_project_idx
                ON pcm_project_aliases(project_id)
                """
            )
            try db.execute(
                sql: """
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
                """
            )
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS code_artifacts_project_path_idx
                ON code_artifacts(project_id, file_path)
                """
            )
            try db.execute(
                sql: """
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
                """
            )
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS pcm_file_manifest_project_path_idx
                ON pcm_file_manifest(project_id, file_path)
                """
            )
            try db.execute(
                sql: """
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
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS code_symbols_project_name_idx
                ON code_symbols(project_id, name)
                """
            )
            try db.execute(
                sql: """
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
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS code_references_symbol_idx
                ON code_references(project_id, to_symbol_id)
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS code_call_edges (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    caller_symbol_id TEXT NOT NULL,
                    callee_symbol_id TEXT NOT NULL,
                    confidence_tier TEXT NOT NULL,
                    indexed_at TEXT NOT NULL
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS code_call_edges_project_idx
                ON code_call_edges(project_id, caller_symbol_id)
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS code_diagnostics_cache (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    file_path TEXT NOT NULL,
                    tool TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    blob_sha TEXT,
                    cached_at TEXT NOT NULL
                )
                """
            )
            try db.execute(
                sql: """
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
                """
            )
        }
        migrator.registerMigration("v51a_drop_body_fts") { db in try db.execute(sql: "DROP TABLE IF EXISTS agent_memories_fts") }
    }

    /// Maps persisted switcher CLI type tokens onto catalog provider IDs used as
    /// per-provider drain targets. Package-visible so CoreTests can pin Junie /
    /// Prime Agent without standing up a full pre-v46 schema fixture.
    static func providerIDForSwitcherCLIType(_ rawValue: String) -> String? {
        switch rawValue {
        case "codex":
            return "codex"
        case "claude":
            return "claude-code"
        case "opencode":
            return "opencode"
        case "droid":
            return "factory"
        case "forge":
            return "forge"
        case "antigravity":
            return "antigravity"
        case "grok":
            return "xai"
        case "cursoragent":
            return "cursor-agent"
        case "omp":
            return "omp"
        case "gemini":
            return "geminicli"
        case "kimi":
            return "kimi"
        case "pi":
            return "pi-agent"
        case "junie":
            return "junie"
        case "fx":
            return "fx"
        case "prime-agent":
            return "prime-agent"
        default:
            return nil
        }
    }
}
