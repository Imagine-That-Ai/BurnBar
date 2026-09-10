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
#   --list      List all migrations and their transaction/retry/rollback contract
#   --inspect   Create a quiesced, checksummed SQLCipher database bundle
#   <version>   Show forensic rollback notes for the specified migration
#
# This script does NOT auto-execute revert SQL. It shows the SQL and
# requires human confirmation before any destructive operation.
#
# Database location:
#   ~/Library/Application Support/OpenBurnBar/openburnbar.sqlite

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB_PATH="$HOME/Library/Application Support/OpenBurnBar/openburnbar.sqlite"
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
# Format: "name|transaction|retry|rollback|description"
#
# `atomic|unapplied-only|backup-restore` means GRDB owns the transaction,
# automatic retry is supported only when the migration identifier was not
# committed, and the supported rollback is restoration of the keyed backup.
# This deliberately does not claim that ALTER TABLE or data rewrites are
# intrinsically idempotent or that OpenBurnBar ships tested down migrations.
#
# This catalog must be kept in sync with OpenBurnBarDatabase.swift.

MIGRATIONS=(
  "v1_initial|atomic|unapplied-only|backup-restore|Initial schema creation — all core tables"
  "v2_sync|atomic|unapplied-only|backup-restore|Cloud sync tracking columns"
  "v3_conversations|atomic|unapplied-only|backup-restore|Conversation model and FTS"
  "v4_summaries|atomic|unapplied-only|backup-restore|Summary tables"
  "v5_fts_rebuild|atomic|unapplied-only|backup-restore|Full FTS index rebuild"
  "v6_fts_standalone_triggers|atomic|unapplied-only|backup-restore|Standalone FTS triggers"
  "v7_conversation_cloud_sync|atomic|unapplied-only|backup-restore|Conversation cloud sync metadata"
  "v8_chat_transcript_pieces|atomic|unapplied-only|backup-restore|Chat transcript pieces table"
  "v9_source_type|atomic|unapplied-only|backup-restore|Source type column addition"
  "v10_log_synced_at|atomic|unapplied-only|backup-restore|Log sync timestamp column"
  "v11_auto_summary_metadata|atomic|unapplied-only|backup-restore|Auto-summary metadata columns"
  "v12_token_usage_dedupe_unique_session_model|atomic|unapplied-only|backup-restore|Token usage dedup with unique session+model constraint"
  "v13_backfill_claude_usage_timestamps|atomic|unapplied-only|backup-restore|Backfill Claude usage timestamps"
  "v14_local_search_substrate|atomic|unapplied-only|backup-restore|Local search substrate (FTS5 + semantic)"
  "v15_source_artifact_registry|atomic|unapplied-only|backup-restore|Source artifact registry table"
  "v16_shared_artifact_sync_state|atomic|unapplied-only|backup-restore|Shared artifact sync state columns"
  "v17_shared_artifact_permissions_and_audit|atomic|unapplied-only|backup-restore|Shared artifact permissions and audit"
  "v18_summary_attempt_tracking|atomic|unapplied-only|backup-restore|Summary attempt tracking"
  "v19_conversation_fts_trigger_fix|atomic|unapplied-only|backup-restore|Conversation FTS trigger fix"
  "v20_chat_threads|atomic|unapplied-only|backup-restore|Chat threads table"
  "v21_multifield_fts|atomic|unapplied-only|backup-restore|Multi-field FTS content"
  "v22_cross_device_sync|atomic|unapplied-only|backup-restore|Cross-device sync columns"
  "v23_device_hardware_model|atomic|unapplied-only|backup-restore|Device hardware model column"
  "v24_repair_custom_icon_column|atomic|unapplied-only|backup-restore|Repair custom icon column"
  "v25_operating_action_history|atomic|unapplied-only|backup-restore|Operating action history table"
  "v26_controller_runtime_cache|atomic|unapplied-only|backup-restore|Controller runtime cache table"
  "v27_token_usage_reasoning_source|atomic|unapplied-only|backup-restore|Token usage reasoning source column"
  "v28_token_usage_provenance|atomic|unapplied-only|backup-restore|Token usage provenance tracking"
  "v29_parser_checkpoints|atomic|unapplied-only|backup-restore|Parser checkpoint store"
  "v30_remote_sync_watermarks|atomic|unapplied-only|backup-restore|Remote sync watermark store"
  "v31_chunk_content_hash|atomic|unapplied-only|backup-restore|Chunk content hash column"
  "v32_switcher_profiles|atomic|unapplied-only|backup-restore|Switcher profiles table"
  "v33_backfill_cursors|atomic|unapplied-only|backup-restore|Cursor backfill migration"
  "v34_vector_index_snapshots|atomic|unapplied-only|backup-restore|Vector index snapshot tracking"
  "v35_provider_accounts|atomic|unapplied-only|backup-restore|Provider accounts table and token usage account attribution"
  "v36_repair_kimi_request_id_models|atomic|unapplied-only|backup-restore|Repair Kimi request-id models and duplicate cache accounting"
  "v37_token_usage_performance_indexes|atomic|unapplied-only|backup-restore|Token usage performance indexes"
  "v38_chat_message_attachments|atomic|unapplied-only|backup-restore|Chat message attachments JSON column"
  "v39_project_memory_snapshots|atomic|unapplied-only|backup-restore|Project memory snapshot table"
  "v40_reprice_gpt55_cached_input|atomic|unapplied-only|backup-restore|Reprice GPT-5.5 cached input rows"
  "v41_reprice_openai_family_cached_input|atomic|unapplied-only|backup-restore|Reprice OpenAI-family cached input rows"
  "v42_budget_rules_and_events|atomic|unapplied-only|backup-restore|Budget rules and budget events tables"
  "v43_text_expansion_snippets|atomic|unapplied-only|backup-restore|Text expansion snippets table and active-trigger index"
  "v44_repair_token_accounting_duplicates|atomic|unapplied-only|backup-restore|Delete duplicated token accounting rows"
  "v45_conversation_working_directory|atomic|unapplied-only|backup-restore|Conversation working directory column"
  "v46_drain_target_per_provider|atomic|unapplied-only|backup-restore|Per-provider switcher drain target pointer"
  "v47_conversation_tombstones|atomic|unapplied-only|backup-restore|Conversation tombstone and version columns"
  "v48_conversation_fts_orphan_repair|atomic|unapplied-only|backup-restore|Repair orphaned conversation FTS rows"
  "v49_token_usage_parent_request_id|atomic|unapplied-only|backup-restore|Fusion parent request attribution column and index"
  "v50_project_code_memory_schema|atomic|unapplied-only|backup-restore|Project Code Memory tables and indexes"
  "v51a_drop_body_fts|atomic|unapplied-only|backup-restore|Drop obsolete body-only agent memory FTS table"
  "v51_chat_memory_authority|atomic|unapplied-only|backup-restore|Chat memory authority metadata, jobs, and tombstones"
  "v52_memory_extraction_job_intent_and_lease|atomic|unapplied-only|backup-restore|Memory extraction intent and lease columns"
  "v53_memory_forget_outbox|atomic|unapplied-only|backup-restore|User-scoped memory forget replication outbox"
  "v54_provider_quota_snapshots|atomic|unapplied-only|backup-restore|Durable provider quota snapshot cache"
  "v55_search_chunks_fts_rowid|atomic|unapplied-only|backup-restore|Backfill search_chunks ftsRowid and sweep orphaned FTS rows for rowid-targeted deletes"
  "v56_parser_checkpoint_file_manifest|atomic|unapplied-only|backup-restore|Normalized parser checkpoint file-identity manifest"
  "v57_execution_source_attribution|atomic|unapplied-only|backup-restore|Execution-source columns, index, and evidence-backed historical attribution"
  "v58_ai_inbox|atomic|unapplied-only|backup-restore|AI Inbox items, delivery state, and routing indexes"
  "v59_founder_lens|atomic|unapplied-only|backup-restore|Founder Lens reply threads, plan ledger, and memory export"
  "v60_billing_kind|atomic|unapplied-only|backup-restore|Billing provenance column (api vs subscription spend) with deterministic backfill"
  "v61_usage_memory|atomic|unapplied-only|backup-restore|Usage-memory substrate: candidate spool, salience sidecar, memory links, extraction-job source_kind"
  "v62_war_room_originator|atomic|unapplied-only|backup-restore|War Room STARTED BY attribution columns on token_usage plus the originator lookup index"
  "v63_standing_orders|atomic|unapplied-only|backup-restore|Standing orders table backing the War Room rhythm (cadence, target machine, last fired)"
  "v64_token_usage_start_time_index|atomic|unapplied-only|backup-restore|Index on token_usage.startTime so the Command Board window scan stops walking the table"
  "v65_memory_quarantine_bodies|atomic|unapplied-only|backup-restore|Encrypted review holding table for quarantined memory bodies"
  "v66_agent_memory_bodies|atomic|unapplied-only|backup-restore|Approved bodies for engine-mirrored memories, the copy blind sync seals and uploads"
  "v67_agent_memory_inbox|atomic|unapplied-only|backup-restore|Landing zone for memory facts pulled back from the member's cloud vault, drained by the engine"
)

