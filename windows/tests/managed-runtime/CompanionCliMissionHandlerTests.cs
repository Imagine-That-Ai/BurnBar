using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Mission;
using OpenBurnBar.App.ManagedAgentRuntime.Run;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class CompanionCliMissionHandlerTests
{
    [Fact]
    public async Task SubmitAsync_ExecutesSafeDependencyGraphThroughLocalMissionRuntime()
    {
        string path = Path.Combine(Path.GetTempPath(), $"obb-mission-handler-{Guid.NewGuid():N}.jsonl");
        try
        {
            var runs = new HeadlessRunService(new JsonLinesHeadlessRunJournal(path));
            var handler = new CompanionCliMissionHandler(
                new LocalMissionDagExecutor(
                    runs,
                    rateLimiter: new MissionRateLimiter(60, TimeSpan.FromMinutes(1))));
            using JsonDocument request = JsonDocument.Parse("""
                {
                  "missionId": "mission-live-1",
                  "nodes": [
                    { "id": "ready", "kind": "health" },
                    { "id": "settle", "kind": "delay", "payload": "0", "dependsOn": ["ready"] }
                  ]
                }
                """);

            object? result = await handler.SubmitAsync(request.RootElement, CancellationToken.None);
            string wire = JsonSerializer.Serialize(result);

            Assert.Contains("mission-live-1", wire, StringComparison.Ordinal);
            Assert.Contains("Succeeded", wire, StringComparison.Ordinal);
            Assert.Contains("ready", wire, StringComparison.Ordinal);
            Assert.Contains("settle", wire, StringComparison.Ordinal);
            Assert.True(File.Exists(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task SubmitAsync_RejectsUnsafeKindBeforeWritingJournal()
    {
        string path = Path.Combine(Path.GetTempPath(), $"obb-mission-handler-{Guid.NewGuid():N}.jsonl");
        try
        {
            var handler = new CompanionCliMissionHandler(
                new LocalMissionDagExecutor(
                    new HeadlessRunService(new JsonLinesHeadlessRunJournal(path))));
            using JsonDocument request = JsonDocument.Parse("""
                {
                  "missionId": "mission-unsafe",
                  "nodes": [{ "id": "bad", "kind": "shell", "payload": "whoami" }]
                }
                """);

            await Assert.ThrowsAsync<ArgumentException>(() =>
                handler.SubmitAsync(request.RootElement, CancellationToken.None));

            Assert.False(File.Exists(path));
        }
        finally
        {
            File.Delete(path);
        }
    }
}
