using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.ElderWand;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.ElderWand;

public sealed class ElderWandFusionOrchestratorTests
{
    [Fact]
    public async Task RunAsync_RunsParallelPanelJudgeAndSynthesisInStableOrder()
    {
        var calls = new ConcurrentQueue<FusionToolCall>();
        var bothPanelCallsStarted = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        int activePanelCalls = 0;
        int maximumConcurrentPanelCalls = 0;
        var orchestrator = new ElderWandFusionOrchestrator(async (call, token) =>
        {
            calls.Enqueue(call);
            if (call.Kind == "panel")
            {
                int active = Interlocked.Increment(ref activePanelCalls);
                UpdateMaximum(ref maximumConcurrentPanelCalls, active);
                if (active == 2)
                {
                    bothPanelCallsStarted.TrySetResult(true);
                }

                await bothPanelCallsStarted.Task.WaitAsync(TimeSpan.FromSeconds(2), token);
                Interlocked.Decrement(ref activePanelCalls);
            }
            return FusionToolResult.Done(call.Kind + ":" + call.Model, Raw(call.Kind));
        });

        FusionRunResult result = await orchestrator.RunAsync(new FusionRunRequest(
            "explain it",
            AnalysisModels: new[] { "slow", "fast" },
            JudgeModel: "judge",
            OriginatingModel: "origin"));

        Assert.True(result.Succeeded);
        Assert.Equal("synthesis:origin", result.Output);
        Assert.Equal(new[] { "slow", "fast", "judge", "origin" }, result.Steps.Select(step => step.Call.Model));
        Assert.Equal(2, maximumConcurrentPanelCalls);
        Assert.Contains(calls, call => call.Kind == "judge" && call.Payload.Contains("Analysis answer 2", StringComparison.Ordinal));
        Assert.Contains(calls, call => call.Kind == "synthesis" && call.Payload.Contains("Judge verdict", StringComparison.Ordinal));
    }

    private static void UpdateMaximum(ref int target, int value)
    {
        int observed;
        do
        {
            observed = Volatile.Read(ref target);
            if (observed >= value)
            {
                return;
            }
        }
        while (Interlocked.CompareExchange(ref target, value, observed) != observed);
    }

    [Fact]
    public async Task RunAsync_DropsFailedPanelMemberButFailsWhenAllFail()
    {
        var partial = new ElderWandFusionOrchestrator((call, _) => Task.FromResult(
            call.Kind == "panel" && call.Model == "bad"
                ? FusionToolResult.Fail("no_route")
                : FusionToolResult.Done(call.Kind)));
        FusionRunResult partialResult = await partial.RunAsync(new FusionRunRequest(
            "seed",
            AnalysisModels: new[] { "good", "bad" },
            JudgeModel: "judge",
            OriginatingModel: "origin"));
        Assert.True(partialResult.Succeeded);
        Assert.DoesNotContain(partialResult.Steps, step => step.Call.Model == "bad");

        var failed = new ElderWandFusionOrchestrator((call, _) => Task.FromResult(
            call.Kind == "panel" ? FusionToolResult.Fail("no_route") : FusionToolResult.Done("unused")));
        FusionRunResult failedResult = await failed.RunAsync(new FusionRunRequest(
            "seed",
            AnalysisModels: new[] { "a", "b" },
            JudgeModel: "judge",
            OriginatingModel: "origin"));
        Assert.False(failedResult.Succeeded);
        Assert.Equal("all_analysis_models_failed", failedResult.Error);
    }

    [Fact]
    public async Task RunAsync_JudgeFailureFallsBackAndStillSynthesizes()
    {
        FusionToolCall? synthesis = null;
        var orchestrator = new ElderWandFusionOrchestrator((call, _) =>
        {
            if (call.Kind == "judge") return Task.FromResult(FusionToolResult.Fail("judge_down"));
            if (call.Kind == "synthesis") synthesis = call;
            return Task.FromResult(FusionToolResult.Done(call.Kind + " output"));
        });

        FusionRunResult result = await orchestrator.RunAsync(new FusionRunRequest(
            "seed",
            AnalysisModels: new[] { "panel" },
            JudgeModel: "judge",
            OriginatingModel: "origin"));

        Assert.True(result.Succeeded);
        Assert.NotNull(synthesis);
        Assert.Contains("judge unavailable", synthesis!.Payload, StringComparison.Ordinal);
    }

    [Fact]
    public async Task RunAsync_PreservesConversationAndStreamingSynthesisBody()
    {
        byte[] streamBody = System.Text.Encoding.UTF8.GetBytes("data: {\"choices\":[]}\n\ndata: [DONE]\n");
        FusionToolCall? panel = null;
        var orchestrator = new ElderWandFusionOrchestrator((call, _) =>
        {
            if (call.Kind == "panel") panel = call;
            return Task.FromResult(call.Kind == "synthesis"
                ? FusionToolResult.Done(string.Empty, streamBody, "text/event-stream")
                : FusionToolResult.Done(call.Kind + " output"));
        });
        var conversation = new[]
        {
            new FusionMessage("system", "system context"),
            new FusionMessage("user", "earlier question"),
            new FusionMessage("assistant", "earlier answer"),
            new FusionMessage("user", "latest question"),
        };

        FusionRunResult result = await orchestrator.RunAsync(new FusionRunRequest(
            "latest question",
            AnalysisModels: new[] { "panel" },
            JudgeModel: "judge",
            OriginatingModel: "origin",
            WantsStream: true,
            Conversation: conversation));

        Assert.True(result.Succeeded);
        Assert.Equal("text/event-stream", result.ContentType);
        Assert.Equal(streamBody, result.RawBody);
        Assert.True(result.Steps[^1].Call.Stream);
        Assert.Equal(conversation, panel!.Messages);
    }

