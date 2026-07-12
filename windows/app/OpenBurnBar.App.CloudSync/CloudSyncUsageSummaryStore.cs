using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Read-only consumer of Mac-uploaded token-usage events at
/// <c>users/{uid}/usage/{deviceId}_{usageId}</c> (parity: <c>UsageSyncService.swift</c>),
/// aggregated into the Dashboard/Insights headline <see cref="DashboardUsageSummary"/>.
/// This is the live cloud fallback the Dashboard uses when the local SQLCipher
/// <c>token_usage</c> table is empty but a signed-in session exists — the same way
/// <c>QuotaAccountsSource</c> falls back to <c>quota_snapshots</c>. The private
/// <c>sealedProjectName</c> field is never read (BurnBar cannot decrypt it and this
/// aggregate does not need it).
/// </summary>
public sealed class CloudSyncUsageSummaryStore
{
    private readonly ICloudSyncGateway _gateway;
    private readonly string _uid;
    private readonly int _limit;
    private readonly Func<DateTimeOffset> _clock;

    public CloudSyncUsageSummaryStore(
        ICloudSyncGateway gateway,
        string uid,
        int limit = 2000,
        Func<DateTimeOffset>? clock = null)
    {
        _gateway = gateway;
        _uid = uid;
        _limit = limit;
        _clock = clock ?? (static () => DateTimeOffset.UtcNow);
    }

    public string CollectionPath => $"users/{_uid}/usage";

    /// <summary>
    /// Aggregate the usage events into the Dashboard summary — spend for the current UTC
    /// calendar month, total tokens across all rows, and the distinct session count —
    /// mirroring <see cref="OpenBurnBar.Storage.TokenUsageReadSeam"/>. Returns <c>null</c>
    /// when the collection has no decodable rows so the caller treats it as "no cloud data".
    /// </summary>
    public async Task<DashboardUsageSummary?> LoadSummaryAsync(CancellationToken cancellationToken = default)
    {
        ICloudSyncQuerySnapshot snap = await _gateway
            .Collection(CollectionPath)
            .Limit(_limit)
            .GetDocumentsAsync(cancellationToken)
            .ConfigureAwait(false);

        DateTimeOffset now = _clock();
        var monthStart = new DateTimeOffset(now.Year, now.Month, 1, 0, 0, 0, TimeSpan.Zero);

        double spend = 0;
        long tokens = 0;
        var sessions = new HashSet<string>(StringComparer.Ordinal);
        int decoded = 0;

        foreach (ICloudSyncDocumentSnapshot doc in snap.Documents)
        {
            if (!CloudUsageEventCodec.TryDecode(doc.Data, out CloudUsageEventRow row))
            {
                continue;
            }

            decoded++;
            tokens += row.TotalTokens;

            if (row.CostUSD is { } cost && row.RecordedAt is { } recordedAt && recordedAt >= monthStart)
            {
                spend += cost;
            }

            if (!string.IsNullOrWhiteSpace(row.SessionId))
            {
                sessions.Add(row.SessionId!);
            }
        }

        if (decoded == 0)
        {
            return null;
        }

        bool hasData = spend > 0 || tokens > 0 || sessions.Count > 0;
        return new DashboardUsageSummary(spend, tokens, sessions.Count, hasData, DashboardUsageOrigin.Cloud);
    }
}

/// <summary>Decoded Firestore usage event (wire shape from <c>UsageSyncService.encodeUsage</c>).</summary>
public sealed record CloudUsageEventRow(
    long TotalTokens,
    double? CostUSD,
    string? SessionId,
    DateTimeOffset? RecordedAt);

internal static class CloudUsageEventCodec
{
    public static bool TryDecode(CloudSyncFields data, out CloudUsageEventRow row)
    {
        bool hasTokens = TryLong(data, "totalTokens", out long tokens);
        bool hasCost = TryDouble(data, "costUSD", out double? cost);
        bool hasRecordedAt = TryTimestamp(data, "recordedAt", out DateTimeOffset recordedAt);
        TryString(data, "sessionId", out string? sessionId);

        // A usage doc must carry at least one usage signal to count toward the aggregate.
        if (!hasTokens && !hasCost && !hasRecordedAt && string.IsNullOrWhiteSpace(sessionId))
        {
            row = new CloudUsageEventRow(0, null, null, null);
            return false;
        }

        row = new CloudUsageEventRow(
            hasTokens ? tokens : 0,
            hasCost ? cost : null,
            sessionId,
            hasRecordedAt ? recordedAt : null);
        return true;
    }

    private static bool TryString(CloudSyncFields fields, string key, out string? value)
    {
        value = null;
        if (!fields.TryGet(key, out CloudSyncValue? v) || v is not CloudSyncValue.StringValue s)
        {
            return false;
        }

        value = s.Value;
        return true;
    }

    private static bool TryLong(CloudSyncFields fields, string key, out long value)
    {
        value = 0;
        if (!fields.TryGet(key, out CloudSyncValue? v))
        {
            return false;
        }

        switch (v)
        {
            case CloudSyncValue.IntegerValue i:
                value = i.Value;
                return true;
            case CloudSyncValue.DoubleValue d:
                value = (long)d.Value;
                return true;
            case CloudSyncValue.StringValue s when long.TryParse(
                s.Value,
                System.Globalization.NumberStyles.Integer,
                System.Globalization.CultureInfo.InvariantCulture,
                out long parsed):
                value = parsed;
                return true;
            default:
                return false;
        }
    }

    private static bool TryDouble(CloudSyncFields fields, string key, out double? value)
    {
        value = null;
        if (!fields.TryGet(key, out CloudSyncValue? v))
        {
            return false;
        }

        value = v switch
        {
            CloudSyncValue.DoubleValue d => d.Value,
            CloudSyncValue.IntegerValue i => i.Value,
            CloudSyncValue.StringValue s when double.TryParse(
                s.Value,
                System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture,
                out double parsed) => parsed,
            _ => (double?)null,
        };
        return value is not null;
    }

    private static bool TryTimestamp(CloudSyncFields fields, string key, out DateTimeOffset value)
    {
        value = default;
        if (!fields.TryGet(key, out CloudSyncValue? v))
        {
            return false;
        }

        if (v is CloudSyncValue.TimestampValue ts)
        {
            value = ts.Value;
            return true;
        }

        if (v is CloudSyncValue.StringValue s
            && DateTimeOffset.TryParse(
                s.Value,
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.RoundtripKind,
                out DateTimeOffset parsed))
        {
            value = parsed;
            return true;
        }

        return false;
    }
}
