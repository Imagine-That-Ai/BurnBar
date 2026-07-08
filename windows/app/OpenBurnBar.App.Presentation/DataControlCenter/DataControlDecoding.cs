using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using OpenBurnBar.App.Presentation.Memories;

namespace OpenBurnBar.App.Presentation.DataControlCenter;

// PORTED (faithful) from the parse + error-distillation half of
// AgentLens/Services/DataControlCenterViewModel.swift (applyUsage / parseAuditEvent /
// parseDate / intValue / int64Value / userFacing).
//
// The Swift VM reads FirebaseFunctions `result.data as? [String: Any]`. The portable analog is an
// IReadOnlyDictionary<string, object?> (a decoded JSON object). Keeping the coercion + distillation
// here means the real FirebaseFunctions Windows adapter and the macOS `dotnet test` share ONE
// tested decode path, and the workbench never leaks a raw `code=internal` string.

/// <summary>Number / date coercion helpers mirroring the Swift <c>intValue</c>/<c>parseDate</c> set.</summary>
public static class CallableValue
{
    /// <summary>Coerce to <see cref="int"/> or <c>null</c>. Swift: <c>intValueOptional</c>.</summary>
    public static int? IntOrNull(object? raw) => raw switch
    {
        null => null,
        int i => i,
        long l => (int)l,
        double d => (int)d,
        float f => (int)f,
        bool b => b ? 1 : 0,
        string s => int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : null,
        _ => null,
    };

    /// <summary>Coerce to <see cref="int"/>, defaulting 0. Swift: <c>intValue</c>.</summary>
    public static int Int(object? raw) => IntOrNull(raw) ?? 0;

    /// <summary>Coerce to <see cref="long"/>, defaulting 0. Swift: <c>int64Value</c>.</summary>
    public static long Int64(object? raw) => raw switch
    {
        null => 0,
        long l => l,
        int i => i,
        double d => (long)d,
        float f => (long)f,
        string s => long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : 0,
        _ => 0,
    };

    /// <summary>Coerce to <see cref="bool"/>, defaulting <paramref name="fallback"/>.</summary>
    public static bool Bool(object? raw, bool fallback = false) => raw switch
    {
        bool b => b,
        string s when bool.TryParse(s, out var v) => v,
        _ => fallback,
    };

    /// <summary>Coerce to <see cref="string"/>, or <c>null</c>.</summary>
    public static string? StringOrNull(object? raw) => raw as string;

    /// <summary>
    /// Parse an ISO-8601 string (with or without fractional seconds) or epoch-millis number into a
    /// timestamp. Swift: <c>parseDate</c>.
    /// </summary>
    public static DateTimeOffset? Date(object? raw)
    {
        switch (raw)
        {
            case string s when DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var parsed):
                return parsed;
            case double ms:
                return DateTimeOffset.FromUnixTimeMilliseconds((long)ms);
            case long ms:
                return DateTimeOffset.FromUnixTimeMilliseconds(ms);
            case int ms:
                return DateTimeOffset.FromUnixTimeMilliseconds(ms);
            default:
                return null;
        }
    }

    /// <summary>Read a nested object (a JSON sub-dictionary).</summary>
    public static IReadOnlyDictionary<string, object?>? Dict(object? raw) =>
        raw as IReadOnlyDictionary<string, object?>;

    /// <summary>Read an array of objects (a JSON list).</summary>
    public static IReadOnlyList<object?>? List(object? raw) =>
        raw as IReadOnlyList<object?>;
}

