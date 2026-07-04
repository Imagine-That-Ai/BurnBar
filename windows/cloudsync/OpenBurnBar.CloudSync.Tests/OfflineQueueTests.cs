using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using OpenBurnBar.CloudSync.Offline;
using Xunit;

namespace OpenBurnBar.CloudSync.Tests;

/// <summary>
/// The offline-write-queue state machine: latency compensation, offline
/// buffering, ordered FIFO drain on reconnect, and fail-closed drain (a failing
/// mutation and everything after it stay queued). Driven by the FakeGateway.
/// </summary>
public sealed class OfflineQueueTests
{
    private static CloudSyncFields Fields(params (string Key, CloudSyncValue Value)[] pairs) =>
        CloudSyncFields.From(pairs.Select(p => new KeyValuePair<string, CloudSyncValue>(p.Key, p.Value)));

    [Fact]
    public async Task Online_write_goes_straight_to_the_gateway()
    {
        var gateway = new FakeCloudSyncGateway();
        var queue = new OfflineWriteQueue(gateway, startOnline: true);

        await queue.SetAsync("c/d", Fields(("n", new CloudSyncValue.IntegerValue(1))), merge: false);

        Assert.Equal(0, queue.PendingCount);
        Assert.NotNull(gateway.DocumentData("c/d"));
    }

    [Fact]
    public async Task Offline_write_buffers_and_latency_compensates_local_view()
    {
        var gateway = new FakeCloudSyncGateway();
        var queue = new OfflineWriteQueue(gateway, startOnline: true);
        queue.GoOffline();

        await queue.SetAsync("c/d", Fields(("n", new CloudSyncValue.IntegerValue(1))), merge: false);

        Assert.Equal(1, queue.PendingCount);
        Assert.Null(gateway.DocumentData("c/d")); // not yet on the server
        // ...but the local (latency-compensated) view already reflects the write.
        CloudSyncFields? local = queue.LocalView("c/d");
        Assert.NotNull(local);
        Assert.Equal(1, ((CloudSyncValue.IntegerValue)local!["n"]!).Value);
    }

    [Fact]
    public async Task Go_online_drains_the_queue_in_fifo_order()
    {
        var gateway = new FakeCloudSyncGateway();
        var queue = new OfflineWriteQueue(gateway, startOnline: false);

        await queue.SetAsync("c/a", Fields(("n", new CloudSyncValue.IntegerValue(1))), merge: false);
        await queue.SetAsync("c/b", Fields(("n", new CloudSyncValue.IntegerValue(2))), merge: false);
        Assert.Equal(2, queue.PendingCount);

        int drained = await queue.GoOnlineAsync();

        Assert.Equal(2, drained);
        Assert.Equal(0, queue.PendingCount);
        Assert.Equal(2, queue.FlushedCount);
        Assert.Equal(1, ((CloudSyncValue.IntegerValue)gateway.DocumentData("c/a")!["n"]!).Value);
        Assert.Equal(2, ((CloudSyncValue.IntegerValue)gateway.DocumentData("c/b")!["n"]!).Value);
    }

    [Fact]
    public async Task Offline_merge_folds_into_the_local_overlay()
    {
        var gateway = new FakeCloudSyncGateway();
        var queue = new OfflineWriteQueue(gateway, startOnline: false);

        await queue.SetAsync("c/d", Fields(("a", new CloudSyncValue.IntegerValue(1))), merge: false);
        await queue.SetAsync("c/d", Fields(("b", new CloudSyncValue.IntegerValue(2))), merge: true);
        await queue.SetAsync("c/d", Fields(("a", CloudSyncValue.Delete.Instance)), merge: true);

        CloudSyncFields local = queue.LocalView("c/d")!;
        Assert.Null(local["a"]);
        Assert.Equal(2, ((CloudSyncValue.IntegerValue)local["b"]!).Value);
    }

    [Fact]
    public async Task Offline_delete_leaves_a_local_tombstone()
    {
        var gateway = new FakeCloudSyncGateway();
        var queue = new OfflineWriteQueue(gateway, startOnline: false);

        await queue.SetAsync("c/d", Fields(("n", new CloudSyncValue.IntegerValue(1))), merge: false);
        await queue.DeleteAsync("c/d");

        Assert.True(queue.HasPendingDelete("c/d"));
        Assert.Null(queue.LocalView("c/d"));
    }

    [Fact]
    public async Task Drain_is_fail_closed_and_retains_the_failing_mutation()
    {
        var inner = new FakeCloudSyncGateway();
        // First queued write applies; the second throws.
        var gateway = new FailAfterNWritesGateway(inner, failAfter: 1);
        var queue = new OfflineWriteQueue(gateway, startOnline: false);

        await queue.SetAsync("c/a", Fields(("n", new CloudSyncValue.IntegerValue(1))), merge: false);
        await queue.SetAsync("c/b", Fields(("n", new CloudSyncValue.IntegerValue(2))), merge: false);
        await queue.SetAsync("c/c", Fields(("n", new CloudSyncValue.IntegerValue(3))), merge: false);

        await Assert.ThrowsAsync<System.InvalidOperationException>(() => queue.GoOnlineAsync());

        // c/a flushed; c/b (failed) + c/c (after) are retained — nothing dropped.
        Assert.NotNull(inner.DocumentData("c/a"));
        Assert.Null(inner.DocumentData("c/b"));
        Assert.Equal(2, queue.PendingCount);
        Assert.Equal("c/b", queue.PendingMutations[0].Path);
        Assert.Equal(1, queue.FlushedCount);
    }

    [Fact]
    public async Task Retrying_after_a_failure_drains_the_remainder()
    {
        var inner = new FakeCloudSyncGateway();
        var gateway = new FailAfterNWritesGateway(inner, failAfter: 1);
        var queue = new OfflineWriteQueue(gateway, startOnline: false);
        await queue.SetAsync("c/a", Fields(("n", new CloudSyncValue.IntegerValue(1))), merge: false);
        await queue.SetAsync("c/b", Fields(("n", new CloudSyncValue.IntegerValue(2))), merge: false);
        await Assert.ThrowsAsync<System.InvalidOperationException>(() => queue.GoOnlineAsync());

        // A healthy gateway on retry drains the retained mutation.
        var healthy = new OfflineWriteQueue(inner, startOnline: false);
        await healthy.SetAsync("c/b", Fields(("n", new CloudSyncValue.IntegerValue(2))), merge: false);
        int drained = await healthy.GoOnlineAsync();

        Assert.Equal(1, drained);
        Assert.Equal(2, ((CloudSyncValue.IntegerValue)inner.DocumentData("c/b")!["n"]!).Value);
    }
}
