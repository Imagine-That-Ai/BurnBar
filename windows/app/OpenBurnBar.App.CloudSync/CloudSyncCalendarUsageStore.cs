using OpenBurnBar.App.Presentation.Calendar;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Read-only consumer of Mac-uploaded token-usage events at
/// <c>users/{uid}/usage/{deviceId}_{usageId}</c> (parity: <c>UsageSyncService.swift</c>),
/// decoded into per-event <see cref="CalendarUsageRow"/>s for the Calendar surface —
/// the row-level twin of <see cref="CloudSyncUsageSummaryStore"/> and the live cloud
/// fallback the Calendar uses when the local SQLCipher <c>token_usage</c> table has
/// no rows in the grid window but a signed-in session exists.
///
/// The private <c>sealedProjectName</c> field is never read (same stance as the
/// summary store): cloud rows carry an empty project name, so the Project Focus
/// card honestly groups them under "Unattributed" rather than fabricating names.
/// </summary>
public sealed class CloudSyncCalendarUsageStore
{
    private readonly ICloudSyncGateway _gateway;
    private readonly string _uid;
    private readonly int _limit;

    public CloudSyncCalendarUsageStore(
        ICloudSyncGateway gateway,
        string uid,
        int limit = 2000)
    {
        _gateway = gateway;
        _uid = uid;
        _limit = limit;
    }

    public string CollectionPath => $"users/{_uid}/usage";

    /// <summary>
    /// Decodes usage events whose start instant falls in <paramref name="startUtc"/>
    /// (inclusive) … <paramref name="endUtcExclusive"/>. Returns <c>null</c> when the
    /// collection has no decodable rows so the caller treats it as "no cloud data".
    /// Rows without a decodable start timestamp are skipped — an event that cannot
    /// be day-bucketed honestly must not leak into the surface.
    /// </summary>
    public async Task<CalendarUsageData?> LoadRowsAsync(
        DateTimeOffset startUtc,
        DateTimeOffset endUtcExclusive,
        CancellationToken cancellationToken = default)
    {
        ICloudSyncQuerySnapshot snap = await _gateway
            .Collection(CollectionPath)
            .Limit(_limit)
            .GetDocumentsAsync(cancellationToken)
            .ConfigureAwait(false);

        var rows = new List<CalendarUsageRow>();
        int decoded = 0;
        foreach (ICloudSyncDocumentSnapshot doc in snap.Documents)
        {
            if (!CloudCalendarUsageEventCodec.TryDecode(doc.Data, out CalendarUsageRow row))
            {
                continue;
            }

            decoded++;
            if (row.StartUtc < startUtc || row.StartUtc >= endUtcExclusive)
            {
                continue;
            }

            rows.Add(row);
        }

        if (decoded == 0)
        {
            return null;
        }

        return new CalendarUsageData(
            rows,
            rows.Count > 0 ? DashboardUsageOrigin.Cloud : DashboardUsageOrigin.Empty);
    }
}

/// <summary>
/// Defensive decoder for the <c>users/{uid}/usage</c> wire shape
/// (<c>UsageSyncService.encodeUsage</c>), mirroring <c>CloudUsageEventCodec</c>'s
/// tolerance (stringified numbers, missing optional fields). An event counts as
/// decodable when it carries at least one usage signal; <c>costUSD</c> is
/// preferred with the encoder's <c>cost</c> key as fallback, and
/// <c>startTime</c> is preferred with <c>recordedAt</c> as fallback.
/// </summary>
internal static class CloudCalendarUsageEventCodec
{
    public static bool TryDecode(CloudSyncFields data, out CalendarUsageRow row)
    {
        TryString(data, "id", out string? id);
        TryString(data, "provider", out string? provider);
        TryString(data, "sessionId", out string? sessionId);
        TryString(data, "model", out string? model);
        bool hasTokens = TryLong(data, "totalTokens", out long totalTokens);
        bool hasCost = TryDouble(data, "costUSD", out double? costUsd)
            || TryDouble(data, "cost", out costUsd);
        bool hasStart = TryTimestamp(data, "startTime", out DateTimeOffset startUtc)
            || TryTimestamp(data, "recordedAt", out startUtc);
        TryLong(data, "inputTokens", out long inputTokens);
        TryLong(data, "outputTokens", out long outputTokens);
        TryLong(data, "cacheCreationTokens", out long cacheCreationTokens);
        TryLong(data, "cacheReadTokens", out long cacheReadTokens);
        TryLong(data, "reasoningTokens", out long reasoningTokens);

        // A usage doc must carry at least one usage signal to count as a row.
        if (!hasTokens && !hasCost && !hasStart && string.IsNullOrWhiteSpace(sessionId))
        {
            row = new CalendarUsageRow("", "", "", "", "", 0, 0, 0, 0, 0, 0, 0, DateTimeOffset.MinValue);
            return false;
        }

        row = new CalendarUsageRow(
            id ?? string.Empty,
            provider ?? string.Empty,
            sessionId ?? string.Empty,
            ProjectName: string.Empty, // sealedProjectName is never read (see store comment).
            model ?? string.Empty,
            inputTokens,
            outputTokens,
            cacheCreationTokens,
            cacheReadTokens,
            reasoningTokens,
            hasTokens ? totalTokens : 0,
            hasCost ? costUsd ?? 0 : 0,
            hasStart ? startUtc : DateTimeOffset.MinValue);
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
