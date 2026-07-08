using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Read-only consumer of Mac-uploaded quota snapshots at
/// <c>users/{uid}/quota_snapshots/{providerID}_{accountID}_{sourceID}</c>.
/// Quota is computed on desktop by Swift <c>ProviderQuotaService</c>; Windows does not
/// read the local SQLCipher <c>provider_quota_snapshots</c> table (it stays empty without the engine).
/// </summary>
public sealed class CloudSyncQuotaSnapshotStore
{
    private readonly ICloudSyncGateway _gateway;
    private readonly string _uid;

    public CloudSyncQuotaSnapshotStore(ICloudSyncGateway gateway, string uid)
    {
        _gateway = gateway;
        _uid = uid;
    }

    public string CollectionPath => $"users/{_uid}/quota_snapshots";

    public async Task<IReadOnlyList<CloudQuotaSnapshotRow>> LoadSnapshotsAsync(
        CancellationToken cancellationToken = default)
    {
        ICloudSyncQuerySnapshot snap = await _gateway
            .Collection(CollectionPath)
            .Limit(500)
            .GetDocumentsAsync(cancellationToken)
            .ConfigureAwait(false);

        var rows = new List<CloudQuotaSnapshotRow>();
        foreach (ICloudSyncDocumentSnapshot doc in snap.Documents)
        {
            CloudQuotaSnapshotRow? row = CloudQuotaSnapshotCodec.TryDecode(doc.DocumentId, doc.Data);
            if (row is not null)
            {
                rows.Add(row);
            }
        }

        rows.Sort((a, b) => b.FetchedAt.CompareTo(a.FetchedAt));
        return rows;
    }
}

/// <summary>Decoded Firestore quota snapshot (wire shape from <c>QuotaSnapshotSyncService</c>).</summary>
public sealed record CloudQuotaSnapshotRow(
    string DocumentId,
    string ProviderToken,
    string? ProviderId,
    string? AccountId,
    string? AccountLabel,
    DateTimeOffset FetchedAt,
    IReadOnlyList<CloudQuotaBucketRow> Buckets);

public sealed record CloudQuotaBucketRow(
    string Name,
    double? Used,
    double? Limit,
    double? Remaining,
    string? Window,
    DateTimeOffset? ResetsAt,
    string? Label);

internal static class CloudQuotaSnapshotCodec
{
    public static CloudQuotaSnapshotRow? TryDecode(string documentId, CloudSyncFields data)
    {
        if (!TryString(data, "provider", out string? providerToken) || string.IsNullOrWhiteSpace(providerToken))
        {
            return null;
        }

        if (!TryTimestamp(data, "fetchedAt", out DateTimeOffset fetchedAt))
        {
            return null;
        }

        TryString(data, "providerID", out string? providerId);
        TryString(data, "accountID", out string? accountId);
        TryString(data, "accountLabel", out string? accountLabel);

        var buckets = new List<CloudQuotaBucketRow>();
        if (data.TryGet("buckets", out CloudSyncValue? bucketsValue)
            && bucketsValue is CloudSyncValue.ArrayValue array)
        {
            foreach (CloudSyncValue item in array.Items)
            {
                if (item is CloudSyncValue.MapValue map)
                {
                    CloudQuotaBucketRow? bucket = TryDecodeBucket(map);
                    if (bucket is not null)
                    {
                        buckets.Add(bucket);
                    }
                }
            }
        }

        if (buckets.Count == 0)
        {
            return null;
        }

        return new CloudQuotaSnapshotRow(
            documentId,
            providerToken.Trim(),
            providerId,
            accountId,
            accountLabel,
            fetchedAt,
            buckets);
    }

    private static CloudQuotaBucketRow? TryDecodeBucket(CloudSyncValue.MapValue map)
    {
        if (!TryString(map.Fields, "name", out string? name) || string.IsNullOrWhiteSpace(name))
        {
            return null;
        }

        TryDouble(map.Fields, "used", out double? used);
        TryDouble(map.Fields, "limit", out double? limit);
        TryDouble(map.Fields, "remaining", out double? remaining);
        TryString(map.Fields, "window", out string? window);
        TryTimestamp(map.Fields, "resetsAt", out DateTimeOffset resetsAt);

        string? label = null;
        if (map.Fields.TryGetValue("meta", out CloudSyncValue? metaValue)
            && metaValue is CloudSyncValue.MapValue metaMap
            && TryString(metaMap.Fields, "label", out string? metaLabel))
        {
            label = metaLabel;
        }

        return new CloudQuotaBucketRow(
            name.Trim(),
            used,
            limit,
            remaining,
            window,
            resetsAt == default ? null : resetsAt,
            label);
    }

    private static bool TryString(IReadOnlyDictionary<string, CloudSyncValue> fields, string key, out string? value)
    {
        value = null;
        if (!fields.TryGetValue(key, out CloudSyncValue? v) || v is not CloudSyncValue.StringValue s)
        {
            return false;
        }

        value = s.Value;
        return true;
    }

    private static bool TryString(CloudSyncFields fields, string key, out string? value) =>
        TryString(fields.Values, key, out value);

    private static bool TryDouble(IReadOnlyDictionary<string, CloudSyncValue> fields, string key, out double? value)
    {
        value = null;
        if (!fields.TryGetValue(key, out CloudSyncValue? v))
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
            _ => null,
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

    private static bool TryTimestamp(IReadOnlyDictionary<string, CloudSyncValue> fields, string key, out DateTimeOffset value)
    {
        value = default;
        if (!fields.TryGetValue(key, out CloudSyncValue? v))
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