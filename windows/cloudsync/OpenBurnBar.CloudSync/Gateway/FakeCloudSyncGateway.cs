using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Firestore;

namespace OpenBurnBar.CloudSync.Gateway;

/// <summary>
/// In-memory fake Firestore backend for deterministic CloudSync testing — a
/// faithful C# port of AgentLens/Services/CloudSync/CloudSyncFirestoreFakeGateway.swift.
///
/// <list type="bullet">
///   <item>Stores documents as <c>path -&gt; CloudSyncFields</c>.</item>
///   <item>Supports batch writes, collection queries, ordering, limits, and simple filtering.</item>
///   <item>Resolves <see cref="CloudSyncValue.ServerTimestamp"/> to the injected clock
///         at write time and applies <see cref="CloudSyncValue.Delete"/> to merged writes.</item>
///   <item>Thread-safe via a single lock, mirroring the Swift lock-backed state.</item>
/// </list>
/// It also drives the offline-queue + snapshot-listener state machines
/// (<see cref="OpenBurnBar.CloudSync.Offline"/>) by exposing change notifications
/// through <see cref="DocumentChanged"/>.
/// </summary>
public sealed class FakeCloudSyncGateway : ICloudSyncGateway
{
    private readonly object _gate = new();
    private readonly Dictionary<string, CloudSyncFields> _store = new(StringComparer.Ordinal);
    private readonly Func<DateTimeOffset> _clock;

    /// <summary>Raised after any committed document write/delete (path). Drives listeners.</summary>
    public event Action<string>? DocumentChanged;

    public FakeCloudSyncGateway(Func<DateTimeOffset>? clock = null)
    {
        // Swift substitutes Date() (real now). Tests want determinism, so the
        // default clock is a fixed instant; inject a moving clock to vary it.
        _clock = clock ?? (static () => new DateTimeOffset(2026, 7, 3, 10, 0, 0, TimeSpan.Zero));
    }

    /// <summary>When set, the next write/read/commit/transaction throws this and clears nothing.</summary>
    public Exception? NextError { get; set; }

    /// <summary>Runs once before the next transaction, then clears (parity with beforeNextTransaction).</summary>
    public Action? BeforeNextTransaction { get; set; }

    /// <summary>Number of batch commits executed.</summary>
    public int BatchCommitCount { get; private set; }

    public ICloudSyncCollection Collection(string collectionPath) =>
        new FakeCollection(this, collectionPath);

    public ICloudSyncWriteBatch Batch() => new FakeWriteBatch(this);

    public async Task<bool> RunTransactionAsync(
        Func<ICloudSyncTransaction, Task<bool>> updateBlock,
        CancellationToken cancellationToken = default)
    {
        ThrowIfNextError();
        Action? hook;
        lock (_gate)
        {
            hook = BeforeNextTransaction;
            BeforeNextTransaction = null;
        }
        hook?.Invoke();

        var transaction = new FakeTransaction(this);
        bool shouldCommit = await updateBlock(transaction).ConfigureAwait(false);
        if (shouldCommit)
        {
            transaction.Commit();
        }
        return shouldCommit;
    }

    // ── Direct test accessors (parity with the Swift fake's inspection API) ──
    public CloudSyncFields? DocumentData(string path)
    {
        lock (_gate) { return _store.TryGetValue(path, out CloudSyncFields? f) ? f : null; }
    }

    public IReadOnlyDictionary<string, CloudSyncFields> DocumentsUnder(string collectionPath)
    {
        string prefix = collectionPath + "/";
        lock (_gate)
        {
            var result = new Dictionary<string, CloudSyncFields>(StringComparer.Ordinal);
            foreach (KeyValuePair<string, CloudSyncFields> kv in _store)
            {
                if (!kv.Key.StartsWith(prefix, StringComparison.Ordinal)) continue;
                string remainder = kv.Key[prefix.Length..];
                if (!remainder.Contains('/')) result[kv.Key] = kv.Value; // direct children only
            }
            return result;
        }
    }

    /// <summary>Write a document directly (bypassing the gateway) to simulate a remote change.</summary>
    public void SetDocumentData(CloudSyncFields data, string path)
    {
        lock (_gate) { _store[path] = Normalize(data); }
        DocumentChanged?.Invoke(path);
    }

    // ── Internal store operations ───────────────────────────────────────────
    internal void StoreSet(string path, CloudSyncFields data, bool merge)
    {
        lock (_gate)
        {
            if (merge)
            {
                MergeLocked(path, data);
            }
            else
            {
                _store[path] = Normalize(data);
            }
        }
        DocumentChanged?.Invoke(path);
    }

