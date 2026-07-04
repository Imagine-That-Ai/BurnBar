using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.CloudSync.Offline;

/// <summary>
/// The offline-write-queue state machine — the Windows port of the behavior the
/// Firebase Firestore SDK gives the macOS app for free (offline persistence +
/// latency compensation + ordered flush on reconnect). Windows has no Firestore
/// SDK, so this reproduces the semantics over the portable gateway:
///
/// <list type="bullet">
///   <item><b>Latency compensation</b>: a write updates a local overlay
///         immediately, so <see cref="LocalView"/> reflects the intent before the
///         server confirms.</item>
///   <item><b>Offline buffering</b>: while <see cref="IsOnline"/> is false, writes
///         are appended to an in-order mutation queue instead of hitting the
///         gateway.</item>
///   <item><b>Ordered flush</b>: on <see cref="GoOnlineAsync"/> the queue drains
///         FIFO through the gateway.</item>
///   <item><b>Fail-closed drain</b>: if a drained write throws, draining stops and
///         the failed + remaining mutations stay queued — a write is never
///         silently dropped.</item>
/// </list>
/// It is driven in tests by the <see cref="FakeCloudSyncGateway"/>.
/// </summary>
public sealed class OfflineWriteQueue
{
    public enum MutationKind { Set, Delete }

    public sealed record Mutation(long Sequence, MutationKind Kind, string Path, CloudSyncFields? Data, bool Merge);

    private readonly object _gate = new();
    private readonly ICloudSyncGateway _gateway;
    private readonly List<Mutation> _queue = new();
    private readonly Dictionary<string, CloudSyncFields?> _overlay = new(StringComparer.Ordinal);
    private long _sequence;

    public OfflineWriteQueue(ICloudSyncGateway gateway, bool startOnline = true)
    {
        _gateway = gateway;
        IsOnline = startOnline;
    }

    public bool IsOnline { get; private set; }

    public int PendingCount
    {
        get { lock (_gate) { return _queue.Count; } }
    }

    /// <summary>Total mutations successfully flushed to the gateway over this queue's life.</summary>
    public int FlushedCount { get; private set; }

    public IReadOnlyList<Mutation> PendingMutations
    {
        get { lock (_gate) { return _queue.ToList(); } }
    }

    /// <summary>Enqueue a set/merge write (offline) or write through immediately (online).</summary>
    public Task SetAsync(string path, CloudSyncFields data, bool merge, CancellationToken cancellationToken = default)
    {
        Mutation mutation;
        lock (_gate)
        {
            ApplyToOverlay(MutationKind.Set, path, data, merge);
            mutation = new Mutation(NextSequence(), MutationKind.Set, path, data, merge);
            if (!IsOnline)
            {
                _queue.Add(mutation);
                return Task.CompletedTask;
            }
        }
        return FlushSingleAsync(mutation, cancellationToken);
    }

    /// <summary>Enqueue a delete (offline) or delete immediately (online).</summary>
    public Task DeleteAsync(string path, CancellationToken cancellationToken = default)
    {
        Mutation mutation;
        lock (_gate)
        {
            ApplyToOverlay(MutationKind.Delete, path, data: null, merge: false);
            mutation = new Mutation(NextSequence(), MutationKind.Delete, path, Data: null, Merge: false);
            if (!IsOnline)
            {
                _queue.Add(mutation);
                return Task.CompletedTask;
            }
        }
        return FlushSingleAsync(mutation, cancellationToken);
    }

    /// <summary>Transition to offline. Subsequent writes buffer until <see cref="GoOnlineAsync"/>.</summary>
    public void GoOffline()
    {
        lock (_gate) { IsOnline = false; }
    }

    /// <summary>
    /// Transition to online and drain the mutation queue FIFO. Returns the number
    /// of mutations flushed. On a gateway error the drain stops fail-closed with
    /// the failed mutation still at the head of the queue.
    /// </summary>
    public async Task<int> GoOnlineAsync(CancellationToken cancellationToken = default)
    {
        lock (_gate) { IsOnline = true; }

        int drained = 0;
        while (true)
        {
            Mutation? next;
            lock (_gate)
            {
                next = _queue.Count > 0 ? _queue[0] : null;
            }
            if (next is null) break;

            await ApplyMutationAsync(next, cancellationToken).ConfigureAwait(false);

            lock (_gate)
            {
                // Remove the head we just flushed (it is still at index 0).
                if (_queue.Count > 0 && _queue[0].Sequence == next.Sequence)
                {
                    _queue.RemoveAt(0);
                }
                FlushedCount++;
            }
            drained++;
        }
        return drained;
    }

    /// <summary>The latency-compensated local view of a document: the pending write
    /// result, a null value for a pending delete, or null when nothing is pending.</summary>
    public CloudSyncFields? LocalView(string path)
    {
        lock (_gate) { return _overlay.TryGetValue(path, out CloudSyncFields? v) ? v : null; }
    }

    /// <summary>True when a delete is the latest pending intent for <paramref name="path"/>.</summary>
    public bool HasPendingDelete(string path)
    {
        lock (_gate) { return _overlay.TryGetValue(path, out CloudSyncFields? v) && v is null; }
    }

    private async Task FlushSingleAsync(Mutation mutation, CancellationToken cancellationToken)
    {
        await ApplyMutationAsync(mutation, cancellationToken).ConfigureAwait(false);
        lock (_gate) { FlushedCount++; }
    }

    private Task ApplyMutationAsync(Mutation mutation, CancellationToken cancellationToken)
    {
        (string collectionPath, string documentId) = FirestoreDatabase.SplitDocumentPath(mutation.Path);
        ICloudSyncDocument document = _gateway.Collection(collectionPath).Document(documentId);
        return mutation.Kind switch
        {
            MutationKind.Set => document.SetDataAsync(mutation.Data!, mutation.Merge, cancellationToken),
            MutationKind.Delete => document.DeleteDocumentAsync(cancellationToken),
            _ => throw new ArgumentOutOfRangeException(nameof(mutation)),
        };
    }

    private void ApplyToOverlay(MutationKind kind, string path, CloudSyncFields? data, bool merge)
    {
        switch (kind)
        {
            case MutationKind.Delete:
                _overlay[path] = null;
                break;
            case MutationKind.Set when !merge:
                _overlay[path] = data;
                break;
            case MutationKind.Set:
                CloudSyncFields? existing = _overlay.TryGetValue(path, out CloudSyncFields? cur) ? cur : null;
                _overlay[path] = MergeOverlay(existing, data!);
                break;
        }
    }

    private static CloudSyncFields MergeOverlay(CloudSyncFields? existing, CloudSyncFields incoming)
    {
        var merged = existing is null
            ? new Dictionary<string, CloudSyncValue>(StringComparer.Ordinal)
            : new Dictionary<string, CloudSyncValue>(existing.Values, StringComparer.Ordinal);
        foreach (KeyValuePair<string, CloudSyncValue> kv in incoming.Values)
        {
            if (kv.Value is CloudSyncValue.Delete) merged.Remove(kv.Key);
            else merged[kv.Key] = kv.Value;
        }
        return new CloudSyncFields(merged);
    }

    private long NextSequence() => ++_sequence;
}
