using System.Globalization;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Presentation.Memories;
using OpenBurnBar.CloudSync.Crypto;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using Xunit;

namespace OpenBurnBar.App.CloudSync.Tests;

public sealed class CloudSyncMemoryRoundTripTests
{
    private const string Uid = "user_test_1";

    [Fact]
    public async Task FakeGateway_MemoryFact_SealDecodeAndOpenBody_RoundTrips()
    {
        byte[] vaultKey = CloudVaultCrypto.GenerateVaultKey();
        var gateway = new FakeCloudSyncGateway();
        var store = new CloudSyncMemoryStore(gateway, Uid, vaultKey);

        var now = DateTimeOffset.Parse("2026-07-04T12:00:00Z", CultureInfo.InvariantCulture);
        var memory = new Memory(
            Id: "mem_alpha",
            Kind: MemoryKind.Fact,
            Scope: new MemoryScope(UserId: Uid),
            Confidence: 0.92,
            BodyRedacted: "[sealed]",
            ReviewStatus: MemoryReviewStatus.Approved,
            Citations: Array.Empty<MemoryCitation>(),
            ValidFrom: now.AddDays(-1),
            CreatedAt: now.AddDays(-1),
            UpdatedAt: now,
            SourceKind: MemorySourceKind.Chat);

        (string docId, CloudSyncFields fields) = MemoryCloudFactCodec.EncodeFact(
            memory,
            "The user prefers dark mode in the IDE.",
            Uid,
            vaultKey,
            now);

        string path = $"{store.CollectionPath}/{docId}";
        gateway.SetDocumentData(fields, path);

        MemoryPage page = await store.LoadPageAsync(
            new MemoryPageRequest(new MemoryScope(), IncludeQuarantined: true));
        Assert.Single(page.Items);
        Assert.Equal("mem_alpha", page.Items[0].Id);
        Assert.Equal(MemoryReviewStatus.Approved, page.Items[0].ReviewStatus);

        string? body = await store.OpenBodyAsync("mem_alpha");
        Assert.Equal("The user prefers dark mode in the IDE.", body);

        await Assert.ThrowsAsync<MemoryReviewMacOnlyException>(() =>
            store.SetStatusAsync("mem_alpha", MemoryReviewStatus.Rejected));
    }
}