using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Quota;
using OpenBurnBar.App.Quota.Acquisition;
using Xunit;

namespace OpenBurnBar.App.Quota.Acquisition.Tests;

/// <summary>
/// The fan-in coordinator: it drives every <see cref="IQuotaPayloadSource"/>,
/// stores the latest snapshot per source, raises change events, tracks per-source
/// errors, coalesces watcher signals on the injected clock, and retries throwing
/// sources up to the configured attempt cap. All deterministic — no wall clock.
/// </summary>
public sealed class QuotaAcquisitionCoordinatorTests
{
    private static QuotaAcquisitionOptions FastOptions(int maxAttempts = 2) => new()
    {
        RetryDelay = TimeSpan.Zero,
        MaxAttemptsPerSource = maxAttempts,
    };

    [Fact]
    public async Task RefreshAsync_FansInEverySource_AndReturnsOneSnapshotPerProducingSource()
    {
        var clock = new ManualQuotaClock();
        var claude = new FakeQuotaSource("claude-statusline", () => AcquisitionTestSupport.Snapshot("claude"));
        var cursor = new FakeQuotaSource("cursor-usage", () => AcquisitionTestSupport.Snapshot("cursor"));
        var quiet = new FakeQuotaSource("codex-usage", () => null); // no signal right now
        using var coordinator = new QuotaAcquisitionCoordinator(
            new IQuotaPayloadSource[] { claude, cursor, quiet }, clock, FastOptions());

        IReadOnlyList<ProviderQuotaSnapshot> snapshots = await coordinator.RefreshAsync();

        Assert.Equal(1, claude.CallCount);
        Assert.Equal(1, cursor.CallCount);
        Assert.Equal(1, quiet.CallCount);
        Assert.Equal(new[] { "claude", "cursor" }, snapshots.Select(s => s.Provider).OrderBy(p => p));
        Assert.DoesNotContain(snapshots, s => s.Provider == "codex");
    }

    [Fact]
    public async Task RefreshAsync_RaisesSnapshotsChanged_OnlyWhenTheStoredSnapshotChanges()
    {
        var clock = new ManualQuotaClock();
        // Sticky last-known-good: the same instance re-read is NOT a change
        // (StoreLocked uses reference identity), so the event fires once.
        ProviderQuotaSnapshot stable = AcquisitionTestSupport.Snapshot("claude");
        var source = new FakeQuotaSource("claude-statusline", () => stable);
        using var coordinator = new QuotaAcquisitionCoordinator(
            new IQuotaPayloadSource[] { source }, clock, FastOptions());

        var events = 0;
        coordinator.SnapshotsChanged += _ => events++;

        await coordinator.RefreshAsync(); // first read → change
        await coordinator.RefreshAsync(); // same instance → no change

        Assert.Equal(1, events);
        Assert.Single(coordinator.LatestSnapshots);
    }

    [Fact]
    public async Task RefreshAsync_RecordsPerSourceError_WhenASourceThrows_AndDoesNotKillOthers()
    {
        var clock = new ManualQuotaClock();
        var boom = new FakeQuotaSource("codex-usage", () => throw new InvalidOperationException("token expired"));
        var ok = new FakeQuotaSource("claude-statusline", () => AcquisitionTestSupport.Snapshot("claude"));
        using var coordinator = new QuotaAcquisitionCoordinator(
            new IQuotaPayloadSource[] { boom, ok }, clock, FastOptions());

        IReadOnlyList<ProviderQuotaSnapshot> snapshots = await coordinator.RefreshAsync();

        Assert.Single(snapshots); // the healthy source still produced
        Assert.Equal("claude", snapshots[0].Provider);
        Assert.True(coordinator.LastErrors.ContainsKey("codex-usage"));
        Assert.Contains("token expired", coordinator.LastErrors["codex-usage"]);
        Assert.False(coordinator.LastErrors.ContainsKey("claude-statusline"));
    }

    [Fact]
    public async Task RefreshAsync_RetriesAThrowingSource_UpToTheAttemptCap()
    {
        var clock = new ManualQuotaClock();
        var attempts = 0;
        var flaky = new FakeQuotaSource("cursor-usage", () =>
        {
            attempts++;
            if (attempts < 2)
            {
                throw new TimeoutException("transient");
            }

            return AcquisitionTestSupport.Snapshot("cursor");
        });
        using var coordinator = new QuotaAcquisitionCoordinator(
            new IQuotaPayloadSource[] { flaky }, clock, FastOptions(maxAttempts: 2));

        IReadOnlyList<ProviderQuotaSnapshot> snapshots = await coordinator.RefreshAsync();

        Assert.Equal(2, attempts); // failed once, succeeded on the retry
        Assert.Single(snapshots);
        Assert.Equal("cursor", snapshots[0].Provider);
        Assert.False(coordinator.LastErrors.ContainsKey("cursor-usage")); // cleared on eventual success
    }

