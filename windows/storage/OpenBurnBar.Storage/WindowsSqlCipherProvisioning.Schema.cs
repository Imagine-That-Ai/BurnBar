namespace OpenBurnBar.Storage;

public sealed partial class WindowsSqlCipherProvisioner
{
    private static readonly string[] SchemaStatements =
    {
        "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)",
        // v29_parser_checkpoints is a prerequisite of the v56 file manifest.
        // Keep its canonical GRDB column/index shape before stamping v56.
        """
        CREATE TABLE IF NOT EXISTS parser_checkpoints (
            provider TEXT PRIMARY KEY,
            checkpointToken TEXT NOT NULL,
            lastProcessedFilePath TEXT,
            lastProcessedAt DATETIME NOT NULL,
            version INTEGER NOT NULL DEFAULT 1
        )
        """,
        "CREATE INDEX IF NOT EXISTS parser_checkpoints_provider_idx ON parser_checkpoints(provider)",
        // v56_parser_checkpoint_file_manifest. This DDL must precede the
        // grdb_migrations stamp below; otherwise a fresh/reset Windows database
        // claims v56 while ParserCheckpointStore has no manifest table.
        """
        CREATE TABLE IF NOT EXISTS parser_checkpoint_files (
            provider TEXT NOT NULL,
            path TEXT NOT NULL,
            fileSizeBytes INTEGER,
            modificationDate DATETIME,
            creationDate DATETIME,
            fileSystemNumber TEXT,
            fileNumber TEXT,
            PRIMARY KEY (provider, path)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS token_usage (
            id TEXT NOT NULL PRIMARY KEY,
            provider TEXT NOT NULL,
            sessionId TEXT NOT NULL,
            projectName TEXT NOT NULL DEFAULT '',
            model TEXT NOT NULL,
            inputTokens INTEGER NOT NULL DEFAULT 0,
            outputTokens INTEGER NOT NULL DEFAULT 0,
            cacheCreationTokens INTEGER NOT NULL DEFAULT 0,
            cacheReadTokens INTEGER NOT NULL DEFAULT 0,
            reasoningTokens INTEGER NOT NULL DEFAULT 0,
            totalTokens INTEGER NOT NULL DEFAULT 0,
            cost REAL NOT NULL DEFAULT 0,
            startTime TEXT NOT NULL DEFAULT '',
            endTime TEXT NOT NULL DEFAULT '',
            createdAt TEXT NOT NULL DEFAULT '',
            usageSource TEXT NOT NULL DEFAULT 'measured',
            executionSourceID TEXT NOT NULL DEFAULT 'unknown',
            executionSourceName TEXT NOT NULL DEFAULT 'Unknown',
            executionSourceKind TEXT NOT NULL DEFAULT 'unknown',
            executionSourceConfidence TEXT NOT NULL DEFAULT 'unknown',
            sourceDeviceId TEXT,
            sourceDeviceName TEXT,
            isRemote INTEGER NOT NULL DEFAULT 0,
            providerID TEXT,
            providerAccountID TEXT,
            providerAccountLabel TEXT,
            providerAccountSource TEXT,
            provenanceMethod TEXT NOT NULL DEFAULT 'api',
            provenanceConfidence TEXT NOT NULL DEFAULT 'exact',
            estimatorVersion TEXT NOT NULL DEFAULT 'windows-provisioner-v1',
            parentRequestID TEXT
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS token_usage_unique_session_model_idx ON token_usage(provider, sessionId, model, COALESCE(sourceDeviceId, ''), COALESCE(providerAccountID, ''))",
        "CREATE INDEX IF NOT EXISTS token_usage_created_at_idx ON token_usage(createdAt DESC)",
        "CREATE INDEX IF NOT EXISTS token_usage_session_idx ON token_usage(sessionId)",
        "CREATE INDEX IF NOT EXISTS token_usage_execution_source_time_idx ON token_usage(executionSourceID, startTime)",
        """
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT NOT NULL PRIMARY KEY,
            provider TEXT NOT NULL,
            sessionId TEXT NOT NULL,
            projectName TEXT NOT NULL DEFAULT '',
            inferredTaskTitle TEXT NOT NULL DEFAULT '',
            fullText TEXT NOT NULL DEFAULT '',
            indexedAt TEXT,
            messageCount INTEGER NOT NULL DEFAULT 0,
            deletedAt TEXT,
            workingDirectory TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS conversations_indexed_at_idx ON conversations(indexedAt DESC)",
        // Mirrors the Mac endpoint schema exactly (v6_fts_standalone_triggers):
        // a STANDALONE FTS5 table kept in sync by the conversations_ai/ad/au
        // triggers below. It must NOT be declared with content='conversations'
        // (external content): plain trigger DELETEs corrupt external-content
        // FTS5 indexes, and the column order (inferredTaskTitle first) is part
        // of the byte-compat contract — snippet(conversations_fts, 1, …) reads
        // column 1 = fullText. Checked by scripts/check-migrator-parity.mjs.
        "CREATE VIRTUAL TABLE IF NOT EXISTS conversations_fts USING fts5(inferredTaskTitle, fullText, tokenize='porter unicode61')",
        """
        CREATE TRIGGER IF NOT EXISTS conversations_ai AFTER INSERT ON conversations BEGIN
            INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
            VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS conversations_ad AFTER DELETE ON conversations BEGIN
            DELETE FROM conversations_fts WHERE rowid = old.rowid;
        END
        """,
        """
        CREATE TRIGGER IF NOT EXISTS conversations_au AFTER UPDATE ON conversations BEGIN
            DELETE FROM conversations_fts WHERE rowid = old.rowid;
            INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
            VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
        END
        """,
        """
        CREATE TABLE IF NOT EXISTS chat_threads (
            id TEXT NOT NULL PRIMARY KEY,
            title TEXT,
            backend TEXT NOT NULL DEFAULT 'cli',
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            projectPath TEXT,
            sessionId TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS chat_threads_updated_idx ON chat_threads(updatedAt DESC)",
        """
        CREATE TABLE IF NOT EXISTS chat_messages (
            id TEXT NOT NULL PRIMARY KEY,
            threadId TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            cliUsed TEXT,
            transcriptPiecesJSON TEXT,
            attachmentsJSON TEXT,
            errorKind TEXT,
            errorMessage TEXT,
            retrievalStateJSON TEXT,
            modelUsed TEXT,
            backend TEXT,
            isStreaming INTEGER NOT NULL DEFAULT 0,
            metadata TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS chat_messages_thread_time_idx ON chat_messages(threadId, timestamp)",
        "CREATE INDEX IF NOT EXISTS chat_messages_timestamp_idx ON chat_messages(timestamp DESC)",
        """
        CREATE TABLE IF NOT EXISTS chat_stream_failures (
            id TEXT NOT NULL PRIMARY KEY,
            threadId TEXT NOT NULL,
            messageId TEXT,
            kind TEXT NOT NULL,
            message TEXT NOT NULL,
            createdAt TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS chat_stream_failures_thread_idx ON chat_stream_failures(threadId, createdAt DESC)",
        """
        CREATE TABLE IF NOT EXISTS chat_retrieval_events (
            id TEXT NOT NULL PRIMARY KEY,
            threadId TEXT NOT NULL,
            messageId TEXT NOT NULL,
            kind TEXT NOT NULL,
            detail TEXT NOT NULL,
            createdAt TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS chat_retrieval_events_message_idx ON chat_retrieval_events(messageId, createdAt DESC)",
        """
        CREATE TABLE IF NOT EXISTS budget_rules (
            id TEXT NOT NULL PRIMARY KEY,
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
            pausedUntil TEXT,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            syncedAt TEXT,
            sourceDeviceID TEXT,
            isEnabled INTEGER NOT NULL DEFAULT 1
        )
        """,
        "CREATE INDEX IF NOT EXISTS budget_rules_enabled_idx ON budget_rules(isEnabled, scope)",
        """
        CREATE TABLE IF NOT EXISTS budget_events (
            id TEXT NOT NULL PRIMARY KEY,
            ruleID TEXT NOT NULL,
            kind TEXT NOT NULL,
            source TEXT,
            amountAtEvent REAL NOT NULL,
            limitAtEvent REAL NOT NULL,
            detailJSON TEXT,
            occurredAt TEXT NOT NULL,
            syncedAt TEXT,
            sourceDeviceID TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS budget_events_rule_time_idx ON budget_events(ruleID, occurredAt DESC)",
        """
        CREATE TABLE IF NOT EXISTS switcher_profiles (
            id TEXT NOT NULL PRIMARY KEY,
            targetKind TEXT NOT NULL,
            browserType TEXT,
            browserMetadataJSON TEXT,
            cliType TEXT,
            cliMetadataJSON TEXT,
            sortKey INTEGER NOT NULL DEFAULT 0,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS switcher_profiles_sort_idx ON switcher_profiles(sortKey, createdAt)",
        """
        CREATE TABLE IF NOT EXISTS switcher_active_profile (
            activeProfileID TEXT,
            providerID TEXT,
            updatedAt TEXT NOT NULL
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS switcher_active_provider_idx ON switcher_active_profile(COALESCE(providerID, ''))",
        """
        CREATE TABLE IF NOT EXISTS app_state (
            key TEXT NOT NULL PRIMARY KEY,
            value TEXT NOT NULL,
            updatedAt REAL NOT NULL
        )
        """,
    };
}
