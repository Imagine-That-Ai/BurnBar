# Database Operations

This runbook covers the macOS app's local GRDB/SQLCipher database, migration contract, backup handling, and recovery drills.

## Storage Contract

The canonical database is:

```text
~/Library/Application Support/OpenBurnBar/openburnbar.sqlite
```

Encryption at rest is enabled by default. The SQLCipher passphrase is held by the app's key-management path, not by this runbook or the rollback shell script. A stock `sqlite3` process cannot read an encrypted database and must not be used as an integrity or migration check.

The production Keychain account is reserved for the installed app. XCTest and UI-test processes must use an injected in-memory Keychain client or their process-local `.xctest.<pid>` account. Tests must never create, read, or delete the production database-key item.

When an encrypted database already exists, startup may only open it with an existing Keychain key. A missing key must not cause a replacement key to be generated. A missing or rejected key leaves the database bytes in place and enters recovery mode with a specific error.

The database normally runs in WAL mode. `openburnbar.sqlite`, `openburnbar.sqlite-wal`, and `openburnbar.sqlite-shm` are one storage unit while a writer is active. Never copy only the main file from a live database.

## Migration Architecture

GRDB registers 58 ordered migrations through `v57_execution_source_attribution`. Applied identifiers live in `grdb_migrations`, inside the encrypted database.

The macOS app and shared `OpenBurnBarData` target intentionally carry parallel migration definitions. CI runs `scripts/ci/verify-migration-rollback-catalog.mjs`, which enforces:

- exact registration order from each migrator's actual function-call sequence;
- normalized migration-body equality;
- exact, hash-pinned exceptions for reviewed platform adaptations;
- exact rollback-catalog order and coverage; and
- this generated documentation table.

The hash-pinned exceptions are narrow. Changing either implementation, including the shared v46 provider mapping helper, invalidates the exception and requires review.

### Transaction, Retry, and Rollback

These properties are separate:

- **Transaction `atomic`:** GRDB commits the migration body and its identifier together. A thrown error rolls back the migration transaction.
- **Retry `unapplied-only`:** relaunch retry is supported only when the identifier is absent because the transaction did not commit. This does not assert that individual `ALTER TABLE`, FTS, or data-rewrite statements are idempotent.
- **Rollback `backup-restore`:** OpenBurnBar does not ship or certify down migrations. The supported rollback is restoration of a keyed pre-migration backup.

No current migration is classified as independently reversible. SQL snippets printed by `scripts/rollback-migration.sh vXX` are forensic notes, not executable or tested down migrations.

## Migration Catalog

