using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Json;

namespace OpenBurnBar.CloudSync.Gateway;

/// <summary>
/// Live <see cref="ICloudSyncGateway"/> over the Firestore REST/RPC v1 wire — the
/// Windows replacement for the macOS Firebase Firestore SDK (which is unavailable
/// off-Apple). It speaks:
/// <list type="bullet">
///   <item><c>documents.get</c> (HTTP GET) for reads,</item>
///   <item><c>documents.patch</c> (HTTP PATCH + updateMask) for simple set/merge,</item>
///   <item><c>documents:commit</c> for transformed writes, batches, and transactions,</item>
///   <item><c>documents:runQuery</c> for filtered/ordered/limited collection reads,</item>
///   <item><c>documents.delete</c> (HTTP DELETE) for single deletes.</item>
/// </list>
/// Every request carries <c>Authorization: Bearer &lt;idToken&gt;</c> and, when App
/// Check is required, <c>X-Firebase-AppCheck</c>. If App Check is required but no
/// token is available the request is refused <b>fail-closed</b> — never sent
/// unauthenticated. The live authenticated round-trip is dev-host/CI-deferred; the
/// request SHAPES and response PARSING are proven here via a fake transport.
/// </summary>
public sealed class FirestoreRestGateway : ICloudSyncGateway
{
    private readonly ICloudSyncHttpTransport _transport;
    private readonly ICloudSyncCredentialsProvider _credentials;
    private readonly FirestoreDatabase _database;
    private readonly bool _requireAppCheck;

    public FirestoreRestGateway(
        ICloudSyncHttpTransport transport,
        ICloudSyncCredentialsProvider credentials,
        FirestoreDatabase database,
        bool requireAppCheck = true)
    {
        _transport = transport;
        _credentials = credentials;
        _database = database;
        _requireAppCheck = requireAppCheck;
    }

    public ICloudSyncCollection Collection(string collectionPath) => new RestCollection(this, collectionPath);

    public ICloudSyncWriteBatch Batch() => new RestWriteBatch(this);

    public async Task<bool> RunTransactionAsync(
        Func<ICloudSyncTransaction, Task<bool>> updateBlock,
        CancellationToken cancellationToken = default)
    {
        string transactionId = await BeginTransactionAsync(cancellationToken).ConfigureAwait(false);
        var transaction = new RestTransaction(this, transactionId);

        bool shouldCommit;
        try
        {
            shouldCommit = await updateBlock(transaction).ConfigureAwait(false);
        }
        catch
        {
            await RollbackAsync(transactionId, cancellationToken).ConfigureAwait(false);
            throw;
        }

        if (shouldCommit)
        {
            JsonObject body = FirestoreWriteEncoder.BuildCommitBody(transaction.Writes, transactionId);
            await CommitAsync(body, cancellationToken).ConfigureAwait(false);
        }
        else
        {
            await RollbackAsync(transactionId, cancellationToken).ConfigureAwait(false);
        }
        return shouldCommit;
    }

    // ── Internal RPCs ───────────────────────────────────────────────────────
    internal async Task<CloudSyncFields?> GetDocumentAsync(string path, string? transactionId, CancellationToken cancellationToken)
    {
        string url = _database.DocumentUrl(path);
        if (transactionId is { Length: > 0 })
        {
            url += $"?transaction={Uri.EscapeDataString(transactionId)}";
        }
        CloudSyncHttpResponse response = await SendAsync(HttpVerb.Get, url, body: null, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode == 404) return null;
        ThrowIfFailed(response);
        return FirestoreDocument.FromRestJson(response.Body).Fields;
    }

