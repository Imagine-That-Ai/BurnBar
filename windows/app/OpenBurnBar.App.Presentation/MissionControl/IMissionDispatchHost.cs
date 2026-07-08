using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.MissionControl;

// The platform-side dispatch seam. Mirrors the macOS MissionConsoleHost protocol
// (OpenBurnBarCore/.../MissionConsoleTypes.swift) reduced to the pure I/O contract: the
// WinUI host implements this against Firestore's cli_agent_mission_requests collection
// (the same envelope the phone writes for the Mac to execute), while tests supply a fake.
// The observable draft + snapshot state lives in MissionConsoleViewModel, not here.

/// <summary>Async dispatch / approval / refresh service the console view-model drives.</summary>
public interface IMissionDispatchHost
{
    /// <summary>Create a mission from a composed envelope. Returns the new mission id on
    /// success, or a failure message. Mirrors <c>MissionConsoleHost.dispatch</c>.</summary>
    Task<MissionDispatchOutcome> DispatchAsync(MissionDispatchRequest request);

    /// <summary>Answer a pending approval. Mirrors <c>MissionConsoleHost.respond</c>.</summary>
    Task RespondToApprovalAsync(MissionApprovalAsk ask, bool approve);

    /// <summary>Pull the current console snapshot. Mirrors <c>MissionConsoleHost.refresh</c>
    /// (which mutates the host's <c>snapshot</c>); here it returns the fresh value.</summary>
    Task<MissionConsoleSnapshot> RefreshAsync();
}
