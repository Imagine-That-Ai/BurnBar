using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.DataControlCenter;

// PORTED (faithful, scoped) from the nested value types in
// AgentLens/Services/DataControlCenterViewModel.swift. These are the plain, portable data
// shapes the inventory DataGrid, Basin, inspector, and governance dialogs bind to — the SAME
// assembly the WinUI app references and the macOS `dotnet test` exercises.

/// <summary>Plan tier echoed by getDataDomainUsage. Swift: <c>enum Tier</c>.</summary>
public enum AccountPlanTier
{
    Ultra,
    Pro,
    Free,
}

/// <summary>Maps <see cref="AccountPlanTier"/> to/from the callable's raw string.</summary>
public static class AccountPlanTierExtensions
{
    public static string RawValue(this AccountPlanTier tier) => tier switch
    {
        AccountPlanTier.Ultra => "ultra",
        AccountPlanTier.Pro => "pro",
        AccountPlanTier.Free => "free",
        _ => "free",
    };

    public static AccountPlanTier? FromRawValue(string? raw) => raw switch
    {
        "ultra" => AccountPlanTier.Ultra,
        "pro" => AccountPlanTier.Pro,
        "free" => AccountPlanTier.Free,
        _ => null,
    };
}

/// <summary>
/// One inventory row: a registry domain decorated with its live usage snapshot. Identifiable by
/// the registry id so selection + sort stay stable across refreshes. Swift: <c>DomainRow</c>.
/// </summary>
public sealed record DomainRow(DataDomain Domain, int Count, long Bytes)
{
    public string Id => Domain.Id;

    public string Title => Domain.Title;

    /// <summary>True when the domain holds at least one record (the record COUNT, not a collection).</summary>
    public bool HasRecords => Count >= 1;

    public EncryptionTier Tier => Domain.EncryptionTier;

    public string Retention => Domain.Retention;
}

/// <summary>Tiered Pensieve caps echoed from getDataDomainUsage. Swift: <c>PensieveLimits</c>.</summary>
public readonly record struct PensieveLimits(int Sources, int Chunks, long Bytes)
{
    public static PensieveLimits Empty => new(0, 0, 0);
}

/// <summary>A registered recovery method (listRecovery). Swift: <c>RecoveryMethod</c>.</summary>
public sealed record RecoveryMethod(string RecoveryId, string Kind, DateTimeOffset? CreatedAt, bool Confirmed)
{
    public string Id => RecoveryId;

    public bool IsRecoveryContact => Kind == "recovery_contact";
}

/// <summary>Which recovery method is being registered. Swift: <c>RecoveryKind</c>.</summary>
public enum RecoveryKind
{
    RecoveryKey,
    RecoveryContact,
}

/// <summary>Maps <see cref="RecoveryKind"/> to the callable's raw string.</summary>
public static class RecoveryKindExtensions
{
    public static string RawValue(this RecoveryKind kind) => kind switch
    {
        RecoveryKind.RecoveryKey => "recovery_key",
        RecoveryKind.RecoveryContact => "recovery_contact",
        _ => "recovery_key",
    };
}

/// <summary>One tamper-evident audit event (getAuditLog). Swift: <c>AuditEvent</c>.</summary>
public sealed record AuditEvent(
    int Seq,
    DateTimeOffset? Timestamp,
    string Actor,
    string Action,
    string Domain,
    string PrevHash,
    string Hash)
{
    public int Id => Seq;
}

/// <summary>A page of audit events + the continuation cursor (getAuditLog).</summary>
public sealed record AuditPage(IReadOnlyList<AuditEvent> Events, string? NextCursor);

/// <summary>Result of verifyAuditLog. Swift: <c>AuditVerification</c>.</summary>
public readonly record struct AuditVerification(bool Valid, int? BrokenAt);

/// <summary>Result of deleteDomainData. Swift: <c>DeleteResult</c>.</summary>
public readonly record struct DeleteResult(int FirestoreDocs, int StorageObjects);

/// <summary>Which surfaces a panic revoke tears down. Swift: <c>RevokeScope</c>.</summary>
public enum RevokeScope
{
    Sync,
    All,
}

/// <summary>Maps <see cref="RevokeScope"/> to the callable's raw string.</summary>
public static class RevokeScopeExtensions
{
    public static string RawValue(this RevokeScope scope) => scope switch
    {
        RevokeScope.Sync => "sync",
        RevokeScope.All => "all",
        _ => "sync",
    };
}

/// <summary>Result of revokeAllAccess. Swift: <c>RevokeResult</c>.</summary>
public readonly record struct RevokeResult(int McpClients, int Devices, int EscrowDevices, int Providers);

/// <summary>
/// The decoded getDataDomainUsage snapshot: plan tier, Pensieve caps, and per-domain live
/// count/bytes keyed by domain id. Produced by <see cref="DataDomainUsageParser"/> from the raw
/// callable payload (the portable analog of Swift <c>applyUsage(_:)</c>).
/// </summary>
public sealed record DataDomainUsageSnapshot(
    AccountPlanTier Tier,
    PensieveLimits PensieveLimits,
    IReadOnlyDictionary<string, DomainUsage> UsageById)
{
    public static DataDomainUsageSnapshot Empty { get; } = new(
        AccountPlanTier.Free,
        PensieveLimits.Empty,
        new Dictionary<string, DomainUsage>());
}

/// <summary>Live count/bytes for a single domain (one row of getDataDomainUsage.domains).</summary>
public readonly record struct DomainUsage(int Count, long Bytes);