    [Fact]
    public async Task RunAsync_ExecutesBoundedToolLoopAndReturnsToolResultToModel()
    {
        int panelTurns = 0;
        bool sawToolResult = false;
        FusionTool tool = Tool("web_fetch", (_, _) => Task.FromResult("trusted page text"));
        var orchestrator = new ElderWandFusionOrchestrator((call, _) =>
        {
            if (call.Kind == "panel" && panelTurns++ == 0)
            {
                return Task.FromResult(new FusionToolResult(
                    true,
                    false,
                    null,
                    null,
                    new[] { new FusionRequestedToolCall("call-1", "web_fetch", "{\"url\":\"https://example.com\"}") }));
            }
            sawToolResult |= call.Messages?.Any(message =>
                message.Role == "tool" && message.Content == "trusted page text") == true;
            return Task.FromResult(FusionToolResult.Done(call.Kind + " done"));
        }, tools: new[] { tool });

        FusionRunResult result = await orchestrator.RunAsync(new FusionRunRequest(
            "seed",
            MaxSteps: 1,
            AnalysisModels: new[] { "panel" },
            JudgeModel: "judge",
            OriginatingModel: "origin"));

        Assert.True(result.Succeeded);
        Assert.True(sawToolResult);
        Assert.Equal(2, panelTurns);
    }

    [Fact]
    public async Task RunAsync_ValidatesConfigurationAndClampsPanelToEight()
    {
        var models = new ConcurrentBag<string>();
        var orchestrator = new ElderWandFusionOrchestrator((call, _) =>
        {
            if (call.Kind == "panel") models.Add(call.Model!);
            return Task.FromResult(FusionToolResult.Done(call.Kind));
        });
        FusionRunResult missing = await orchestrator.RunAsync(new FusionRunRequest("seed"));
        Assert.Equal("analysis_models_required", missing.Error);

        FusionRunResult bounded = await orchestrator.RunAsync(new FusionRunRequest(
            "seed",
            AnalysisModels: Enumerable.Range(0, 12).Select(index => "m" + index).ToArray(),
            JudgeModel: "judge",
            OriginatingModel: "origin"));
        Assert.True(bounded.Succeeded);
        Assert.Equal(8, models.Count);
    }

    [Fact]
    public async Task RunAsync_JournalsMetadataAndDigestsWithoutPayloads()
    {
        string path = Path.Combine(Path.GetTempPath(), "obb-fusion-" + Path.GetRandomFileName() + ".jsonl");
        try
        {
            var orchestrator = new ElderWandFusionOrchestrator(
                (call, _) => Task.FromResult(FusionToolResult.Done("secret-output-" + call.Kind)),
                new JsonLinesFusionRunJournal(path));
            FusionRunResult result = await orchestrator.RunAsync(new FusionRunRequest(
                "secret-prompt",
                RunId: "run-1",
                AnalysisModels: new[] { "panel" },
                JudgeModel: "judge",
                OriginatingModel: "origin"));

            Assert.True(result.Succeeded);
            string contents = await File.ReadAllTextAsync(path);
            Assert.Contains("run-1", contents, StringComparison.Ordinal);
            Assert.DoesNotContain("secret-prompt", contents, StringComparison.Ordinal);
            Assert.DoesNotContain("secret-output", contents, StringComparison.Ordinal);
            Assert.Contains("outputSha256", contents, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    [Fact]
    public void WebTools_DenyPrivateSpecialAndMixedAddressFamilies()
    {
        Assert.False(ElderWandWebTools.IsPublicAddress(IPAddress.Loopback));
        Assert.False(ElderWandWebTools.IsPublicAddress(IPAddress.Parse("10.0.0.1")));
        Assert.False(ElderWandWebTools.IsPublicAddress(IPAddress.Parse("169.254.169.254")));
        Assert.False(ElderWandWebTools.IsPublicAddress(IPAddress.Parse("172.31.1.2")));
        Assert.False(ElderWandWebTools.IsPublicAddress(IPAddress.Parse("192.168.1.2")));
        Assert.False(ElderWandWebTools.IsPublicAddress(IPAddress.IPv6Loopback));
        Assert.False(ElderWandWebTools.IsPublicAddress(IPAddress.Parse("fc00::1")));
        Assert.True(ElderWandWebTools.IsPublicAddress(IPAddress.Parse("1.1.1.1")));
        Assert.True(ElderWandWebTools.IsPublicAddress(IPAddress.Parse("2606:4700:4700::1111")));
    }

    [Fact]
    public async Task WebSearch_FailsClosedWithoutAuthenticatedHostedBackend()
    {
        FusionTool search = Assert.Single(ElderWandWebTools.CreateProduction(), tool => tool.Name == "web_search");
        string result = await search.InvokeAsync("{\"query\":\"current docs\"}", CancellationToken.None);
        Assert.Contains("unavailable", result, StringComparison.OrdinalIgnoreCase);
    }

    private static FusionTool Tool(
        string name,
        Func<string, CancellationToken, Task<string>> invoke)
    {
        using JsonDocument schema = JsonDocument.Parse(
            $"{{\"type\":\"function\",\"function\":{{\"name\":\"{name}\",\"parameters\":{{\"type\":\"object\"}}}}}}");
        return new FusionTool(name, schema.RootElement.Clone(), invoke);
    }

    private static byte[] Raw(string value) => JsonSerializer.SerializeToUtf8Bytes(new { value });
}
