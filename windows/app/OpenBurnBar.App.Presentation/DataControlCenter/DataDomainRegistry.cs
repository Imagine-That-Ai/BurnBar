using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.DataControlCenter;

// PORTED (faithful) from the GENERATED registry packages/data-domains/gen/DataDomains.swift
// (source of truth: packages/data-domains/registry.json → codegen.mjs). The Swift shell reads
// the emitted DataDomains.swift; the WinUI shell reads THIS emitted-shape port. Both are hand-
// kept in lock-step with registry.json, so a new domain/tier surfaces in both renders.
//
// The registry is the source of truth for a domain's SHAPE (tier, paths, retention, actions);
// the live getDataDomainUsage snapshot (IDataControlCallableHub) supplies count/bytes. Keeping
// this portable + unit-tested on macOS (windows/tests/presentation) is exactly the pattern the
// SessionLogs/Memory lanes proved.
//
// NOTE on Icon: the macOS registry stores an SF Symbol name (e.g. "chart.bar.fill"). It is kept
// verbatim here as the faithful registry datum; the Windows Segoe-MDL2 glyph is a render concern
// mapped in the app layer (DataControlCenter/DomainGlyphMap.cs), so the portable data stays
// platform-neutral.

/// <summary>
/// How much of a domain the server can read — the encryption tier. Ported from the generated
/// Swift <c>EncryptionTier</c> (raw values match registry.json exactly so a usage snapshot's
/// string tier round-trips).
/// </summary>
public enum EncryptionTier
{
    /// <summary>Stored as plaintext; BurnBar's servers can read it to run the product.</summary>
    ServerReadable,

    /// <summary>Encrypted at rest; BurnBar holds only the wrapped key under device trust.</summary>
    ZeroAccess,

    /// <summary>Sealed on-device with the vault key; BurnBar never sees plaintext or key.</summary>
    EndToEnd,
}

/// <summary>Maps <see cref="EncryptionTier"/> to/from the registry.json raw string.</summary>
public static class EncryptionTierExtensions
{
    public static string RawValue(this EncryptionTier tier) => tier switch
    {
        EncryptionTier.ServerReadable => "server_readable",
        EncryptionTier.ZeroAccess => "zero_access",
        EncryptionTier.EndToEnd => "end_to_end",
        _ => "server_readable",
    };

    public static EncryptionTier? FromRawValue(string? raw) => raw switch
    {
        "server_readable" => EncryptionTier.ServerReadable,
        "zero_access" => EncryptionTier.ZeroAccess,
        "end_to_end" => EncryptionTier.EndToEnd,
        _ => null,
    };
}

/// <summary>
/// One governed data domain. Faithful port of the generated Swift <c>DataDomain</c> struct — the
/// same 17 fields, so the inspector, flip, paths card, and action gating read identical data.
/// </summary>
public sealed record DataDomain(
    string Id,
    string Title,
    string Icon,
    EncryptionTier EncryptionTier,
    string Summary,
    IReadOnlyList<string> ServerSees,
    IReadOnlyList<string> DeviceOnly,
    IReadOnlyList<string> FirestorePaths,
    IReadOnlyList<string> StoragePaths,
    string? CountSource,
    string? ByteSource,
    string Retention,
    IReadOnlyList<string> Actions,
    string? EntitlementGate,
    string? SuspensionSurface,
    string? CloudVaultRewrapStrategy,
    string? SealingScheme)
{
    /// <summary>True when the domain exposes the named per-domain action (export/delete/recover/verify).</summary>
    public bool HasAction(string action) => Actions.Contains(action, StringComparer.Ordinal);
}

/// <summary>The ordered catalog of governed domains — port of Swift <c>DataDomains.all</c>.</summary>
public static class DataDomains
{
    private static string[] A(params string[] items) => items;