<!-- BEGIN GENERATED MIGRATION CATALOG -->
| # | Name | Transaction | Retry | Rollback | Description |
|---:|---|---|---|---|---|
| 1 | `v1_initial` | atomic | unapplied-only | backup-restore | Initial schema creation — all core tables |
| 2 | `v2_sync` | atomic | unapplied-only | backup-restore | Cloud sync tracking columns |
| 3 | `v3_conversations` | atomic | unapplied-only | backup-restore | Conversation model and FTS |
| 4 | `v4_summaries` | atomic | unapplied-only | backup-restore | Summary tables |
| 5 | `v5_fts_rebuild` | atomic | unapplied-only | backup-restore | Full FTS index rebuild |
| 6 | `v6_fts_standalone_triggers` | atomic | unapplied-only | backup-restore | Standalone FTS triggers |
| 7 | `v7_conversation_cloud_sync` | atomic | unapplied-only | backup-restore | Conversation cloud sync metadata |
| 8 | `v8_chat_transcript_pieces` | atomic | unapplied-only | backup-restore | Chat transcript pieces table |
| 9 | `v9_source_type` | atomic | unapplied-only | backup-restore | Source type column addition |
| 10 | `v10_log_synced_at` | atomic | unapplied-only | backup-restore | Log sync timestamp column |
| 11 | `v11_auto_summary_metadata` | atomic | unapplied-only | backup-restore | Auto-summary metadata columns |
| 12 | `v12_token_usage_dedupe_unique_session_model` | atomic | unapplied-only | backup-restore | Token usage dedup with unique session+model constraint |
| 13 | `v13_backfill_claude_usage_timestamps` | atomic | unapplied-only | backup-restore | Backfill Claude usage timestamps |
| 14 | `v14_local_search_substrate` | atomic | unapplied-only | backup-restore | Local search substrate (FTS5 + semantic) |
| 15 | `v15_source_artifact_registry` | atomic | unapplied-only | backup-restore | Source artifact registry table |
| 16 | `v16_shared_artifact_sync_state` | atomic | unapplied-only | backup-restore | Shared artifact sync state columns |
| 17 | `v17_shared_artifact_permissions_and_audit` | atomic | unapplied-only | backup-restore | Shared artifact permissions and audit |
| 18 | `v18_summary_attempt_tracking` | atomic | unapplied-only | backup-restore | Summary attempt tracking |
| 19 | `v19_conversation_fts_trigger_fix` | atomic | unapplied-only | backup-restore | Conversation FTS trigger fix |
| 20 | `v20_chat_threads` | atomic | unapplied-only | backup-restore | Chat threads table |
| 21 | `v21_multifield_fts` | atomic | unapplied-only | backup-restore | Multi-field FTS content |
| 22 | `v22_cross_device_sync` | atomic | unapplied-only | backup-restore | Cross-device sync columns |
| 23 | `v23_device_hardware_model` | atomic | unapplied-only | backup-restore | Device hardware model column |
| 24 | `v24_repair_custom_icon_column` | atomic | unapplied-only | backup-restore | Repair custom icon column |
| 25 | `v25_operating_action_history` | atomic | unapplied-only | backup-restore | Operating action history table |
| 26 | `v26_controller_runtime_cache` | atomic | unapplied-only | backup-restore | Controller runtime cache table |
| 27 | `v27_token_usage_reasoning_source` | atomic | unapplied-only | backup-restore | Token usage reasoning source column |
| 28 | `v28_token_usage_provenance` | atomic | unapplied-only | backup-restore | Token usage provenance tracking |
| 29 | `v29_parser_checkpoints` | atomic | unapplied-only | backup-restore | Parser checkpoint store |
| 30 | `v30_remote_sync_watermarks` | atomic | unapplied-only | backup-restore | Remote sync watermark store |
| 31 | `v31_chunk_content_hash` | atomic | unapplied-only | backup-restore | Chunk content hash column |
| 32 | `v32_switcher_profiles` | atomic | unapplied-only | backup-restore | Switcher profiles table |
| 33 | `v33_backfill_cursors` | atomic | unapplied-only | backup-restore | Cursor backfill migration |
| 34 | `v34_vector_index_snapshots` | atomic | unapplied-only | backup-restore | Vector index snapshot tracking |
| 35 | `v35_provider_accounts` | atomic | unapplied-only | backup-restore | Provider accounts table and token usage account attribution |
| 36 | `v36_repair_kimi_request_id_models` | atomic | unapplied-only | backup-restore | Repair Kimi request-id models and duplicate cache accounting |
| 37 | `v37_token_usage_performance_indexes` | atomic | unapplied-only | backup-restore | Token usage performance indexes |
| 38 | `v38_chat_message_attachments` | atomic | unapplied-only | backup-restore | Chat message attachments JSON column |
| 39 | `v39_project_memory_snapshots` | atomic | unapplied-only | backup-restore | Project memory snapshot table |
| 40 | `v40_reprice_gpt55_cached_input` | atomic | unapplied-only | backup-restore | Reprice GPT-5.5 cached input rows |
| 41 | `v41_reprice_openai_family_cached_input` | atomic | unapplied-only | backup-restore | Reprice OpenAI-family cached input rows |
| 42 | `v42_budget_rules_and_events` | atomic | unapplied-only | backup-restore | Budget rules and budget events tables |
| 43 | `v43_text_expansion_snippets` | atomic | unapplied-only | backup-restore | Text expansion snippets table and active-trigger index |
| 44 | `v44_repair_token_accounting_duplicates` | atomic | unapplied-only | backup-restore | Delete duplicated token accounting rows |
| 45 | `v45_conversation_working_directory` | atomic | unapplied-only | backup-restore | Conversation working directory column |
| 46 | `v46_drain_target_per_provider` | atomic | unapplied-only | backup-restore | Per-provider switcher drain target pointer |
| 47 | `v47_conversation_tombstones` | atomic | unapplied-only | backup-restore | Conversation tombstone and version columns |
| 48 | `v48_conversation_fts_orphan_repair` | atomic | unapplied-only | backup-restore | Repair orphaned conversation FTS rows |
| 49 | `v49_token_usage_parent_request_id` | atomic | unapplied-only | backup-restore | Fusion parent request attribution column and index |
| 50 | `v50_project_code_memory_schema` | atomic | unapplied-only | backup-restore | Project Code Memory tables and indexes |
| 51 | `v51a_drop_body_fts` | atomic | unapplied-only | backup-restore | Drop obsolete body-only agent memory FTS table |
| 52 | `v51_chat_memory_authority` | atomic | unapplied-only | backup-restore | Chat memory authority metadata, jobs, and tombstones |
| 53 | `v52_memory_extraction_job_intent_and_lease` | atomic | unapplied-only | backup-restore | Memory extraction intent and lease columns |
| 54 | `v53_memory_forget_outbox` | atomic | unapplied-only | backup-restore | User-scoped memory forget replication outbox |
| 55 | `v54_provider_quota_snapshots` | atomic | unapplied-only | backup-restore | Durable provider quota snapshot cache |
| 56 | `v55_search_chunks_fts_rowid` | atomic | unapplied-only | backup-restore | Backfill search_chunks ftsRowid and sweep orphaned FTS rows for rowid-targeted deletes |
| 57 | `v56_parser_checkpoint_file_manifest` | atomic | unapplied-only | backup-restore | Normalized parser checkpoint file-identity manifest |
| 58 | `v57_execution_source_attribution` | atomic | unapplied-only | backup-restore | Execution-source columns, index, and evidence-backed historical attribution |
| 59 | `v58_ai_inbox` | atomic | unapplied-only | backup-restore | AI Inbox items, delivery state, and routing indexes |
| 60 | `v59_founder_lens` | atomic | unapplied-only | backup-restore | Founder Lens reply threads, plan ledger, and memory export |
| 61 | `v60_billing_kind` | atomic | unapplied-only | backup-restore | Billing provenance column (api vs subscription spend) with deterministic backfill |
| 62 | `v61_usage_memory` | atomic | unapplied-only | backup-restore | Usage-memory substrate: candidate spool, salience sidecar, memory links, extraction-job source_kind |
| 63 | `v62_war_room_originator` | atomic | unapplied-only | backup-restore | War Room STARTED BY attribution columns on token_usage plus the originator lookup index |
| 64 | `v63_standing_orders` | atomic | unapplied-only | backup-restore | Standing orders table backing the War Room rhythm (cadence, target machine, last fired) |
| 65 | `v64_token_usage_start_time_index` | atomic | unapplied-only | backup-restore | Index on token_usage.startTime so the Command Board window scan stops walking the table |
| 66 | `v65_memory_quarantine_bodies` | atomic | unapplied-only | backup-restore | Encrypted review holding table for quarantined memory bodies |
| 67 | `v66_agent_memory_bodies` | atomic | unapplied-only | backup-restore | Approved bodies for engine-mirrored memories, the copy blind sync seals and uploads |
<!-- END GENERATED MIGRATION CATALOG -->

