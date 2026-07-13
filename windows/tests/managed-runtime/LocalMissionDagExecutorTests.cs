using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Mission;
using OpenBurnBar.App.ManagedAgentRuntime.Run;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class LocalMissionDagExecutorTests
{
    [Fact]
    public async Task ExecuteAsync_RunsDependencyOrderAndRequiresApproval()
    {
        string path = Path.Combine(Path.GetTempPath(), $"obb-mission-{Guid.NewGuid():N}.jsonl");
        try
        {
            var runs = new HeadlessRunService(new JsonLinesHeadlessRunJournal(path));
            var approved = new List<string>();
            var executed = new List<string>();
            var executor = new LocalMissionDagExecutor(runs, (node, _) =>
            {
                approved.Add(node.Id);
                return Task.FromResult(true);
            });
            var definition = new MissionDefinition("mission-1", new[]
            {
                new MissionNode("plan", "plan", "plan"),
                new MissionNode("run", "run", "run", new[] { "plan" }),
            });

            MissionExecutionResult result = await executor.ExecuteAsync(
                definition,
                new MissionPolicy(AllowedKinds: new HashSet<string> { "plan", "run" }, RequireApproval: true),
                (node, _) =>
                {
                    executed.Add(node.Id);
                    return Task.FromResult(MissionStepResult.Ok());
                });

            Assert.Equal(HeadlessRunState.Succeeded, result.State);
            Assert.Equal(new[] { "plan", "run" }, approved);
            Assert.Equal(new[] { "plan", "run" }, executed);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task ExecuteAsync_FailsClosedWhenApprovalIsDenied()
    {
        string path = Path.Combine(Path.GetTempPath(), $"obb-mission-{Guid.NewGuid():N}.jsonl");
        try
        {
            var executor = new LocalMissionDagExecutor(
                new HeadlessRunService(new JsonLinesHeadlessRunJournal(path)),
                (_, _) => Task.FromResult(false));
            MissionExecutionResult result = await executor.ExecuteAsync(
                new MissionDefinition("mission-2", new[] { new MissionNode("danger", "shell", "x") }),
                new MissionPolicy(RequireApproval: true),
                (_, _) => Task.FromResult(MissionStepResult.Ok()));

            Assert.Equal(HeadlessRunState.Failed, result.State);
            Assert.Equal("danger", result.FailedNodeId);
            Assert.Equal("mission_step_not_approved", result.Error);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task ExecuteAsync_RejectsDisallowedKindsBeforeWritingJournal()
    {
        string path = Path.Combine(Path.GetTempPath(), $"obb-mission-{Guid.NewGuid():N}.jsonl");
        try
        {
            var executor = new LocalMissionDagExecutor(
                new HeadlessRunService(new JsonLinesHeadlessRunJournal(path)));
            await Assert.ThrowsAsync<ArgumentException>(() => executor.ExecuteAsync(
                new MissionDefinition("mission-3", new[] { new MissionNode("x", "shell", "x") }),
                new MissionPolicy(AllowedKinds: new HashSet<string> { "safe" }),
                (_, _) => Task.FromResult(MissionStepResult.Ok())));
            Assert.False(File.Exists(path));
        }
        finally
        {
            File.Delete(path);
        }
    }
}
