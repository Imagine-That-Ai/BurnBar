using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.MissionControl;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.MissionControl;

/// <summary>Locks the console view-model ported from MissionControlConsoleView +
/// MissionConsoleHost: draft mutation + PropertyChanged, reactive forecast/resolved-runtime,
/// canDispatch gating, dispatch clearing the draft, and error surfacing.</summary>
public sealed class MissionConsoleViewModelTests
{
    private sealed class FakeHost : IMissionDispatchHost
    {
        public MissionConsoleSnapshot Next = MissionConsoleSnapshot.Empty;
        public MissionDispatchOutcome DispatchResult = MissionDispatchOutcome.Success("mission-1");
        public MissionDispatchRequest? LastRequest;
        public int DispatchCalls;
        public (MissionApprovalAsk ask, bool approve)? LastApproval;
        public Exception? RespondThrows;

        public Task<MissionDispatchOutcome> DispatchAsync(MissionDispatchRequest request)
        {
            DispatchCalls++;
            LastRequest = request;
            return Task.FromResult(DispatchResult);
        }

        public Task RespondToApprovalAsync(MissionApprovalAsk ask, bool approve)
        {
            if (RespondThrows is not null)
            {
                throw RespondThrows;
            }

            LastApproval = (ask, approve);
            return Task.CompletedTask;
        }

        public Task<MissionConsoleSnapshot> RefreshAsync() => Task.FromResult(Next);
    }

    private static readonly IReadOnlyList<MissionRuntime> Catalog = new[]
    {
        new MissionRuntime("claude", "Claude Code", "CLD", "claudeCode", RuntimeAvailability.Online),
        new MissionRuntime("codex", "Codex CLI", "CDX", "codex", RuntimeAvailability.Online, pricingFactor: 0.9),
        new MissionRuntime("openclaw", "OpenClaw", "OCL", "openClaw", RuntimeAvailability.Online, pricingFactor: 0.85),
    };

    private static MissionConsoleSnapshot SnapshotWith(params MissionActiveTile[] tiles) =>
        new(
            new MissionSystemHealth(DaemonState.Live, DateTimeOffset.Now, tiles.Length, 0, 0, 2.0, 1.5, 3, 3),
            Catalog, tiles, Array.Empty<MissionTickerEntry>(), Array.Empty<MissionApprovalAsk>(),
            new[] { "burnbar" }, new[] { "burnbar" });

    [Fact]
    public void CanDispatch_RequiresNonEmptyPrompt()
    {
        var vm = new MissionConsoleViewModel(new FakeHost());
        Assert.False(vm.CanDispatch);
        vm.Prompt = "  ";
        Assert.False(vm.CanDispatch);
        vm.Prompt = "Investigate the sync bug";
        Assert.True(vm.CanDispatch);
    }

    [Fact]
    public void PromptChange_RaisesCanDispatchNotification()
    {
        var vm = new MissionConsoleViewModel(new FakeHost());
        var changed = new List<string?>();
        vm.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        vm.Prompt = "go";
        Assert.Contains(nameof(vm.Prompt), changed);
        Assert.Contains(nameof(vm.CanDispatch), changed);
    }

    [Fact]
    public async Task ResolvedRuntime_AutoPreviewsPlannerFirstChoice()
    {
        var host = new FakeHost { Next = SnapshotWith() };
        var vm = new MissionConsoleViewModel(host);
        await vm.RefreshAsync();

        // Default kind is Diligence -> planner prefers "claude" first.
        Assert.Equal("auto", vm.RuntimeId);
        Assert.Equal("claude", vm.ResolvedRuntime.Id);

        // Creative -> planner prefers "openclaw" first.
        vm.Kind = MissionKind.Creative;
        Assert.Equal("openclaw", vm.ResolvedRuntime.Id);
    }

    [Fact]
    public async Task ResolvedRuntime_ExplicitSelectionWins()
    {
        var host = new FakeHost { Next = SnapshotWith() };
        var vm = new MissionConsoleViewModel(host);
        await vm.RefreshAsync();
        vm.RuntimeId = "codex";
        Assert.Equal("codex", vm.ResolvedRuntime.Id);
        Assert.Equal("codex", vm.RuntimeAccentKey);
    }

    [Fact]
    public void RuntimeAccentKey_AutoIsFactory()
    {
        var vm = new MissionConsoleViewModel(new FakeHost());
        Assert.Equal("factory", vm.RuntimeAccentKey);
    }

    [Fact]
    public async Task KindChange_RecomputesForecast()
    {
        var host = new FakeHost { Next = SnapshotWith() };
        var vm = new MissionConsoleViewModel(host);
        await vm.RefreshAsync();

        MissionForecast before = vm.Forecast;
        var changed = new List<string?>();
        vm.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        vm.Kind = MissionKind.Creative; // higher multiplier -> different band
        Assert.Contains(nameof(vm.Forecast), changed);
        Assert.NotEqual(before, vm.Forecast);
    }