    internal void StoreDelete(string path)
    {
        lock (_gate) { _store.Remove(path); }
        DocumentChanged?.Invoke(path);
    }

    internal CloudSyncFields? StoreGet(string path)
    {
        lock (_gate) { return _store.TryGetValue(path, out CloudSyncFields? f) ? f : null; }
    }

    internal void ApplyWrites(IReadOnlyList<(string Path, CloudSyncFields Data, bool Merge)> writes)
    {
        var touched = new List<string>();
        lock (_gate)
        {
            foreach ((string path, CloudSyncFields data, bool merge) in writes)
            {
                if (merge) MergeLocked(path, data);
                else _store[path] = Normalize(data);
                touched.Add(path);
            }
        }
        foreach (string path in touched) DocumentChanged?.Invoke(path);
    }

    internal void IncrementBatchCommitCount()
    {
        lock (_gate) { BatchCommitCount++; }
    }

    // Events may only be raised by their declaring type; nested gateways route through this.
    internal void RaiseDocumentChanged(string path) => DocumentChanged?.Invoke(path);

    internal IReadOnlyList<(string Path, CloudSyncFields Data)> QueryDocuments(CloudSyncQuerySpec spec)
    {
        List<(string Path, CloudSyncFields Data)> docs;
        lock (_gate)
        {
            string prefix = spec.CollectionPath + "/";
            docs = _store
                .Where(kv => kv.Key.StartsWith(prefix, StringComparison.Ordinal)
                             && !kv.Key[prefix.Length..].Contains('/'))
                .Select(kv => (kv.Key, kv.Value))
                .ToList();
        }

        foreach (CloudSyncFieldFilter filter in spec.Filters)
        {
            docs = docs.Where(d => FakeQueryEngine.Matches(d.Data, filter)).ToList();
        }

        if (spec.Order is { } order)
        {
            docs.Sort((a, b) =>
            {
                int cmp = FakeQueryEngine.Compare(a.Data[order.Field], b.Data[order.Field]);
                return order.Descending ? -cmp : cmp;
            });
        }

        if (spec.Limit is { } limit)
        {
            docs = docs.Take(limit).ToList();
        }

        return docs;
    }

    internal void ThrowIfNextError()
    {
        if (NextError is { } error) throw error;
    }

    // Merge under lock: apply Delete sentinels by removing keys, else overwrite.
    private void MergeLocked(string path, CloudSyncFields data)
    {
        CloudSyncFields normalized = Normalize(data);
        var merged = _store.TryGetValue(path, out CloudSyncFields? existing)
            ? new Dictionary<string, CloudSyncValue>(existing.Values, StringComparer.Ordinal)
            : new Dictionary<string, CloudSyncValue>(StringComparer.Ordinal);
        foreach (KeyValuePair<string, CloudSyncValue> kv in normalized.Values)
        {
            if (kv.Value is CloudSyncValue.Delete) merged.Remove(kv.Key);
            else merged[kv.Key] = kv.Value;
        }
        _store[path] = new CloudSyncFields(merged);
    }

    // Resolve ServerTimestamp sentinels to the clock instant, recursively.
    private CloudSyncFields Normalize(CloudSyncFields data)
    {
        var result = new Dictionary<string, CloudSyncValue>(StringComparer.Ordinal);
        foreach (KeyValuePair<string, CloudSyncValue> kv in data.Values)
        {
            result[kv.Key] = NormalizeValue(kv.Value);
        }
        return new CloudSyncFields(result);
    }

    private CloudSyncValue NormalizeValue(CloudSyncValue value) => value switch
    {
        CloudSyncValue.ServerTimestamp => new CloudSyncValue.TimestampValue(_clock()),
        CloudSyncValue.MapValue m => new CloudSyncValue.MapValue(
            m.Fields.ToDictionary(k => k.Key, v => NormalizeValue(v.Value), StringComparer.Ordinal)),
        CloudSyncValue.ArrayValue a => new CloudSyncValue.ArrayValue(a.Items.Select(NormalizeValue).ToList()),
        _ => value,
    };

    // ── Nested gateway implementations ──────────────────────────────────────
    private sealed class FakeCollection : ICloudSyncCollection
    {
        private readonly FakeCloudSyncGateway _owner;
        private readonly string _path;

        public FakeCollection(FakeCloudSyncGateway owner, string path)
        {
            _owner = owner;
            _path = path;
        }

        public ICloudSyncDocument Document(string documentPath) =>
            new FakeDocument(_owner, $"{_path}/{documentPath}");

        public ICloudSyncQuery WhereGreaterThan(string field, CloudSyncValue value) =>
            new FakeQuery(_owner, CloudSyncQuerySpec.ForCollection(_path)
                .With(new CloudSyncFieldFilter(field, CloudSyncQueryOperator.GreaterThan, value)));

