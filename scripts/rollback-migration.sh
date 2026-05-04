#!/usr/bin/env bash
#
# rollback-migration.sh — Inspect or prepare rollback SQL for a database migration.
#
# Usage:
#   scripts/rollback-migration.sh <target_version>
#   scripts/rollback-migration.sh v33
#   scripts/rollback-migration.sh --list
#   scripts/rollback-migration.sh --inspect
#
# What it does:
#   --list      List all migrations and their rollback safety classification
#   --inspect   Open an interactive sqlite3 session against a backup of the DB
#   <version>   Show revert SQL for the specified migration
#
# This script does NOT auto-execute revert SQL. It shows the SQL and
# requires human confirmation before any destructive operation.
#
# Database location:
#   ~/Library/Application Support/OpenBurnBar/OpenBurnBar.sqlite

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB_PATH="$HOME/Library/Application Support/OpenBurnBar/OpenBurnBar.sqlite"
DB_BACKUP_DIR="$HOME/Library/Application Support/OpenBurnBar/backups"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

error()   { echo -e "${RED}ERROR: $1${NC}" >&2; }
warn()    { echo -e "${YELLOW}WARNING: $1${NC}" >&2; }
success() { echo -e "${GREEN}$1${NC}"; }
info()    { echo -e "${BOLD}$1${NC}"; }

# ── Migration catalog ───────────────────────────────────────────────────
#
# Format: "name|safety|description"
# Safety: "safe-rerun" (idempotent) or "manual" (needs careful revert)
#
# This catalog must be kept in sync with OpenBurnBarDatabase.swift.

MIGRATIONS=(
  "v1_initial|safe-rerun|Initial schema creation — all core tables"
  "v2_sync|manual|Cloud sync tracking columns"
  "v3_conversations|manual|Conversation model and FTS"
  "v4_summaries|safe-rerun|Summary tables"
  "v5_fts_rebuild|safe-rerun|Full FTS index rebuild"
  "v6_fts_standalone_triggers|safe-rerun|Standalone FTS triggers"
  "v7_conversation_cloud_sync|manual|Conversation cloud sync metadata"
  "v8_chat_transcript_pieces|safe-rerun|Chat transcript pieces table"
  "v9_source_type|manual|Source type column addition"
  "v10_log_synced_at|safe-rerun|Log sync timestamp column"
  "v11_auto_summary_metadata|safe-rerun|Auto-summary metadata columns"
  "v12_token_usage_dedupe_unique_session_model|manual|Token usage dedup with unique session+model constraint"
  "v13_backfill_claude_usage_timestamps|safe-rerun|Backfill Claude usage timestamps"
  "v14_local_search_substrate|manual|Local search substrate (FTS5 + semantic)"
  "v15_source_artifact_registry|manual|Source artifact registry table"
  "v16_shared_artifact_sync_state|safe-rerun|Shared artifact sync state columns"
  "v17_shared_artifact_permissions_and_audit|manual|Shared artifact permissions and audit"
  "v18_summary_attempt_tracking|safe-rerun|Summary attempt tracking"
  "v19_conversation_fts_trigger_fix|safe-rerun|Conversation FTS trigger fix"
  "v20_chat_threads|manual|Chat threads table"
  "v21_multifield_fts|manual|Multi-field FTS content"
  "v22_cross_device_sync|safe-rerun|Cross-device sync columns"
  "v23_device_hardware_model|safe-rerun|Device hardware model column"
  "v24_repair_custom_icon_column|safe-rerun|Repair custom icon column"
  "v25_operating_action_history|manual|Operating action history table"
  "v26_controller_runtime_cache|safe-rerun|Controller runtime cache table"
  "v27_token_usage_reasoning_source|safe-rerun|Token usage reasoning source column"
  "v28_token_usage_provenance|manual|Token usage provenance tracking"
  "v29_parser_checkpoints|safe-rerun|Parser checkpoint store"
  "v30_remote_sync_watermarks|safe-rerun|Remote sync watermark store"
  "v31_chunk_content_hash|safe-rerun|Chunk content hash column"
  "v32_switcher_profiles|manual|Switcher profiles table"
  "v33_backfill_cursors|safe-rerun|Cursor backfill migration"
  "v34_vector_index_snapshots|manual|Vector index snapshot tracking"
)

