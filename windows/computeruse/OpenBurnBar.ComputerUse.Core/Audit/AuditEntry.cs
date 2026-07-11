// One entry in the Computer-Use audit chain.
//
// Port of ComputerUseAuditEntry.swift. The field set is locked at ship and never
// reordered — the chain hashes a canonical-JSON serialization of this entry, so
// a re-hash after decode must reproduce byte-identical JSON. Screenshots /
// selectors / URLs stay private at rest: only the action descriptor's hash is
// recorded, not its payload.

using System;
using System.Text.Json;
using OpenBurnBar.ComputerUse.Core.Crypto;

namespace OpenBurnBar.ComputerUse.Core.Audit;

/// <summary>Who authorized the action recorded by an audit entry.</summary>
public enum AuditApprovedBy
{
    Mac,
    Phone,
    TrustedScope,
    Step,
    Denied,
    Panic,
}

/// <summary>Wire strings for <see cref="AuditApprovedBy"/>.</summary>
public static class AuditApprovedByWire
{
    public static string ToWire(this AuditApprovedBy value) => value switch
    {
        AuditApprovedBy.Mac => "mac",
        AuditApprovedBy.Phone => "phone",
        AuditApprovedBy.TrustedScope => "trusted_scope",
        AuditApprovedBy.Step => "step",
        AuditApprovedBy.Denied => "denied",
        AuditApprovedBy.Panic => "panic",
        _ => throw new ArgumentOutOfRangeException(nameof(value), value, null),
    };

    public static bool TryParse(string wire, out AuditApprovedBy value)
    {
        switch (wire)
        {
            case "mac": value = AuditApprovedBy.Mac; return true;
            case "phone": value = AuditApprovedBy.Phone; return true;
            case "trusted_scope": value = AuditApprovedBy.TrustedScope; return true;
            case "step": value = AuditApprovedBy.Step; return true;
            case "denied": value = AuditApprovedBy.Denied; return true;
            case "panic": value = AuditApprovedBy.Panic; return true;
            default: value = AuditApprovedBy.Denied; return false;
        }
    }
}

/// <summary>A tamper-evident audit-chain entry.</summary>
public sealed class ComputerUseAuditEntry
{
    /// <summary>Current schema version; the validator rejects a mismatch.</summary>
    public const int CurrentSchemaVersion = 1;

    public ComputerUseAuditEntry(
        string sessionId,
        int entryIndex,
        DateTimeOffset timestamp,
        string actionKind,
        string actionSummary,
        string actionDescriptorHashHex,
        AuditApprovedBy approvedBy,
        string parentEntryHashHex,
        string macAppVersion,
        string? beforeScreenshotHashHex = null,
        string? afterScreenshotHashHex = null,
        string? approvalId = null,
        string? scopeRuleId = null,
        string? denyReason = null,
        string? macHostNodeId = null,
        int schemaVersion = CurrentSchemaVersion)
    {
        SchemaVersion = schemaVersion;
        SessionId = sessionId;
        EntryIndex = entryIndex;
        Timestamp = timestamp;
        ActionKind = actionKind;
        ActionSummary = actionSummary;
        ActionDescriptorHashHex = actionDescriptorHashHex;
        ApprovedBy = approvedBy;
        ParentEntryHashHex = parentEntryHashHex;
        MacAppVersion = macAppVersion;
        BeforeScreenshotHashHex = beforeScreenshotHashHex;
        AfterScreenshotHashHex = afterScreenshotHashHex;
        ApprovalId = approvalId;
        ScopeRuleId = scopeRuleId;
        DenyReason = denyReason;
        MacHostNodeId = macHostNodeId;
    }

    public int SchemaVersion { get; }

    public string SessionId { get; }

    public int EntryIndex { get; }

    public DateTimeOffset Timestamp { get; }

    public string ActionKind { get; }

    public string ActionSummary { get; }

    public string ActionDescriptorHashHex { get; }

