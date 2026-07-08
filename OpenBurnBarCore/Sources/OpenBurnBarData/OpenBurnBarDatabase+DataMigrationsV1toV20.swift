import Foundation
import GRDB

extension OpenBurnBarDatabase {
    static func registerDataMigrationsV1toV20(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "token_usage") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull().indexed()
                t.column("sessionId", .text).notNull().indexed()
                t.column("projectName", .text).notNull()
                t.column("model", .text).notNull()
                t.column("inputTokens", .integer).notNull()
                t.column("outputTokens", .integer).notNull()
                t.column("cacheCreationTokens", .integer).notNull()
                t.column("cacheReadTokens", .integer).notNull()
                t.column("totalTokens", .integer).notNull()
                t.column("cost", .double).notNull()
                t.column("startTime", .datetime).notNull().indexed()
                t.column("endTime", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2_sync") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "syncedAt", .datetime)
            }
        }

        migrator.registerMigration("v3_conversations") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull().indexed()
                t.column("sessionId", .text).notNull().indexed()
                t.column("projectName", .text).notNull()
                t.column("startTime", .datetime)
                t.column("endTime", .datetime)
                t.column("messageCount", .integer).notNull().defaults(to: 0)
                t.column("userWordCount", .integer).notNull().defaults(to: 0)
                t.column("assistantWordCount", .integer).notNull().defaults(to: 0)
                t.column("keyFiles", .text)
                t.column("keyCommands", .text)
                t.column("keyTools", .text)
                t.column("inferredTaskTitle", .text).notNull().defaults(to: "")
                t.column("lastAssistantMessage", .text).notNull().defaults(to: "")
                t.column("fullText", .text).notNull().defaults(to: "")
                t.column("indexedAt", .datetime).notNull()
                t.column("fileModifiedAt", .datetime)
            }

            try db.create(table: "chat_messages") { t in
                t.column("id", .text).primaryKey()
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("cliUsed", .text)
            }

            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE conversations_fts USING fts5(
                    inferredTaskTitle,
                    fullText,
                    content='conversations',
                    content_rowid='rowid',
                    tokenize='porter unicode61'
                )
                """
            )
        }

        migrator.registerMigration("v4_summaries") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "summary", .text)
            }
        }

        migrator.registerMigration("v5_fts_rebuild") { db in
            try db.execute(
                sql: "INSERT INTO conversations_fts(conversations_fts) VALUES('rebuild')"
            )
        }

        migrator.registerMigration("v6_fts_standalone_triggers") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_au")
            try db.execute(sql: "DROP TABLE IF EXISTS conversations_fts")

            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE conversations_fts USING fts5(
                    inferredTaskTitle,
                    fullText,
                    tokenize='porter unicode61'
                )
                """
            )

            try db.execute(
                sql: """
                INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                SELECT rowid, inferredTaskTitle, fullText FROM conversations
                """
            )

            try db.execute(
                sql: """
                CREATE TRIGGER conversations_ai AFTER INSERT ON conversations BEGIN
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER conversations_ad AFTER DELETE ON conversations BEGIN
                    DELETE FROM conversations_fts WHERE rowid = old.rowid;
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER conversations_au AFTER UPDATE ON conversations BEGIN
                    DELETE FROM conversations_fts WHERE rowid = old.rowid;
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
                """
            )
        }

        migrator.registerMigration("v7_conversation_cloud_sync") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "conversationSyncedAt", .datetime)
            }
        }

        migrator.registerMigration("v8_chat_transcript_pieces") { db in
            try db.alter(table: "chat_messages") { t in
                t.add(column: "transcriptPiecesJSON", .text)
            }
        }

        migrator.registerMigration("v9_source_type") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "sourceType", .text).notNull().defaults(to: "provider_log")
            }
        }

        migrator.registerMigration("v10_log_synced_at") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "logSyncedAt", .datetime)
            }
        }

        migrator.registerMigration("v11_auto_summary_metadata") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "summaryTitle", .text)
                t.add(column: "summaryUpdatedAt", .datetime)
                t.add(column: "summaryProvider", .text)
                t.add(column: "summaryModel", .text)
            }

            try db.create(table: "summary_runs") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text).notNull().indexed()
                t.column("provider", .text).notNull()
                t.column("model", .text).notNull()
                t.column("costUSD", .double).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull().indexed()
            }
        }

        migrator.registerMigration("v12_token_usage_dedupe_unique_session_model") { db in
            try db.execute(sql: """
                DELETE FROM token_usage
                WHERE rowid NOT IN (
                    SELECT MAX(rowid)
                    FROM token_usage
                    GROUP BY provider, sessionId, model
                )
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS token_usage_unique_session_model_idx
                ON token_usage(provider, sessionId, model)
                """)
        }

        migrator.registerMigration("v13_backfill_claude_usage_timestamps") { db in
            try db.execute(sql: """
                UPDATE token_usage
                SET
                    startTime = COALESCE(
                        (
                            SELECT c.startTime
                            FROM conversations c
                            WHERE c.provider = token_usage.provider
                              AND c.sessionId = CASE
                                  WHEN instr(token_usage.sessionId, '/') > 0
                                  THEN substr(token_usage.sessionId, 1, instr(token_usage.sessionId, '/') - 1)
                                  ELSE token_usage.sessionId
                              END
                            ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC
                            LIMIT 1
                        ),
                        token_usage.startTime
                    ),
                    endTime = COALESCE(
                        (
                            SELECT COALESCE(c.endTime, c.startTime)
                            FROM conversations c
                            WHERE c.provider = token_usage.provider
                              AND c.sessionId = CASE
                                  WHEN instr(token_usage.sessionId, '/') > 0
                                  THEN substr(token_usage.sessionId, 1, instr(token_usage.sessionId, '/') - 1)
                                  ELSE token_usage.sessionId
                              END
                            ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC
                            LIMIT 1
                        ),
                        token_usage.endTime
                    )
                WHERE token_usage.provider = 'Claude Code'
                """)
        }

        migrator.registerMigration("v14_local_search_substrate") { db in
            try db.create(table: "search_documents") { t in
                t.column("id", .text).primaryKey()
                t.column("sourceKind", .text).notNull().indexed()
                t.column("sourceID", .text).notNull()
                t.column("sourceVersionID", .text).notNull().defaults(to: "")
                t.column("provider", .text)
                t.column("projectName", .text)
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("bodyPreview", .text)
                t.column("sourceUpdatedAt", .datetime)
                t.column("indexedAt", .datetime).notNull().indexed()
                t.column("contentHash", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "search_documents_source_lookup_idx",
                on: "search_documents",
                columns: ["sourceKind", "sourceID", "sourceVersionID"],
                unique: true
            )
            try db.create(
                index: "search_documents_project_provider_idx",
                on: "search_documents",
                columns: ["projectName", "provider", "indexedAt"]
            )

            try db.create(table: "search_chunks") { t in
                t.column("id", .text).primaryKey()
                t.column("documentID", .text)
                    .notNull()
                    .references("search_documents", column: "id", onDelete: .cascade)
                t.column("sourceKind", .text).notNull().indexed()
                t.column("sourceID", .text).notNull()
                t.column("sourceVersionID", .text).notNull().defaults(to: "")
                t.column("ordinal", .integer).notNull()
                t.column("startOffset", .integer).notNull()
                t.column("endOffset", .integer).notNull()
                t.column("messageStartOffset", .integer)
                t.column("messageEndOffset", .integer)
                t.column("sectionPath", .text)
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "search_chunks_unique_document_ordinal_idx",
                on: "search_chunks",
                columns: ["documentID", "ordinal"],
                unique: true
            )
            try db.create(
                index: "search_chunks_document_offset_idx",
                on: "search_chunks",
                columns: ["documentID", "startOffset", "endOffset"]
            )
            try db.create(
                index: "search_chunks_source_lookup_idx",
                on: "search_chunks",
                columns: ["sourceKind", "sourceID", "sourceVersionID"]
            )
            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE search_chunks_fts USING fts5(
                    chunkID UNINDEXED,
                    documentID UNINDEXED,
                    title,
                    chunkText,
                    tokenize='porter unicode61'
                )
                """
            )

            try db.create(table: "projection_jobs") { t in
                t.column("id", .text).primaryKey()
                t.column("jobType", .text).notNull().indexed()
                t.column("sourceKind", .text)
                t.column("sourceID", .text)
                t.column("sourceVersionID", .text).notNull().defaults(to: "")
                t.column("status", .text).notNull().indexed()
                t.column("priority", .integer).notNull().defaults(to: 100)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("maxAttempts", .integer).notNull().defaults(to: 5)
                t.column("payloadJSON", .text)
                t.column("lastErrorCode", .text)
                t.column("lastErrorMessage", .text)
                t.column("scheduledAt", .datetime).notNull()
                t.column("availableAt", .datetime).notNull().indexed()
                t.column("startedAt", .datetime)
                t.column("completedAt", .datetime)
                t.column("leaseOwner", .text)
                t.column("leaseExpiresAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "projection_jobs_poll_idx",
                on: "projection_jobs",
                columns: ["status", "availableAt", "priority", "createdAt"]
            )
            try db.create(
                index: "projection_jobs_source_lookup_idx",
                on: "projection_jobs",
                columns: ["sourceKind", "sourceID", "sourceVersionID"]
            )

            try db.create(table: "embedding_models") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull()
                t.column("modelName", .text).notNull()
                t.column("dimensions", .integer).notNull()
                t.column("distanceMetric", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "embedding_models_provider_model_idx",
                on: "embedding_models",
                columns: ["provider", "modelName"],
                unique: true
            )

            try db.create(table: "embedding_versions") { t in
                t.column("id", .text).primaryKey()
                t.column("modelID", .text)
                    .notNull()
                    .references("embedding_models", column: "id", onDelete: .cascade)
                t.column("versionTag", .text).notNull()
                t.column("chunkerVersion", .text).notNull()
                t.column("normalizationVersion", .text).notNull()
                t.column("promptVersion", .text).notNull()
                t.column("isActive", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "embedding_versions_identity_idx",
                on: "embedding_versions",
                columns: ["modelID", "versionTag", "chunkerVersion", "normalizationVersion", "promptVersion"],
                unique: true
            )
            try db.create(
                index: "embedding_versions_active_idx",
                on: "embedding_versions",
                columns: ["modelID", "isActive"]
            )

            try db.create(table: "chunk_embeddings") { t in
                t.column("chunkID", .text)
                    .notNull()
                    .references("search_chunks", column: "id", onDelete: .cascade)
                t.column("embeddingVersionID", .text)
                    .notNull()
                    .references("embedding_versions", column: "id", onDelete: .cascade)
                t.column("vectorBlob", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["chunkID", "embeddingVersionID"])
            }
            try db.create(
                index: "chunk_embeddings_version_lookup_idx",
                on: "chunk_embeddings",
                columns: ["embeddingVersionID"]
            )

            try db.create(table: "retrieval_health") { t in
                t.column("subsystem", .text).primaryKey()
                t.column("status", .text).notNull()
                t.column("errorCode", .text)
                t.column("errorMessage", .text)
                t.column("detailsJSON", .text)
                t.column("observedAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v15_source_artifact_registry") { db in
            try db.create(table: "source_artifacts") { t in
                t.column("id", .text).primaryKey()
                t.column("sourceKind", .text).notNull().indexed()
                t.column("canonicalPath", .text).notNull()
                t.column("rootPath", .text).notNull().indexed()
                t.column("relativePath", .text).notNull()
                t.column("provenance", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("fileSizeBytes", .integer).notNull().defaults(to: 0)
                t.column("fileModifiedAt", .datetime)
                t.column("status", .text).notNull().defaults(to: SourceArtifactStatus.active.rawValue).indexed()
                t.column("discoveredAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "source_artifacts_canonical_path_idx",
                on: "source_artifacts",
                columns: ["canonicalPath"],
                unique: true
            )
            try db.create(
                index: "source_artifacts_root_relative_idx",
                on: "source_artifacts",
                columns: ["rootPath", "relativePath"],
                unique: true
            )
        }

        migrator.registerMigration("v16_shared_artifact_sync_state") { db in
            try db.create(table: "shared_artifact_sync_state") { t in
                t.column("sourceArtifactID", .text)
                    .primaryKey()
                    .references("source_artifacts", column: "id", onDelete: .cascade)
                t.column("remoteArtifactID", .text).notNull()
                t.column("workspaceID", .text).notNull()
                t.column("teamID", .text).notNull()
                t.column("ownerUserID", .text)
                t.column("revisionID", .text).notNull()
                t.column("remoteContentHash", .text)
                t.column("localContentHashAtSync", .text)
                t.column("remoteUpdatedAt", .datetime)
                t.column("lastPulledAt", .datetime)
                t.column("lastSyncedAt", .datetime)
                t.column("syncStatus", .text).notNull().defaults(to: SharedArtifactSyncStatus.pendingPull.rawValue)
                t.column("lastErrorCode", .text)
                t.column("lastErrorMessage", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "shared_artifact_sync_remote_lookup_idx",
                on: "shared_artifact_sync_state",
                columns: ["remoteArtifactID"],
                unique: true
            )
            try db.create(
                index: "shared_artifact_sync_scope_idx",
                on: "shared_artifact_sync_state",
                columns: ["workspaceID", "teamID"]
            )
            try db.create(
                index: "shared_artifact_sync_status_idx",
                on: "shared_artifact_sync_state",
                columns: ["syncStatus"]
            )
        }

        migrator.registerMigration("v17_shared_artifact_permissions_and_audit") { db in
            try db.create(table: "artifact_permissions") { t in
                t.column("sourceArtifactID", .text)
                    .notNull()
                    .references("source_artifacts", column: "id", onDelete: .cascade)
                t.column("workspaceID", .text).notNull()
                t.column("teamID", .text).notNull()
                t.column("principalType", .text).notNull()
                t.column("principalID", .text).notNull()
                t.column("role", .text).notNull()
                t.column("visibility", .text).notNull()
                t.column("canRead", .boolean).notNull().defaults(to: true)
                t.column("canWrite", .boolean).notNull().defaults(to: false)
                t.column("canShare", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["sourceArtifactID", "principalType", "principalID"])
            }
            try db.create(
                index: "artifact_permissions_principal_lookup_idx",
                on: "artifact_permissions",
                columns: ["workspaceID", "teamID", "principalType", "principalID", "canRead"]
            )
            try db.create(
                index: "artifact_permissions_source_lookup_idx",
                on: "artifact_permissions",
                columns: ["sourceArtifactID", "canRead", "visibility"]
            )

            try db.create(table: "audit_events") { t in
                t.column("id", .text).primaryKey()
                t.column("sourceArtifactID", .text)
                    .references("source_artifacts", column: "id", onDelete: .setNull)
                t.column("remoteArtifactID", .text)
                t.column("workspaceID", .text).notNull()
                t.column("teamID", .text).notNull()
                t.column("actorUserID", .text)
                t.column("actorRole", .text)
                t.column("action", .text).notNull()
                t.column("detailsJSON", .text)
                t.column("occurredAt", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(
                index: "audit_events_source_time_idx",
                on: "audit_events",
                columns: ["sourceArtifactID", "occurredAt"]
            )
            try db.create(
                index: "audit_events_scope_time_idx",
                on: "audit_events",
                columns: ["workspaceID", "teamID", "occurredAt"]
            )
            try db.create(
                index: "audit_events_action_time_idx",
                on: "audit_events",
                columns: ["action", "occurredAt"]
            )
        }

        migrator.registerMigration("v18_summary_attempt_tracking") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "summaryAttemptedAt", .datetime)
            }
        }

        migrator.registerMigration("v19_conversation_fts_trigger_fix") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS conversations_au")

            try db.execute(
                sql: """
                CREATE TRIGGER conversations_ad AFTER DELETE ON conversations BEGIN
                    DELETE FROM conversations_fts WHERE rowid = old.rowid;
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER conversations_au AFTER UPDATE ON conversations BEGIN
                    DELETE FROM conversations_fts WHERE rowid = old.rowid;
                    INSERT INTO conversations_fts(rowid, inferredTaskTitle, fullText)
                    VALUES (new.rowid, new.inferredTaskTitle, new.fullText);
                END
                """
            )
        }

        migrator.registerMigration("v20_chat_threads") { db in
            try db.create(table: "chat_threads") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }

            try db.alter(table: "chat_messages") { t in
                t.add(column: "threadId", .text).notNull().defaults(to: Self.legacyChatThreadID)
            }

            try db.create(
                index: "chat_messages_thread_time_idx",
                on: "chat_messages",
                columns: ["threadId", "timestamp"]
            )

            try db.execute(
                sql: """
                INSERT OR IGNORE INTO chat_threads (id, createdAt, updatedAt)
                VALUES (
                    ?,
                    COALESCE((SELECT MIN(timestamp) FROM chat_messages), CURRENT_TIMESTAMP),
                    COALESCE((SELECT MAX(timestamp) FROM chat_messages), CURRENT_TIMESTAMP)
                )
                """,
                arguments: [Self.legacyChatThreadID]
            )
        }
    }
}