# ── Commands ─────────────────────────────────────────────────────────────

cmd_list() {
  echo ""
  info "OpenBurnBar Database Migration Catalog"
  echo ""
  printf "%-4s %-48s %-12s %s\n" " #" "Migration" "Safety" "Description"
  printf "%-4s %-48s %-12s %s\n" "---" "----------------------------------------------" "----------" "-----------"

  local idx=0
  for entry in "${MIGRATIONS[@]}"; do
    idx=$((idx + 1))
    name="$(echo "$entry" | cut -d'|' -f1)"
    safety="$(echo "$entry" | cut -d'|' -f2)"
    desc="$(echo "$entry" | cut -d'|' -f3)"
    printf "%-4s %-48s %-12s %s\n" "$idx" "$name" "$safety" "$desc"
  done

  echo ""
  echo "Safety classifications:"
  echo "  safe-rerun  — Migration is idempotent; safe to re-run after a partial failure"
  echo "  manual      — Requires careful revert; data loss possible if dropped"
  echo ""
  echo "Database: $DB_PATH"
  if [[ -f "$DB_PATH" ]]; then
    current_version="$(sqlite3 "$DB_PATH" "SELECT MAX(identifier) FROM grdb_migrations" 2>/dev/null || echo 'unknown')"
    echo "Current migration: $current_version"
  else
    echo "Database not found at expected path."
  fi
}

cmd_inspect() {
  if [[ ! -f "$DB_PATH" ]]; then
    error "Database not found at $DB_PATH"
    echo "  Make sure OpenBurnBar has been launched at least once." >&2
    exit 1
  fi

  mkdir -p "$DB_BACKUP_DIR"
  BACKUP_NAME="OpenBurnBar-rollback-$(date +%Y%m%d-%H%M%S).sqlite"
  BACKUP_PATH="$DB_BACKUP_DIR/$BACKUP_NAME"

  echo "Creating timestamped backup..."
  cp "$DB_PATH" "$BACKUP_PATH"
  success "Backup created: $BACKUP_PATH"

  echo ""
  echo "Current database state:"
  echo "  Path: $DB_PATH"
  echo "  Size: $(du -h "$DB_PATH" | cut -f1)"

  current_version="$(sqlite3 "$DB_PATH" "SELECT MAX(identifier) FROM grdb_migrations" 2>/dev/null || echo 'unknown')"
  echo "  Applied migrations: $(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM grdb_migrations" 2>/dev/null || echo '?')"
  echo "  Latest migration: $current_version"

  integrity="$(sqlite3 "$DB_PATH" "PRAGMA integrity_check" 2>/dev/null || echo 'failed')"
  echo "  Integrity: $integrity"
  echo ""

  echo "Opening interactive sqlite3 session against backup..."
  echo "  Use '.tables' to list tables, '.schema TABLE' for DDL."
  echo "  The backup is at: $BACKUP_PATH"
  echo "  Your LIVE database is at: $DB_PATH"
  echo ""
  echo "Type 'exit' or Ctrl-D to exit."
  echo ""

  sqlite3 "$BACKUP_PATH"
}

get_safety() {
  local target="$1"
  for entry in "${MIGRATIONS[@]}"; do
    name="$(echo "$entry" | cut -d'|' -f1)"
    # Support both full name (v34_vector_index_snapshots) and short prefix (v34)
    if [[ "$name" == "$target" || "$name" == "${target}_"* ]]; then
      echo "$(echo "$entry" | cut -d'|' -f2)"
      return 0
    fi
  done
  echo "unknown"
  return 1
}

