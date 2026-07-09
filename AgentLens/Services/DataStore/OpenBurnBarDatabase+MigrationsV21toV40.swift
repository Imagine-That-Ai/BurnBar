import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - Migrations v21–v40

/// Ordered migration registrations v21_multifield_fts through
/// v40_reprice_gpt55_cached_input, extracted verbatim from the canonical
/// migrator. Registration order is sacred: bodies and sequence must not change.
extension OpenBurnBarDatabase {
    static func registerMigrationsV21toV40(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v21_multifield_fts") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE search_chunks_fts_new USING fts5(
                    chunkID UNINDEXED,
                    documentID UNINDEXED,
                    title,
                    chunkText,
                    projectName,
                    provider,
                    tokenize='porter unicode61'
                )
                """)

            try db.execute(sql: """
                INSERT INTO search_chunks_fts_new (chunkID, documentID, title, chunkText, projectName, provider)
                SELECT
                    scf.chunkID,
                    scf.documentID,
                    COALESCE(scf.title, ''),
                    COALESCE(scf.chunkText, ''),
                    COALESCE(d.projectName, ''),
                    COALESCE(d.provider, '')
                FROM search_chunks_fts scf
                JOIN search_documents d ON d.id = scf.documentID
                """)

            try db.execute(sql: "DROP TABLE search_chunks_fts")
            try db.execute(sql: "ALTER TABLE search_chunks_fts_new RENAME TO search_chunks_fts")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE search_documents_fts USING fts5(
                    documentID UNINDEXED,
                    title,
                    subtitle,
                    bodyPreview,
                    projectName,
                    provider,
                    tokenize='porter unicode61'
                )
                """)

            try db.execute(sql: """
                INSERT INTO search_documents_fts (documentID, title, subtitle, bodyPreview, projectName, provider)
                SELECT
                    id,
                    COALESCE(title, ''),
                    COALESCE(subtitle, ''),
                    COALESCE(bodyPreview, ''),
                    COALESCE(projectName, ''),
                    COALESCE(provider, '')
                FROM search_documents
                """)

            try db.execute(sql: """
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
                """)

            try db.execute(sql: """
                CREATE TRIGGER search_documents_fts_ad AFTER DELETE ON search_documents BEGIN
                    DELETE FROM search_documents_fts WHERE documentID = old.id;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER search_documents_fts_au AFTER UPDATE ON search_documents BEGIN
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

        migrator.registerMigration("v22_cross_device_sync") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "sourceDeviceId", .text)
                t.add(column: "sourceDeviceName", .text)
                t.add(column: "isRemote", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "DROP INDEX IF EXISTS token_usage_unique_session_model_idx")
            try db.execute(sql: """
                CREATE UNIQUE INDEX token_usage_unique_session_model_device_idx
                ON token_usage(provider, sessionId, model, COALESCE(sourceDeviceId, ''))
                """)
            try db.alter(table: "conversations") { t in
                t.add(column: "sourceDeviceId", .text)
                t.add(column: "sourceDeviceName", .text)
                t.add(column: "isRemote", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "devices") { t in
                t.column("deviceId", .text).primaryKey()
                t.column("deviceName", .text).notNull()
                t.column("isLocal", .integer).notNull().defaults(to: 0)
                t.column("lastSeenAt", .datetime)
                t.column("createdAt", .datetime).notNull()
            }
            let localName = Host.current().localizedName ?? "This Mac"
            let now = Date()
            try db.execute(
                sql: "INSERT OR IGNORE INTO devices (deviceId, deviceName, isLocal, lastSeenAt, createdAt) VALUES (?, ?, 1, ?, ?)",
                arguments: [UserDefaults.standard.string(forKey: OpenBurnBarCore.OpenBurnBarIdentity.deviceIDKey) ?? "unknown", localName, now, now]
            )
        }

        migrator.registerMigration("v23_device_hardware_model") { db in
            try db.alter(table: "devices") { t in
                t.add(column: "hardwareModel", .text)
                t.add(column: "customIcon", .text)
            }
            let hwModel = DeviceHardwareIcon.localHardwareModel
            try db.execute(
                sql: "UPDATE devices SET hardwareModel = ? WHERE isLocal = 1",
                arguments: [hwModel]
            )
        }

        migrator.registerMigration("v24_repair_custom_icon_column") { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(devices)")
            let hasCustomIcon = columns.contains { ($0["name"] as? String) == "customIcon" }
            if !hasCustomIcon {
                try db.alter(table: "devices") { t in
                    t.add(column: "customIcon", .text)
                }
            }
        }

        migrator.registerMigration("v25_operating_action_history") { db in
            try db.create(table: "operating_action_history") { t in
                t.column("id", .text).primaryKey()
                t.column("projectName", .text).notNull()
                t.column("missionFingerprint", .text)
                t.column("actionKind", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("detail", .text)
                t.column("overrideMode", .text)
                t.column("forcedDirectionStatus", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "operating_action_history_project_time_idx",
                on: "operating_action_history",
                columns: ["projectName", "createdAt"]
            )
            try db.create(
                index: "operating_action_history_kind_time_idx",
                on: "operating_action_history",
                columns: ["actionKind", "createdAt"]
            )
            try db.create(
                index: "operating_action_history_mission_time_idx",
                on: "operating_action_history",
                columns: ["missionFingerprint", "createdAt"]
            )
        }

        migrator.registerMigration("v26_controller_runtime_cache") { db in
            try db.create(table: "controller_runtime_cache") { t in
                t.column("cacheKey", .text).primaryKey()
                t.column("payloadJSON", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "controller_runtime_cache_updated_idx",
                on: "controller_runtime_cache",
                columns: ["updatedAt"]
            )
        }

        migrator.registerMigration("v27_token_usage_reasoning_source") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "reasoningTokens", .integer).notNull().defaults(to: 0)
                t.add(column: "usageSource", .text).notNull().defaults(to: "unknown")
            }
            try db.execute(sql: """
                UPDATE token_usage
                SET totalTokens = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens + reasoningTokens
                """)
        }

        migrator.registerMigration("v28_token_usage_provenance") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "provenanceMethod", .text).notNull().defaults(to: "unknown")
                t.add(column: "provenanceConfidence", .text).notNull().defaults(to: "unknown")
                t.add(column: "estimatorVersion", .text).notNull().defaults(to: "")
            }
            // Backfill existing rows based on usageSource + provider confidence
            try db.execute(sql: """
                UPDATE token_usage
                SET provenanceMethod = CASE
                    WHEN usageSource = 'provider_log' THEN 'provider_log'
                    WHEN usageSource = 'cursor_bridge' THEN 'connector_bridge'
                    WHEN usageSource = 'daemon' THEN 'daemon_bridge'
                    WHEN usageSource = 'in_app_chat' THEN 'in_app_chat'
                    WHEN usageSource = 'billing_api' THEN 'billing_api'
                    ELSE 'provider_log'
                END,
                provenanceConfidence = CASE
                    WHEN usageSource IN ('provider_log', 'cursor_bridge', 'daemon', 'in_app_chat', 'billing_api') THEN 'exact'
                    ELSE 'unknown'
                END,
                estimatorVersion = ''
                WHERE provenanceMethod = 'unknown'
                """)
        }

        migrator.registerMigration("v29_parser_checkpoints") { db in
            // Tracks parser checkpoint/high-watermark state for safe resume after interruption.
            // Checkpoint advances only after successful ingestion transaction commit (VAL-PERSIST-004).
            // Resume from checkpoint must be gap-free and duplicate-free (VAL-PERSIST-005).
            try db.create(table: "parser_checkpoints") { t in
                t.column("provider", .text).primaryKey()
                t.column("checkpointToken", .text).notNull()
                t.column("lastProcessedFilePath", .text)
                t.column("lastProcessedAt", .datetime).notNull()
                t.column("version", .integer).notNull().defaults(to: 1)
            }
            // Index for querying checkpoints by provider
            try db.create(
                index: "parser_checkpoints_provider_idx",
                on: "parser_checkpoints",
                columns: ["provider"]
            )
        }

        migrator.registerMigration("v30_remote_sync_watermarks") { db in
            // Tracks durable remote sync watermarks per account and collection scope.
            // Watermark advances ONLY after successful sync commit (VAL-PERSIST-010).
            // Scope is account-aware and collection-safe (VAL-PERSIST-011).
            try db.create(table: "remote_sync_watermarks") { t in
                t.column("accountUid", .text).notNull()
                t.column("collectionKind", .text).notNull()
                t.column("lastSyncedAt", .datetime).notNull()
                t.column("lastProcessedRemoteUpdateAt", .datetime)
                t.column("version", .integer).notNull().defaults(to: 1)
                t.primaryKey(["accountUid", "collectionKind"])
            }
            try db.create(
                index: "remote_sync_watermarks_account_idx",
                on: "remote_sync_watermarks",
                columns: ["accountUid"]
            )
        }

        migrator.registerMigration("v31_chunk_content_hash") { db in
            // Add content-based hash column to search_chunks for incremental diffing.
            // Unlike chunk ID (which includes sourceVersionID), contentHash is stable
            // across re-projections, enabling unchanged-chunk skip and embedding reuse.
            try db.alter(table: "search_chunks") { t in
                t.add(column: "contentHash", .text)
            }
            // Index for efficient lookup of existing embeddings by contentHash.
            try db.create(
                index: "search_chunks_content_hash_idx",
                on: "search_chunks",
                columns: ["documentID", "contentHash"]
            )
        }

        migrator.registerMigration("v32_switcher_profiles") { db in
            // Switcher profile registry for account-based profile launching.
            // Stores ONLY non-sensitive launch metadata — no OAuth tokens, passwords, or cookies.
            //
            // Profile types:
            //   - browser: Chrome and Safari profile identifiers for browser-based launching
            //   - cli: Codex, Claude Code, and OpenCode profile configurations
            //
            // Security boundaries:
            //   - VAL-SWITCH-001: No cookie/session import or raw credential persistence
            //   - Profile metadata is launch-only reference data; secrets remain in Keychain/system stores

            try db.create(table: "switcher_profiles") { t in
                t.column("id", .text).primaryKey()
                t.column("targetKind", .text).notNull().indexed()
                t.column("browserType", .text)
                t.column("browserMetadataJSON", .text)
                t.column("cliType", .text)
                t.column("cliMetadataJSON", .text)
                t.column("sortKey", .integer).notNull().defaults(to: 0).indexed()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Deterministic ordering index: sortKey ASC, createdAt ASC
            try db.create(
                index: "switcher_profiles_deterministic_order_idx",
                on: "switcher_profiles",
                columns: ["sortKey", "createdAt"]
            )

            // Active profile state: single-row table for atomic active profile transitions
            try db.create(table: "switcher_active_profile") { t in
                t.column("activeProfileID", .text)
                t.column("updatedAt", .datetime).notNull()
            }

            // Initial row ensures ON CONFLICT DO NOTHING semantics work
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (NULL, ?)",
                arguments: [Date()]
            )
        }

        migrator.registerMigration("v33_backfill_cursors") { db in
            // Tracks historical backfill cursor state per provider for monotonic window progression.
            //
            // VAL-PERSIST-006: Backfill run is bounded to 7-day window.
            // VAL-PERSIST-007: Backfill cursor progresses monotonically across runs.
            //
            // The lastProcessedWindowUpperBound is the exclusive upper bound of the last
            // successfully processed 7-day window. New backfill starts from this point.
            try db.create(table: "backfill_cursors") { t in
                t.column("provider", .text).primaryKey()
                t.column("lastProcessedWindowUpperBound", .datetime)
                t.column("earliestSourceDate", .datetime)
                t.column("updatedAt", .datetime).notNull()
                t.column("version", .integer).notNull().defaults(to: 1)
            }
            try db.create(
                index: "backfill_cursors_provider_idx",
                on: "backfill_cursors",
                columns: ["provider"]
            )
        }

        migrator.registerMigration("v34_vector_index_snapshots") { db in
            try db.create(table: "vector_index_snapshots") { t in
                t.column("embeddingVersionID", .text)
                    .notNull()
                    .references("embedding_versions", column: "id", onDelete: .cascade)
                t.column("backendID", .text).notNull()
                t.column("state", .text).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("dimensions", .integer).notNull()
                t.column("distanceMetric", .text).notNull()
                t.column("vectorCount", .integer).notNull().defaults(to: 0)
                t.column("storageRelativePath", .text)
                t.column("fileBytes", .integer).notNull().defaults(to: 0)
                t.column("backendVersion", .text).notNull()
                t.column("errorCode", .text)
                t.column("errorMessage", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("lastBuiltAt", .datetime)
                t.primaryKey(["embeddingVersionID", "backendID"])
            }
            try db.create(
                index: "vector_index_snapshots_state_idx",
                on: "vector_index_snapshots",
                columns: ["state", "updatedAt"]
            )
        }

        migrator.registerMigration("v35_provider_accounts") { db in
            try db.create(table: "provider_accounts") { t in
                t.column("id", .text).primaryKey()
                t.column("providerID", .text).notNull().indexed()
                t.column("label", .text).notNull()
                t.column("identityHint", .text)
                t.column("status", .text).notNull()
                t.column("credentialKind", .text).notNull()
                t.column("storageScope", .text).notNull().indexed()
                t.column("redactedLabel", .text).notNull()
                t.column("sourceDeviceID", .text)
                t.column("linkedSwitcherProfileID", .text)
                t.column("isDefault", .boolean).notNull().defaults(to: false).indexed()
                t.column("sortKey", .double).notNull().defaults(to: 0)
                t.column("lastValidatedAt", .datetime)
                t.column("lastRefreshAt", .datetime)
                t.column("lastErrorCode", .text)
                t.column("schemaVersion", .integer).notNull().defaults(to: 1)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "provider_accounts_provider_sort_idx",
                on: "provider_accounts",
                columns: ["providerID", "sortKey", "createdAt"]
            )
            try db.create(
                index: "provider_accounts_provider_default_idx",
                on: "provider_accounts",
                columns: ["providerID", "isDefault"]
            )

            try db.alter(table: "token_usage") { t in
                t.add(column: "providerID", .text)
                t.add(column: "providerAccountID", .text)
                t.add(column: "providerAccountLabel", .text)
                t.add(column: "providerAccountSource", .text)
            }
            try db.execute(sql: """
                UPDATE token_usage
                SET providerID = CASE
                    WHEN provider = 'Claude Code' THEN 'claude-code'
                    WHEN provider = 'Codex' THEN 'codex'
                    ELSE lower(replace(provider, ' ', ''))
                END
                WHERE providerID IS NULL
                """)
            try db.execute(sql: "DROP INDEX IF EXISTS token_usage_unique_session_model_device_idx")
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX token_usage_unique_session_model_device_account_idx
                ON token_usage(provider, sessionId, model, COALESCE(sourceDeviceId, ''), COALESCE(providerAccountID, ''))
                """
            )
            try db.create(
                index: "token_usage_provider_account_idx",
                on: "token_usage",
                columns: ["provider", "providerAccountID"]
            )
            try db.create(
                index: "token_usage_account_time_idx",
                on: "token_usage",
                columns: ["providerAccountID", "startTime"]
            )
        }

        migrator.registerMigration("v36_repair_kimi_request_id_models") { db in
            // Older Kimi imports could persist OpenAI-style response IDs as model names
            // and count cache-read tokens in both input and cache buckets. Drop duplicate
            // legacy rows when a corrected kimi-for-coding row already exists, then repair
            // any remaining rows in place so dashboards stop treating request IDs as models.
            try db.execute(sql: """
                DELETE FROM token_usage
                WHERE provider = 'Kimi'
                  AND model LIKE 'chatcmpl-%'
                  AND EXISTS (
                    SELECT 1
                    FROM token_usage corrected
                    WHERE corrected.provider = token_usage.provider
                      AND corrected.sessionId = token_usage.sessionId
                      AND corrected.model = 'kimi-for-coding'
                      AND COALESCE(corrected.sourceDeviceId, '') = COALESCE(token_usage.sourceDeviceId, '')
                      AND COALESCE(corrected.providerAccountID, '') = COALESCE(token_usage.providerAccountID, '')
                  )
                """)

            try db.execute(sql: """
                DELETE FROM token_usage
                WHERE provider = 'Kimi'
                  AND model LIKE 'chatcmpl-%'
                  AND EXISTS (
                    SELECT 1
                    FROM token_usage winner
                    WHERE winner.provider = token_usage.provider
                      AND winner.sessionId = token_usage.sessionId
                      AND winner.model LIKE 'chatcmpl-%'
                      AND COALESCE(winner.sourceDeviceId, '') = COALESCE(token_usage.sourceDeviceId, '')
                      AND COALESCE(winner.providerAccountID, '') = COALESCE(token_usage.providerAccountID, '')
                      AND (
                        winner.totalTokens > token_usage.totalTokens
                        OR (winner.totalTokens = token_usage.totalTokens AND winner.rowid > token_usage.rowid)
                      )
                  )
                """)

            try db.execute(sql: """
                UPDATE token_usage
                SET model = 'kimi-for-coding',
                    inputTokens = MAX(0, inputTokens - cacheReadTokens - cacheCreationTokens),
                    totalTokens = MAX(0, inputTokens - cacheReadTokens - cacheCreationTokens)
                        + outputTokens
                        + cacheCreationTokens
                        + cacheReadTokens
                        + COALESCE(reasoningTokens, 0),
                    cost = (
                        (MAX(0, inputTokens - cacheReadTokens - cacheCreationTokens) + cacheCreationTokens) * 0.6
                        + outputTokens * 2.5
                        + cacheReadTokens * 0.15
                    ) / 1000000.0,
                    syncedAt = NULL
                WHERE provider = 'Kimi'
                  AND model LIKE 'chatcmpl-%'
                """)
        }

        migrator.registerMigration("v37_token_usage_performance_indexes") { db in
            try db.create(
                index: "token_usage_sync_pending_idx",
                on: "token_usage",
                columns: ["syncedAt", "isRemote", "startTime"]
            )
            try db.create(
                index: "token_usage_provider_time_idx",
                on: "token_usage",
                columns: ["provider", "startTime"]
            )
            try db.create(
                index: "token_usage_provider_model_time_idx",
                on: "token_usage",
                columns: ["provider", "model", "startTime"]
            )
            try db.create(
                index: "token_usage_provider_id_time_idx",
                on: "token_usage",
                columns: ["providerID", "startTime"]
            )
        }

        migrator.registerMigration("v38_chat_message_attachments") { db in
            try db.alter(table: "chat_messages") { t in
                t.add(column: "attachmentsJSON", .text)
            }
        }

        migrator.registerMigration("v39_project_memory_snapshots") { db in
            try db.create(table: "project_memory_snapshots") { t in
                t.column("projectSlug", .text).primaryKey()
                t.column("projectDisplayName", .text).notNull()
                t.column("snapshotJSON", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("sourceSessionCount", .integer).notNull().defaults(to: 0)
                t.column("sourceConversationCount", .integer).notNull().defaults(to: 0)
                t.column("generatedAt", .datetime).notNull().indexed()
                t.column("schemaVersion", .integer).notNull().defaults(to: 1)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "project_memory_snapshots_updated_idx",
                on: "project_memory_snapshots",
                columns: ["updatedAt"]
            )
        }

        migrator.registerMigration("v40_reprice_gpt55_cached_input") { db in
            try db.execute(sql: """
                UPDATE token_usage
                SET cost = (
                        MAX(inputTokens, 0) * 5.0
                        + MAX(outputTokens, 0) * 30.0
                        + MAX(cacheCreationTokens, 0) * 5.0
                        + MAX(cacheReadTokens, 0) * 0.5
                    ) / 1000000.0,
                    syncedAt = NULL
                WHERE LOWER(model) IN ('gpt-5.5', 'gpt-5.5-fast')
                """)
        }
    }
}