/// <summary>Decodes the getDataDomainUsage payload into a typed snapshot. Swift: <c>applyUsage</c>.</summary>
public static class DataDomainUsageParser
{
    /// <summary>
    /// Parse the raw callable payload. Unknown / missing fields degrade to defaults (Free tier,
    /// empty caps, zero usage) rather than throwing — matching the Swift VM's lenient merge.
    /// </summary>
    public static DataDomainUsageSnapshot Parse(IReadOnlyDictionary<string, object?>? payload)
    {
        if (payload is null)
        {
            return DataDomainUsageSnapshot.Empty;
        }

        AccountPlanTier tier = AccountPlanTier.Free;
        if (payload.TryGetValue("tier", out var rawTier)
            && AccountPlanTierExtensions.FromRawValue(rawTier as string) is { } parsedTier)
        {
            tier = parsedTier;
        }

        var limits = PensieveLimits.Empty;
        if (payload.TryGetValue("limits", out var rawLimits)
            && CallableValue.Dict(rawLimits) is { } limitsDict
            && limitsDict.TryGetValue("pensieve", out var rawPensieve)
            && CallableValue.Dict(rawPensieve) is { } pensieve)
        {
            limits = new PensieveLimits(
                CallableValue.Int(pensieve.GetValueOrDefault("sources")),
                CallableValue.Int(pensieve.GetValueOrDefault("chunks")),
                CallableValue.Int64(pensieve.GetValueOrDefault("bytes")));
        }

        var usageById = new Dictionary<string, DomainUsage>(StringComparer.Ordinal);
        if (payload.TryGetValue("domains", out var rawDomains) && CallableValue.List(rawDomains) is { } domains)
        {
            foreach (var entry in domains)
            {
                if (CallableValue.Dict(entry) is not { } row || row.GetValueOrDefault("id") is not string id)
                {
                    continue;
                }

                usageById[id] = new DomainUsage(
                    CallableValue.Int(row.GetValueOrDefault("count")),
                    CallableValue.Int64(row.GetValueOrDefault("bytes")));
            }
        }

        return new DataDomainUsageSnapshot(tier, limits, usageById);
    }
}

/// <summary>Decodes getAuditLog / listRecovery payloads. Swift: <c>parseAuditEvent</c> / recovery map.</summary>
public static class GovernanceDecoding
{
    /// <summary>Parse one audit event, or <c>null</c> when it lacks a sequence number.</summary>
    public static AuditEvent? ParseAuditEvent(IReadOnlyDictionary<string, object?> entry)
    {
        if (CallableValue.IntOrNull(entry.GetValueOrDefault("seq")) is not { } seq)
        {
            return null;
        }

        return new AuditEvent(
            Seq: seq,
            Timestamp: CallableValue.Date(entry.GetValueOrDefault("ts")),
            Actor: entry.GetValueOrDefault("actor") as string ?? "—",
            Action: entry.GetValueOrDefault("action") as string ?? "—",
            Domain: entry.GetValueOrDefault("domain") as string ?? "—",
            PrevHash: entry.GetValueOrDefault("prevHash") as string ?? string.Empty,
            Hash: entry.GetValueOrDefault("hash") as string ?? string.Empty);
    }

    /// <summary>Parse an audit page: events (seq-bearing only) + the continuation cursor.</summary>
    public static AuditPage ParseAuditPage(IReadOnlyDictionary<string, object?>? payload)
    {
        if (payload is null || CallableValue.List(payload.GetValueOrDefault("events")) is not { } events)
        {
            return new AuditPage(Array.Empty<AuditEvent>(), null);
        }

        var parsed = events
            .Select(CallableValue.Dict)
            .Where(d => d is not null)
            .Select(d => ParseAuditEvent(d!))
            .Where(e => e is not null)
            .Select(e => e!)
            .ToList();

        return new AuditPage(parsed, CursorString(payload.GetValueOrDefault("nextCursor")));
    }

    /// <summary>
    /// Normalize a <c>nextCursor</c> to the <see cref="AuditPage.NextCursor"/> string. The deployed
    /// getAuditLog (functions/src/callables/auditLog.ts) returns <c>nextCursor</c> as a <b>number</b>
    /// (last event seq + 1), omitting it on the final page; the macOS Swift VM read it with
    /// <c>as? String</c> and so never advanced (a real reference bug). We coerce the numeric cursor to
    /// its invariant string form here so the Windows client actually paginates, while a string cursor
    /// (a dev-host / future contract) still passes through untouched.
    /// </summary>
    private static string? CursorString(object? raw) => raw switch
    {
        null => null,
        string s => s.Length == 0 ? null : s,
        long l => l.ToString(CultureInfo.InvariantCulture),
        int i => i.ToString(CultureInfo.InvariantCulture),
        double d => ((long)d).ToString(CultureInfo.InvariantCulture),
        _ => null,
    };

    /// <summary>Parse deleteDomainData's <c>deleted.{firestoreDocs,storageObjects}</c> tally.</summary>
    public static DeleteResult ParseDeleteResult(IReadOnlyDictionary<string, object?>? payload)
    {
        if (payload is null || CallableValue.Dict(payload.GetValueOrDefault("deleted")) is not { } deleted)
        {
            return new DeleteResult(0, 0);
        }

        return new DeleteResult(
            CallableValue.Int(deleted.GetValueOrDefault("firestoreDocs")),
            CallableValue.Int(deleted.GetValueOrDefault("storageObjects")));
    }