    [Fact]
    public async Task SignalChangeAsync_CoalescesConcurrentSignalsForTheSameSource_IntoOneRefresh()
    {
        var gate = new TaskCompletionSource();
        var clock = new ManualQuotaClock
        {
            // Hold the debounce delay open until we release it, so both signals
            // arrive while the first is still pending.
            OnDelay = (_, _) => gate.Task,
        };
        var source = new FakeQuotaSource("claude-statusline", () => AcquisitionTestSupport.Snapshot("claude"));
        using var coordinator = new QuotaAcquisitionCoordinator(
            new IQuotaPayloadSource[] { source }, clock, FastOptions());

        Task first = coordinator.SignalChangeAsync("claude-statusline");
        Task second = coordinator.SignalChangeAsync("claude-statusline");

        Assert.Same(first, second); // coalesced: same in-flight refresh task
        gate.SetResult();
        await Task.WhenAll(first, second);

        Assert.Equal(1, source.CallCount); // exactly one acquisition despite two signals
    }

    [Fact]
    public void AttachWatcher_StartsTheWatcher_AndDisposesItWithTheCoordinator()
    {
        var clock = new ManualQuotaClock();
        var source = new FakeQuotaSource("claude-statusline", () => AcquisitionTestSupport.Snapshot("claude"));
        var watcher = new FakeQuotaFileWatcher();
        var coordinator = new QuotaAcquisitionCoordinator(
            new IQuotaPayloadSource[] { source }, clock, FastOptions());

        coordinator.AttachWatcher(watcher, "claude-statusline");
        Assert.True(watcher.Started);

        coordinator.Dispose();
        Assert.True(watcher.Disposed);
    }

    [Fact]
    public async Task RunAutomaticRefreshLoop_WaitsTheInitialDelay_ThenRefreshesOnInterval()
    {
        var releases = new List<TaskCompletionSource>();
        var clock = new ManualQuotaClock
        {
            OnDelay = (_, _) =>
            {
                var tcs = new TaskCompletionSource();
                releases.Add(tcs);
                return tcs.Task;
            },
        };
        var source = new FakeQuotaSource("claude-statusline", () => AcquisitionTestSupport.Snapshot("claude"));
        using var coordinator = new QuotaAcquisitionCoordinator(
            new IQuotaPayloadSource[] { source }, clock, new QuotaAcquisitionOptions { RetryDelay = TimeSpan.Zero });

        using var cts = new CancellationTokenSource();
        Task loop = coordinator.RunAutomaticRefreshLoopAsync(cts.Token);

        await WaitFor(() => releases.Count >= 1); // parked on the initial delay
        Assert.Equal(0, source.CallCount);        // nothing before the initial delay elapses

        releases[0].SetResult();                  // initial delay elapses → first refresh
        await WaitFor(() => source.CallCount >= 1);
        Assert.Equal(QuotaAcquisitionPolicy.AutoRefreshInitialDelay, clock.Delays[0]);

        await WaitFor(() => releases.Count >= 2);  // now parked on the interval
        Assert.Equal(QuotaAcquisitionPolicy.AutoRefreshInterval, clock.Delays[1]);

        cts.Cancel();
        releases[^1].TrySetCanceled();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => loop);
    }

    [Fact]
    public async Task NoSignal_KeepsTheLastKnownGoodSnapshot()
    {
        var clock = new ManualQuotaClock();
        var yield = true;
        var source = new FakeQuotaSource("claude-statusline",
            () => yield ? AcquisitionTestSupport.Snapshot("claude") : null);
        using var coordinator = new QuotaAcquisitionCoordinator(
            new IQuotaPayloadSource[] { source }, clock, FastOptions());

        await coordinator.RefreshAsync();
        yield = false;
        IReadOnlyList<ProviderQuotaSnapshot> snapshots = await coordinator.RefreshAsync();

        // Sticky last-known-good (Mac store semantics): a later "no signal" keeps
        // the previous snapshot on display.
        Assert.Single(snapshots);
        Assert.Equal("claude", snapshots[0].Provider);
    }

    [Fact]
    public async Task WatcherSeamContract_FireRoutesThroughDebounceIntoOneRefresh()
    {
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var clock = new ManualQuotaClock { OnDelay = (_, _) => gate.Task };
        var source = new FakeQuotaSource("claude-statusline", () => AcquisitionTestSupport.Snapshot("claude"));
        var watcher = new FakeQuotaFileWatcher();
        using var coordinator = new QuotaAcquisitionCoordinator(
            new IQuotaPayloadSource[] { source }, clock, FastOptions());

        coordinator.AttachWatcher(watcher, "claude-statusline");
        watcher.Fire("snapshot.json");
        watcher.Fire("snapshot.json"); // burst within the debounce window
        Assert.Equal(0, source.CallCount);

        gate.SetResult();
        await WaitFor(() => source.CallCount == 1);

        Assert.Equal(1, source.CallCount);
        Assert.Equal(QuotaAcquisitionPolicy.ChangeDebounce, clock.Delays[0]);
    }

    [Fact]
    public async Task SignalChange_ForAnUnknownSource_IsANoOp()
    {
        var clock = new ManualQuotaClock();
        var source = new FakeQuotaSource("known", () => AcquisitionTestSupport.Snapshot("cursor"));
        using var coordinator = new QuotaAcquisitionCoordinator(
            new IQuotaPayloadSource[] { source }, clock, FastOptions());

        await coordinator.SignalChangeAsync("unknown");

        Assert.Equal(0, source.CallCount);
    }

    private static async Task WaitFor(Func<bool> condition)
    {
        for (var i = 0; i < 200 && !condition(); i++)
        {
            await Task.Delay(5);
        }

        Assert.True(condition(), "condition not reached before timeout");
    }
}
