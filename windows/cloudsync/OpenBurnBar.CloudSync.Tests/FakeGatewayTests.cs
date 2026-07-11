using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using Xunit;

namespace OpenBurnBar.CloudSync.Tests;

/// <summary>
/// Semantics parity for the in-memory gateway port
/// (CloudSyncFirestoreFakeGateway.swift): CRUD, merge, delete, batch, transaction,
/// query filter/order/limit, serverTimestamp normalization, and injected-error
/// behavior.
/// </summary>
public sealed class FakeGatewayTests
{
    private static CloudSyncFields Fields(params (string Key, CloudSyncValue Value)[] pairs) =>
        CloudSyncFields.From(pairs.Select(p => new KeyValuePair<string, CloudSyncValue>(p.Key, p.Value)));

    [Fact]
    public async Task Set_then_get_round_trips()
    {
        var gateway = new FakeCloudSyncGateway();
        ICloudSyncDocument doc = gateway.Collection("users/u1/usage").Document("e1");

        await doc.SetDataAsync(Fields(("provider", new CloudSyncValue.StringValue("anthropic"))), merge: false);

        CloudSyncFields? read = await doc.GetDataAsync();
        Assert.NotNull(read);
        Assert.Equal("anthropic", ((CloudSyncValue.StringValue)read!["provider"]!).Value);
    }

    [Fact]
    public async Task Merge_preserves_existing_fields_and_delete_removes_one()
    {
        var gateway = new FakeCloudSyncGateway();
        ICloudSyncDocument doc = gateway.Collection("c").Document("d");

        await doc.SetDataAsync(Fields(
            ("a", new CloudSyncValue.IntegerValue(1)),
            ("b", new CloudSyncValue.IntegerValue(2))), merge: false);
        await doc.SetDataAsync(Fields(("c", new CloudSyncValue.IntegerValue(3))), merge: true);
        await doc.SetDataAsync(Fields(("a", CloudSyncValue.Delete.Instance)), merge: true);

        CloudSyncFields read = (await doc.GetDataAsync())!;
        Assert.Null(read["a"]);                                        // deleted
        Assert.Equal(2, ((CloudSyncValue.IntegerValue)read["b"]!).Value); // preserved across merge
        Assert.Equal(3, ((CloudSyncValue.IntegerValue)read["c"]!).Value); // merged in
    }

    [Fact]
    public async Task ServerTimestamp_sentinel_normalizes_to_the_injected_clock()
    {
        var clock = new DateTimeOffset(2030, 1, 2, 3, 4, 5, TimeSpan.Zero);
        var gateway = new FakeCloudSyncGateway(() => clock);
        ICloudSyncDocument doc = gateway.Collection("c").Document("d");

        await doc.SetDataAsync(Fields(("updatedAt", CloudSyncValue.ServerTimestamp.Instance)), merge: false);

        CloudSyncFields read = (await doc.GetDataAsync())!;
        Assert.Equal(clock, ((CloudSyncValue.TimestampValue)read["updatedAt"]!).Value);
    }

    [Fact]
    public async Task Delete_removes_the_document()
    {
        var gateway = new FakeCloudSyncGateway();
        ICloudSyncDocument doc = gateway.Collection("c").Document("d");
        await doc.SetDataAsync(Fields(("x", new CloudSyncValue.IntegerValue(1))), merge: false);

        await doc.DeleteDocumentAsync();

        Assert.Null(await doc.GetDataAsync());
    }

    [Fact]
    public async Task Batch_commits_all_writes_and_increments_the_counter()
    {
        var gateway = new FakeCloudSyncGateway();
        ICloudSyncDocument d1 = gateway.Collection("c").Document("d1");
        ICloudSyncDocument d2 = gateway.Collection("c").Document("d2");

        ICloudSyncWriteBatch batch = gateway.Batch();
        batch.SetData(Fields(("n", new CloudSyncValue.IntegerValue(1))), d1, merge: false);
        batch.SetData(Fields(("n", new CloudSyncValue.IntegerValue(2))), d2, merge: false);
        await batch.CommitAsync();

        Assert.Equal(1, gateway.BatchCommitCount);
        Assert.Equal(1, ((CloudSyncValue.IntegerValue)(await d1.GetDataAsync())!["n"]!).Value);
        Assert.Equal(2, ((CloudSyncValue.IntegerValue)(await d2.GetDataAsync())!["n"]!).Value);
    }

