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

    [Fact]
    public async Task Dispatch_refresh_and_approval_round_trip_via_fake_gateway()
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
        Assert.True(dispatch.Dispatched);
        Assert.False(string.IsNullOrWhiteSpace(dispatch.MissionId));

        string docPath = $"{CollectionPath}/{dispatch.MissionId}";
        CloudSyncFields? stored = gateway.DocumentData(docPath);
        Assert.NotNull(stored);
        Assert.Equal("pending", ReadString(stored!, "status"));
        Assert.Equal(request.Prompt, ReadString(stored!, "prompt"));

        MissionConsoleSnapshot afterDispatch = await host.RefreshAsync();
        Assert.Contains(afterDispatch.ActiveTiles, t => t.Id == dispatch.MissionId);

        // Simulate listener claim → waiting for approval
        await gateway.Collection(CollectionPath).Document(dispatch.MissionId!).SetDataAsync(
            CloudSyncFields.From(new[]
            {
                new KeyValuePair<string, CloudSyncValue>("status", CloudSyncValue.Of("waiting_for_approval")),
                new KeyValuePair<string, CloudSyncValue>("approvalStatus", CloudSyncValue.Of("pending")),
                new KeyValuePair<string, CloudSyncValue>("approvalSummary", CloudSyncValue.Of("Deploy firestore rules")),
            }),
            merge: true);

        MissionConsoleSnapshot awaiting = await host.RefreshAsync();
        MissionApprovalAsk ask = Assert.Single(awaiting.ApprovalAsks);
        Assert.Equal(dispatch.MissionId, ask.MissionId);

        await host.RespondToApprovalAsync(ask, approve: true);

        CloudSyncFields? patched = gateway.DocumentData(docPath);
        Assert.NotNull(patched);
        Assert.Equal("running", ReadString(patched!, "status"));
        Assert.Equal("approved", ReadString(patched!, "approvalStatus"));
    }

    private static string? ReadString(CloudSyncFields data, string key) =>
        data[key] is CloudSyncValue.StringValue s ? s.Value : null;
}