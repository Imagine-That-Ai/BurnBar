using OpenBurnBar.App.Presentation.Memories;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.App.CloudSync;

/// <summary>
/// Read-only memory review feed over Firestore <c>memory_facts</c> (G4: no approve/reject on Windows).
/// </summary>
public sealed class CloudSyncMemoryStore
{
    private readonly ICloudSyncGateway _gateway;
    private readonly string _uid;
    private readonly byte[] _vaultKey;

    public CloudSyncMemoryStore(ICloudSyncGateway gateway, string uid, byte[] vaultKey)
    {
        _gateway = gateway;
        _uid = uid;
        _vaultKey = vaultKey;
    }

    public string CollectionPath => $"users/{_uid}/memory_facts";

    public async Task<MemoryPage> LoadPageAsync(MemoryPageRequest request, CancellationToken cancellationToken = default)
    {
        ICloudSyncQuerySnapshot snap = await _gateway
            .Collection(CollectionPath)
            .Limit(500)
            .GetDocumentsAsync(cancellationToken)
            .ConfigureAwait(false);

        var decoded = new List<Memory>();
        foreach (ICloudSyncDocumentSnapshot doc in snap.Documents)
        {
            if (!doc.Data.Values.TryGetValue("reviewStatus", out CloudSyncValue? rs)
                || rs is not CloudSyncValue.StringValue statusStr)
            {
                continue;
            }

            MemoryReviewStatus reviewStatus = MemoryCloudFactCodec.ParseReviewStatus(statusStr.Value);
            if (!request.IncludeQuarantined && reviewStatus == MemoryReviewStatus.Quarantined)
            {
                continue;
            }

            try
            {
                MemoryCloudFactPayload payload = MemoryCloudFactCodec.OpenPayload(doc.Data, _uid, doc.DocumentId, _vaultKey);
                DateTimeOffset created = ReadTimestamp(doc.Data, "replicatedAt") ?? payload.UpdatedAt;
                decoded.Add(MemoryCloudFactCodec.DecodeAuthority(payload, reviewStatus, created));
            }
            catch
            {
                // Skip corrupt rows — inbox stays usable (lenient like Swift VM merges).
            }
        }

        decoded.Sort((a, b) => b.UpdatedAt.CompareTo(a.UpdatedAt));
        int total = decoded.Count;
        int skip = Math.Max(0, (request.Page - 1) * request.PageSize);
        var pageItems = decoded.Skip(skip).Take(request.PageSize).ToList();
        return new MemoryPage(pageItems, request.Page, request.PageSize, total);
    }

    public async Task<string?> OpenBodyAsync(string memoryId, CancellationToken cancellationToken = default)
    {
        string docId = MemoryCloudFactCodec.MemoryFactDocId(memoryId, _vaultKey);
        CloudSyncFields? data = await _gateway
            .Collection(CollectionPath)
            .Document(docId)
            .GetDataAsync(cancellationToken)
            .ConfigureAwait(false);
        if (data is null)
        {
            return null;
        }

        MemoryCloudFactPayload payload = MemoryCloudFactCodec.OpenPayload(data, _uid, docId, _vaultKey);
        return payload.Text;
    }

    public Task<bool> SetStatusAsync(string memoryId, MemoryReviewStatus status, CancellationToken cancellationToken = default) =>
        throw new MemoryReviewMacOnlyException();

    private static DateTimeOffset? ReadTimestamp(CloudSyncFields fields, string key) =>
        fields.Values.TryGetValue(key, out CloudSyncValue? v) && v is CloudSyncValue.TimestampValue ts
            ? ts.Value
            : null;
}