    internal async Task PatchDocumentAsync(string path, CloudSyncFields data, bool merge, CancellationToken cancellationToken)
    {
        // Transforms (serverTimestamp / delete) cannot ride a PATCH body — route
        // them through :commit where updateTransforms + updateMask express them.
        if (data.Values.Values.Any(v => v.IsTransform))
        {
            JsonObject write = FirestoreWriteEncoder.BuildSetWrite(_database.DocumentName(path), data, merge);
            await CommitAsync(FirestoreWriteEncoder.BuildCommitBody(new[] { write }), cancellationToken).ConfigureAwait(false);
            return;
        }

        string url = _database.DocumentUrl(path);
        if (merge)
        {
            string mask = string.Join("&", data.Values.Keys
                .OrderBy(k => k, StringComparer.Ordinal)
                .Select(k => $"updateMask.fieldPaths={Uri.EscapeDataString(k)}"));
            if (mask.Length > 0) url += "?" + mask;
        }

        byte[] body = FirestoreDocument.FieldsRestJsonBytes(data);
        CloudSyncHttpResponse response = await SendAsync(HttpVerb.Patch, url, body, cancellationToken).ConfigureAwait(false);
        ThrowIfFailed(response);
    }

    internal async Task DeleteDocumentAsync(string path, CancellationToken cancellationToken)
    {
        string url = _database.DocumentUrl(path);
        CloudSyncHttpResponse response = await SendAsync(HttpVerb.Delete, url, body: null, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode == 404) return; // already gone — idempotent
        ThrowIfFailed(response);
    }

    internal async Task CommitAsync(JsonObject commitBody, CancellationToken cancellationToken)
    {
        byte[] body = CanonicalJson.SerializeToUtf8Bytes(commitBody);
        CloudSyncHttpResponse response = await SendAsync(HttpVerb.Post, _database.CommitUrl, body, cancellationToken).ConfigureAwait(false);
        ThrowIfFailed(response);
    }

    internal async Task<IReadOnlyList<ICloudSyncDocumentSnapshot>> RunQueryAsync(CloudSyncQuerySpec spec, CancellationToken cancellationToken)
    {
        string url = _database.RunQueryUrl(FirestoreWriteEncoder.QueryParentPath(spec.CollectionPath));
        byte[] body = CanonicalJson.SerializeToUtf8Bytes(FirestoreWriteEncoder.BuildRunQueryBody(spec));
        CloudSyncHttpResponse response = await SendAsync(HttpVerb.Post, url, body, cancellationToken).ConfigureAwait(false);
        ThrowIfFailed(response);
        return ParseRunQueryResults(response.Body);
    }

    internal static IReadOnlyList<ICloudSyncDocumentSnapshot> ParseRunQueryResults(byte[] json)
    {
        using var document = JsonDocument.Parse(json);
        var results = new List<ICloudSyncDocumentSnapshot>();
        if (document.RootElement.ValueKind != JsonValueKind.Array) return results;
        foreach (JsonElement element in document.RootElement.EnumerateArray())
        {
            if (!element.TryGetProperty("document", out JsonElement docElement)
                || docElement.ValueKind != JsonValueKind.Object)
            {
                continue; // readTime-only / empty rows carry no document
            }
            FirestoreDocument doc = FirestoreDocument.FromRestJson(docElement);
            results.Add(new RestDocumentSnapshot(doc.DocumentId, doc.Fields));
        }
        return results;
    }

    private async Task<string> BeginTransactionAsync(CancellationToken cancellationToken)
    {
        string url = $"{_database.Host}/v1/{_database.DocumentsRoot}:beginTransaction";
        byte[] body = CanonicalJson.SerializeToUtf8Bytes(new JsonObject());
        CloudSyncHttpResponse response = await SendAsync(HttpVerb.Post, url, body, cancellationToken).ConfigureAwait(false);
        ThrowIfFailed(response);
        using var document = JsonDocument.Parse(response.Body);
        return document.RootElement.TryGetProperty("transaction", out JsonElement txn) && txn.ValueKind == JsonValueKind.String
            ? txn.GetString()!
            : throw new CloudSyncGatewayException(CloudSyncGatewayErrorKind.Unknown, "beginTransaction returned no token.");
    }

    private async Task RollbackAsync(string transactionId, CancellationToken cancellationToken)
    {
        string url = $"{_database.Host}/v1/{_database.DocumentsRoot}:rollback";
        byte[] body = CanonicalJson.SerializeToUtf8Bytes(new JsonObject { ["transaction"] = transactionId });
        CloudSyncHttpResponse response = await SendAsync(HttpVerb.Post, url, body, cancellationToken).ConfigureAwait(false);
        ThrowIfFailed(response);
    }

