using System;
using System.Collections.Generic;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;

namespace OpenBurnBar.CloudSync.Sync;

/// <summary>The kind of change a document underwent between two poll snapshots.</summary>
public enum SyncChangeKind
{
    /// <summary>The document is present now and was absent in the last-known state.</summary>
    Added,

    /// <summary>The document is present in both but its fields changed structurally.</summary>
    Modified,

    /// <summary>The document was present in the last-known state and is absent now.</summary>
    Removed,
}

/// <summary>
/// A single per-document change. For <see cref="SyncChangeKind.Removed"/>,
/// <see cref="Data"/> is the last-known field set (so consumers can act on what left);
/// otherwise it is the current field set.
/// </summary>
public sealed record SyncDocumentChange(string DocumentId, SyncChangeKind Kind, CloudSyncFields Data);

/// <summary>
/// The pure snapshot-diff engine for the live poll loop — the collection-level
/// analogue of <c>SnapshotListenerRegistry</c>'s per-document dedupe. It compares a
/// last-known <c>id → fields</c> map against a freshly polled document set using the
/// SAME structural equality contract (<c>CloudSyncValue.MapValue.Equals</c>) and
/// emits Added / Modified / Removed changes. No sockets, no clock — trivially testable.
/// </summary>
public static class FirestoreSnapshotDiffer
{
    /// <summary>
    /// Diff <paramref name="current"/> (freshly polled, in query order) against the
    /// <paramref name="previous"/> last-known state. Added/Modified changes are
    /// emitted in query order; Removed changes follow, in the previous-state order.
    /// </summary>
    public static IReadOnlyList<SyncDocumentChange> Diff(
        IReadOnlyDictionary<string, CloudSyncFields> previous,
        IReadOnlyList<ICloudSyncDocumentSnapshot> current)
    {
        if (previous is null) throw new ArgumentNullException(nameof(previous));
        if (current is null) throw new ArgumentNullException(nameof(current));

        var changes = new List<SyncDocumentChange>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (ICloudSyncDocumentSnapshot doc in current)
        {
            seen.Add(doc.DocumentId);
            if (!previous.TryGetValue(doc.DocumentId, out CloudSyncFields? prev))
            {
                changes.Add(new SyncDocumentChange(doc.DocumentId, SyncChangeKind.Added, doc.Data));
            }
            else if (!FieldsEqual(prev, doc.Data))
            {
                changes.Add(new SyncDocumentChange(doc.DocumentId, SyncChangeKind.Modified, doc.Data));
            }
        }

        foreach (KeyValuePair<string, CloudSyncFields> kv in previous)
        {
            if (!seen.Contains(kv.Key))
            {
                changes.Add(new SyncDocumentChange(kv.Key, SyncChangeKind.Removed, kv.Value));
            }
        }

        return changes;
    }

    /// <summary>Project a polled document set into an <c>id → fields</c> last-known state map.</summary>
    public static IReadOnlyDictionary<string, CloudSyncFields> ToState(IReadOnlyList<ICloudSyncDocumentSnapshot> documents)
    {
        if (documents is null) throw new ArgumentNullException(nameof(documents));
        var map = new Dictionary<string, CloudSyncFields>(StringComparer.Ordinal);
        foreach (ICloudSyncDocumentSnapshot doc in documents)
        {
            map[doc.DocumentId] = doc.Data;
        }
        return map;
    }

    /// <summary>
    /// Structural equality on two document field sets (the same contract
    /// <c>SnapshotListenerRegistry.FieldsEqual</c> uses for its dedupe).
    /// </summary>
    public static bool FieldsEqual(CloudSyncFields? a, CloudSyncFields? b)
    {
        if (a is null && b is null) return true;
        if (a is null || b is null) return false;
        return new CloudSyncValue.MapValue(a.Values).Equals(new CloudSyncValue.MapValue(b.Values));
    }
}
