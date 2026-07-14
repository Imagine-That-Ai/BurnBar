using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;
using Xunit;

namespace OpenBurnBar.App.Quota.Tests;

public sealed class DomainCoreQuotaShadowEvidenceTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"openburnbar-shadow-{Guid.NewGuid():D}");

    [Fact]
    public void Serialization_UsesExactPrivacySafeSchemaIncludingNullCategory()
    {
        string json = JsonSerializer.Serialize(Sample(1));
        using JsonDocument document = JsonDocument.Parse(json);
        string[] keys = document.RootElement.EnumerateObject().Select(property => property.Name).Order().ToArray();

        Assert.Equal(new[]
        {
            "channel", "consumer", "coreVersion", "domain", "legacyMicros", "mismatchCategory",
            "observedAt", "operation", "outcome", "rustMicros", "sampleId", "schemaVersion",
        }, keys);
        Assert.Equal(JsonValueKind.Null, document.RootElement.GetProperty("mismatchCategory").ValueKind);
        Assert.DoesNotContain("uid", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("payload", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("deviceId", json, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Rotation_BoundsReadyFilesAndDropsOldestWholeBatch()
    {
        var spool = new DomainCoreQuotaShadowEvidenceSpool(
            _directory,
            maxFileBytes: 4096,
            maxReadyFiles: 2,
            maxSamplesPerFile: 1);

        spool.Append(Sample(1));
        spool.Append(Sample(2));
        spool.Append(Sample(3));
        DomainCoreQuotaShadowEvidenceSpool.ReadyBatch batch = Assert.IsType<DomainCoreQuotaShadowEvidenceSpool.ReadyBatch>(spool.NextBatch());

        Assert.Equal(2, spool.PendingSampleCount());
        Assert.Equal(2, Directory.EnumerateFiles(_directory, "ready-*.jsonl").Count());
        Assert.Equal("00000000-0000-4000-8000-000000000002", batch.Samples.Single().SampleId);
    }

    [Fact]
    public void FailedUploadCanRetrySameBatchUntilAcknowledged()
    {
        var spool = new DomainCoreQuotaShadowEvidenceSpool(_directory);
        spool.Append(Sample(1));

        DomainCoreQuotaShadowEvidenceSpool.ReadyBatch first = Assert.IsType<DomainCoreQuotaShadowEvidenceSpool.ReadyBatch>(spool.NextBatch());
        DomainCoreQuotaShadowEvidenceSpool.ReadyBatch retry = Assert.IsType<DomainCoreQuotaShadowEvidenceSpool.ReadyBatch>(spool.NextBatch());
        Assert.Equal(first.Token, retry.Token);
        Assert.Equal(1, spool.PendingSampleCount());

        spool.Acknowledge(retry.Token);
        Assert.Equal(0, spool.PendingSampleCount());
        Assert.Null(spool.NextBatch());
    }

    [Fact]
    public async Task RapidSamplesCoalesceIntoOneBoundedDelayedUpload()
    {
        var spool = new DomainCoreQuotaShadowEvidenceSpool(_directory);
        var batchSizes = new List<int>();
        var delays = new Queue<TaskCompletionSource>();
        var delayStarted = new SemaphoreSlim(0);
        Task ControlledDelay(TimeSpan _)
        {
            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (delays) delays.Enqueue(completion);
            delayStarted.Release();
            return completion.Task;
        }
        async Task ReleaseNextDelay()
        {
            await delayStarted.WaitAsync(TimeSpan.FromSeconds(5), CancellationToken.None);
            TaskCompletionSource completion;
            lock (delays) completion = delays.Dequeue();
            completion.SetResult();
        }
        var uploaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var coordinator = new DomainCoreQuotaShadowUploadCoordinator(
            spool,
            (samples, _) =>
            {
                lock (batchSizes) batchSizes.Add(samples.Count);
                uploaded.SetResult();
                return Task.CompletedTask;
            },
            TimeSpan.FromSeconds(5),
            ControlledDelay);

        spool.Append(Sample(1));
        coordinator.Schedule();
        await delayStarted.WaitAsync(TimeSpan.FromSeconds(5), CancellationToken.None);
        spool.Append(Sample(2));
        coordinator.Schedule();
        TaskCompletionSource first;
        lock (delays) first = delays.Dequeue();
        first.SetResult();
        await delayStarted.WaitAsync(TimeSpan.FromSeconds(5), CancellationToken.None);
        spool.Append(Sample(3));
        coordinator.Schedule();
        TaskCompletionSource second;
        lock (delays) second = delays.Dequeue();
        second.SetResult();
        await ReleaseNextDelay();
        await uploaded.Task.WaitAsync(TimeSpan.FromSeconds(5));

        lock (batchSizes) Assert.Equal(new[] { 3 }, batchSizes);
        Assert.Equal(0, spool.PendingSampleCount());
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }

    private static DomainCoreQuotaShadowSampleV1 Sample(int suffix) => new()
    {
        SampleId = $"00000000-0000-4000-8000-{suffix:D12}",
        Channel = "internal",
        Operation = "claude_quota",
        CoreVersion = "0.3.0",
        ObservedAt = "2026-07-13T12:00:00.000Z",
        Outcome = "match",
        MismatchCategory = null,
        LegacyMicros = 120,
        RustMicros = 80,
    };
}