    private async Task<CloudSyncHttpResponse> SendAsync(HttpVerb method, string url, byte[]? body, CancellationToken cancellationToken)
    {
        IReadOnlyDictionary<string, string> headers = await BuildAuthHeadersAsync(cancellationToken).ConfigureAwait(false);
        var request = new CloudSyncHttpRequest(method, url, body, headers);
        return await _transport.SendAsync(request, cancellationToken).ConfigureAwait(false);
    }

    private async Task<IReadOnlyDictionary<string, string>> BuildAuthHeadersAsync(CancellationToken cancellationToken)
    {
        CloudSyncCredentials credentials = await _credentials.GetCredentialsAsync(cancellationToken).ConfigureAwait(false);
        var headers = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["Authorization"] = $"Bearer {credentials.IdToken}",
        };
        if (_requireAppCheck && string.IsNullOrEmpty(credentials.AppCheckToken))
        {
            // Fail-closed: an App-Check-required deployment never emits an
            // un-attested Firestore request.
            throw new CloudSyncGatewayException(
                CloudSyncGatewayErrorKind.PermissionDenied,
                "App Check token required but unavailable; refusing to send an un-attested Firestore request.");
        }
        if (credentials.AppCheckToken is { Length: > 0 } appCheck)
        {
            headers["X-Firebase-AppCheck"] = appCheck;
        }
        return headers;
    }

    private static void ThrowIfFailed(CloudSyncHttpResponse response)
    {
        if (!response.IsSuccess)
        {
            throw CloudSyncGatewayException.FromHttpStatus(response.StatusCode, System.Text.Encoding.UTF8.GetString(response.Body));
        }
    }

    // ── Nested gateway surface ──────────────────────────────────────────────
    private sealed class RestCollection : ICloudSyncCollection
    {
        private readonly FirestoreRestGateway _owner;
        private readonly string _path;

        public RestCollection(FirestoreRestGateway owner, string path)
        {
            _owner = owner;
            _path = path;
        }

        public ICloudSyncDocument Document(string documentPath) => new RestDocument(_owner, $"{_path}/{documentPath}");

        public ICloudSyncQuery WhereGreaterThan(string field, CloudSyncValue value) =>
            new RestQuery(_owner, CloudSyncQuerySpec.ForCollection(_path)
                .With(new CloudSyncFieldFilter(field, CloudSyncQueryOperator.GreaterThan, value)));

        public ICloudSyncQuery WhereEqualTo(string field, CloudSyncValue value) =>
            new RestQuery(_owner, CloudSyncQuerySpec.ForCollection(_path)
                .With(new CloudSyncFieldFilter(field, CloudSyncQueryOperator.EqualTo, value)));

        public ICloudSyncQuery OrderBy(string field, bool descending) =>
            new RestQuery(_owner, CloudSyncQuerySpec.ForCollection(_path).With(new CloudSyncOrder(field, descending)));

        public ICloudSyncQuery Limit(int limit) =>
            new RestQuery(_owner, CloudSyncQuerySpec.ForCollection(_path).WithLimit(limit));

        public async Task<ICloudSyncQuerySnapshot> GetDocumentsAsync(CancellationToken cancellationToken = default) =>
            new RestQuerySnapshot(await _owner.RunQueryAsync(CloudSyncQuerySpec.ForCollection(_path), cancellationToken).ConfigureAwait(false));
    }

    private sealed class RestDocument : ICloudSyncDocument
    {
        private readonly FirestoreRestGateway _owner;

        public RestDocument(FirestoreRestGateway owner, string path)
        {
            _owner = owner;
            Path = path;
        }

        public string Path { get; }

        public ICloudSyncCollection Collection(string collectionPath) => new RestCollection(_owner, $"{Path}/{collectionPath}");

        public Task<CloudSyncFields?> GetDataAsync(CancellationToken cancellationToken = default) =>
            _owner.GetDocumentAsync(Path, transactionId: null, cancellationToken);

        public Task SetDataAsync(CloudSyncFields data, bool merge, CancellationToken cancellationToken = default) =>
            _owner.PatchDocumentAsync(Path, data, merge, cancellationToken);

        public Task DeleteDocumentAsync(CancellationToken cancellationToken = default) =>
            _owner.DeleteDocumentAsync(Path, cancellationToken);
    }

    private sealed class RestQuery : ICloudSyncQuery
    {
        private readonly FirestoreRestGateway _owner;
        private readonly CloudSyncQuerySpec _spec;

        public RestQuery(FirestoreRestGateway owner, CloudSyncQuerySpec spec)
        {
            _owner = owner;
            _spec = spec;
        }

        public ICloudSyncQuery WhereGreaterThan(string field, CloudSyncValue value) =>
            new RestQuery(_owner, _spec.With(new CloudSyncFieldFilter(field, CloudSyncQueryOperator.GreaterThan, value)));

        public ICloudSyncQuery WhereEqualTo(string field, CloudSyncValue value) =>
            new RestQuery(_owner, _spec.With(new CloudSyncFieldFilter(field, CloudSyncQueryOperator.EqualTo, value)));

        public ICloudSyncQuery OrderBy(string field, bool descending) =>
            new RestQuery(_owner, _spec.With(new CloudSyncOrder(field, descending)));

        public ICloudSyncQuery Limit(int limit) => new RestQuery(_owner, _spec.WithLimit(limit));

        public async Task<ICloudSyncQuerySnapshot> GetDocumentsAsync(CancellationToken cancellationToken = default) =>
            new RestQuerySnapshot(await _owner.RunQueryAsync(_spec, cancellationToken).ConfigureAwait(false));
    }

    private sealed class RestQuerySnapshot : ICloudSyncQuerySnapshot
    {
        public RestQuerySnapshot(IReadOnlyList<ICloudSyncDocumentSnapshot> documents) => Documents = documents;
        public IReadOnlyList<ICloudSyncDocumentSnapshot> Documents { get; }
    }

    private sealed class RestDocumentSnapshot : ICloudSyncDocumentSnapshot
    {
        public RestDocumentSnapshot(string documentId, CloudSyncFields data)
        {
            DocumentId = documentId;
            Data = data;
        }

        public string DocumentId { get; }
        public CloudSyncFields Data { get; }
    }

    private sealed class RestWriteBatch : ICloudSyncWriteBatch
    {
        private readonly FirestoreRestGateway _owner;
        private readonly List<JsonObject> _writes = new();

        public RestWriteBatch(FirestoreRestGateway owner) => _owner = owner;

        public void SetData(CloudSyncFields data, ICloudSyncDocument document, bool merge)
        {
            string name = _owner._database.DocumentName(Require(document).Path);
            _writes.Add(FirestoreWriteEncoder.BuildSetWrite(name, data, merge));
        }

        public void DeleteDocument(ICloudSyncDocument document)
        {
            string name = _owner._database.DocumentName(Require(document).Path);
            _writes.Add(FirestoreWriteEncoder.BuildDeleteWrite(name));
        }

        public Task CommitAsync(CancellationToken cancellationToken = default) =>
            _owner.CommitAsync(FirestoreWriteEncoder.BuildCommitBody(_writes), cancellationToken);

        private static RestDocument Require(ICloudSyncDocument document) =>
            document as RestDocument ?? throw CloudSyncGatewayException.DocumentImplementationMismatch(nameof(RestDocument));
    }

    private sealed class RestTransaction : ICloudSyncTransaction
    {
        private readonly FirestoreRestGateway _owner;
        private readonly string _transactionId;
        private readonly List<JsonObject> _writes = new();

        public RestTransaction(FirestoreRestGateway owner, string transactionId)
        {
            _owner = owner;
            _transactionId = transactionId;
        }

        public IReadOnlyList<JsonObject> Writes => _writes;

        public Task<CloudSyncFields?> GetDataAsync(ICloudSyncDocument document, CancellationToken cancellationToken = default) =>
            _owner.GetDocumentAsync(Require(document).Path, _transactionId, cancellationToken);

        public void SetData(CloudSyncFields data, ICloudSyncDocument document, bool merge)
        {
            string name = _owner._database.DocumentName(Require(document).Path);
            _writes.Add(FirestoreWriteEncoder.BuildSetWrite(name, data, merge));
        }

        private static RestDocument Require(ICloudSyncDocument document) =>
            document as RestDocument ?? throw CloudSyncGatewayException.DocumentImplementationMismatch(nameof(RestDocument));
    }
}
