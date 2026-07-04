using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.MissionControl;

// PORTED (faithful) from MissionControlConsoleView + MissionConsoleHost
// (OpenBurnBarCore/.../MissionControl/*). The SwiftUI console splits state between the view
// (draft: title/prompt/kind/runtime/depth/approval/permissions/project) and the host
// (snapshot / isDispatching / inlineError / lastDispatchedMissionID). The Windows port folds
// both into one INotifyPropertyChanged view-model the WinUI page x:Binds to — with the
// forecast, resolved-runtime, and canDispatch derivations recomputed reactively. All logic
// is portable so it is unit-tested on macOS; the IMissionDispatchHost seam does the I/O.

/// <summary>Backs the Windows Mission Control console: composer draft + live snapshot +
/// dispatch orchestration.</summary>
public sealed class MissionConsoleViewModel : INotifyPropertyChanged
{
    private readonly IMissionDispatchHost _host;

    private MissionConsoleSnapshot _snapshot = MissionConsoleSnapshot.Empty;
    private bool _isDispatching;
    private string? _inlineError;
    private string? _lastDispatchedMissionId;

    // Draft (the SwiftUI @State fields).
    private string _title = string.Empty;
    private string _prompt = string.Empty;
    private MissionKind _kind = MissionKind.Diligence;
    private string _runtimeId = "auto";
    private MissionDepth _depth = MissionDepth.Standard;
    private MissionApprovalMode _approvalMode = MissionApprovalMode.ExistingPolicy;
    private bool _commandsAllowed;
    private bool _fileEditsAllowed;
    private string _targetProject = string.Empty;

    public MissionConsoleViewModel(IMissionDispatchHost host)
    {
        _host = host ?? throw new ArgumentNullException(nameof(host));
    }

    // MARK: Host state

    public MissionConsoleSnapshot Snapshot
    {
        get => _snapshot;
        private set
        {
            _snapshot = value;
            OnPropertyChanged();
            RaiseSnapshotDerived();
            // Runtime catalog changed -> resolved runtime + forecast may move.
            RaiseDraftDerived();
        }
    }

