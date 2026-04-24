# Database Operations

This document covers OpenBurnBar's local SQLite database: migration management, rollback strategies, and operational drills.

## Database Location

```
~/Library/Application Support/OpenBurnBar/OpenBurnBar.sqlite
```

Backups are created automatically by the app before each migration run (via `runMigrationsSafely()`). Backup location:

```
~/Library/Application Support/OpenBurnBar/OpenBurnBar.sqlite.backup-<timestamp>
```

## Migration Architecture

OpenBurnBar uses [GRDB](https://github.com/groue/GRDB.swift) for schema migrations. Each migration is registered with a unique string identifier (e.g., `v1_initial`, `v2_sync`) and runs in order. GRDB tracks applied migrations in the `grdb_migrations` table.

### Migration Lifecycle

1. App launches → `DataStore` initializes with `runMigrations: true`
2. `runMigrationsSafely()` runs integrity check (`PRAGMA integrity_check`)
3. If integrity passes, creates backup (except in-memory databases)
4. GRDB migrator runs all unapplied migrations in order
5. If a migration fails, the app starts with `runMigrations: false` and logs the error

### Migration Catalog

| # | Name | Safety | Description |
|---|------|--------|-------------|
| 1 | `v1_initial` | safe-rerun | Initial schema — all core tables |
| 2 | `v2_sync` | manual | Cloud sync tracking columns |
| 3 | `v3_conversations` | manual | Conversation model and FTS |
| 4 | `v4_summaries` | safe-rerun | Summary tables |
| 5 | `v5_fts_rebuild` | safe-rerun | Full FTS index rebuild |
| 6 | `v6_fts_standalone_triggers` | safe-rerun | Standalone FTS triggers |
| 7 | `v7_conversation_cloud_sync` | manual | Conversation cloud sync metadata |
| 8 | `v8_chat_transcript_pieces` | safe-rerun | Chat transcript pieces table |
| 9 | `v9_source_type` | manual | Source type column addition |
| 10 | `v10_log_synced_at` | safe-rerun | Log sync timestamp column |
| 11 | `v11_auto_summary_metadata` | safe-rerun | Auto-summary metadata columns |
| 12 | `v12_token_usage_dedupe_unique_session_model` | manual | Token usage dedup with unique constraint |
| 13 | `v13_backfill_claude_usage_timestamps` | safe-rerun | Backfill Claude usage timestamps |
| 14 | `v14_local_search_substrate` | manual | Local search substrate (FTS5 + semantic) |
| 15 | `v15_source_artifact_registry` | manual | Source artifact registry table |
| 16 | `v16_shared_artifact_sync_state` | safe-rerun | Shared artifact sync state columns |
| 17 | `v17_shared_artifact_permissions_and_audit` | manual | Shared artifact permissions and audit |
| 18 | `v18_summary_attempt_tracking` | safe-rerun | Summary attempt tracking |
| 19 | `v19_conversation_fts_trigger_fix` | safe-rerun | Conversation FTS trigger fix |
| 20 | `v20_chat_threads` | manual | Chat threads table |
| 21 | `v21_multifield_fts` | manual | Multi-field FTS content |
| 22 | `v22_cross_device_sync` | safe-rerun | Cross-device sync columns |
| 23 | `v23_device_hardware_model` | safe-rerun | Device hardware model column |
| 24 | `v24_repair_custom_icon_column` | safe-rerun | Repair custom icon column |
| 25 | `v25_operating_action_history` | manual | Operating action history table |
| 26 | `v26_controller_runtime_cache` | safe-rerun | Controller runtime cache table |
| 27 | `v27_token_usage_reasoning_source` | safe-rerun | Token usage reasoning source column |
| 28 | `v28_token_usage_provenance` | manual | Token usage provenance tracking |
| 29 | `v29_parser_checkpoints` | safe-rerun | Parser checkpoint store |
| 30 | `v30_remote_sync_watermarks` | safe-rerun | Remote sync watermark store |
| 31 | `v31_chunk_content_hash` | safe-rerun | Chunk content hash column |
| 32 | `v32_switcher_profiles` | manual | Switcher profiles table |
| 33 | `v33_backfill_cursors` | safe-rerun | Cursor backfill migration |
| 34 | `v34_vector_index_snapshots` | manual | Vector index snapshot tracking |

### Safety Classifications

- **safe-rerun**: Migration is idempotent. If a partial failure occurs, re-launching the app will re-attempt the migration from where it left off. No data loss risk.
- **manual**: Migration adds tables, columns, or constraints that cannot be trivially reverted in SQLite (e.g., `DROP COLUMN` requires SQLite 3.35.0+, `DROP UNIQUE` requires table rebuild). Reverting these requires careful SQL and may cause data loss.

## Rollback Strategies

### Strategy 1: Restore from Backup (Recommended for all cases)

The app creates a timestamped backup before each migration. This is the safest rollback path.

```bash
# 1. Stop OpenBurnBar completely (quit from menu bar)

# 2. List available backups
ls -lt ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite.backup-*

# 3. Verify backup integrity
sqlite3 ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite.backup-YYYYMMDD-HHMMSS "PRAGMA integrity_check;"
# Expected output: ok

# 4. Replace the live database with the backup
cd ~/Library/Application\ Support/OpenBurnBar/
cp OpenBurnBar.sqlite OpenBurnBar.sqlite.failed-$(date +%Y%m%d-%H%M%S)
cp OpenBurnBar.sqlite.backup-YYYYMMDD-HHMMSS OpenBurnBar.sqlite

# 5. Relaunch OpenBurnBar
open -a OpenBurnBar
```

### Strategy 2: Re-run Safe Migrations

For `safe-rerun` migrations, simply relaunch the app. The GRDB migrator will detect the unapplied migration and re-run it.

### Strategy 3: Manual SQL Revert (Last Resort)

For `manual` migrations, use the rollback helper script to review suggested SQL:

```bash
scripts/rollback-migration.sh v34
```

Then apply the SQL against a backup copy first:

```bash
# 1. Create an inspection backup
scripts/rollback-migration.sh --inspect

# 2. Test the revert SQL in the interactive session

# 3. Only after testing, apply to live DB (with backup)
```

### Strategy 4: Nuclear Reset

If the database is beyond repair, OpenBurnBar will recreate it on next launch:

```bash
# WARNING: This destroys ALL local data. Cloud-synced data will be preserved on Firebase.
mv ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite ~/Desktop/openburnbar-db-recovery-$(date +%Y%m%d).sqlite

# On next launch, OpenBurnBar will create a fresh database and run all migrations.
```

## Rollback Drill Procedure

Run this drill after any migration change to validate rollback procedures:

### Drill 1: Backup and Restore (5 minutes)

```bash
# 1. Verify database exists and is healthy
sqlite3 ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite "PRAGMA integrity_check;"

# 2. Check current migration state
sqlite3 ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite "SELECT * FROM grdb_migrations ORDER BY identifier;"

# 3. Create a manual backup
cp ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite \
   ~/Desktop/openburnbar-drill-backup-$(date +%Y%m%d).sqlite

# 4. Verify backup
sqlite3 ~/Desktop/openburnbar-drill-backup-$(date +%Y%m%d).sqlite "PRAGMA integrity_check;"

# 5. Simulate restore
cp ~/Desktop/openburnbar-drill-backup-$(date +%Y%m%d).sqlite \
   ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite

# 6. Verify restore
open -a OpenBurnBar  # App should launch normally
```

### Drill 2: Migration List Review (2 minutes)

```bash
# List all migrations and their safety classifications
scripts/rollback-migration.sh --list
```

Review that the catalog matches what's in `OpenBurnBarDatabase.swift`.

### Drill 3: Failed Migration Simulation (10 minutes)

```bash
# 1. Quit OpenBurnBar
# 2. Create backup
scripts/rollback-migration.sh --inspect
# 3. In the interactive session, verify schema
# 4. Simulate a failed migration by adding a partial migration record
sqlite3 ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite \
  "INSERT INTO grdb_migrations (identifier) VALUES ('v99_test_rollback');"
# 5. Launch OpenBurnBar — it should handle the unknown migration gracefully
# 6. Clean up: remove the test record
sqlite3 ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite \
  "DELETE FROM grdb_migrations WHERE identifier = 'v99_test_rollback';"
```

## Adding a New Migration

When adding a new migration to `OpenBurnBarDatabase.swift`:

1. Register it with `migrator.registerMigration("vXX_name") { db in ... }`
2. Update the catalog table in this document
3. Update the `MIGRATION_SAFETY`, `MIGRATION_DESC`, and `REVERT_SQL` arrays in `scripts/rollback-migration.sh`
4. Classify the migration as `safe-rerun` or `manual` based on:
   - If the migration only adds new tables/indexes that can be dropped: `safe-rerun`
   - If it adds columns to existing tables with data, changes constraints, or modifies FTS: `manual`
5. If `manual`, add suggested revert SQL to `REVERT_SQL` in the script

## Daemon Database

The daemon does not use SQLite directly — it communicates with the app's DataStore via JSON-RPC. The daemon's own state directory (`~/Library/Application Support/OpenBurnBar/`) contains:

- Provider config
- Run journals and checkpoints
- Controller events
- Connector configuration

These are file-based and can be reset by removing the daemon support directory. The daemon will recreate configuration on next launch.

## Monitoring

- Check database size: `du -h ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite`
- Check migration state: `sqlite3 ~/Library/Application\ Support/OpenBurnBar/OpenBurnBar.sqlite "SELECT identifier FROM grdb_migrations ORDER BY identifier;"`
- Check integrity: `sqlite3 ~/Library/Application\ Support/OpenBurnBar/openburnbar.sqlite "PRAGMA integrity_check;"`
