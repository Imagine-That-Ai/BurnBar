using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using OpenBurnBar.CloudSync.Sync;
using Xunit;

namespace OpenBurnBar.CloudSync.Tests;

/// <summary>
/// The pure pieces of the live sync orchestration: the snapshot-diff engine
/// (Added / Modified / Removed + structural dedupe) and the exponential-with-cap
/// backoff schedule.
/// </summary>
public sealed class SyncDiffBackoffTests
{
    private static CloudSyncFields Fields(params (string Key, CloudSyncValue Value)[] pairs) =>
        CloudSyncFields.From(pairs.Select(p => new KeyValuePair<string, CloudSyncValue>(p.Key, p.Value)));

    private sealed record Snap(string DocumentId, CloudSyncFields Data) : ICloudSyncDocumentSnapshot;

    private static IReadOnlyList<ICloudSyncDocumentSnapshot> Docs(params (string Id, CloudSyncFields Data)[] docs) =>
        docs.Select(d => (ICloudSyncDocumentSnapshot)new Snap(d.Id, d.Data)).ToList();

    [Fact]
    public void Diff_from_empty_marks_everything_added()
    {
        var current = Docs(
            ("d1", Fields(("n", new CloudSyncValue.IntegerValue(1)))),
            ("d2", Fields(("n", new CloudSyncValue.IntegerValue(2)))));

        IReadOnlyList<SyncDocumentChange> changes =
            FirestoreSnapshotDiffer.Diff(new Dictionary<string, CloudSyncFields>(), current);

        Assert.Equal(2, changes.Count);
        Assert.All(changes, c => Assert.Equal(SyncChangeKind.Added, c.Kind));
        Assert.Equal(new[] { "d1", "d2" }, changes.Select(c => c.DocumentId).ToArray());
    }

    [Fact]
    public void Diff_detects_modified_added_and_removed_together()
    {
        IReadOnlyDictionary<string, CloudSyncFields> previous = FirestoreSnapshotDiffer.ToState(Docs(
            ("keep", Fields(("n", new CloudSyncValue.IntegerValue(1)))),
            ("change", Fields(("n", new CloudSyncValue.IntegerValue(2)))),
            ("gone", Fields(("n", new CloudSyncValue.IntegerValue(3))))));

        var current = Docs(
            ("keep", Fields(("n", new CloudSyncValue.IntegerValue(1)))),      // unchanged → deduped
            ("change", Fields(("n", new CloudSyncValue.IntegerValue(99)))),   // modified
            ("new", Fields(("n", new CloudSyncValue.IntegerValue(4)))));      // added

        IReadOnlyList<SyncDocumentChange> changes = FirestoreSnapshotDiffer.Diff(previous, current);

        Assert.Equal(SyncChangeKind.Modified, changes.Single(c => c.DocumentId == "change").Kind);
        Assert.Equal(SyncChangeKind.Added, changes.Single(c => c.DocumentId == "new").Kind);
        SyncDocumentChange removed = changes.Single(c => c.DocumentId == "gone");
        Assert.Equal(SyncChangeKind.Removed, removed.Kind);
        // Removed carries the LAST-KNOWN data so consumers can act on what left.
        Assert.Equal(3, ((CloudSyncValue.IntegerValue)removed.Data["n"]!).Value);
        Assert.DoesNotContain(changes, c => c.DocumentId == "keep"); // structural dedupe
    }

    [Fact]
    public void Diff_of_identical_sets_is_empty()
    {
        var docs = Docs(("d1", Fields(("a", new CloudSyncValue.StringValue("x")))));
        IReadOnlyDictionary<string, CloudSyncFields> previous = FirestoreSnapshotDiffer.ToState(docs);

        Assert.Empty(FirestoreSnapshotDiffer.Diff(previous, docs));
    }

    [Fact]
    public void Backoff_grows_exponentially_and_caps()
    {
        var policy = new SyncBackoffPolicy(baseDelayMillis: 1_000, maxDelayMillis: 10_000, multiplier: 2.0);

        Assert.Equal(1_000, policy.DelayMillisFor(1));
        Assert.Equal(2_000, policy.DelayMillisFor(2));
        Assert.Equal(4_000, policy.DelayMillisFor(3));
        Assert.Equal(8_000, policy.DelayMillisFor(4));
        Assert.Equal(10_000, policy.DelayMillisFor(5));  // capped
        Assert.Equal(10_000, policy.DelayMillisFor(50)); // still capped, no overflow
    }

    [Fact]
    public void Backoff_zero_or_one_failure_is_base_delay()
    {
        var policy = new SyncBackoffPolicy(baseDelayMillis: 2_000, maxDelayMillis: 60_000, multiplier: 2.0);
        Assert.Equal(2_000, policy.DelayMillisFor(0));
        Assert.Equal(2_000, policy.DelayMillisFor(1));
    }
}
