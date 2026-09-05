using System.Collections.Generic;

namespace OpenBurnBar.Storage;

public sealed partial class WindowsSqlCipherProvisioner
{
    public static string JournalPath(string databasePath) => databasePath + ".windows-migration-journal.json";

    public static string RedactedLogPath(string databasePath) => databasePath + ".recovery.log";

    private static readonly string[] AppliedMigrationIdentifiers =
    {
        "v1_initial",
        "v2_sync",
        "v3_conversations",
        "v4_summaries",
        "v5_fts_rebuild",
        "v6_fts_standalone_triggers",
        "v7_conversation_cloud_sync",
        "v8_chat_transcript_pieces",
        "v9_source_type",
        "v10_log_synced_at",
        "v11_auto_summary_metadata",
        "v12_token_usage_dedupe_unique_session_model",
        "v13_backfill_claude_usage_timestamps",
        "v14_local_search_substrate",
        "v15_source_artifact_registry",
        "v16_shared_artifact_sync_state",
        "v17_shared_artifact_permissions_and_audit",
        "v18_summary_attempt_tracking",
        "v19_conversation_fts_trigger_fix",
        "v20_chat_threads",
        "v21_multifield_fts",
        "v22_cross_device_sync",
        "v23_device_hardware_model",
        "v24_repair_custom_icon_column",
        "v25_operating_action_history",
        "v26_controller_runtime_cache",
        "v27_token_usage_reasoning_source",
        "v28_token_usage_provenance",
        "v29_parser_checkpoints",
        "v30_remote_sync_watermarks",
        "v31_chunk_content_hash",
        "v32_switcher_profiles",
        "v33_backfill_cursors",
        "v34_vector_index_snapshots",
        "v35_provider_accounts",
        "v36_repair_kimi_request_id_models",
        "v37_token_usage_performance_indexes",
        "v38_chat_message_attachments",
        "v39_project_memory_snapshots",
        "v40_reprice_gpt55_cached_input",
        "v41_reprice_openai_family_cached_input",
        "v42_budget_rules_and_events",
        "v43_text_expansion_snippets",
        "v44_repair_token_accounting_duplicates",
        "v45_conversation_working_directory",
        "v46_drain_target_per_provider",
        "v47_conversation_tombstones",
        "v48_conversation_fts_orphan_repair",
        "v49_token_usage_parent_request_id",
        "v50_project_code_memory_schema",
        "v51a_drop_body_fts",
        "v51_chat_memory_authority",
        "v52_memory_extraction_job_intent_and_lease",
        "v53_memory_forget_outbox",
        "v54_provider_quota_snapshots",
        "v55_search_chunks_fts_rowid",
        "v56_parser_checkpoint_file_manifest",
        "v57_execution_source_attribution",
        "v58_ai_inbox",
        "v59_founder_lens",
        "v60_billing_kind",
        "v61_usage_memory",
        "v62_war_room_originator",
        "v63_standing_orders",
        "v64_token_usage_start_time_index",
        CurrentMigrationEndpoint,
    };

    private static IReadOnlyList<WindowsStorageRecoveryAction> ActionsFor(WindowsStorageFailureKind kind) =>
        kind switch
        {
            WindowsStorageFailureKind.FullDisk => new[] { WindowsStorageRecoveryAction.Retry, WindowsStorageRecoveryAction.RevealRedactedLog },
            WindowsStorageFailureKind.AccessDenied => new[] { WindowsStorageRecoveryAction.Retry, WindowsStorageRecoveryAction.RevealRedactedLog },
            WindowsStorageFailureKind.LockedFile => new[] { WindowsStorageRecoveryAction.Retry, WindowsStorageRecoveryAction.RevealRedactedLog },
            WindowsStorageFailureKind.UnsupportedSchema => new[] { WindowsStorageRecoveryAction.Archive, WindowsStorageRecoveryAction.Reset, WindowsStorageRecoveryAction.RevealRedactedLog },
            _ => new[] { WindowsStorageRecoveryAction.Retry, WindowsStorageRecoveryAction.Archive, WindowsStorageRecoveryAction.Reset, WindowsStorageRecoveryAction.RevealRedactedLog },
        };

    private static string TitleFor(WindowsStorageFailureKind kind) =>
        kind switch
        {
            WindowsStorageFailureKind.WrongKey => "The protected storage key does not match this database.",
            WindowsStorageFailureKind.CorruptDatabase => "The local encrypted database could not be read.",
            WindowsStorageFailureKind.LockedFile => "The local encrypted database is locked by another process.",
            WindowsStorageFailureKind.InterruptedMigration => "Storage migration was interrupted before completion.",
            WindowsStorageFailureKind.UnsupportedSchema => "The local database schema is newer than this Windows build.",
            WindowsStorageFailureKind.FullDisk => "Windows does not have enough disk space to finish storage work.",
            WindowsStorageFailureKind.AccessDenied => "Windows denied access to the local storage path.",
            _ => "Storage recovery required.",
        };

    private static string MessageFor(WindowsStorageFailureKind kind) =>
        kind switch
        {
            WindowsStorageFailureKind.WrongKey => "Retry after restoring the protected key, or archive and reset the database after confirming data loss.",
            WindowsStorageFailureKind.CorruptDatabase => "Retry, archive the damaged file for support, or reset only after explicit confirmation.",
            WindowsStorageFailureKind.LockedFile => "Close the process holding the file and retry. OpenBurnBar will not show this as empty data.",
            WindowsStorageFailureKind.InterruptedMigration => "Retry will continue the transactional Windows migration journal from the recorded boundary.",
            WindowsStorageFailureKind.UnsupportedSchema => "Install a compatible build, or archive/reset this database after exporting diagnostics.",
            WindowsStorageFailureKind.FullDisk => "Free disk space and retry. Reset is not offered because valid data may still be present.",
            WindowsStorageFailureKind.AccessDenied => "Fix folder permissions or choose a writable profile path, then retry.",
            _ => "Storage recovery is required before local data surfaces can load.",
        };
}
