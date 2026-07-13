using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace OpenBurnBar.App.UsageRuntime.Tests;

public sealed class WindowsUsageRuntimeTests
{
    [Fact]
    public async Task StartAsync_PersistsAndPublishesLiveSnapshot()
    {
        var engine = new FakeUsageEngine(Response(withUsage: true));
        var store = new RecordingSnapshotStore();
        await using var runtime = CreateRuntime(engine, store);

        await runtime.StartAsync();

        Assert.Equal(UsageRuntimePhase.Ready, runtime.State.Phase);
        Assert.Single(runtime.State.Snapshot.Usages);
        Assert.NotNull(runtime.State.LastSuccessfulScan);
        Assert.Equal(1, engine.CallCount);
        Assert.Equal(1, store.PersistCount);
    }

    [Fact]
    public async Task Constructor_UsesConfiguredPeriodicInterval()
    {
        var runtime = CreateRuntime(
            new FakeUsageEngine(Response(withUsage: false)),
            new RecordingSnapshotStore(),
            periodicInterval: TimeSpan.FromMinutes(10));
        await using (runtime)
        {
            Assert.Equal(TimeSpan.FromMinutes(10), runtime.PeriodicInterval);
        }
    }

    [Fact]
    public void ForCurrentUser_IndexingGateControlsConversationBodyCollection()
    {
        Assert.False(WindowsUsagePaths.ForCurrentUser(includeConversationBodies: false)
            .ScanRequest.IncludeConversationBodies);
        Assert.True(WindowsUsagePaths.ForCurrentUser(includeConversationBodies: true)
            .ScanRequest.IncludeConversationBodies);
    }

    [Fact]
    public async Task ManualScan_WithProviderFailure_PublishesDegradedStateAndKeepsGoodRows()
    {
        var engine = new FakeUsageEngine(
            Response(withUsage: true),
            Response(withUsage: true, withProviderFailure: true));
        var store = new RecordingSnapshotStore();
        await using var runtime = CreateRuntime(engine, store);
        await runtime.StartAsync();

        await runtime.ScanAsync(UsageScanReason.Manual);

        Assert.Equal(UsageRuntimePhase.Degraded, runtime.State.Phase);
        Assert.Equal(UsageRuntimeFailureKind.NativeEngineFailure, runtime.State.FailureKind);
        Assert.Single(runtime.State.Snapshot.Usages);
        Assert.Equal(2, store.PersistCount);
    }

