using System;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.MissionControl;

namespace OpenBurnBar.App.MissionControl;

/// <summary>
/// Dev-host placeholder for <see cref="IMissionDispatchHost"/> — the Windows analog of the
/// SessionLogs demo stream. It builds a representative snapshot (runtimes, live tiles, ticker,
/// one approval ask) from synthetic <see cref="MissionRecord"/>s via the portable, unit-tested
/// <see cref="MissionSnapshotBuilder"/>, so the console renders real content in the shell today.
/// The Firestore-backed host (cli_agent_mission_requests, the same envelope the phone writes)
/// lands in a later wave and swaps in behind this same interface.
/// </summary>
public sealed class MissionDispatchDemoHost : IMissionDispatchHost
{
    private static readonly MissionRuntime[] Runtimes =
    {
        new("claude", "Claude Code", "CLD", "claudeCode", RuntimeAvailability.Online, 0.84, 6, null, 1.1),
        new("codex", "Codex CLI", "CDX", "codex", RuntimeAvailability.Online, 0.61, 4, null, 0.9),
        new("hermes", "Hermes Relay", "HRM", "hermes", RuntimeAvailability.Online, null, 0, null, 0.4),
        new("pi", "Pi Agent", "PI", "piAgent", RuntimeAvailability.Online, null, 0, null, 0.25),
        new("openclaw", "OpenClaw", "OCL", "openClaw", RuntimeAvailability.Unknown, null, 0, null, 0.85),
        new("ollama", "Ollama (local)", "OLM", "ollama", RuntimeAvailability.Unknown, null, 0, "Free, on-device.", 0.05),
    };

    public Task<MissionDispatchOutcome> DispatchAsync(MissionDispatchRequest request) =>
        Task.FromResult(MissionDispatchOutcome.Success($"demo-{Guid.NewGuid():N}"));

    public Task RespondToApprovalAsync(MissionApprovalAsk ask, bool approve) => Task.CompletedTask;

    public Task<MissionConsoleSnapshot> RefreshAsync()
    {
        DateTimeOffset now = DateTimeOffset.Now;

        var missions = new[]
        {
            new MissionRecord("m-diligence", "Audit the sync escrow path", "burnbar",
                MissionRecordState.Running, MissionApprovalState.None, now.AddMinutes(-4),
                burn: 0.42, worker: "Claude Code",
                packetSummary: "Reading ControlPlaneStore migrations…"),
            new MissionRecord("m-debt", "Decompose the 1.9k-line listener", "burnbar",
                MissionRecordState.Partial, MissionApprovalState.None, now.AddMinutes(-12),
                burn: 0.88, worker: "Codex CLI",
                latestResultSummary: "3 of 5 extractions landed."),
            new MissionRecord("m-security", "Threat-model the Firestore dispatch", "burnbar",
                MissionRecordState.Running, MissionApprovalState.Pending, now.AddMinutes(-1),
                burn: 0.15, worker: "Claude Code",
                latestAuditSummary: "Wants to run `firebase deploy --only firestore:rules`."),
            new MissionRecord("m-queued", "Trim the token budget on cheap routes", "console",
                MissionRecordState.Planned, MissionApprovalState.None, now.AddMinutes(-20)),
        };

        var events = new[]
        {
            new MissionControllerEvent("e1", now.AddSeconds(-8), MissionEventCategory.Mission,
                "Dispatched", "Audit the sync escrow path started on Claude Code."),
            new MissionControllerEvent("e2", now.AddSeconds(-45), MissionEventCategory.Followup,
                "Tooling", "Read 12 files under Services/CloudSync.", "AgentLens/Services/CloudSync"),
            new MissionControllerEvent("e3", now.AddMinutes(-3), MissionEventCategory.Replay,
                "Replay", "Verifier replay FAILED on 1 step — retrying."),
        };

        var snapshot = MissionSnapshotBuilder.Build(
            missions,
            events,
            Runtimes,
            new MissionRuntimeSnapshot(RuntimeSnapshotSource.Daemon, now),
            now);

        return Task.FromResult(snapshot);
    }
}
