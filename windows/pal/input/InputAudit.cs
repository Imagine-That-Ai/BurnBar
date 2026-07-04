// Audit record for every input-gate decision (advisory + enforced).
//
// "Advisory action logs" (lane contract) and the macOS invariant that a durable audit
// record is appended BEFORE dispatch (ComputerUseDenyReason.auditFailure: "absence of one
// denies the action") both live here. Every decision — dispatched or rejected — produces a
// record. The record carries a PreviousEntryHashHex slot + canonical bytes so the Ed25519
// audit-chain lane can hash-link + sign these entries without a schema change.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace OpenBurnBar.Pal.Input;

/// <summary>Whether the audited decision dispatched or was refused.</summary>
public enum InputDispatchDecision
{
    Dispatched,
    Rejected,
}

/// <summary>One append-only audit entry for an input-gate decision.</summary>
public sealed class VirtualHidAuditRecord
{
    public VirtualHidAuditRecord(
        string auditKind,
        InputDispatchRoute route,
        InputDispatchAuthorization authorization,
        InputDispatchDecision decision,
        VirtualHidGateDenyReason? denyReason,
        string? capabilityTokenNonce,
        long timestampUnixMs,
        string? previousEntryHashHex = null)
    {
        AuditKind = auditKind ?? throw new ArgumentNullException(nameof(auditKind));
        Route = route;
        Authorization = authorization;
        Decision = decision;
        DenyReason = denyReason;
        CapabilityTokenNonce = capabilityTokenNonce;
        TimestampUnixMs = timestampUnixMs;
        PreviousEntryHashHex = previousEntryHashHex;
    }

    public string AuditKind { get; }
    public InputDispatchRoute Route { get; }
    public InputDispatchAuthorization Authorization { get; }
    public InputDispatchDecision Decision { get; }
    public VirtualHidGateDenyReason? DenyReason { get; }
    public string? CapabilityTokenNonce { get; }
    public long TimestampUnixMs { get; }

    /// <summary>Hex hash of the previous chain entry, wired by the audit-chain lane. Null
    /// for an un-chained record.</summary>
    public string? PreviousEntryHashHex { get; }

    /// <summary>Deterministic canonical bytes for hashing/signing this entry (the audit
    /// chain hashes these). Stable field order; not intended to round-trip.</summary>
    public byte[] CanonicalBytes()
    {
        var sb = new StringBuilder(160);
        sb.Append(AuditKind).Append('\n');
        sb.Append(Route).Append('\n');
        sb.Append(Authorization).Append('\n');
        sb.Append(Decision).Append('\n');
        sb.Append(DenyReason?.ToString() ?? "-").Append('\n');
        sb.Append(CapabilityTokenNonce ?? "-").Append('\n');
        sb.Append(TimestampUnixMs.ToString(CultureInfo.InvariantCulture)).Append('\n');
        sb.Append(PreviousEntryHashHex ?? "-");
        return Encoding.UTF8.GetBytes(sb.ToString());
    }
}

/// <summary>The durable audit sink. <see cref="Record"/> MUST persist before dispatch;
/// if it throws, the dispatcher fails closed and does not execute the action.</summary>
public interface IInputAuditSink
{
    void Record(VirtualHidAuditRecord record);
}

/// <summary>In-memory audit sink for tests and ephemeral coordinators.</summary>
public sealed class InMemoryInputAuditSink : IInputAuditSink
{
    private readonly object _gate = new();
    private readonly List<VirtualHidAuditRecord> _records = new();

    public void Record(VirtualHidAuditRecord record)
    {
        if (record is null)
        {
            throw new ArgumentNullException(nameof(record));
        }
        lock (_gate)
        {
            _records.Add(record);
        }
    }

    /// <summary>A snapshot of the recorded entries, oldest first.</summary>
    public IReadOnlyList<VirtualHidAuditRecord> Records
    {
        get
        {
            lock (_gate)
            {
                return _records.ToArray();
            }
        }
    }
}