get_desc() {
  local target="$1"
  for entry in "${MIGRATIONS[@]}"; do
    name="$(echo "$entry" | cut -d'|' -f1)"
    if [[ "$name" == "$target" || "$name" == "${target}_"* ]]; then
      echo "$(echo "$entry" | cut -d'|' -f3)"
      return 0
    fi
  done
  echo "No description"
  return 1
}

# Resolve a short version prefix to the full migration name
resolve_name() {
  local target="$1"
  for entry in "${MIGRATIONS[@]}"; do
    name="$(echo "$entry" | cut -d'|' -f1)"
    if [[ "$name" == "$target" || "$name" == "${target}_"* ]]; then
      echo "$name"
      return 0
    fi
  done
  echo ""
  return 1
}

cmd_revert() {
  local target="$1"
  local full_name

  if [[ ! -f "$DB_PATH" ]]; then
    error "Database not found at $DB_PATH"
    exit 1
  fi

  # Resolve short prefix (e.g., v34) to full name (e.g., v34_vector_index_snapshots)
  full_name="$(resolve_name "$target")"
  if [[ -z "$full_name" ]]; then
    error "Unknown migration: $target"
    echo ""
    echo "Available migrations:"
    for entry in "${MIGRATIONS[@]}"; do
      echo "  $(echo "$entry" | cut -d'|' -f1)"
    done
    exit 1
  fi

  safety="$(get_safety "$target")"
  desc="$(get_desc "$target")"

  echo ""
  info "Rollback Information for $full_name"
  echo ""
  echo "  Description: $desc"
  echo "  Safety:       $safety"
  echo ""

  if [[ "$safety" == "safe-rerun" ]]; then
    echo "  This migration is classified as safe-rerun."
    echo "  If a partial failure occurred, you can re-launch the app and"
    echo "  the migration will be re-attempted from where it left off."
    echo ""
    echo "  Recommended action: re-launch OpenBurnBar and let GRDB re-run the migration."
  else
    echo "  This migration is classified as manual."
    echo "  Reverting requires careful SQL and may cause data loss."
    echo ""

    # Show migration-specific revert hints
    case "$full_name" in
      v2_sync)
        echo "  Suggested revert SQL:"
        echo "    -- Remove cloud sync columns (requires SQLite 3.35.0+ for DROP COLUMN)"
        echo "    -- ALTER TABLE token_usage DROP COLUMN synced_at;"
        ;;
      v3_conversations)
        echo "  Suggested revert SQL:"
        echo "    -- DROP TABLE IF EXISTS message_fts;"
        echo "    -- DROP TABLE IF EXISTS messages;"
        echo "    -- DROP TABLE IF EXISTS conversations;"
        echo "    -- CAUTION: This destroys all conversation data"
        ;;
      v7_conversation_cloud_sync)
        echo "  Suggested revert SQL:"
        echo "    -- ALTER TABLE conversations DROP COLUMN cloud_sync_version;"
        ;;
      v9_source_type)
        echo "  Suggested revert SQL:"
        echo "    -- ALTER TABLE source_artifacts DROP COLUMN source_type;"
        ;;
      v12_token_usage_dedupe_unique_session_model)
        echo "  Suggested revert SQL:"
        echo "    -- Requires table rebuild in SQLite to drop UNIQUE constraint"
        ;;
      v14_local_search_substrate)
        echo "  Suggested revert SQL:"
        echo "    -- DROP TABLE IF EXISTS search_chunks;"
        echo "    -- DROP TABLE IF EXISTS chunk_embeddings;"
        echo "    -- CAUTION: Destroys all search index data"
        ;;
      v15_source_artifact_registry)
        echo "  Suggested revert SQL:"
        echo "    -- DROP TABLE IF EXISTS source_artifacts;"
        echo "    -- CAUTION: Destroys artifact registry"
        ;;
      v17_shared_artifact_permissions_and_audit)
        echo "  Suggested revert SQL:"
        echo "    -- DROP TABLE IF EXISTS shared_artifact_permissions;"
        echo "    -- DROP TABLE IF EXISTS shared_artifact_audit_log;"
        ;;
      v20_chat_threads)
        echo "  Suggested revert SQL:"
        echo "    -- DROP TABLE IF EXISTS chat_threads;"
        echo "    -- DROP TABLE IF EXISTS chat_messages;"
        ;;
      v21_multifield_fts)
        echo "  Suggested revert SQL:"
        echo "    -- Requires FTS rebuild after column changes"
        ;;
      v25_operating_action_history)
        echo "  Suggested revert SQL:"
        echo "    -- DROP TABLE IF EXISTS operating_actions;"
        ;;
      v28_token_usage_provenance)
        echo "  Suggested revert SQL:"
        echo "    -- ALTER TABLE token_usage DROP COLUMN provenance;"
        ;;
      v32_switcher_profiles)
        echo "  Suggested revert SQL:"
        echo "    -- DROP TABLE IF EXISTS switcher_profiles;"
        echo "    -- DROP TABLE IF EXISTS switcher_profile_account_assignments;"
        ;;
      v34_vector_index_snapshots)
        echo "  Suggested revert SQL:"
        echo "    -- DROP TABLE IF EXISTS vector_index_snapshots;"
        ;;
      *)
        echo "  No pre-written revert SQL is available for this migration."
        echo "  Review the migration source in OpenBurnBarDatabase.swift to understand"
        echo "  what DDL changes were made and craft appropriate revert SQL."
        ;;
    esac
  fi

  echo ""
  echo "────────────────────────────────────────────────────────────"
  echo ""
  warn "DO NOT execute revert SQL directly against your live database."
  echo "  1. Create a backup first (use --inspect)"
  echo "  2. Test revert SQL against the backup"
  echo "  3. Only then apply to the live database"
  echo ""
  echo "  To create a timestamped backup and open an interactive session:"
  echo "    scripts/rollback-migration.sh --inspect"

  echo ""
  echo "Migration source (from OpenBurnBarDatabase.swift):"
  echo "────────────────────────────────────────────────────────────"
  db_file="$REPO_ROOT/AgentLens/Services/DataStore/OpenBurnBarDatabase.swift"
  if [[ -f "$db_file" ]]; then
    awk "/migrator\.registerMigration\(\"$full_name\"/,/^\s*\}/" "$db_file" | head -60
  else
    echo "  (Source file not found at expected path)"
  fi
}