    /// <summary>
    /// Parse revokeAllAccess's <c>revoked.{mcpClients,devices,escrowDevices,providers}</c> panic tally.
    /// Mirrors the Swift <c>RevokeResult</c> exactly: the deployed function also returns
    /// <c>revoked.signalSessions</c> and top-level <c>partial</c>/<c>failures</c>, which the macOS VM
    /// ignores and the ported <see cref="RevokeResult"/> likewise does not surface.
    /// </summary>
    public static RevokeResult ParseRevokeResult(IReadOnlyDictionary<string, object?>? payload)
    {
        if (payload is null || CallableValue.Dict(payload.GetValueOrDefault("revoked")) is not { } revoked)
        {
            return new RevokeResult(0, 0, 0, 0);
        }

        return new RevokeResult(
            CallableValue.Int(revoked.GetValueOrDefault("mcpClients")),
            CallableValue.Int(revoked.GetValueOrDefault("devices")),
            CallableValue.Int(revoked.GetValueOrDefault("escrowDevices")),
            CallableValue.Int(revoked.GetValueOrDefault("providers")));
    }

    /// <summary>Parse verifyAuditLog's <c>{ valid, brokenAt? }</c> hash-chain verdict.</summary>
    public static AuditVerification ParseAuditVerification(IReadOnlyDictionary<string, object?>? payload)
    {
        if (payload is null)
        {
            return new AuditVerification(false, null);
        }

        return new AuditVerification(
            CallableValue.Bool(payload.GetValueOrDefault("valid")),
            CallableValue.IntOrNull(payload.GetValueOrDefault("brokenAt")));
    }

    /// <summary>Read setupRecovery's <c>recoveryId</c>, or <c>null</c> when the payload lacks it.</summary>
    public static string? ParseRecoveryId(IReadOnlyDictionary<string, object?>? payload) =>
        payload?.GetValueOrDefault("recoveryId") as string;

    /// <summary>Parse the listRecovery methods (id + kind required). Swift: <c>refreshRecovery</c> map.</summary>
    public static IReadOnlyList<RecoveryMethod> ParseRecoveryMethods(IReadOnlyDictionary<string, object?>? payload)
    {
        if (payload is null || CallableValue.List(payload.GetValueOrDefault("methods")) is not { } methods)
        {
            return Array.Empty<RecoveryMethod>();
        }

        return methods
            .Select(CallableValue.Dict)
            .Where(d => d is not null)
            .Select(d => d!)
            .Where(d => d.GetValueOrDefault("recoveryId") is string && d.GetValueOrDefault("kind") is string)
            .Select(d => new RecoveryMethod(
                RecoveryId: (string)d.GetValueOrDefault("recoveryId")!,
                Kind: (string)d.GetValueOrDefault("kind")!,
                CreatedAt: CallableValue.Date(d.GetValueOrDefault("createdAt")),
                Confirmed: CallableValue.Bool(d.GetValueOrDefault("confirmed"))))
            .ToList();
    }
}

/// <summary>
/// User-facing error distillation. Faithful port of Swift <c>userFacing(_:)</c> — the same calm
/// language for the same underlying Functions failures, so the workbench never shows
/// <c>code=internal</c>.
/// </summary>
public static class DataControlErrorMapping
{
    public const string Fallback = "Something went wrong. Try again.";

    /// <summary>Map an exception to calm copy (honoring <see cref="IFriendlyError"/> first).</summary>
    public static string UserFacing(Exception error)
    {
        if (error is IFriendlyError friendly && friendly.FriendlyMessage is { } message)
        {
            return message;
        }

        return UserFacing(error.Message);
    }

    /// <summary>Map a raw error string to calm copy. Swift: the lowercase-substring ladder.</summary>
    public static string UserFacing(string? raw)
    {
        string trimmed = (raw ?? string.Empty).Trim();
        if (trimmed.Length == 0)
        {
            return Fallback;
        }

        string lower = trimmed.ToLowerInvariant();
        if (lower == "internal"
            || lower.Contains("code=internal")
            || lower.Contains("error 13")
            || lower.Contains("signblob")
            || lower.Contains("signed url"))
        {
            return "We couldn't complete that securely. Try again in a minute.";
        }

        if (lower.Contains("unauthenticated") || (lower.Contains("auth") && lower.Contains("expired")))
        {
            return "Sign in again to manage your data.";
        }

        if (lower.Contains("permission") || lower.Contains("denied"))
        {
            return "This action isn't available for your account yet.";
        }

        if (lower.Contains("network") || lower.Contains("offline") || lower.Contains("timed out"))
        {
            return "Network connection failed. Try again when you're online.";
        }

        return trimmed;
    }
}