        public ICloudSyncQuery WhereEqualTo(string field, CloudSyncValue value) =>
            new FakeQuery(_owner, CloudSyncQuerySpec.ForCollection(_path)
                .With(new CloudSyncFieldFilter(field, CloudSyncQueryOperator.EqualTo, value)));

        public ICloudSyncQuery OrderBy(string field, bool descending) =>
            new FakeQuery(_owner, CloudSyncQuerySpec.ForCollection(_path).With(new CloudSyncOrder(field, descending)));

        public ICloudSyncQuery Limit(int limit) =>
            new FakeQuery(_owner, CloudSyncQuerySpec.ForCollection(_path).WithLimit(limit));

        public Task<ICloudSyncQuerySnapshot> GetDocumentsAsync(CancellationToken cancellationToken = default)
        {
            _owner.ThrowIfNextError();
            return Task.FromResult(FakeQuery.Snapshot(_owner, CloudSyncQuerySpec.ForCollection(_path)));
        }
    }

    private sealed class FakeDocument : ICloudSyncDocument
    {
        private readonly FakeCloudSyncGateway _owner;

        public FakeDocument(FakeCloudSyncGateway owner, string path)
        {
            _owner = owner;
            Path = path;
        }

        public string Path { get; }

        public ICloudSyncCollection Collection(string collectionPath) =>
            new FakeCollection(_owner, $"{Path}/{collectionPath}");

        public Task<CloudSyncFields?> GetDataAsync(CancellationToken cancellationToken = default)
        {
            _owner.ThrowIfNextError();
            return Task.FromResult(_owner.StoreGet(Path));
        }

        public Task SetDataAsync(CloudSyncFields data, bool merge, CancellationToken cancellationToken = default)
        {
            _owner.ThrowIfNextError();
            _owner.StoreSet(Path, data, merge);
            return Task.CompletedTask;
        }

        public Task DeleteDocumentAsync(CancellationToken cancellationToken = default)
        {
            _owner.ThrowIfNextError();
            _owner.StoreDelete(Path);
            return Task.CompletedTask;
        }
    }

    private sealed class FakeQuery : ICloudSyncQuery
    {
        private readonly FakeCloudSyncGateway _owner;
        private readonly CloudSyncQuerySpec _spec;

        public FakeQuery(FakeCloudSyncGateway owner, CloudSyncQuerySpec spec)
        {
            _owner = owner;
            _spec = spec;
        }

        public ICloudSyncQuery WhereGreaterThan(string field, CloudSyncValue value) =>
            new FakeQuery(_owner, _spec.With(new CloudSyncFieldFilter(field, CloudSyncQueryOperator.GreaterThan, value)));

        public ICloudSyncQuery WhereEqualTo(string field, CloudSyncValue value) =>
            new FakeQuery(_owner, _spec.With(new CloudSyncFieldFilter(field, CloudSyncQueryOperator.EqualTo, value)));

        public ICloudSyncQuery OrderBy(string field, bool descending) =>
            new FakeQuery(_owner, _spec.With(new CloudSyncOrder(field, descending)));

        public ICloudSyncQuery Limit(int limit) => new FakeQuery(_owner, _spec.WithLimit(limit));

        public Task<ICloudSyncQuerySnapshot> GetDocumentsAsync(CancellationToken cancellationToken = default)
        {
            _owner.ThrowIfNextError();
            return Task.FromResult(Snapshot(_owner, _spec));
        }

        internal static ICloudSyncQuerySnapshot Snapshot(FakeCloudSyncGateway owner, CloudSyncQuerySpec spec)
        {
            var snapshots = owner.QueryDocuments(spec)
                .Select(d => (ICloudSyncDocumentSnapshot)new FakeDocumentSnapshot(FirestoreDatabase.LeafId(d.Path), d.Data))
                .ToList();
            return new FakeQuerySnapshot(snapshots);
        }
    }

    private sealed class FakeQuerySnapshot : ICloudSyncQuerySnapshot
    {
        public FakeQuerySnapshot(IReadOnlyList<ICloudSyncDocumentSnapshot> documents) => Documents = documents;
        public IReadOnlyList<ICloudSyncDocumentSnapshot> Documents { get; }
    }

    private sealed class FakeDocumentSnapshot : ICloudSyncDocumentSnapshot
    {
        public FakeDocumentSnapshot(string documentId, CloudSyncFields data)
        {
            DocumentId = documentId;
            Data = data;
        }

        public string DocumentId { get; }
        public CloudSyncFields Data { get; }
    }