# ── Commands ─────────────────────────────────────────────────────────────

cmd_list() {
  echo ""
  info "OpenBurnBar Database Migration Catalog"
  echo ""
  printf "%-4s %-46s %-8s %-15s %-16s %s\n" " #" "Migration" "Txn" "Retry" "Rollback" "Description"
  printf "%-4s %-46s %-8s %-15s %-16s %s\n" "---" "--------------------------------------------" "------" "-------------" "--------------" "-----------"

  local idx=0
  for entry in "${MIGRATIONS[@]}"; do
    idx=$((idx + 1))
    name="$(echo "$entry" | cut -d'|' -f1)"
    transaction="$(echo "$entry" | cut -d'|' -f2)"
    retry="$(echo "$entry" | cut -d'|' -f3)"
    rollback="$(echo "$entry" | cut -d'|' -f4)"
    desc="$(echo "$entry" | cut -d'|' -f5)"
    printf "%-4s %-46s %-8s %-15s %-16s %s\n" "$idx" "$name" "$transaction" "$retry" "$rollback" "$desc"
  done

  echo ""
  echo "Migration contract:"
  echo "  atomic          — GRDB commits the migration body and identifier together"
  echo "  unapplied-only  — retry only when the identifier is absent after rollback"
  echo "  backup-restore  — no supported down migration; restore the keyed backup"
  echo ""
  echo "Database: $DB_PATH"
  if [[ ! -f "$DB_PATH" ]]; then
    echo "Database not found at expected path."
  else
    echo "The migration state is encrypted; read it through the running app's diagnostics."
  fi
}