    public string? BeforeScreenshotHashHex { get; }

    public string? AfterScreenshotHashHex { get; }

    public string? ApprovalId { get; }

    public AuditApprovedBy ApprovedBy { get; }

    public string? ScopeRuleId { get; }

    public string? DenyReason { get; }

    public string ParentEntryHashHex { get; }

    public string MacAppVersion { get; }

    public string? MacHostNodeId { get; }

    /// <summary>Canonical-JSON map (audit-hasher form: ms-int date, omitted nulls).</summary>
    public CanonicalJsonObject ToCanonicalMap() => new CanonicalJsonObject()
        .Set("schemaVersion", SchemaVersion)
        .Set("sessionId", SessionId)
        .Set("entryIndex", EntryIndex)
        .Set("timestamp", Timestamp.ToUnixTimeMilliseconds())
        .Set("actionKind", ActionKind)
        .Set("actionSummary", ActionSummary)
        .Set("actionDescriptorHashHex", ActionDescriptorHashHex)
        .Set("beforeScreenshotHashHex", BeforeScreenshotHashHex)
        .Set("afterScreenshotHashHex", AfterScreenshotHashHex)
        .Set("approvalId", ApprovalId)
        .Set("approvedBy", ApprovedBy.ToWire())
        .Set("scopeRuleId", ScopeRuleId)
        .Set("denyReason", DenyReason)
        .Set("parentEntryHashHex", ParentEntryHashHex)
        .Set("macAppVersion", MacAppVersion)
        .Set("macHostNodeId", MacHostNodeId);

    /// <summary>Canonical bytes for this entry (what the chain hashes + appends).</summary>
    public byte[] CanonicalBytes() => CanonicalJson.Encode(ToCanonicalMap());

    /// <summary>
    /// Decodes one canonical-JSON line back into an entry. Returns null on any
    /// structural or type failure so the validator can report a decode failure.
    /// </summary>
    public static ComputerUseAuditEntry? FromJsonLine(ReadOnlySpan<byte> line)
    {
        try
        {
            using var document = JsonDocument.Parse(line.ToArray());
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            if (!AuditApprovedByWire.TryParse(RequireString(root, "approvedBy"), out var approvedBy))
            {
                return null;
            }

            return new ComputerUseAuditEntry(
                sessionId: RequireString(root, "sessionId"),
                entryIndex: RequireInt(root, "entryIndex"),
                timestamp: DateTimeOffset.FromUnixTimeMilliseconds(RequireLong(root, "timestamp")),
                actionKind: RequireString(root, "actionKind"),
                actionSummary: RequireString(root, "actionSummary"),
                actionDescriptorHashHex: RequireString(root, "actionDescriptorHashHex"),
                approvedBy: approvedBy,
                parentEntryHashHex: RequireString(root, "parentEntryHashHex"),
                macAppVersion: RequireString(root, "macAppVersion"),
                beforeScreenshotHashHex: OptionalString(root, "beforeScreenshotHashHex"),
                afterScreenshotHashHex: OptionalString(root, "afterScreenshotHashHex"),
                approvalId: OptionalString(root, "approvalId"),
                scopeRuleId: OptionalString(root, "scopeRuleId"),
                denyReason: OptionalString(root, "denyReason"),
                macHostNodeId: OptionalString(root, "macHostNodeId"),
                schemaVersion: RequireInt(root, "schemaVersion"));
        }
        catch (Exception ex) when (ex is JsonException or FormatException or InvalidOperationException or MissingFieldException)
        {
            return null;
        }
    }

    private static string RequireString(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
        {
            throw new MissingFieldException(name);
        }

        return value.GetString()!;
    }

    private static int RequireInt(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number)
        {
            throw new MissingFieldException(name);
        }

        return value.GetInt32();
    }

    private static long RequireLong(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number)
        {
            throw new MissingFieldException(name);
        }

        return value.GetInt64();
    }

    private static string? OptionalString(JsonElement root, string name)
        => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
}