    private sealed class FakeWriteBatch : ICloudSyncWriteBatch
    {
        private readonly FakeCloudSyncGateway _owner;
        private readonly List<Action> _operations = new();
        private readonly List<string> _touched = new();

        public FakeWriteBatch(FakeCloudSyncGateway owner) => _owner = owner;

        public void SetData(CloudSyncFields data, ICloudSyncDocument document, bool merge)
        {
            if (document is not FakeDocument fake)
            {
                throw CloudSyncGatewayException.DocumentImplementationMismatch(nameof(FakeDocument));
            }
            _operations.Add(() => _owner.StoreSetNoNotify(fake.Path, data, merge));
            _touched.Add(fake.Path);
        }

        public void DeleteDocument(ICloudSyncDocument document)
        {
            if (document is not FakeDocument fake)
            {
                throw CloudSyncGatewayException.DocumentImplementationMismatch(nameof(FakeDocument));
            }
            _operations.Add(() => _owner.StoreDeleteNoNotify(fake.Path));
            _touched.Add(fake.Path);
        }

        public Task CommitAsync(CancellationToken cancellationToken = default)
        {
            _owner.ThrowIfNextError();
            foreach (Action op in _operations) op();
            _operations.Clear();
            _owner.IncrementBatchCommitCount();
            foreach (string path in _touched) _owner.RaiseDocumentChanged(path);
            _touched.Clear();
            return Task.CompletedTask;
        }
    }

    private sealed class FakeTransaction : ICloudSyncTransaction
    {
        private readonly FakeCloudSyncGateway _owner;
        private readonly List<(string Path, CloudSyncFields Data, bool Merge)> _pending = new();

        public FakeTransaction(FakeCloudSyncGateway owner) => _owner = owner;

        public Task<CloudSyncFields?> GetDataAsync(ICloudSyncDocument document, CancellationToken cancellationToken = default)
        {
            if (document is not FakeDocument fake)
            {
                throw CloudSyncGatewayException.DocumentImplementationMismatch(nameof(FakeDocument));
            }
            return Task.FromResult(_owner.StoreGet(fake.Path));
        }

        public void SetData(CloudSyncFields data, ICloudSyncDocument document, bool merge)
        {
            if (document is not FakeDocument fake)
            {
                throw CloudSyncGatewayException.DocumentImplementationMismatch(nameof(FakeDocument));
            }
            _pending.Add((fake.Path, data, merge));
        }

        internal void Commit() => _owner.ApplyWrites(_pending);
    }

    // Batch/transaction writes notify once, after the whole set is applied.
    private void StoreSetNoNotify(string path, CloudSyncFields data, bool merge)
    {
        lock (_gate)
        {
            if (merge) MergeLocked(path, data);
            else _store[path] = Normalize(data);
        }
    }

    private void StoreDeleteNoNotify(string path)
    {
        lock (_gate) { _store.Remove(path); }
    }
}

internal static class FakeQueryEngine
{
    public static bool Matches(CloudSyncFields data, CloudSyncFieldFilter filter)
    {
        CloudSyncValue? fieldValue = data[filter.Field];
        if (fieldValue is null) return false;
        int cmp = Compare(fieldValue, filter.Value);
        return filter.Operator switch
        {
            CloudSyncQueryOperator.GreaterThan => cmp > 0,
            CloudSyncQueryOperator.EqualTo => cmp == 0,
            _ => false,
        };
    }

    // Port of the Swift FakeQueryEngine.compare — Timestamp / String / Int / Double.
    public static int Compare(CloudSyncValue? lhs, CloudSyncValue? rhs)
    {
        if (lhs is null || rhs is null) return 0;
        return (lhs, rhs) switch
        {
            (CloudSyncValue.TimestampValue l, CloudSyncValue.TimestampValue r) => l.Value.CompareTo(r.Value),
            (CloudSyncValue.StringValue l, CloudSyncValue.StringValue r) => string.Compare(l.Value, r.Value, StringComparison.Ordinal),
            (CloudSyncValue.IntegerValue l, CloudSyncValue.IntegerValue r) => l.Value.CompareTo(r.Value),
            (CloudSyncValue.DoubleValue l, CloudSyncValue.DoubleValue r) => l.Value.CompareTo(r.Value),
            // Cross int/double numeric comparison (Firestore treats them as one number domain).
            (CloudSyncValue.IntegerValue l, CloudSyncValue.DoubleValue r) => ((double)l.Value).CompareTo(r.Value),
            (CloudSyncValue.DoubleValue l, CloudSyncValue.IntegerValue r) => l.Value.CompareTo(r.Value),
            _ => 0,
        };
    }
}
