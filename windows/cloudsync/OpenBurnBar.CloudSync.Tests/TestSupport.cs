using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.CloudSync.Tests;

/// <summary>Locates the committed parity vectors copied next to the test assembly.</summary>
internal static class Fixtures
{
    private static readonly string Root = Path.Combine(AppContext.BaseDirectory, "Fixtures");

    public static string PathOf(params string[] segments)
    {
        var all = new string[segments.Length + 1];
        all[0] = Root;
        Array.Copy(segments, 0, all, 1, segments.Length);
        return Path.Combine(all);
    }

    public static byte[] ReadBytes(params string[] segments) => File.ReadAllBytes(PathOf(segments));

    public static string ReadText(params string[] segments) => File.ReadAllText(PathOf(segments), Encoding.UTF8);

    public static IEnumerable<string> ModelVectorFiles() =>
        Directory.EnumerateFiles(Path.Combine(Root, "models"), "*.json");
}

/// <summary>
/// A recording <see cref="ICloudSyncHttpTransport"/>: it captures every request the
/// gateway/callable-client builds and returns a scripted response, so the request
/// SHAPES and response PARSING are provable without a live network.
/// </summary>
internal sealed class RecordingTransport : ICloudSyncHttpTransport
{
    private readonly Func<CloudSyncHttpRequest, CloudSyncHttpResponse> _responder;

    public RecordingTransport(Func<CloudSyncHttpRequest, CloudSyncHttpResponse> responder) => _responder = responder;

    public List<CloudSyncHttpRequest> Requests { get; } = new();

    public CloudSyncHttpRequest LastRequest => Requests[^1];

    public Task<CloudSyncHttpResponse> SendAsync(CloudSyncHttpRequest request, CancellationToken cancellationToken = default)
    {
        Requests.Add(request);
        return Task.FromResult(_responder(request));
    }

    public static CloudSyncHttpResponse Json(int status, string body) =>
        new(status, Encoding.UTF8.GetBytes(body), new Dictionary<string, string>(StringComparer.Ordinal));

    public static CloudSyncHttpResponse Empty(int status) =>
        new(status, Array.Empty<byte>(), new Dictionary<string, string>(StringComparer.Ordinal));

    public string LastRequestBodyText() => Encoding.UTF8.GetString(LastRequest.Body ?? Array.Empty<byte>());
}

/// <summary>
/// Wraps an inner gateway and throws on the write whose 1-based index exceeds
/// <c>failAfter</c> — lets the offline-queue test prove partial FIFO progress plus
/// fail-closed retention (earlier writes applied, the failing + remaining ones
/// stay queued).
/// </summary>
internal sealed class FailAfterNWritesGateway : ICloudSyncGateway
{
    private readonly ICloudSyncGateway _inner;
    private readonly int _failAfter;
    private int _writeCount;

    public FailAfterNWritesGateway(ICloudSyncGateway inner, int failAfter)
    {
        _inner = inner;
        _failAfter = failAfter;
    }

    public int WriteAttempts => _writeCount;

    public ICloudSyncCollection Collection(string collectionPath) =>
        new WrapCollection(this, _inner.Collection(collectionPath));

    public ICloudSyncWriteBatch Batch() => _inner.Batch();

    public Task<bool> RunTransactionAsync(Func<ICloudSyncTransaction, Task<bool>> updateBlock, CancellationToken cancellationToken = default) =>
        _inner.RunTransactionAsync(updateBlock, cancellationToken);

    private void GateWrite()
    {
        _writeCount++;
        if (_writeCount > _failAfter)
        {
            throw new InvalidOperationException($"synthetic write failure on attempt {_writeCount}");
        }
    }

    private sealed class WrapCollection : ICloudSyncCollection
    {
        private readonly FailAfterNWritesGateway _owner;
        private readonly ICloudSyncCollection _inner;

        public WrapCollection(FailAfterNWritesGateway owner, ICloudSyncCollection inner)
        {
            _owner = owner;
            _inner = inner;
        }

        public ICloudSyncDocument Document(string documentPath) => new WrapDocument(_owner, _inner.Document(documentPath));
        public ICloudSyncQuery WhereGreaterThan(string field, CloudSyncValue value) => _inner.WhereGreaterThan(field, value);
        public ICloudSyncQuery WhereEqualTo(string field, CloudSyncValue value) => _inner.WhereEqualTo(field, value);
        public ICloudSyncQuery OrderBy(string field, bool descending) => _inner.OrderBy(field, descending);
        public ICloudSyncQuery Limit(int limit) => _inner.Limit(limit);
        public Task<ICloudSyncQuerySnapshot> GetDocumentsAsync(CancellationToken cancellationToken = default) => _inner.GetDocumentsAsync(cancellationToken);
    }

    private sealed class WrapDocument : ICloudSyncDocument
    {
        private readonly FailAfterNWritesGateway _owner;
        private readonly ICloudSyncDocument _inner;

        public WrapDocument(FailAfterNWritesGateway owner, ICloudSyncDocument inner)
        {
            _owner = owner;
            _inner = inner;
        }

        public string Path => _inner.Path;
        public ICloudSyncCollection Collection(string collectionPath) => new WrapCollection(_owner, _inner.Collection(collectionPath));
        public Task<CloudSyncFields?> GetDataAsync(CancellationToken cancellationToken = default) => _inner.GetDataAsync(cancellationToken);

        public Task SetDataAsync(CloudSyncFields data, bool merge, CancellationToken cancellationToken = default)
        {
            _owner.GateWrite();
            return _inner.SetDataAsync(data, merge, cancellationToken);
        }

        public Task DeleteDocumentAsync(CancellationToken cancellationToken = default)
        {
            _owner.GateWrite();
            return _inner.DeleteDocumentAsync(cancellationToken);
        }
    }
}
