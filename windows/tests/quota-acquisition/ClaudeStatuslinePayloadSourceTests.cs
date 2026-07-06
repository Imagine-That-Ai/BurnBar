using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;
using OpenBurnBar.App.Quota.Acquisition;
using Xunit;

namespace OpenBurnBar.App.Quota.Acquisition.Tests;

/// <summary>
/// Mechanism 1 acquisition half — the statusline snapshot-file source. Freshness
/// policy parity with ClaudeQuotaAdapter.StatuslinePolicy (15 min, judged by the
/// file's modification instant) over the recorded tests/quota fixture.
/// </summary>
public sealed class ClaudeStatuslinePayloadSourceTests
{
    [Fact]
    public async Task FreshSnapshotFile_ParsesValueForValue()
    {
        var dir = AcquisitionTestSupport.CreateTempDirectory();
        try
        {
            var path = Path.Combine(dir, "claude_statusline_snapshot.json");
            File.WriteAllText(path, AcquisitionTestSupport.ReadFixture("claude-statusline-input.json"));
            var modifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero);
            var clock = new ManualQuotaClock { UtcNow = modifiedAt.AddMinutes(1) };

            var source = new ClaudeStatuslinePayloadSource(path, clock);
            ProviderQuotaSnapshot? snapshot = await source.TryAcquireAsync(CancellationToken.None);

            Assert.NotNull(snapshot);
            AcquisitionTestSupport.AssertMatches(
                snapshot!,
                AcquisitionTestSupport.ReadExpected("claude-statusline-expected.json"));
            Assert.Equal(modifiedAt, snapshot!.FetchedAt);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public async Task StaleSnapshotFile_YieldsNoSignal()
    {
        var dir = AcquisitionTestSupport.CreateTempDirectory();
        try
        {
            var path = Path.Combine(dir, "snapshot.json");
            File.WriteAllText(path, AcquisitionTestSupport.ReadFixture("claude-statusline-input.json"));
            var modifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero);

            // One second past StatuslinePolicy.maxSnapshotAge (15 min).
            var clock = new ManualQuotaClock { UtcNow = modifiedAt.AddMinutes(15).AddSeconds(1) };
            var source = new ClaudeStatuslinePayloadSource(path, clock);

            Assert.Null(await source.TryAcquireAsync(CancellationToken.None));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public async Task ExactlyAtMaxAge_IsStillFresh()
    {
        var dir = AcquisitionTestSupport.CreateTempDirectory();
        try
        {
            var path = Path.Combine(dir, "snapshot.json");
            File.WriteAllText(path, "{ \"rate_limits\": { \"five_hour\": { \"used_percentage\": 10 } } }");
            var modifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero);

            // Swift isFreshStatuslineSnapshot uses <= maxSnapshotAge.
            var clock = new ManualQuotaClock { UtcNow = modifiedAt.AddMinutes(15) };
            var source = new ClaudeStatuslinePayloadSource(path, clock);

            Assert.NotNull(await source.TryAcquireAsync(CancellationToken.None));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public async Task MissingFile_YieldsNoSignal()
    {
        var source = new ClaudeStatuslinePayloadSource(
            Path.Combine(AcquisitionTestSupport.CreateTempDirectory(), "absent.json"),
            new ManualQuotaClock());

        Assert.Null(await source.TryAcquireAsync(CancellationToken.None));
    }

    [Fact]
    public async Task PayloadWithoutBuckets_YieldsNoSignal()
    {
        var dir = AcquisitionTestSupport.CreateTempDirectory();
        try
        {
            var path = Path.Combine(dir, "snapshot.json");
            File.WriteAllText(path, "not json");
            var modifiedAt = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero);
            var clock = new ManualQuotaClock { UtcNow = modifiedAt.AddMinutes(1) };

            var source = new ClaudeStatuslinePayloadSource(path, clock);

            Assert.Null(await source.TryAcquireAsync(CancellationToken.None));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