    [Fact]
    public async Task Transaction_commits_when_block_returns_true_and_aborts_when_false()
    {
        var gateway = new FakeCloudSyncGateway();
        ICloudSyncDocument doc = gateway.Collection("c").Document("d");

        bool committed = await gateway.RunTransactionAsync(txn =>
        {
            txn.SetData(Fields(("n", new CloudSyncValue.IntegerValue(7))), doc, merge: false);
            return Task.FromResult(true);
        });
        Assert.True(committed);
        Assert.Equal(7, ((CloudSyncValue.IntegerValue)(await doc.GetDataAsync())!["n"]!).Value);

        bool aborted = await gateway.RunTransactionAsync(txn =>
        {
            txn.SetData(Fields(("n", new CloudSyncValue.IntegerValue(99))), doc, merge: false);
            return Task.FromResult(false);
        });
        Assert.False(aborted);
        Assert.Equal(7, ((CloudSyncValue.IntegerValue)(await doc.GetDataAsync())!["n"]!).Value); // unchanged
    }

    [Fact]
    public async Task BeforeNextTransaction_hook_runs_once()
    {
        var gateway = new FakeCloudSyncGateway();
        int calls = 0;
        gateway.BeforeNextTransaction = () => calls++;

        await gateway.RunTransactionAsync(_ => Task.FromResult(true));
        await gateway.RunTransactionAsync(_ => Task.FromResult(true));

        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task Query_filters_orders_and_limits()
    {
        var gateway = new FakeCloudSyncGateway();
        for (int i = 1; i <= 5; i++)
        {
            await gateway.Collection("scores").Document($"d{i}")
                .SetDataAsync(Fields(("v", new CloudSyncValue.IntegerValue(i))), merge: false);
        }

        ICloudSyncQuerySnapshot snapshot = await gateway.Collection("scores")
            .WhereGreaterThan("v", new CloudSyncValue.IntegerValue(2))
            .OrderBy("v", descending: true)
            .Limit(2)
            .GetDocumentsAsync();

        int[] values = snapshot.Documents
            .Select(d => (int)((CloudSyncValue.IntegerValue)d.Data["v"]!).Value)
            .ToArray();
        Assert.Equal(new[] { 5, 4 }, values);
    }

    [Fact]
    public async Task Equality_filter_matches_exact_value()
    {
        var gateway = new FakeCloudSyncGateway();
        await gateway.Collection("c").Document("a").SetDataAsync(Fields(("k", new CloudSyncValue.StringValue("x"))), merge: false);
        await gateway.Collection("c").Document("b").SetDataAsync(Fields(("k", new CloudSyncValue.StringValue("y"))), merge: false);

        ICloudSyncQuerySnapshot snapshot = await gateway.Collection("c")
            .WhereEqualTo("k", new CloudSyncValue.StringValue("y"))
            .GetDocumentsAsync();

        Assert.Single(snapshot.Documents);
        Assert.Equal("b", snapshot.Documents[0].DocumentId);
    }

    [Fact]
    public async Task Injected_error_propagates_on_read_and_write()
    {
        var gateway = new FakeCloudSyncGateway { NextError = new InvalidOperationException("boom") };
        ICloudSyncDocument doc = gateway.Collection("c").Document("d");

        await Assert.ThrowsAsync<InvalidOperationException>(() => doc.GetDataAsync());
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            doc.SetDataAsync(Fields(("x", new CloudSyncValue.IntegerValue(1))), merge: false));
    }

    [Fact]
    public async Task DocumentsUnder_returns_only_direct_children()
    {
        var gateway = new FakeCloudSyncGateway();
        await gateway.Collection("c").Document("a").SetDataAsync(Fields(("x", new CloudSyncValue.IntegerValue(1))), merge: false);
        // A grand-child under a sub-collection must not leak into the parent listing.
        await gateway.Collection("c").Document("a").Collection("sub").Document("g")
            .SetDataAsync(Fields(("y", new CloudSyncValue.IntegerValue(2))), merge: false);

        IReadOnlyDictionary<string, CloudSyncFields> direct = gateway.DocumentsUnder("c");
        Assert.Single(direct);
        Assert.True(direct.ContainsKey("c/a"));
    }
}