Regenerate and verify the table with:

```bash
node scripts/ci/verify-migration-rollback-catalog.mjs --write-doc
node scripts/ci/verify-migration-rollback-catalog.test.mjs
```

CI runs the verifier without `--write-doc`, so stale documentation fails closed.

## Automatic Migration Backup

`runMigrationsSafely()` checks whether the latest migration is absent. Before migrating an existing on-disk database, it:

1. opens the database through the already-keyed GRDB writer;
2. runs `PRAGMA integrity_check` through that keyed connection;
3. creates `openburnbar.sqlite.backup.<timestamp>` with GRDB's online backup API and a keyed destination configuration;
4. runs the ordered migrator; and
5. restores that backup automatically if migration fails.

Ordinary launches at the current schema do not run the full migration backup path. The app retains the five newest automatic backups.

## Quiesced Inspection Bundle

For incident preservation, first quit OpenBurnBar, then run:

```bash
scripts/rollback-migration.sh --inspect
```

The command fails unless `lsof` proves no process has the database or sidecars open. It copies the encrypted main file and every present WAL/SHM sidecar into a mode-0700 timestamped bundle, rechecks quiescence, byte-compares every source and destination, rejects sidecar creation/removal during the copy, and writes SHA-256 checksums.

This is a byte-preservation bundle, not a logical SQLite backup. It deliberately does not invoke `sqlite3`, request the SQLCipher key, or report a false integrity result. If a process opens the source during the copy, the command quarantines the bundle and fails.