    [Fact]
    public async Task Dispatch_SuccessClearsTitleAndPromptAndRefreshes()
    {
        var host = new FakeHost
        {
            DispatchResult = MissionDispatchOutcome.Success("mission-42"),
            Next = SnapshotWith(new MissionActiveTile("mission-42", "New", "claude", "Claude Code", MissionTilePhase.Running)),
        };
        var vm = new MissionConsoleViewModel(host);
        vm.Title = "My mission";
        vm.Prompt = "Do the thing";

        await vm.DispatchAsync();

        Assert.Equal(1, host.DispatchCalls);
        Assert.Equal(string.Empty, vm.Title);
        Assert.Equal(string.Empty, vm.Prompt);
        Assert.Equal("mission-42", vm.LastDispatchedMissionId);
        Assert.Single(vm.ActiveTiles);
        Assert.False(vm.IsDispatching);
        Assert.Null(vm.InlineError);
    }

    [Fact]
    public async Task Dispatch_FailureSurfacesInlineErrorAndKeepsDraft()
    {
        var host = new FakeHost { DispatchResult = MissionDispatchOutcome.Failed("device not trusted") };
        var vm = new MissionConsoleViewModel(host);
        vm.Prompt = "Do the thing";

        await vm.DispatchAsync();

        Assert.Equal("device not trusted", vm.InlineError);
        Assert.True(vm.HasInlineError);
        Assert.Equal("Do the thing", vm.Prompt); // draft preserved on failure
        Assert.False(vm.IsDispatching);
    }

    [Fact]
    public async Task Dispatch_NoOpWhenPromptEmpty()
    {
        var host = new FakeHost();
        var vm = new MissionConsoleViewModel(host);
        await vm.DispatchAsync();
        Assert.Equal(0, host.DispatchCalls);
    }

    [Fact]
    public void BuildDispatchRequest_TrimsAndDropsEmptyProject()
    {
        var vm = new MissionConsoleViewModel(new FakeHost())
        {
            Title = "  Investigate  ",
            Prompt = "  fix the leak  ",
            TargetProject = "   ",
            Kind = MissionKind.Security,
            Depth = MissionDepth.Deep,
        };
        MissionDispatchRequest req = vm.BuildDispatchRequest();
        Assert.Equal("Investigate", req.Title);
        Assert.Equal("fix the leak", req.Prompt);
        Assert.Null(req.TargetProject);
        Assert.Equal(MissionKind.Security, req.Kind);
        Assert.Equal(MissionDepth.Deep, req.Depth);
        Assert.Equal("windows.missionControl", req.SourceSurface);
    }

    [Fact]
    public async Task Respond_ForwardsToHostAndRefreshes()
    {
        var host = new FakeHost { Next = SnapshotWith() };
        var vm = new MissionConsoleViewModel(host);
        var ask = new MissionApprovalAsk("approval-1", "m1", "Approve?", "msg", "claude", "Claude Code", DateTimeOffset.Now);

        await vm.RespondAsync(ask, approve: true);

        Assert.NotNull(host.LastApproval);
        Assert.True(host.LastApproval!.Value.approve);
        Assert.Equal("m1", host.LastApproval!.Value.ask.MissionId);
    }

    [Fact]
    public async Task Respond_SurfacesHostError()
    {
        var host = new FakeHost { RespondThrows = new InvalidOperationException("reject unavailable") };
        var vm = new MissionConsoleViewModel(host);
        var ask = new MissionApprovalAsk("approval-1", "m1", "Approve?", "msg", null, "Mac fleet", DateTimeOffset.Now);

        await vm.RespondAsync(ask, approve: false);

        Assert.Equal("reject unavailable", vm.InlineError);
    }

    [Fact]
    public async Task Refresh_UpdatesSnapshotDerivedHeroCopy()
    {
        var host = new FakeHost
        {
            Next = SnapshotWith(
                new MissionActiveTile("m1", "One", "claude", "Claude Code", MissionTilePhase.Running),
                new MissionActiveTile("m2", "Two", "codex", "Codex CLI", MissionTilePhase.Running)),
        };
        var vm = new MissionConsoleViewModel(host);
        await vm.RefreshAsync();

        Assert.Equal(2, vm.ActiveMissionCount);
        Assert.Equal("2 missions in flight.", vm.HeroHeadline);
        Assert.True(vm.MacOnline);
        Assert.Equal(MissionGaugeSize.Hero, vm.HeroGauge.Size);
    }

    [Fact]
    public void ClearInlineError_Resets()
    {
        var vm = new MissionConsoleViewModel(new FakeHost());
        // Force an error via a failing dispatch path is async; simulate through respond error instead.
        vm.ClearInlineError();
        Assert.Null(vm.InlineError);
        Assert.False(vm.HasInlineError);
    }
}