cmd_inspect() {
  if [[ ! -f "$DB_PATH" ]]; then
    error "Database not found at $DB_PATH"
    echo "  Make sure OpenBurnBar has been launched at least once." >&2
    exit 1
  fi

  command -v lsof >/dev/null 2>&1 || {
    error "lsof is required to prove the database is quiesced"
    exit 1
  }
  command -v shasum >/dev/null 2>&1 || {
    error "shasum is required to seal the inspection bundle"
    exit 1
  }
  command -v cmp >/dev/null 2>&1 || {
    error "cmp is required to prove the source stayed stable during the copy"
    exit 1
  }

  local database_files=("$DB_PATH")
  for sidecar in "$DB_PATH-wal" "$DB_PATH-shm"; do
    if [[ -e "$sidecar" ]]; then
      database_files+=("$sidecar")
    fi
  done
  if lsof -t -- "${database_files[@]}" >/dev/null 2>&1; then
    error "OpenBurnBar or another process still has the database open"
    echo "  Quit OpenBurnBar and all database tools, then retry." >&2
    exit 1
  fi

  umask 077
  mkdir -p "$DB_BACKUP_DIR"
  BACKUP_NAME="openburnbar-rollback-$(date +%Y%m%d-%H%M%S).bundle"
  BACKUP_PATH="$DB_BACKUP_DIR/$BACKUP_NAME"
  mkdir "$BACKUP_PATH"

  echo "Creating quiesced SQLCipher inspection bundle..."
  for source in "${database_files[@]}"; do
    if [[ -f "$source" ]]; then
      cp -p "$source" "$BACKUP_PATH/$(basename "$source")"
    fi
  done

  if lsof -t -- "${database_files[@]}" >/dev/null 2>&1; then
    mv "$BACKUP_PATH" "$BACKUP_PATH.invalid-open-race"
    error "A process opened the database during the copy; the bundle was quarantined"
    exit 1
  fi

  for source in "$DB_PATH" "$DB_PATH-wal" "$DB_PATH-shm"; do
    destination="$BACKUP_PATH/$(basename "$source")"
    source_changed=0
    if [[ -e "$source" && ! -e "$destination" ]] || [[ ! -e "$source" && -e "$destination" ]]; then
      source_changed=1
    elif [[ -e "$source" ]] && ! cmp -s "$source" "$destination"; then
      source_changed=1
    fi
    if [[ "$source_changed" -eq 1 ]]; then
      mv "$BACKUP_PATH" "$BACKUP_PATH.invalid-source-changed"
      error "The database changed during the copy; the bundle was quarantined"
      exit 1
    fi
  done

  (
    cd "$BACKUP_PATH"
    shasum -a 256 ./* > SHA256SUMS
  )
  chmod -R go-rwx "$BACKUP_PATH"
  success "Inspection bundle created: $BACKUP_PATH"
  echo "  Includes the encrypted database and every present WAL/SHM sidecar."
  echo "  Stock sqlite3 cannot inspect SQLCipher ciphertext and is intentionally not invoked."
  echo "  Validate or restore this bundle only through OpenBurnBar's keyed GRDB recovery path."
}

get_contract() {
  local target="$1"
  for entry in "${MIGRATIONS[@]}"; do
    name="$(echo "$entry" | cut -d'|' -f1)"
    # Support both full name (v34_vector_index_snapshots) and short prefix (v34)
    if [[ "$name" == "$target" || "$name" == "${target}_"* ]]; then
      echo "$entry" | cut -d'|' -f2-4
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
      echo "$entry" | cut -d'|' -f5
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

  contract="$(get_contract "$target")"
  desc="$(get_desc "$target")"

  echo ""
  info "Rollback Information for $full_name"
  echo ""
  echo "  Description: $desc"
  echo "  Contract:    $contract"
  echo ""

  echo "  Automatic retry is supported only if GRDB did not commit this"
  echo "  migration identifier. The supported rollback is restoration of"
  echo "  the keyed pre-migration backup; no down migration is certified."
  echo ""

  # Show migration-specific forensic hints. These are not certified down migrations.
  case "$full_name" in
      v2_sync)
        echo "  Forensic SQL notes:"
        echo "    -- Remove cloud sync columns (requires SQLite 3.35.0+ for DROP COLUMN)"
        echo "    -- ALTER TABLE token_usage DROP COLUMN synced_at;"
        ;;
      v3_conversations)
        echo "  Forensic SQL notes:"
        echo "    -- DROP TABLE IF EXISTS message_fts;"
        echo "    -- DROP TABLE IF EXISTS messages;"
        echo "    -- DROP TABLE IF EXISTS conversations;"
        echo "    -- CAUTION: This destroys all conversation data"
        ;;
      v7_conversation_cloud_sync)
        echo "  Forensic SQL notes:"
        echo "    -- ALTER TABLE conversations DROP COLUMN cloud_sync_version;"
        ;;
      v9_source_type)
        echo "  Forensic SQL notes:"
        echo "    -- ALTER TABLE source_artifacts DROP COLUMN source_type;"
        ;;
      v12_token_usage_dedupe_unique_session_model)
        echo "  Forensic SQL notes:"
        echo "    -- Requires table rebuild in SQLite to drop UNIQUE constraint"
        ;;
      v14_local_search_substrate)
        echo "  Forensic SQL notes:"
        echo "    -- DROP TABLE IF EXISTS search_chunks;"
        echo "    -- DROP TABLE IF EXISTS chunk_embeddings;"
        echo "    -- CAUTION: Destroys all search index data"
        ;;
      v15_source_artifact_registry)
        echo "  Forensic SQL notes:"
        echo "    -- DROP TABLE IF EXISTS source_artifacts;"
        echo "    -- CAUTION: Destroys artifact registry"
        ;;
      v17_shared_artifact_permissions_and_audit)
        echo "  Forensic SQL notes:"
        echo "    -- DROP TABLE IF EXISTS shared_artifact_permissions;"
        echo "    -- DROP TABLE IF EXISTS shared_artifact_audit_log;"
        ;;
      v20_chat_threads)
        echo "  Forensic SQL notes:"
        echo "    -- DROP TABLE IF EXISTS chat_threads;"
        echo "    -- DROP TABLE IF EXISTS chat_messages;"
        ;;
      v21_multifield_fts)
        echo "  Forensic SQL notes:"
        echo "    -- Requires FTS rebuild after column changes"
        ;;
      v25_operating_action_history)
        echo "  Forensic SQL notes:"
        echo "    -- DROP TABLE IF EXISTS operating_actions;"
        ;;
      v28_token_usage_provenance)
        echo "  Forensic SQL notes:"
        echo "    -- ALTER TABLE token_usage DROP COLUMN provenance;"
        ;;
      v32_switcher_profiles)
        echo "  Forensic SQL notes:"
        echo "    -- DROP TABLE IF EXISTS switcher_profiles;"
        echo "    -- DROP TABLE IF EXISTS switcher_profile_account_assignments;"
        ;;
      v34_vector_index_snapshots)
        echo "  Forensic SQL notes:"
        echo "    -- DROP TABLE IF EXISTS vector_index_snapshots;"
        ;;
      v35_provider_accounts)
        echo "  Forensic SQL notes:"
        echo "    -- DROP INDEX IF EXISTS token_usage_account_time_idx;"
        echo "    -- DROP INDEX IF EXISTS token_usage_provider_account_idx;"
        echo "    -- DROP INDEX IF EXISTS token_usage_unique_session_model_device_account_idx;"
        echo "    -- CREATE UNIQUE INDEX token_usage_unique_session_model_device_idx"
        echo "    --   ON token_usage(provider, sessionId, model, COALESCE(sourceDeviceId, ''));"
        echo "    -- DROP TABLE IF EXISTS provider_accounts;"
        echo "    -- CAUTION: Dropping provider_accounts removes local account labels and routing state."
        ;;
      v36_repair_kimi_request_id_models)
        echo "  Forensic SQL notes:"
        echo "    -- No lossless SQL revert: this migration deletes duplicate legacy rows"
        echo "    -- and normalizes Kimi request-id model names in place."
        echo "    -- Restore from the timestamped backup created before migration if needed."
        ;;
      v38_chat_message_attachments)
        echo "  Forensic SQL notes:"
        echo "    -- ALTER TABLE chat_messages DROP COLUMN attachmentsJSON;"
        ;;
      v39_project_memory_snapshots)
        echo "  Forensic SQL notes:"
        echo "    -- DROP TABLE IF EXISTS project_memory_snapshots;"
        echo "    -- CAUTION: Destroys local generated project memory snapshots."
        ;;
      v44_repair_token_accounting_duplicates)
        echo "  Forensic SQL notes:"
        echo "    -- No lossless SQL revert: this migration deletes duplicated token rows."
        echo "    -- Restore from backup if duplicate rows must be recovered."
        ;;
    *)
      echo "  No forensic SQL notes are available for this migration."
      echo "  Review the migration source and restore the keyed backup if rollback is required."
      ;;
  esac

  echo ""
  echo "────────────────────────────────────────────────────────────"
  echo ""
  warn "DO NOT execute revert SQL directly against your live database."
  echo "  1. Quit OpenBurnBar and create a sealed bundle with --inspect"
  echo "  2. Use the app's keyed GRDB recovery path to validate or restore"
  echo "  3. Treat the SQL above as forensic guidance, not an executable down migration"
  echo ""
  echo "  To create a quiesced, checksummed SQLCipher bundle:"
  echo "    scripts/rollback-migration.sh --inspect"

  echo ""
  echo "Migration source (from OpenBurnBarDatabase.swift):"
  echo "────────────────────────────────────────────────────────────"
  db_file="$(grep -RIlF "registerMigration(\"$full_name\"" \
    "$REPO_ROOT/AgentLens/Services/DataStore" --include='*.swift' | head -1)"
  if [[ -n "$db_file" && -f "$db_file" ]]; then
    echo "  $db_file"
    awk "/migrator\.registerMigration\(\"$full_name\"/,/^\s*\}/" "$db_file" | head -60
  else
    echo "  (Migration source file not found)"
  fi
}

# ── Main ────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--list|--inspect|<migration_version>]" >&2
  echo "  --list      List all migration contracts" >&2
  echo "  --inspect   Create a quiesced SQLCipher bundle" >&2
  echo "  v##         Show forensic rollback notes and migration source" >&2
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
    echo "  --list      List all migration contracts"
    echo "  --inspect   Create a quiesced, checksummed SQLCipher bundle"
    echo "  <version>   Show forensic rollback notes for a migration (e.g. v33)"
    echo ""
    echo "Migration contract:"
    echo "  atomic|unapplied-only|backup-restore"
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