## Recovery

### Migration Failure

The app first attempts automatic restoration from the keyed pre-migration backup. If startup still cannot open, key, validate, or migrate the database, it enters recovery mode and does not start dashboard refresh, cloud sync, daemon attach, cursor attach, or periodic parsing.

Use recovery mode to copy diagnostics and preserve the support directory before taking further action. **Archive and Reset** moves the database and sidecars to `StartupRecovery/<timestamp>/` before creating a clean database.

### Missing or Rejected Encryption Key

If recovery mode says the encryption key is missing or rejected, stop retrying until the original key or a recovery bundle is available. The encrypted file is intentionally preserved; generating another key cannot unlock it. First quit the app and make a quiesced inspection bundle. Then use one of these supported paths:

1. Restore the original Keychain item and retry.
2. Import the matching passphrase-wrapped recovery bundle and retry.
3. After confirming the preserved archive is sufficient, use **Archive and Reset** to rebuild local data with the current persisted key.

Do not delete the database, disable encryption, or run a plaintext SQLite repair against it. Database backups require the same original key, so restoring only an older encrypted file does not solve a lost-key incident.

### Operator Restore

Do not perform an ad hoc SQL rollback. Restore the complete encrypted artifact while OpenBurnBar is fully quit:

1. Preserve the current database with `scripts/rollback-migration.sh --inspect`.
2. Select an app-created `openburnbar.sqlite.backup.<timestamp>` from before the failed migration.
3. Move the current main file and sidecars together to a quarantine directory.
4. Copy the selected backup to `openburnbar.sqlite` with owner-only permissions. Do not reuse stale WAL/SHM sidecars.
5. Relaunch OpenBurnBar. The app applies the Keychain-held SQLCipher key, validates the database, and runs only unapplied migrations.

If the Keychain key is missing or belongs to another installation, file replacement cannot recover the data. Use the app's passphrase-wrapped encryption-key recovery bundle flow or restore the original Keychain item; do not disable encryption or attempt plaintext fallback.

## Rollback Drill

Run drills only on an isolated test account and copied support directory, never the active production profile.

1. Confirm the app can open the test copy and reports the expected latest migration.
2. Quit the app and create a quiesced inspection bundle.
3. Verify the bundle checksums with `shasum -a 256 -c SHA256SUMS` from inside the bundle.
4. Exercise recovery-mode Archive and Reset on the test copy.
5. Restore an app-created keyed migration backup with the app quit.
6. Relaunch and verify schema, representative reads/writes, FTS search, and provider-account routing.
7. Record the app version, source migration, target migration, backup identifier, and result in the incident or release evidence.

Do not simulate failure by manually inserting an unknown row into a live `grdb_migrations` table. That requires a keyed connection and does not model a transactional migration failure.

## Adding a Migration

1. Add the migration to both ordered migrator surfaces without changing any prior registration or body.
2. Use a new immutable identifier; never rename or edit a migration that may have shipped.
3. Add the same ordered entry to `MIGRATIONS` in `scripts/rollback-migration.sh`.
4. Keep the contract `atomic|unapplied-only|backup-restore` unless the implementation and tests establish a stronger property.
5. Add forensic notes only when they are useful for diagnosis. Do not present them as a supported down migration.
6. Run `node scripts/ci/verify-migration-rollback-catalog.mjs --write-doc`.
7. Run the verifier tests and the app/shared migration tests against an encrypted fixture upgraded from the previous release schema.

Any intentional app/shared body difference must have a narrow reason, exact fingerprints for both bodies, and mutation coverage. A broad name-only allowlist is not acceptable.
