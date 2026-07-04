using System;
using System.Collections.Generic;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.CloudSync.Offline;

/// <summary>
/// The snapshot-listener state machine — the Windows port of Firestore's
/// <c>addSnapshotListener</c>. Windows has no Firestore SDK, so listener delivery
/// is reproduced over the <see cref="FakeCloudSyncGateway"/>'s change stream:
///
/// <list type="bullet">
///   <item><b>Initial delivery</b>: registering a listener immediately delivers the
///         current snapshot (existing or "does not exist"), with
///         <see cref="DocumentSnapshot.FromInitial"/> = true.</item>
///   <item><b>Change delivery</b>: a subsequent write to the watched path delivers a
///         new snapshot — but only when the data actually changed (dedupe on
///         structural equality), matching a stable state machine.</item>
///   <item><b>Unsubscribe</b>: disposing the returned token stops delivery and
///         decrements <see cref="ActiveListenerCount"/>.</item>
/// </list>
/// </summary>
public sealed class SnapshotListenerRegistry : IDisposable
{
    private readonly object _gate = new();
    private readonly FakeCloudSyncGateway _gateway;
    private readonly Dictionary<long, Registration> _registrations = new();
    private long _nextId;
    private bool _disposed;

    public SnapshotListenerRegistry(FakeCloudSyncGateway gateway)
    {
        _gateway = gateway;
        _gateway.DocumentChanged += OnDocumentChanged;
    }

    public int ActiveListenerCount
    {
        get { lock (_gate) { return _registrations.Count; } }
    }

    /// <summary>A single document snapshot delivered to a listener.</summary>
    public sealed record DocumentSnapshot(string Path, CloudSyncFields? Data, bool FromInitial)
    {
        public bool Exists => Data is not null;
    }

    /// <summary>
    /// Register a document listener. Delivers the current snapshot synchronously,
    /// then delivers again on each data-changing write. Dispose the token to stop.
    /// </summary>
    public IDisposable AddDocumentListener(string path, Action<DocumentSnapshot> onSnapshot)
    {
        if (onSnapshot is null) throw new ArgumentNullException(nameof(onSnapshot));

        long id;
        CloudSyncFields? current = _gateway.DocumentData(path);
        lock (_gate)
        {
            id = _nextId++;
            _registrations[id] = new Registration(path, onSnapshot, current, DeliveryCount: 0);
        }

        var initial = new DocumentSnapshot(path, current, FromInitial: true);
        Deliver(id, initial);
        return new Subscription(this, id);
    }

    private void OnDocumentChanged(string path)
    {
        List<long> matching;
        lock (_gate)
        {
            matching = new List<long>();
            foreach (KeyValuePair<long, Registration> kv in _registrations)
            {
                if (string.Equals(kv.Value.Path, path, StringComparison.Ordinal)) matching.Add(kv.Key);
            }
        }

        foreach (long id in matching)
        {
            CloudSyncFields? current = _gateway.DocumentData(path);
            bool changed;
            lock (_gate)
            {
                if (!_registrations.TryGetValue(id, out Registration? reg)) continue;
                changed = !FieldsEqual(reg.LastDelivered, current);
            }
            if (changed)
            {
                Deliver(id, new DocumentSnapshot(path, current, FromInitial: false));
            }
        }
    }

    private void Deliver(long id, DocumentSnapshot snapshot)
    {
        Action<DocumentSnapshot>? callback = null;
        lock (_gate)
        {
            if (_registrations.TryGetValue(id, out Registration? reg))
            {
                _registrations[id] = reg with { LastDelivered = snapshot.Data, DeliveryCount = reg.DeliveryCount + 1 };
                callback = reg.Callback;
            }
        }
        callback?.Invoke(snapshot);
    }

    private void Remove(long id)
    {
        lock (_gate) { _registrations.Remove(id); }
    }

    /// <summary>Structural equality on two document field sets (null = does-not-exist).</summary>
    internal static bool FieldsEqual(CloudSyncFields? a, CloudSyncFields? b)
    {
        if (a is null && b is null) return true;
        if (a is null || b is null) return false;
        return new CloudSyncValue.MapValue(a.Values).Equals(new CloudSyncValue.MapValue(b.Values));
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _gateway.DocumentChanged -= OnDocumentChanged;
        lock (_gate) { _registrations.Clear(); }
    }

    private sealed record Registration(
        string Path,
        Action<DocumentSnapshot> Callback,
        CloudSyncFields? LastDelivered,
        int DeliveryCount);

    private sealed class Subscription : IDisposable
    {
        private readonly SnapshotListenerRegistry _owner;
        private readonly long _id;
        private bool _disposed;

        public Subscription(SnapshotListenerRegistry owner, long id)
        {
            _owner = owner;
            _id = id;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _owner.Remove(_id);
        }
    }
}
