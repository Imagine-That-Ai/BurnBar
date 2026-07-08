using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.MissionControl;

namespace OpenBurnBar.App.MissionControl;

/// <summary>Honest production fallback when Firestore mission dispatch is not configured. The console still
/// lets the user compose, but dispatch explains which data source is missing instead of inventing work.
/// </summary>
public sealed class EmptyMissionDispatchHost : IMissionDispatchHost
{
    public Task<MissionDispatchOutcome> DispatchAsync(MissionDispatchRequest request) =>
        Task.FromResult(MissionDispatchOutcome.Failed("Connect Firebase mission dispatch in Settings → Data Sources, or launch with OPENBURNBAR_SAMPLE_MODE=1 for a labeled demo."));

    public Task RespondToApprovalAsync(MissionApprovalAsk ask, bool approve) => Task.CompletedTask;

    public Task<MissionConsoleSnapshot> RefreshAsync() => Task.FromResult(MissionConsoleSnapshot.Empty);
}
