using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using OpenBurnBar.App.MissionControl;
using OpenBurnBar.App.Presentation.MissionControl;
using OpenBurnBar.CloudSync.Firestore;
using OpenBurnBar.CloudSync.Gateway;
using Xunit;

namespace OpenBurnBar.App.MissionControl.Tests;

public sealed class FirestoreMissionDispatchHostTests
{
    private static readonly DateTimeOffset FixedNow = new(2026, 7, 4, 12, 0, 0, TimeSpan.Zero);
    private const string Uid = "test-user";
    private const string CollectionPath = $"users/{Uid}/cli_agent_mission_requests";

    private sealed class RecordingApprovalCallable : IMissionApprovalCallable
    {
        public string? RequestId { get; private set; }
        public bool? Approve { get; private set; }

        public Task RespondAsync(string requestId, bool approve, CancellationToken cancellationToken = default)
        {
            RequestId = requestId;
            Approve = approve;
            return Task.CompletedTask;
        }
    }

    [Fact]
    public async Task Dispatch_does_not_write_cli_agent_mission_requests()
    {
        var gateway = new FakeCloudSyncGateway(() => FixedNow);
        var host = new FirestoreMissionDispatchHost(gateway, Uid, () => FixedNow);

        var request = new MissionDispatchRequest(
            title: "Audit escrow",
            prompt: "Read the sync path and summarize risks.",
            kind: MissionKind.Security,
            runtimeId: "claude",
            targetProject: "burnbar",
            depth: MissionDepth.Standard,
            approvalMode: MissionApprovalMode.ExistingPolicy,
            commandsAllowed: false,
            fileEditsAllowed: true,
            sourceSurface: "mission-control-test");

        MissionDispatchOutcome dispatch = await host.DispatchAsync(request);
        Assert.False(dispatch.Dispatched);
        Assert.Contains("createCliAgentMission", dispatch.FailureMessage);
        Assert.Empty(gateway.DocumentsUnder(CollectionPath));
    }

    [Fact]
    public async Task RespondToApproval_calls_respondMissionApproval_and_does_not_merge_approved()
    {
        var gateway = new FakeCloudSyncGateway(() => FixedNow);
        var callable = new RecordingApprovalCallable();
        var host = new FirestoreMissionDispatchHost(gateway, Uid, () => FixedNow, callable);

        string missionId = "mission-1";
        string docPath = $"{CollectionPath}/{missionId}";
        await gateway.Collection(CollectionPath).Document(missionId).SetDataAsync(
            CloudSyncFields.From(new[]
            {
                new KeyValuePair<string, CloudSyncValue>("status", CloudSyncValue.Of("waiting_for_approval")),
                new KeyValuePair<string, CloudSyncValue>("approvalStatus", CloudSyncValue.Of("pending")),
                new KeyValuePair<string, CloudSyncValue>("approvalSummary", CloudSyncValue.Of("Deploy firestore rules")),
            }),
            merge: true);

        MissionConsoleSnapshot awaiting = await host.RefreshAsync();
        MissionApprovalAsk ask = Assert.Single(awaiting.ApprovalAsks);
        await host.RespondToApprovalAsync(ask, approve: true);

        Assert.Equal(missionId, callable.RequestId);
        Assert.True(callable.Approve);
        CloudSyncFields? patched = gateway.DocumentData(docPath);
        Assert.NotNull(patched);
        Assert.Equal("waiting_for_approval", ReadString(patched!, "status"));
        Assert.Equal("pending", ReadString(patched!, "approvalStatus"));
    }

    private static string? ReadString(CloudSyncFields data, string key) =>
        data[key] is CloudSyncValue.StringValue s ? s.Value : null;
}