    [Fact]
    public async Task MissingNativeEngine_IsVisibleAndNeverWrittenAsEmptyData()
    {
        var engine = new FakeUsageEngine(new UsageRuntimeException(
            UsageRuntimeFailureKind.NativeEngineUnavailable,
            "missing"));
        var store = new RecordingSnapshotStore();
        await using var runtime = CreateRuntime(engine, store);

        await runtime.StartAsync();

        Assert.Equal(UsageRuntimePhase.Unavailable, runtime.State.Phase);
        Assert.Equal(UsageRuntimeFailureKind.NativeEngineUnavailable, runtime.State.FailureKind);
        Assert.Equal(0, store.PersistCount);
        Assert.Contains("Repair or reinstall", runtime.State.StatusMessage, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ExistingProviderDirectory_FileChangeTriggersDebouncedRefresh()
    {
        string root = Path.Combine(Path.GetTempPath(), "obb-runtime-watch-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var engine = new FakeUsageEngine(Response(withUsage: false), Response(withUsage: true));
            var store = new RecordingSnapshotStore();
            var paths = TestPaths(root);
            await using var runtime = new WindowsUsageRuntime(
                engine,
                store,
                paths,
                periodicInterval: TimeSpan.FromHours(1),
                fileChangeDebounce: TimeSpan.FromMilliseconds(40));
            await runtime.StartAsync();

            await File.WriteAllTextAsync(Path.Combine(root, "session.jsonl"), "{}\n");
            await engine.WaitForCallCountAsync(2, TimeSpan.FromSeconds(5));

            Assert.True(engine.CallCount >= 2);
            Assert.Equal(UsageRuntimePhase.Ready, runtime.State.Phase);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static WindowsUsageRuntime CreateRuntime(
        IUsageEngine engine,
        IUsageRuntimeSnapshotStore store,
        TimeSpan? periodicInterval = null) => new(
            engine,
            store,
            TestPaths(Path.Combine(Path.GetTempPath(), "obb-runtime-missing-" + Guid.NewGuid().ToString("N"))),
            periodicInterval: periodicInterval ?? TimeSpan.FromHours(1),
            fileChangeDebounce: TimeSpan.FromMilliseconds(10));

    private static WindowsUsagePaths TestPaths(string root) => new(
        new UsageEngineScanRequest
        {
            SupportDirectory = root,
            HomeDirectory = root,
            ClaudeProjectsDirectory = root,
            CodexHomeDirectory = root,
            CursorSessionsDirectory = root,
            FactorySessionsDirectory = root,
            HermesHomeDirectory = root,
            IncludeConversationBodies = true,
        },
        new[] { root });

    private static UsageEngineScanResponse Response(
        bool withUsage,
        bool withProviderFailure = false)
    {
        var providers = new List<UsageProviderScanResult>
        {
            new()
            {
                Provider = "Claude Code",
                Status = UsageProviderScanStatus.Succeeded,
                UsageCount = withUsage ? 1 : 0,
                ConversationCount = 0,
            },
        };
        if (withProviderFailure)
        {
            providers.Add(new UsageProviderScanResult
            {
                Provider = "Codex",
                Status = UsageProviderScanStatus.Failed,
                Error = "fixture failure",
            });
        }

        return new UsageEngineScanResponse
        {
            Ok = true,
            Providers = providers,
            Usages = withUsage
                ? new[]
                {
                    new UsageEngineRecord
                    {
                        Id = "usage-1",
                        Provider = "Claude Code",
                        SessionId = "session-1",
                        ProjectName = "BurnBar",
                        Model = "claude-sonnet-4",
                        InputTokens = 10,
                        OutputTokens = 5,
                        TotalTokens = 15,
                        CostNanoUsd = 42_000_000,
                        StartUnixMilliseconds = 1_750_000_000_000,
                        EndUnixMilliseconds = 1_750_000_001_000,
                        CreatedUnixMilliseconds = 1_750_000_001_000,
                        UsageSource = "provider_log",
                        ProviderId = "anthropic",
                        ProvenanceMethod = "transcript",
                        ProvenanceConfidence = "exact",
                        EstimatorVersion = "fixture",
                    },
                }
                : Array.Empty<UsageEngineRecord>(),
        };
    }

    private sealed class FakeUsageEngine : IUsageEngine
    {
        private readonly ConcurrentQueue<object> _outcomes = new();
        private readonly SemaphoreSlim _called = new(0);
        private int _callCount;

        public FakeUsageEngine(params object[] outcomes)
        {
            foreach (object outcome in outcomes)
            {
                _outcomes.Enqueue(outcome);
            }
        }

        public int CallCount => Volatile.Read(ref _callCount);

        public ValueTask<UsageEngineScanResponse> ScanAsync(
            UsageEngineScanRequest request,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Interlocked.Increment(ref _callCount);
            _called.Release();
            if (!_outcomes.TryDequeue(out object? outcome))
            {
                throw new InvalidOperationException("No fake scan outcome remains.");
            }
            if (outcome is Exception exception)
            {
                throw exception;
            }
            return ValueTask.FromResult((UsageEngineScanResponse)outcome);
        }

        public async Task WaitForCallCountAsync(int expected, TimeSpan timeout)
        {
            using var cancellation = new CancellationTokenSource(timeout);
            while (CallCount < expected)
            {
                await _called.WaitAsync(cancellation.Token);
            }
        }
    }

    private sealed class RecordingSnapshotStore : IUsageRuntimeSnapshotStore
    {
        public int PersistCount { get; private set; }

        public ValueTask PersistAsync(
            UsageEngineScanResponse response,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            PersistCount++;
            return ValueTask.CompletedTask;
        }
    }
}