    /// <summary>The 12 registry domains, in registry order (the sidebar + inventory order).</summary>
    public static IReadOnlyList<DataDomain> All { get; } = new List<DataDomain>
    {
        new(
            Id: "usage_spend", Title: "Usage & Spend", Icon: "chart.bar.fill",
            EncryptionTier: EncryptionTier.ServerReadable,
            Summary: "Per-session token counts, cost estimates, and provider/model/device telemetry. Project names and budget labels are sealed on-device; the server groups spend only by opaque per-project hashes.",
            ServerSees: A("provider", "model", "device", "token counts", "cost estimates", "timestamps", "opaque project hashes"),
            DeviceOnly: A("project names", "budget labels"),
            FirestorePaths: A("usage", "usage_rollups", "usage_counter_days", "usage_counter_totals", "recent_usage", "quota_snapshots", "rollup_jobs", "projects"),
            StoragePaths: A(),
            CountSource: "usage", ByteSource: null,
            Retention: "rolling", Actions: A("view", "export", "delete"),
            EntitlementGate: null, SuspensionSurface: null,
            CloudVaultRewrapStrategy: "document_envelopes", SealingScheme: null),
        new(
            Id: "conversations_chat", Title: "Conversations & Chat", Icon: "bubble.left.and.bubble.right.fill",
            EncryptionTier: EncryptionTier.EndToEnd,
            Summary: "Assistant chats, CLI agent transcripts, mobile mission prompts/results, saved text snippets, rollback scope/diagnostics, approval rules, agent personas, subscription graph edges, and conversation recall metadata are sealed on-device before Firestore receives them.",
            ServerSees: A("provider/runtime identifiers", "message counts", "status/routing metadata", "timestamps", "device ids"),
            DeviceOnly: A("chat titles", "chat previews", "message bodies", "CLI transcripts", "mission prompts/results", "saved text snippets", "project/file/command labels", "rollback scope paths", "rollback error diagnostics", "approval policy labels/globs/projects", "agent persona text", "subscription graph edges and display text"),
            FirestorePaths: A("conversations", "chat_threads", "mobile_assistant_chats", "cli_sessions", "cli_agent_mission_requests", "text_snippets", "rollback_requests", "approval_policies", "agent_identities", "subscription_topics"),
            StoragePaths: A(),
            CountSource: "chat_threads", ByteSource: null,
            Retention: "until_deleted", Actions: A("view", "export", "delete"),
            EntitlementGate: "burnbar_pro", SuspensionSurface: "burnbar_cloud",
            CloudVaultRewrapStrategy: "document_envelopes", SealingScheme: null),
        new(
            Id: "session_logs", Title: "Searchable Session Logs", Icon: "text.magnifyingglass",
            EncryptionTier: EncryptionTier.EndToEnd,
            Summary: "Full conversation bodies + the encrypted search index + project memory. Sealed on-device; the server holds only ciphertext, aggregate cockpit facets, and opaque search/integrity hashes. NOTE: the keyword search index is deterministic — repeated and co-occurring search terms produce stable keyed digests, so the server can learn which terms recur and appear together across your logs (the search structure), and the integrity hashes can confirm a guessed body or chunk; every title, snippet, body, and path stays sealed and unreadable.",
            ServerSees: A("provider", "model", "cost", "token counts", "timing", "integrity hashes", "deterministic keyed search digests"),
            DeviceOnly: A("project/path text", "title", "snippet", "body preview", "full transcript body"),
            FirestorePaths: A("session_logs", "cloud_search_documents", "cloud_search_chunks", "cloud_search_postings", "cloud_search_index_state", "cloud_search_index_manifest", "project_memory_snapshots"),
            StoragePaths: A("session_logs/{documentID}/bodies/{bodyHash}.json.aesgcm"),
            CountSource: "cloud_search_documents", ByteSource: "session_logs",
            Retention: "until_deleted", Actions: A("view", "export", "delete"),
            EntitlementGate: "burnbar_pro", SuspensionSurface: "burnbar_cloud",
            CloudVaultRewrapStrategy: "document_and_storage_envelopes", SealingScheme: null),
        new(
            Id: "pensieve", Title: "Pensieve Knowledge", Icon: "brain.head.profile",
            EncryptionTier: EncryptionTier.EndToEnd,
            Summary: "Your private semantic memory: repo docs, notes, and chat-derived memories your agents recall. Text is sealed on-device; hosted ANN recall is an explicit opt-in over cloaked vectors and opaque keyed hashes. Approved chat memories replicate only as sealed fact envelopes plus opaque source hashes and forget receipts. Those structures still reveal structural signals such as vector geometry, recurrence/co-occurrence patterns, counts, and access timing. Use local-only recall for sensitive memories when available. NOTE: a connected repo stores only opaque keyed repo and GitHub-installation match tokens plus a sealed repo name — the cleartext repo name is observed transiently server-side only to route an inbound GitHub push webhook, never stored.",
            ServerSees: A("cloaked 384-dim vectors", "sourceKind", "opaque keyed slug/dedup/source hashes", "opaque repo and GitHub-installation match tokens", "chunk/byte counts", "approved memory metadata", "forget receipt hashes", "timestamps"),
            DeviceOnly: A("chunk text", "chat memory fact bodies", "chat memory citations", "source paths", "repo names", "section/category metadata"),
            FirestorePaths: A("cloud_search_knowledge", "knowledge_sync_manifests", "knowledge_repos", "memory_facts", "memory_forget_receipts"),
            StoragePaths: A(),
            CountSource: "knowledge_sync_manifests.chunkCount", ByteSource: "knowledge_sync_manifests.byteCount",
            Retention: "until_deleted", Actions: A("view", "export", "delete", "configure", "sync"),
            EntitlementGate: "burnbar_pro_max", SuspensionSurface: "burnbar_cloud_pro",
            CloudVaultRewrapStrategy: "document_envelopes", SealingScheme: "cloudvault-aesgcm-v2"),
        new(
            Id: "provider_accounts", Title: "Provider Accounts", Icon: "person.badge.key.fill",
            EncryptionTier: EncryptionTier.ServerReadable,
            Summary: "Connected AI provider accounts. Labels + status only — the actual credentials live in Google Cloud Secret Manager, never in your data tree.",
            ServerSees: A("provider id", "redacted label", "status", "refresh metadata"),
            DeviceOnly: A("secret material (in Secret Manager, not the user tree)"),
            FirestorePaths: A("provider_accounts", "provider_connections", "provider_account_device_links", "runtime_connection_preferences"),
            StoragePaths: A(),
            CountSource: "provider_accounts", ByteSource: null,
            Retention: "until_disconnected", Actions: A("view", "revoke"),
            EntitlementGate: null, SuspensionSurface: null,
            CloudVaultRewrapStrategy: null, SealingScheme: null),
        new(
            Id: "connected_devices", Title: "Connected Devices & Pairings", Icon: "laptopcomputer.and.iphone",
            EncryptionTier: EncryptionTier.ServerReadable,
            Summary: "Your paired Macs, phones, and relays (Hermes, Pi agent, iroh) and which can talk to your account. NOTE: paired relay and hosted-gateway frame contents are only claimed as sealed after paired E2EE is enabled and the runtime-readiness gate is complete; relay routing metadata, public keys, coarse tool labels, thread ids, attachment ids, and delivery state remain visible. The per-agent subscription graph is cloaked behind opaque keyed doc ids.",
            ServerSees: A("device ids", "pairing metadata", "last seen", "relay routing", "opaque relay key material (public keys)"),
            DeviceOnly: A("paired relay + gateway frame contents after E2EE/runtime readiness is complete (message text, sender names, attachment file names — sealed on-device in that mode)"),
            FirestorePaths: A("devices", "hermes_connections", "hermes_pairings", "hermes_relay_requests", "hermes_session_cache", "hermes_gateway_clients", "hermes_gateway_destinations", "hermes_gateway_events", "hermes_gateway_messages", "hermes_gateway_typing", "hermes_gateway_state", "hermes_gateway_attachments", "hermes_gateway_approvals", "pi_agent_connections", "pi_agent_pairings", "pi_agent_relay_requests", "iroh_pairing", "iroh_pairing_keys", "relay_sender_keys", "runtime_connection_preferences"),
            StoragePaths: A("hermes_gateway_attachments/**"),
            CountSource: "devices", ByteSource: null,
            Retention: "until_revoked", Actions: A("view", "revoke"),
            EntitlementGate: null, SuspensionSurface: null,
            CloudVaultRewrapStrategy: null, SealingScheme: null),
        new(
            Id: "external_mcp", Title: "External Agent Access (MCP)", Icon: "key.horizontal.fill",
            EncryptionTier: EncryptionTier.ServerReadable,
            Summary: "Coding agents you've granted hosted-MCP access to, the scopes they hold, and their access audit trail.",
            ServerSees: A("client id", "display name", "granted scopes", "grant mode", "access timestamps"),
            DeviceOnly: A("decrypted search/recall results (decrypted only in the local shim)"),
            FirestorePaths: A("remote_mcp_clients", "remote_mcp_grants", "remote_mcp_audit_events", "remote_mcp_rate_limits"),
            StoragePaths: A(),
            CountSource: "remote_mcp_clients", ByteSource: null,
            Retention: "until_revoked", Actions: A("view", "revoke"),
            EntitlementGate: "burnbar_pro", SuspensionSurface: "remote_mcp",
            CloudVaultRewrapStrategy: null, SealingScheme: null),
        new(
            Id: "computer_use", Title: "Agent Control & Escrow", Icon: "cursorarrow.rays",
            EncryptionTier: EncryptionTier.ZeroAccess,
            Summary: "Computer-use (Agent Control) sessions and their tamper-evident escrow audit trail.",
            ServerSees: A("session metadata", "action counts", "quota usage"),
            DeviceOnly: A("sealed escrow envelopes"),
            FirestorePaths: A("computer_use_sessions", "computer_use_actions", "computer_use_quota_usage", "agent_grant_authorities", "agent_capability_grant_requests"),
            StoragePaths: A(),
            CountSource: "computer_use_sessions", ByteSource: null,
            Retention: "rolling", Actions: A("view", "delete"),
            EntitlementGate: "burnbar_pro_max", SuspensionSurface: "hosted_agent_control",
            CloudVaultRewrapStrategy: null, SealingScheme: null),
        new(
            Id: "media", Title: "Media", Icon: "photo.on.rectangle.angled",
            EncryptionTier: EncryptionTier.ZeroAccess,
            Summary: "Files, screen, and video relayed between your Mac and phones (Floo media). NOTE: an attachment manifest records only an opaque content hash, mime type, byte size, an opaque per-peer device-id hash, direction, and timestamps — the human-readable file name is sealed on-device (sealedFilename) and never readable by the server.",
            ServerSees: A("session events", "quota usage", "attachment blob hash", "mime type", "byte size", "opaque peer device-id hash", "direction", "short-lived call routing ids", "timestamps"),
            DeviceOnly: A("media payload contents (relayed/sealed)", "attachment file names (sealed on-device)"),
            FirestorePaths: A("media_session_events", "media_quota_usage", "media_attachment_manifests", "incoming_call_contexts"),
            StoragePaths: A(),
            CountSource: "media_attachment_manifests", ByteSource: "media_attachment_manifests",
            Retention: "rolling", Actions: A("view", "delete"),
            EntitlementGate: "burnbar_pro_max", SuspensionSurface: "floo_relay",
            CloudVaultRewrapStrategy: "document_envelopes", SealingScheme: null),
        new(
            Id: "entitlements_billing", Title: "Plan & Billing", Icon: "creditcard.fill",
            EncryptionTier: EncryptionTier.ServerReadable,
            Summary: "Your subscription entitlements (Cloud Pro, Ultra) and their change history.",
            ServerSees: A("entitlement ids", "product ids", "active state", "expiry", "purchase source"),
            DeviceOnly: A(),
            FirestorePaths: A("entitlements", "entitlement_events", "entitlement_bindings", "billing"),
            StoragePaths: A(),
            CountSource: "entitlements", ByteSource: null,
            Retention: "permanent", Actions: A("view"),
            EntitlementGate: null, SuspensionSurface: null,
            CloudVaultRewrapStrategy: null, SealingScheme: null),
        new(
            Id: "device_trust_keys", Title: "Device Trust & Vault Keys", Icon: "lock.shield.fill",
            EncryptionTier: EncryptionTier.EndToEnd,
            Summary: "Which devices are trusted to decrypt your data, and the wrapped vault keys that make end-to-end encryption possible. The crux of the whole E2EE model.",
            ServerSees: A("device trust state", "public key fingerprints", "wrapped (ciphertext) key blobs"),
            DeviceOnly: A("the vault key itself (Keychain / 0600 file, never uploaded)"),
            FirestorePaths: A("cloud_vault_state", "cloud_vault_key_wrappers", "cloud_vault_rotation_jobs", "cloud_vault_rotation_requirements", "escrow_devices", "escrow_public_keys", "signal_identity_public_keys", "escrow_grants", "escrow_envelopes", "escrow_audit_events", "account_recovery_methods"),
            StoragePaths: A(),
            CountSource: "escrow_devices", ByteSource: null,
            Retention: "until_revoked", Actions: A("view", "approve", "revoke", "recover"),
            EntitlementGate: null, SuspensionSurface: null,
            CloudVaultRewrapStrategy: "key_wrappers_only", SealingScheme: null),
        new(
            Id: "audit_timeline", Title: "Access Audit Timeline", Icon: "list.bullet.rectangle.portrait.fill",
            EncryptionTier: EncryptionTier.ServerReadable,
            Summary: "A unified, tamper-evident log of who/what accessed your data, when — across every device, agent, and grant.",
            ServerSees: A("actor", "action", "domain", "timestamp", "hash-chain links", "generic notification routing ids"),
            DeviceOnly: A(),
            FirestorePaths: A("remote_mcp_audit_events", "hermes_audit_events", "pi_agent_audit_events", "iroh_audit_events", "escrow_audit_events", "entitlement_events", "budgetEvents", "agent_notification_events", "agent_notification_replies", "unified_audit_log", "audit_meta"),
            StoragePaths: A(),
            CountSource: "unified_audit_log", ByteSource: null,
            Retention: "append_only", Actions: A("view", "verify", "export"),
            EntitlementGate: null, SuspensionSurface: null,
            CloudVaultRewrapStrategy: "document_envelopes", SealingScheme: null),
    };

    /// <summary>Resolve a domain by id, or <c>null</c>. Port of Swift <c>DataDomains.domain(_:)</c>.</summary>
    public static DataDomain? Domain(string id) => All.FirstOrDefault(d => d.Id == id);
}