# ── Main ────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--list|--inspect|<migration_version>]" >&2
  echo "  --list      List all migrations with safety classifications" >&2
  echo "  --inspect   Create backup + interactive sqlite3 session" >&2
  echo "  v##         Show revert SQL and migration source for a version" >&2
  exit 1
fi

case "$1" in
  --list|-l)
    cmd_list
    ;;
  --inspect|-i)
    cmd_inspect
    ;;
  -h|--help)
    echo "Usage: $0 [--list|--inspect|<migration_version>]"
    echo ""
    echo "OpenBurnBar database migration rollback helper."
    echo ""
    echo "Commands:"
    echo "  --list      List all migrations with safety classifications"
    echo "  --inspect   Create backup + open interactive sqlite3 session"
    echo "  <version>   Show revert SQL for a specific migration (e.g. v33)"
    echo ""
    echo "Safety classifications:"
    echo "  safe-rerun  Migration is idempotent; can be re-run safely"
    echo "  manual      Requires careful revert; data loss possible"
    echo ""
    echo "Database: $DB_PATH"
    ;;
  v*)
    cmd_revert "$1"
    ;;
  *)
    error "Unknown command: $1"
    echo "Use --list, --inspect, or a migration version (e.g., v33)" >&2
    exit 1
    ;;
esac
