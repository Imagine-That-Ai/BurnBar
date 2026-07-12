using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using OpenBurnBar.CloudSync.Offline;
using Xunit;

namespace OpenBurnBar.CloudSync.Tests;

/// <summary>
/// The snapshot-listener state machine (Firestore addSnapshotListener parity):
/// initial delivery, change-driven re-delivery, dedupe on unchanged data,
/// tombstone-on-delete, unsubscribe, and multi-listener fan-out. Driven by the
/// FakeGateway change stream.
/// </summary>
public sealed class ListenerSemanticsTests
{
    private static CloudSyncFields Fields(params (string Key, CloudSyncValue Value)[] pairs) =>
        CloudSyncFields.From(pairs.Select(p => new KeyValuePair<string, CloudSyncValue>(p.Key, p.Value)));

    [Fact]
    public async Task Initial_snapshot_is_delivered_on_registration()
    {
        var gateway = new FakeCloudSyncGateway();
        await gateway.Collection("c").Document("d").SetDataAsync(Fields(("n", new CloudSyncValue.IntegerValue(1))), merge: false);
        using var registry = new SnapshotListenerRegistry(gateway);

        var received = new List<SnapshotListenerRegistry.DocumentSnapshot>();
        registry.AddDocumentListener("c/d", received.Add);

        Assert.Single(received);
        Assert.True(received[0].FromInitial);
        Assert.True(received[0].Exists);
        Assert.Equal(1, ((CloudSyncValue.IntegerValue)received[0].Data!["n"]!).Value);
    }

    [Fact]
    public void Initial_snapshot_for_a_missing_document_reports_not_exists()
    {
        var gateway = new FakeCloudSyncGateway();
        using var registry = new SnapshotListenerRegistry(gateway);

        SnapshotListenerRegistry.DocumentSnapshot? snapshot = null;
        registry.AddDocumentListener("c/missing", s => snapshot = s);

        Assert.NotNull(snapshot);
        Assert.True(snapshot!.FromInitial);
        Assert.False(snapshot.Exists);
    }

    [Fact]
    public async Task Change_delivers_a_new_snapshot()
    {
        var gateway = new FakeCloudSyncGateway();
        using var registry = new SnapshotListenerRegistry(gateway);
        var received = new List<SnapshotListenerRegistry.DocumentSnapshot>();
        registry.AddDocumentListener("c/d", received.Add);

        await gateway.Collection("c").Document("d").SetDataAsync(Fields(("n", new CloudSyncValue.IntegerValue(5))), merge: false);

        Assert.Equal(2, received.Count); // initial (not-exists) + change
        Assert.False(received[1].FromInitial);
        Assert.Equal(5, ((CloudSyncValue.IntegerValue)received[1].Data!["n"]!).Value);
    }

    [Fact]
    public async Task Identical_write_is_deduped()
    {
        var gateway = new FakeCloudSyncGateway();
        await gateway.Collection("c").Document("d").SetDataAsync(Fields(("n", new CloudSyncValue.IntegerValue(1))), merge: false);
        using var registry = new SnapshotListenerRegistry(gateway);
        var received = new List<SnapshotListenerRegistry.DocumentSnapshot>();
        registry.AddDocumentListener("c/d", received.Add);

        // Re-write the SAME data — no data change, so no extra delivery.
        await gateway.Collection("c").Document("d").SetDataAsync(Fields(("n", new CloudSyncValue.IntegerValue(1))), merge: false);

        Assert.Single(received); // only the initial delivery
    }

    [Fact]
    public async Task Delete_delivers_a_tombstone_snapshot()
    {
        var gateway = new FakeCloudSyncGateway();
        await gateway.Collection("c").Document("d").SetDataAsync(Fields(("n", new CloudSyncValue.IntegerValue(1))), merge: false);
        using var registry = new SnapshotListenerRegistry(gateway);
        var received = new List<SnapshotListenerRegistry.DocumentSnapshot>();
        registry.AddDocumentListener("c/d", received.Add);

        await gateway.Collection("c").Document("d").DeleteDocumentAsync();

        Assert.Equal(2, received.Count);
        Assert.False(received[1].Exists);
    }

    [Fact]
    public async Task Unsubscribe_stops_further_delivery()
    {
        var gateway = new FakeCloudSyncGateway();
        using var registry = new SnapshotListenerRegistry(gateway);
        var received = new List<SnapshotListenerRegistry.DocumentSnapshot>();
        IDisposable token = registry.AddDocumentListener("c/d", received.Add);
        Assert.Equal(1, registry.ActiveListenerCount);

        token.Dispose();
        Assert.Equal(0, registry.ActiveListenerCount);

        await gateway.Collection("c").Document("d").SetDataAsync(Fields(("n", new CloudSyncValue.IntegerValue(9))), merge: false);
        Assert.Single(received); // only the initial delivery before unsubscribe
    }

    [Fact]
    public async Task Multiple_listeners_on_the_same_path_all_receive_changes()
    {
        var gateway = new FakeCloudSyncGateway();
        using var registry = new SnapshotListenerRegistry(gateway);
        int a = 0, b = 0;
        registry.AddDocumentListener("c/d", _ => a++);
        registry.AddDocumentListener("c/d", _ => b++);

        await gateway.Collection("c").Document("d").SetDataAsync(Fields(("n", new CloudSyncValue.IntegerValue(1))), merge: false);

        Assert.Equal(2, a); // initial + change
        Assert.Equal(2, b);
    }
}