    public bool IsDispatching
    {
        get => _isDispatching;
        private set
        {
            if (_isDispatching != value)
            {
                _isDispatching = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(CanDispatch));
                OnPropertyChanged(nameof(DispatchLabel));
            }
        }
    }

    public string? InlineError
    {
        get => _inlineError;
        private set
        {
            if (_inlineError != value)
            {
                _inlineError = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(HasInlineError));
            }
        }
    }

    public bool HasInlineError => !string.IsNullOrEmpty(_inlineError);

    public string? LastDispatchedMissionId
    {
        get => _lastDispatchedMissionId;
        private set
        {
            if (_lastDispatchedMissionId != value)
            {
                _lastDispatchedMissionId = value;
                OnPropertyChanged();
            }
        }
    }

    // MARK: Draft

    public string Title
    {
        get => _title;
        set { if (_title != value) { _title = value ?? string.Empty; OnPropertyChanged(); } }
    }

    public string Prompt
    {
        get => _prompt;
        set
        {
            if (_prompt != value)
            {
                _prompt = value ?? string.Empty;
                OnPropertyChanged();
                OnPropertyChanged(nameof(CanDispatch));
            }
        }
    }

    public MissionKind Kind
    {
        get => _kind;
        set
        {
            if (_kind != value)
            {
                _kind = value;
                OnPropertyChanged();
                RaiseDraftDerived();
            }
        }
    }

    public string RuntimeId
    {
        get => _runtimeId;
        set
        {
            string next = string.IsNullOrEmpty(value) ? "auto" : value;
            if (_runtimeId != next)
            {
                _runtimeId = next;
                OnPropertyChanged();
                RaiseDraftDerived();
            }
        }
    }

    public MissionDepth Depth
    {
        get => _depth;
        set
        {
            if (_depth != value)
            {
                _depth = value;
                OnPropertyChanged();
                RaiseDraftDerived();
            }
        }
    }

    public MissionApprovalMode ApprovalMode
    {
        get => _approvalMode;
        set
        {
            if (_approvalMode != value)
            {
                _approvalMode = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(Recommendation));
            }
        }
    }

    public bool CommandsAllowed
    {
        get => _commandsAllowed;
        set
        {
            if (_commandsAllowed != value)
            {
                _commandsAllowed = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(Recommendation));
            }
        }
    }

    public bool FileEditsAllowed
    {
        get => _fileEditsAllowed;
        set
        {
            if (_fileEditsAllowed != value)
            {
                _fileEditsAllowed = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(Recommendation));
            }
        }
    }

    public string TargetProject
    {
        get => _targetProject;
        set { if (_targetProject != value) { _targetProject = value ?? string.Empty; OnPropertyChanged(); } }
    }

    // MARK: Derived

    /// <summary>The runtime the forecast + dispatch button resolve to. Mirrors
    /// <c>resolvedRuntime</c>: AUTO previews the planner's first choice for the kind.</summary>
    public MissionRuntime ResolvedRuntime
    {
        get
        {
            if (_runtimeId == "auto")
            {
                string? preferredId = MissionKindInfo.PreferredRuntimes(_kind).FirstOrDefault();
                MissionRuntime? preferred = preferredId is null
                    ? null
                    : _snapshot.Runtimes.FirstOrDefault(r => r.Id == preferredId);
                return preferred ?? MissionRuntime.Auto;
            }

            return _snapshot.Runtimes.FirstOrDefault(r => r.Id == _runtimeId) ?? MissionRuntime.Auto;
        }
    }

    /// <summary>Provider key driving the dispatch button's accent. AUTO uses ember (the
    /// "factory" brand); otherwise the resolved runtime's provider. Mirrors
    /// <c>runtimeAccent</c>.</summary>
    public string RuntimeAccentKey => _runtimeId == "auto" ? "factory" : ResolvedRuntime.ProviderKey;

    /// <summary>The forecast band for the current draft. Mirrors the reactive
    /// <c>MissionConsoleForecastComputer.forecast(...)</c> in the console view.</summary>
    public MissionForecast Forecast => MissionForecastComputer.Forecast(_kind, _depth, ResolvedRuntime);

    /// <summary>The runtime constellation rows (AUTO + advertised runtimes) with selection +
    /// "preferred for {kind}" state. Recomputed when runtimes / selection / kind change.</summary>
    public IReadOnlyList<MissionRuntimeCardItem> ConstellationItems =>
        MissionRuntimeCardItem.Build(_snapshot.Runtimes, _runtimeId, _kind);

    /// <summary>The mission-kind chooser chips with selection state. Recomputed on kind change.</summary>
    public IReadOnlyList<MissionKindChipItem> KindChips => MissionKindChipItem.Build(_kind);

    /// <summary>The selected kind's tagline, shown under the chooser. Mirrors the Swift hint.</summary>
    public string KindTagline => MissionKindInfo.Tagline(_kind);

    /// <summary>The planner recommendation the envelope would carry.</summary>
    public MissionRecommendation Recommendation =>
        MissionForecastComputer.Recommendation(_depth, _approvalMode, _commandsAllowed, _fileEditsAllowed);

    /// <summary>Gate for the dispatch button. Mirrors <c>canDispatch</c>: a non-empty prompt
    /// and no dispatch in flight.</summary>
    public bool CanDispatch => _prompt.Trim().Length > 0 && !_isDispatching;

    /// <summary>Dispatch button caption. Mirrors the Swift CTA ("Dispatch via {RUNTIME}" /
    /// "Dispatching…").</summary>
    public string DispatchLabel => _isDispatching
        ? "Dispatching…"
        : $"Dispatch via {ResolvedRuntime.DisplayName}";

    // Snapshot-derived convenience surface for the hero + situation room.

    public IReadOnlyList<MissionRuntime> Runtimes => _snapshot.Runtimes;
    public IReadOnlyList<MissionActiveTile> ActiveTiles => _snapshot.ActiveTiles;
    public IReadOnlyList<MissionTickerEntry> RecentTicker => _snapshot.RecentTicker;
    public IReadOnlyList<MissionApprovalAsk> ApprovalAsks => _snapshot.ApprovalAsks;
    public IReadOnlyList<string> KnownProjects => _snapshot.KnownProjects;
    public IReadOnlyList<string> RecentProjects => _snapshot.RecentProjects;
    public MissionSystemHealth Health => _snapshot.Health;

    public bool HasActiveTiles => _snapshot.ActiveTiles.Count > 0;
    public bool HasApprovals => _snapshot.ApprovalAsks.Count > 0;
    public bool HasTicker => _snapshot.RecentTicker.Count > 0;

    public int ActiveMissionCount => _snapshot.ActiveTiles.Count(t => MissionTilePhaseInfo.IsLive(t.Phase));
    public int ApprovalPendingCount => _snapshot.ApprovalAsks.Count;
    public int BlockedCount => _snapshot.ActiveTiles.Count(t => MissionTilePhaseInfo.IsProblem(t.Phase));
    public bool HasCompletedSinceLastOpen => _snapshot.ActiveTiles.Any(t => t.Phase == MissionTilePhase.Completed);
    public bool MacOnline => _snapshot.Health.DaemonState != DaemonState.MacOffline;

    public string HeroHeadline =>
        MissionHeroText.Headline(ActiveMissionCount, ApprovalPendingCount, BlockedCount, HasCompletedSinceLastOpen);

    public string HeroSubtitle => MissionHeroText.Subtitle(_snapshot.Health, DateTimeOffset.Now);

    // Mono meta-strip readouts for the hero (formatted so the XAML binds plain strings).
    public string InFlightLabel => ActiveMissionCount.ToString(System.Globalization.CultureInfo.InvariantCulture);
    public string QueuedLabel => _snapshot.Health.QueuedMissions.ToString(System.Globalization.CultureInfo.InvariantCulture);
    public string BurnPerHourLabel => MissionFormatting.Cost(_snapshot.Health.BurnPerHourUsd, _snapshot.Health.BurnPerHourUsd < 1);
    public string BurnTodayLabel => MissionFormatting.Cost(_snapshot.Health.BurnTodayUsd);
    public string RuntimesLabel => $"{_snapshot.Health.OnlineRuntimes}/{_snapshot.Health.TotalRuntimes}";

    /// <summary>The hero gauge configuration. Mirrors the Swift hero's
    /// <c>MissionFABGauge.Configuration</c> assembly.</summary>
    public MissionGaugeConfiguration HeroGauge => new(
        size: MissionGaugeSize.Hero,
        activeMissionCount: ActiveMissionCount,
        approvalPendingCount: ApprovalPendingCount,
        blockedCount: BlockedCount,
        hasCompletedSinceLastOpen: HasCompletedSinceLastOpen,
        burnSweep: MissionHeroText.BurnSweep(_snapshot.Health.BurnPerHourUsd),
        burnPerHourUsd: _snapshot.Health.BurnPerHourUsd,
        macOnline: MacOnline);

    // MARK: Commands

    /// <summary>Pull the latest snapshot. Mirrors the console's <c>.task { await host.refresh() }</c>.</summary>
    public async Task RefreshAsync()
    {
        MissionConsoleSnapshot fresh = await _host.RefreshAsync().ConfigureAwait(false);
        Snapshot = fresh ?? MissionConsoleSnapshot.Empty;
    }

    /// <summary>Compose the current draft into an envelope. Mirrors <c>dispatchRequest</c>.</summary>
    public MissionDispatchRequest BuildDispatchRequest()
    {
        string trimmedProject = _targetProject.Trim();
        return new MissionDispatchRequest(
            title: _title.Trim(),
            prompt: _prompt.Trim(),
            kind: _kind,
            runtimeId: _runtimeId,
            targetProject: trimmedProject.Length == 0 ? null : trimmedProject,
            depth: _depth,
            approvalMode: _approvalMode,
            commandsAllowed: _commandsAllowed,
            fileEditsAllowed: _fileEditsAllowed,
            sourceSurface: "windows.missionControl");
    }

    /// <summary>Dispatch the draft. Mirrors <c>dispatch()</c>: on success the draft's title +
    /// prompt clear and the snapshot refreshes.</summary>
    public async Task DispatchAsync()
    {
        if (!CanDispatch)
        {
            return;
        }

        IsDispatching = true;
        try
        {
            MissionDispatchOutcome outcome = await _host.DispatchAsync(BuildDispatchRequest()).ConfigureAwait(false);
            if (outcome.Dispatched)
            {
                LastDispatchedMissionId = outcome.MissionId;
                InlineError = null;
                Title = string.Empty;
                Prompt = string.Empty;
                MissionConsoleSnapshot fresh = await _host.RefreshAsync().ConfigureAwait(false);
                Snapshot = fresh ?? MissionConsoleSnapshot.Empty;
            }
            else
            {
                InlineError = outcome.FailureMessage;
            }
        }
        finally
        {
            IsDispatching = false;
        }
    }

    /// <summary>Answer an approval. Mirrors <c>respond(to:approve:)</c>.</summary>
    public async Task RespondAsync(MissionApprovalAsk ask, bool approve)
    {
        try
        {
            await _host.RespondToApprovalAsync(ask, approve).ConfigureAwait(false);
            MissionConsoleSnapshot fresh = await _host.RefreshAsync().ConfigureAwait(false);
            Snapshot = fresh ?? MissionConsoleSnapshot.Empty;
        }
        catch (Exception error)
        {
            InlineError = error.Message;
        }
    }

    public void ClearInlineError() => InlineError = null;

    // MARK: Change plumbing

    private void RaiseDraftDerived()
    {
        OnPropertyChanged(nameof(ResolvedRuntime));
        OnPropertyChanged(nameof(RuntimeAccentKey));
        OnPropertyChanged(nameof(Forecast));
        OnPropertyChanged(nameof(Recommendation));
        OnPropertyChanged(nameof(ConstellationItems));
        OnPropertyChanged(nameof(KindChips));
        OnPropertyChanged(nameof(KindTagline));
        OnPropertyChanged(nameof(DispatchLabel));
    }

    private void RaiseSnapshotDerived()
    {
        OnPropertyChanged(nameof(Runtimes));
        OnPropertyChanged(nameof(ConstellationItems));
        OnPropertyChanged(nameof(ActiveTiles));
        OnPropertyChanged(nameof(HasActiveTiles));
        OnPropertyChanged(nameof(RecentTicker));
        OnPropertyChanged(nameof(HasTicker));
        OnPropertyChanged(nameof(ApprovalAsks));
        OnPropertyChanged(nameof(HasApprovals));
        OnPropertyChanged(nameof(KnownProjects));
        OnPropertyChanged(nameof(RecentProjects));
        OnPropertyChanged(nameof(Health));
        OnPropertyChanged(nameof(ActiveMissionCount));
        OnPropertyChanged(nameof(ApprovalPendingCount));
        OnPropertyChanged(nameof(BlockedCount));
        OnPropertyChanged(nameof(HasCompletedSinceLastOpen));
        OnPropertyChanged(nameof(MacOnline));
        OnPropertyChanged(nameof(HeroHeadline));
        OnPropertyChanged(nameof(HeroSubtitle));
        OnPropertyChanged(nameof(HeroGauge));
        OnPropertyChanged(nameof(InFlightLabel));
        OnPropertyChanged(nameof(QueuedLabel));
        OnPropertyChanged(nameof(BurnPerHourLabel));
        OnPropertyChanged(nameof(BurnTodayLabel));
        OnPropertyChanged(nameof(RuntimesLabel));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
