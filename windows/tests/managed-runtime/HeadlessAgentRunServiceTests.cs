using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Planning;
using OpenBurnBar.App.ManagedAgentRuntime.Run;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class HeadlessAgentRunServiceTests
{
    [Fact]
    public async Task GenericLoop_ClaimsLowRiskToolAndCompletesFromResult()
    {
        var responses = new ConcurrentQueue<ModelCompletionResult>(new[]
        {
            Completion("""{"action":"read_file","rationale":"Inspect it","arguments":{"path":"src/app.cs"}}"""),
            Completion("""{"action":"complete","rationale":"Verified","message":"done"}"""),
        });
        var journal = new TestJournal();
        await using HeadlessAgentRunService service = CreateService(journal, responses);
        await service.StartAsync();

        await service.SubmitAsync(Request("run-read", metadata: GenericMetadata("secret objective")));
        HeadlessAgentRunDetail waiting = await WaitForPhaseAsync(service, "run-read", HeadlessAgentRunPhase.WaitingOnCompanion);
        Assert.Equal(BurnBarToolKind.ReadFile, waiting.PendingToolCall?.Tool);

        HeadlessAgentToolClaimResponse claim = await service.ClaimToolAsync("run-read", "client", "session");
        Assert.Equal(HeadlessAgentToolDisposition.Dispatched, claim.Disposition);
        Assert.NotNull(claim.ToolCall);
        await service.SubmitToolResultAsync(new HeadlessAgentToolResultSubmission(
            "client",
            "session",
            "run-read",
            claim.ToolCall!.CallId,
            true,
            JsonSerializer.SerializeToElement(new { path = "src/app.cs", content = "private secret file content" }),
            null,
            DateTimeOffset.UtcNow));

        HeadlessAgentRunDetail completed = await WaitForPhaseAsync(service, "run-read", HeadlessAgentRunPhase.Completed);
        Assert.Equal(2, completed.LoopState.IterationCount);
        Assert.DoesNotContain(journal.Entries, entry => entry.Error?.Contains("secret", StringComparison.Ordinal) == true);
        Assert.All(journal.Entries, entry => Assert.Matches("^[a-z_]+$", entry.StepId ?? string.Empty));
    }

    [Fact]
    public async Task RiskyTool_RequiresApprovalAndCannotSubmitBeforeClaim()
    {
        var responses = new ConcurrentQueue<ModelCompletionResult>(new[]
        {
            Completion("""{"action":"apply_patch","rationale":"Edit","arguments":{"changes":[{"path":"a.txt","content":"new"}]}}"""),
            Completion("""{"action":"complete","rationale":"Done"}"""),
        });
        await using HeadlessAgentRunService service = CreateService(new TestJournal(), responses);
        await service.StartAsync();
        await service.SubmitAsync(Request("run-approval", metadata: GenericMetadata("edit")));

        HeadlessAgentRunDetail awaiting = await WaitForPhaseAsync(service, "run-approval", HeadlessAgentRunPhase.AwaitingApproval);
        Assert.Equal(BurnBarToolKind.ApplyPatch, awaiting.ApprovalRequest?.Tool);
        HeadlessAgentRunDetail queued = await service.RespondToApprovalAsync(new HeadlessAgentApprovalResponse(
            "run-approval",
            awaiting.ApprovalRequest!.ApprovalId,
            "client",
            HeadlessAgentApprovalDecision.Approve,
            null,
            DateTimeOffset.UtcNow));
        Assert.Equal(HeadlessAgentRunPhase.WaitingOnCompanion, queued.Run.Phase);
        Assert.Equal(awaiting.ApprovalRequest.ApprovalId, queued.PendingToolCall?.ApprovalId);

        HeadlessAgentRunException unclaimed = await Assert.ThrowsAsync<HeadlessAgentRunException>(() =>
            service.SubmitToolResultAsync(new HeadlessAgentToolResultSubmission(
                "client", "session", "run-approval", queued.PendingToolCall!.CallId, true,
                JsonSerializer.SerializeToElement(new { changed = true }), null, DateTimeOffset.UtcNow)));
        Assert.Equal("tool_not_claimed", unclaimed.Code);

        HeadlessAgentToolClaimResponse claim = await service.ClaimToolAsync("run-approval", "client", "session");
        await service.SubmitToolResultAsync(new HeadlessAgentToolResultSubmission(
            "client", "session", "run-approval", claim.ToolCall!.CallId, true,
            JsonSerializer.SerializeToElement(new { changed = true }), null, DateTimeOffset.UtcNow));
        await WaitForPhaseAsync(service, "run-approval", HeadlessAgentRunPhase.Completed);
    }

    [Fact]
    public async Task RunLevelApproval_DoesNotAuthorizeAnyRiskyTool()
    {
        var responses = new ConcurrentQueue<ModelCompletionResult>(new[]
        {
            Completion("""{"action":"apply_patch","rationale":"First","arguments":{"changes":[{"path":"a","content":"b"}]}}"""),
            Completion("""{"action":"run_terminal","rationale":"Second","arguments":{"command":"dotnet test"}}"""),
        });
        await using HeadlessAgentRunService service = CreateService(new TestJournal(), responses);
        await service.StartAsync();
        await service.SubmitAsync(Request("run-one-shot", requiresApproval: true, metadata: GenericMetadata("two tools")));

        HeadlessAgentRunDetail runApproval = await WaitForPhaseAsync(service, "run-one-shot", HeadlessAgentRunPhase.AwaitingApproval);
        await service.RespondToApprovalAsync(new HeadlessAgentApprovalResponse(
            "run-one-shot", runApproval.ApprovalRequest!.ApprovalId, "client",
            HeadlessAgentApprovalDecision.Approve, null, DateTimeOffset.UtcNow));
        HeadlessAgentRunDetail firstApproval = await WaitForPhaseAsync(
            service,
            "run-one-shot",
            HeadlessAgentRunPhase.AwaitingApproval);
        Assert.Equal(BurnBarToolKind.ApplyPatch, firstApproval.ApprovalRequest?.Tool);
        Assert.NotEqual(runApproval.ApprovalRequest!.ApprovalId, firstApproval.ApprovalRequest!.ApprovalId);
        HeadlessAgentRunDetail firstTool = await service.RespondToApprovalAsync(new HeadlessAgentApprovalResponse(
            "run-one-shot", firstApproval.ApprovalRequest.ApprovalId, "client",
            HeadlessAgentApprovalDecision.Approve, null, DateTimeOffset.UtcNow));
        Assert.Equal(HeadlessAgentRunPhase.WaitingOnCompanion, firstTool.Run.Phase);
        Assert.Equal(firstApproval.ApprovalRequest.ApprovalId, firstTool.PendingToolCall?.ApprovalId);

        HeadlessAgentToolClaimResponse claim = await service.ClaimToolAsync("run-one-shot", "client", "session");
        await service.SubmitToolResultAsync(new HeadlessAgentToolResultSubmission(
            "client", "session", "run-one-shot", claim.ToolCall!.CallId, true,
            JsonSerializer.SerializeToElement(new { changed = true }), null, DateTimeOffset.UtcNow));
        HeadlessAgentRunDetail secondApproval = await WaitForPhaseAsync(
            service,
            "run-one-shot",
            HeadlessAgentRunPhase.AwaitingApproval);
        Assert.Equal(BurnBarToolKind.RunTerminal, secondApproval.ApprovalRequest?.Tool);
    }

    [Fact]
    public async Task ModelRequestedApproval_CannotAuthorizeDifferentRiskyTool()
    {
        var responses = new ConcurrentQueue<ModelCompletionResult>(new[]
        {
            Completion("""{"action":"request_approval","requestedTool":"apply_patch","rationale":"Approve a patch"}"""),
            Completion("""{"action":"run_terminal","rationale":"Swap the action","arguments":{"command":"whoami"}}"""),
        });
        await using HeadlessAgentRunService service = CreateService(new TestJournal(), responses);
        await service.StartAsync();
        await service.SubmitAsync(Request("run-model-swap", metadata: GenericMetadata("test exact approval")));

        HeadlessAgentRunDetail displayed = await WaitForPhaseAsync(
            service,
            "run-model-swap",
            HeadlessAgentRunPhase.AwaitingApproval);
        Assert.Equal(BurnBarToolKind.ApplyPatch, displayed.ApprovalRequest?.Tool);
        await service.RespondToApprovalAsync(new HeadlessAgentApprovalResponse(
            "run-model-swap", displayed.ApprovalRequest!.ApprovalId, "client",
            HeadlessAgentApprovalDecision.Approve, null, DateTimeOffset.UtcNow));

        HeadlessAgentRunDetail rebound = await WaitForPhaseAsync(
            service,
            "run-model-swap",
            HeadlessAgentRunPhase.AwaitingApproval);
        Assert.Equal(BurnBarToolKind.RunTerminal, rebound.ApprovalRequest?.Tool);
        Assert.NotEqual(displayed.ApprovalRequest.ApprovalId, rebound.ApprovalRequest!.ApprovalId);
        Assert.Null(rebound.PendingToolCall);
    }

    [Fact]
    public async Task ApprovedDesktopInputExecutesInternallyAndCompletesDurableRun()
    {
        var responses = new ConcurrentQueue<ModelCompletionResult>(new[]
        {
            Completion("""{"action":"complete","rationale":"Input complete","message":"done"}"""),
        });
        await using HeadlessAgentRunService service = CreateService(new TestJournal(), responses);
        await service.StartAsync();
        JsonElement metadata = JsonSerializer.SerializeToElement(new
        {
            agentIntent = new
            {
                kind = "generic",
                objective = "type approved text",
                summary = "Type into the active application.",
                requestedTools = new[] { "mac_input_type" },
                toolArguments = new { text = "approved text" },
            },
        });
        await service.SubmitAsync(Request("run-internal-input", metadata: metadata));
        HeadlessAgentRunDetail awaiting = await WaitForPhaseAsync(
            service,
            "run-internal-input",
            HeadlessAgentRunPhase.AwaitingApproval);
        string approvalId = awaiting.ApprovalRequest!.ApprovalId;
        await service.RespondToApprovalAsync(new HeadlessAgentApprovalResponse(
            "run-internal-input",
            approvalId,
            "client",
            HeadlessAgentApprovalDecision.Approve,
            null,
            DateTimeOffset.UtcNow));
        await WaitForPhaseAsync(service, "run-internal-input", HeadlessAgentRunPhase.WaitingOnCompanion);
        var internalTools = new RecordingInternalToolExecutor();
        var handler = new CompanionCliAgentRunHandler(service, internalTools);

        object? wire = await handler.ClaimToolAsync(
            JsonSerializer.SerializeToElement(new
            {
                runId = "run-internal-input",
                clientId = "client",
                sessionId = "session",
            }),
            CancellationToken.None);

        JsonElement response = JsonSerializer.SerializeToElement(wire);
        Assert.Equal("executed_in_process", response.GetProperty("disposition").GetString());
        Assert.Equal(1, internalTools.Calls);
        Assert.Equal(approvalId, internalTools.ApprovalId);
        Assert.Equal(BurnBarToolKind.MacInputType, internalTools.Tool);
        HeadlessAgentRunDetail completed = await WaitForPhaseAsync(
            service,
            "run-internal-input",
            HeadlessAgentRunPhase.Completed);
        Assert.Equal(HeadlessAgentRunPhase.Completed, completed.Run.Phase);
    }

    [Fact]
    public async Task ProviderFailure_FailsOverExactModelAndRecordsBothAttempts()
    {
        var calls = new ConcurrentQueue<string>();
        var routes = new[]
        {
            Route("route-a", 0),
            Route("route-b", 1),
        };
        var router = new ModelProxyRouter(routes);
        var executor = new DelegateModelCompletionExecutor((route, _, _) =>
        {
            calls.Enqueue(route.Id);
            return Task.FromResult(route.Id == "route-a"
                ? new ModelCompletionResult(502, Array.Empty<byte>(), "application/json", false)
                : Completion("""{"action":"complete","rationale":"Recovered"}"""));
        });
        await using var service = new HeadlessAgentRunService(
            router,
            executor,
            new TestJournal(),
            new InMemoryHeadlessAgentCheckpointStore());
        await service.StartAsync();

        await service.SubmitAsync(Request("run-failover", metadata: GenericMetadata("finish")));
        await WaitForPhaseAsync(service, "run-failover", HeadlessAgentRunPhase.Completed);
        Assert.Equal(new[] { "route-a", "route-b" }, calls.ToArray());
        Assert.Equal(2, router.TelemetryStore.Snapshot().RetainedRequests);
        Assert.Equal(1, router.TelemetryStore.Snapshot().Failures);
    }

    [Fact]
    public async Task InvalidDecision_UsesOneRepairAttempt()
    {
        int calls = 0;
        var executor = new DelegateModelCompletionExecutor((_, _, _) =>
        {
            calls++;
            return Task.FromResult(calls == 1
                ? Completion("not json")
                : Completion("""prefix {"action":"complete","rationale":"A } inside string is valid"} suffix"""));
        });
        var router = new ModelProxyRouter(new[] { Route("route", 0) });
        await using var service = new HeadlessAgentRunService(
            router, executor, new TestJournal(), new InMemoryHeadlessAgentCheckpointStore());
        await service.StartAsync();

        await service.SubmitAsync(Request("run-repair", metadata: GenericMetadata("repair")));
        await WaitForPhaseAsync(service, "run-repair", HeadlessAgentRunPhase.Completed);
        Assert.Equal(2, calls);
        Assert.Equal(2, router.TelemetryStore.Snapshot().RetainedRequests);
    }

    [Fact]
    public async Task Restart_RestoresPendingToolAndDuplicateResultIsIdempotent()
    {
        var checkpointStore = new InMemoryHeadlessAgentCheckpointStore();
        var journal = new TestJournal();
        var responses = new ConcurrentQueue<ModelCompletionResult>(new[]
        {
            Completion("""{"action":"read_file","rationale":"Read","arguments":{"path":"a.txt"}}"""),
        });
        HeadlessAgentRunService first = CreateService(journal, responses, checkpointStore);
        await first.StartAsync();
        await first.SubmitAsync(Request("run-restart", metadata: GenericMetadata("read")));
        HeadlessAgentRunDetail before = await WaitForPhaseAsync(first, "run-restart", HeadlessAgentRunPhase.WaitingOnCompanion);
        await first.DisposeAsync();

        var resumedResponses = new ConcurrentQueue<ModelCompletionResult>(new[]
        {
            Completion("""{"action":"complete","rationale":"Done"}"""),
        });
        await using HeadlessAgentRunService second = CreateService(journal, resumedResponses, checkpointStore);
        await second.StartAsync();
        HeadlessAgentRunDetail restored = await second.GetAsync("run-restart", "client");
        Assert.Equal(before.PendingToolCall?.CallId, restored.PendingToolCall?.CallId);

        HeadlessAgentToolClaimResponse claim = await second.ClaimToolAsync("run-restart", "client", "session");
        var result = new HeadlessAgentToolResultSubmission(
            "client", "session", "run-restart", claim.ToolCall!.CallId, true,
            JsonSerializer.SerializeToElement(new { path = "a.txt", content = "content" }), null,
            DateTimeOffset.UtcNow);
        await second.SubmitToolResultAsync(result);
        await WaitForPhaseAsync(second, "run-restart", HeadlessAgentRunPhase.Completed);
        HeadlessAgentRunDetail duplicate = await second.SubmitToolResultAsync(result);
        Assert.Equal(HeadlessAgentRunPhase.Completed, duplicate.Run.Phase);
    }

    [Fact]
    public async Task FailedApply_RetriesOnceThenFailsClosed()
    {
        var metadata = JsonSerializer.SerializeToElement(new
        {
            workspaceWorkflow = new
            {
                type = "replace_string_in_file",
                path = "a.txt",
                from = "old",
                to = "new",
            },
        });
        await using HeadlessAgentRunService service = CreateService(
            new TestJournal(),
            new ConcurrentQueue<ModelCompletionResult>());
        await service.StartAsync();
        await service.SubmitAsync(Request("run-retry", metadata: metadata));

        HeadlessAgentRunDetail read = await WaitForPhaseAsync(service, "run-retry", HeadlessAgentRunPhase.WaitingOnCompanion);
        await CompleteClaimedToolAsync(service, read, JsonSerializer.SerializeToElement(new { path = "a.txt", content = "old" }));
        HeadlessAgentRunDetail approval = await WaitForPhaseAsync(service, "run-retry", HeadlessAgentRunPhase.AwaitingApproval);
        await service.RespondToApprovalAsync(new HeadlessAgentApprovalResponse(
            "run-retry", approval.ApprovalRequest!.ApprovalId, "client",
            HeadlessAgentApprovalDecision.Approve, null, DateTimeOffset.UtcNow));
        HeadlessAgentRunDetail apply = await WaitForPhaseAsync(service, "run-retry", HeadlessAgentRunPhase.WaitingOnCompanion);
        await FailClaimedToolAsync(service, apply, BurnBarToolExecutionErrorCode.ApplyFailed);

        HeadlessAgentRunDetail retryApproval = await WaitForPhaseAsync(service, "run-retry", HeadlessAgentRunPhase.AwaitingApproval);
        await service.RespondToApprovalAsync(new HeadlessAgentApprovalResponse(
            "run-retry", retryApproval.ApprovalRequest!.ApprovalId, "client",
            HeadlessAgentApprovalDecision.Approve, null, DateTimeOffset.UtcNow));
        HeadlessAgentRunDetail retriedApply = await WaitForPhaseAsync(service, "run-retry", HeadlessAgentRunPhase.WaitingOnCompanion);
        await FailClaimedToolAsync(service, retriedApply, BurnBarToolExecutionErrorCode.ApplyFailed);
        HeadlessAgentRunDetail failed = await WaitForPhaseAsync(service, "run-retry", HeadlessAgentRunPhase.Failed);
        Assert.Equal("simulated failure", failed.Run.ErrorMessage);
        Assert.Null(failed.PendingToolCall);
    }

    [Fact]
    public async Task Replacement_RejectsAmbiguousSourceWithoutQueuingWrite()
    {
        var metadata = JsonSerializer.SerializeToElement(new
        {
            workspaceWorkflow = new
            {
                type = "replace_string_in_file",
                path = "a.txt",
                from = "old",
                to = "new",
            },
        });
        await using HeadlessAgentRunService service = CreateService(
            new TestJournal(),
            new ConcurrentQueue<ModelCompletionResult>());
        await service.StartAsync();
        await service.SubmitAsync(Request("run-ambiguous", metadata: metadata));
        HeadlessAgentRunDetail read = await WaitForPhaseAsync(service, "run-ambiguous", HeadlessAgentRunPhase.WaitingOnCompanion);
        await CompleteClaimedToolAsync(
            service,
            read,
            JsonSerializer.SerializeToElement(new { path = "a.txt", content = "old and old" }));

        HeadlessAgentRunDetail failed = await WaitForPhaseAsync(service, "run-ambiguous", HeadlessAgentRunPhase.Failed);
        Assert.Contains("more than once", failed.Run.ErrorMessage, StringComparison.Ordinal);
        Assert.Null(failed.PendingToolCall);
    }

    [Fact]
    public void CheckpointCodec_RejectsWindowsUnsafeRunIdOnEveryHost()
    {
        Assert.Throws<ArgumentException>(() => HeadlessAgentCheckpointCodec.ValidateRunId("bad:run"));
        Assert.Throws<ArgumentException>(() => HeadlessAgentCheckpointCodec.ValidateRunId("bad\\run"));
        Assert.Throws<ArgumentException>(() => HeadlessAgentCheckpointCodec.ValidateRunId("bad\nrun"));
    }

    [Theory]
    [InlineData("intent")]
    [InlineData("planOutline")]
    [InlineData("loopState")]
    public void CheckpointCodec_RejectsMissingNestedState(string propertyName)
    {
        JsonElement metadata = GenericMetadata("validate");
        BurnBarPlannedRun plan = new BurnBarPlannerService().PlanRaw("validate", metadata);
        var checkpoint = new HeadlessAgentRunCheckpoint(
            "run-nested",
            "client",
            "session",
            HeadlessAgentRunPhase.Planning,
            "test-model",
            "validate",
            metadata,
            false,
            false,
            plan.Intent,
            plan.Outline,
            1,
            null,
            null,
            false,
            null,
            null,
            null,
            0,
            null,
            false,
            null,
            HeadlessAgentLoopState.Empty,
            DateTimeOffset.UtcNow);
        JsonObject encoded = Assert.IsType<JsonObject>(JsonNode.Parse(HeadlessAgentCheckpointCodec.Serialize(checkpoint)));
        encoded[propertyName] = null;

        Assert.Throws<InvalidDataException>(() =>
            HeadlessAgentCheckpointCodec.Deserialize("run-nested", Encoding.UTF8.GetBytes(encoded.ToJsonString())));
    }

    [Fact]
    public async Task ModelRequestedLowRiskApproval_FailsClosed()
    {
        var responses = new ConcurrentQueue<ModelCompletionResult>(new[]
        {
            Completion("""{"action":"request_approval","requestedTool":"read_file","rationale":"Pause"}"""),
        });
        await using HeadlessAgentRunService service = CreateService(new TestJournal(), responses);
        await service.StartAsync();
        await service.SubmitAsync(Request("run-low-risk-approval", metadata: GenericMetadata("inspect")));

        HeadlessAgentRunDetail failed = await WaitForPhaseAsync(
            service,
            "run-low-risk-approval",
            HeadlessAgentRunPhase.Failed);
        Assert.Contains("low-risk", failed.Run.ErrorMessage, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AgentLoop_StopsAtConfiguredIterationLimit()
    {
        int calls = 0;
        var router = new ModelProxyRouter(new[] { Route("route", 0) });
        var executor = new DelegateModelCompletionExecutor((_, _, _) =>
        {
            calls++;
            return Task.FromResult(Completion(
                "{\"action\":\"read_file\",\"rationale\":\"Again\",\"arguments\":{\"path\":\"a.txt\"}}"));
        });
        await using var service = new HeadlessAgentRunService(
            router,
            executor,
            new TestJournal(),
            new InMemoryHeadlessAgentCheckpointStore(),
            loop: new HeadlessAgentLoopService(maximumIterations: 1));
        await service.StartAsync();
        await service.SubmitAsync(Request("run-limit", metadata: GenericMetadata("loop")));
        HeadlessAgentRunDetail tool = await WaitForPhaseAsync(service, "run-limit", HeadlessAgentRunPhase.WaitingOnCompanion);
        await CompleteClaimedToolAsync(
            service,
            tool,
            JsonSerializer.SerializeToElement(new { path = "a.txt", content = "content" }));

        HeadlessAgentRunDetail failed = await WaitForPhaseAsync(service, "run-limit", HeadlessAgentRunPhase.Failed);
        Assert.Contains("exceeded 1", failed.Run.ErrorMessage, StringComparison.Ordinal);
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task JsonJournal_NeverPersistsPromptOrToolContent()
    {
        string path = Path.Combine(Path.GetTempPath(), $"obb-agent-journal-{Guid.NewGuid():N}.jsonl");
        try
        {
            var responses = new ConcurrentQueue<ModelCompletionResult>(new[]
            {
                Completion("""{"action":"complete","rationale":"Done"}"""),
            });
            await using HeadlessAgentRunService service = CreateService(
                new JsonLinesHeadlessRunJournal(path),
                responses);
            await service.StartAsync();
            await service.SubmitAsync(new HeadlessAgentRunRequest(
                "run-journal",
                "client",
                "session",
                "super-secret-prompt-value",
                "test-model",
                Metadata: GenericMetadata("another-secret")));
            await WaitForPhaseAsync(service, "run-journal", HeadlessAgentRunPhase.Completed);

            string journal = await File.ReadAllTextAsync(path);
            Assert.DoesNotContain("super-secret", journal, StringComparison.Ordinal);
            Assert.DoesNotContain("another-secret", journal, StringComparison.Ordinal);
            Assert.Contains("run_completed", journal, StringComparison.Ordinal);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task Startup_RejectsCorruptProtectedCheckpointWithoutStartingWork()
    {
        var journal = new TestJournal();
        await journal.AppendAsync(new HeadlessRunJournalEntry(
            "run-corrupt",
            HeadlessRunState.Running,
            "model_started",
            null,
            DateTimeOffset.UtcNow));
        var router = new ModelProxyRouter(new[] { Route("route", 0) });
        await using var service = new HeadlessAgentRunService(
            router,
            new DelegateModelCompletionExecutor((_, _, _) => throw new Xunit.Sdk.XunitException("model must not run")),
            journal,
            new CorruptCheckpointStore());

        await service.StartAsync();
        HeadlessRunJournalEntry failed = Assert.Single(
            journal.Entries,
            entry => entry.State == HeadlessRunState.Failed);
        Assert.Equal("checkpoint_rejected", failed.StepId);
        Assert.Equal("checkpoint_rejected", failed.Error);
    }

    [Fact]
    public async Task Submit_RejectsOversizedMetadataBeforeCheckpointing()
    {
        await using HeadlessAgentRunService service = CreateService(
            new TestJournal(),
            new ConcurrentQueue<ModelCompletionResult>());
        await service.StartAsync();
        JsonElement metadata = JsonSerializer.SerializeToElement(new { value = new string('x', 300 * 1024) });

        HeadlessAgentRunException error = await Assert.ThrowsAsync<HeadlessAgentRunException>(() =>
            service.SubmitAsync(Request("run-large-metadata", metadata: metadata)));
        Assert.Equal("metadata_too_large", error.Code);
    }

    private static HeadlessAgentRunService CreateService(
        IHeadlessRunJournal journal,
        ConcurrentQueue<ModelCompletionResult> responses,
        IHeadlessAgentCheckpointStore? checkpoints = null)
    {
        var router = new ModelProxyRouter(new[] { Route("route", 0) });
        var executor = new DelegateModelCompletionExecutor((_, _, _) =>
        {
            if (!responses.TryDequeue(out ModelCompletionResult response))
            {
                return Task.FromResult(new ModelCompletionResult(503, Array.Empty<byte>(), "application/json", false));
            }
            return Task.FromResult(response);
        });
        return new HeadlessAgentRunService(
            router,
            executor,
            journal,
            checkpoints ?? new InMemoryHeadlessAgentCheckpointStore());
    }

    private static HeadlessAgentRunRequest Request(
        string runId,
        bool requiresApproval = false,
        JsonElement? metadata = null) =>
        new(runId, "client", "session", "secret objective", "test-model", requiresApproval, metadata);

    private static JsonElement GenericMetadata(string objective) => JsonSerializer.SerializeToElement(new
    {
        agentIntent = new
        {
            kind = "generic",
            objective,
            summary = "Perform the requested work.",
        },
        candidatePaths = new[] { "src/app.cs" },
    });

    private static ModelRoute Route(string id, int priority) => new(
        id,
        "test",
        "test-model",
        priority,
        true,
        new Uri($"https://{id}.test/v1/chat/completions"));

    private static ModelCompletionResult Completion(string content)
    {
        byte[] body = JsonSerializer.SerializeToUtf8Bytes(new
        {
            choices = new[] { new { message = new { content } } },
            usage = new { prompt_tokens = 5, completion_tokens = 2 },
        });
        return new ModelCompletionResult(200, body, "application/json", true);
    }

    private static async Task<HeadlessAgentRunDetail> WaitForPhaseAsync(
        HeadlessAgentRunService service,
        string runId,
        HeadlessAgentRunPhase phase)
    {
        DateTimeOffset deadline = DateTimeOffset.UtcNow.AddSeconds(10);
        while (DateTimeOffset.UtcNow < deadline)
        {
            HeadlessAgentRunDetail detail = await service.GetAsync(runId, "client");
            if (detail.Run.Phase == phase) return detail;
            if (HeadlessAgentRunStateMachine.IsTerminal(detail.Run.Phase) && detail.Run.Phase != phase)
            {
                throw new Xunit.Sdk.XunitException(
                    $"Run entered {detail.Run.Phase} instead of {phase}: {detail.Run.ErrorMessage}");
            }
            await Task.Delay(20);
        }
        throw new TimeoutException($"Run '{runId}' did not enter {phase}.");
    }

    private static async Task CompleteClaimedToolAsync(
        HeadlessAgentRunService service,
        HeadlessAgentRunDetail detail,
        JsonElement output)
    {
        HeadlessAgentToolClaimResponse claim = await service.ClaimToolAsync(detail.Run.RunId, "client", "session");
        await service.SubmitToolResultAsync(new HeadlessAgentToolResultSubmission(
            "client", "session", detail.Run.RunId, claim.ToolCall!.CallId, true,
            output, null, DateTimeOffset.UtcNow));
    }

    private static async Task FailClaimedToolAsync(
        HeadlessAgentRunService service,
        HeadlessAgentRunDetail detail,
        BurnBarToolExecutionErrorCode code)
    {
        HeadlessAgentToolClaimResponse claim = await service.ClaimToolAsync(detail.Run.RunId, "client", "session");
        await service.SubmitToolResultAsync(new HeadlessAgentToolResultSubmission(
            "client", "session", detail.Run.RunId, claim.ToolCall!.CallId, false,
            null, new HeadlessAgentToolError(code, "simulated failure"), DateTimeOffset.UtcNow));
    }

    private sealed class TestJournal : IHeadlessRunJournal
    {
        private readonly object _gate = new();
        private readonly List<HeadlessRunJournalEntry> _entries = new();

        public IReadOnlyList<HeadlessRunJournalEntry> Entries
        {
            get
            {
                lock (_gate) return _entries.ToArray();
            }
        }

        public Task AppendAsync(HeadlessRunJournalEntry entry, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lock (_gate) _entries.Add(entry);
            return Task.CompletedTask;
        }

        public Task<IReadOnlyList<HeadlessRunJournalEntry>> ReadAllAsync(
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(Entries);
        }
    }

    private sealed class RecordingInternalToolExecutor : IHeadlessAgentInternalToolExecutor
    {
        public int Calls { get; private set; }
        public string? ApprovalId { get; private set; }
        public BurnBarToolKind? Tool { get; private set; }

        public bool CanExecute(BurnBarToolKind tool) => tool == BurnBarToolKind.MacInputType;

        public Task<HeadlessAgentInternalToolExecutionResult> ExecuteAsync(
            string sessionId,
            HeadlessAgentToolCall call,
            CancellationToken cancellationToken = default)
        {
            Calls++;
            ApprovalId = call.ApprovalId;
            Tool = call.Tool;
            return Task.FromResult(new HeadlessAgentInternalToolExecutionResult(
                true,
                JsonSerializer.SerializeToElement(new { status = "dispatched" })));
        }
    }

    private sealed class CorruptCheckpointStore : IHeadlessAgentCheckpointStore
    {
        public Task SaveAsync(HeadlessAgentRunCheckpoint checkpoint, CancellationToken cancellationToken = default) =>
            throw new InvalidDataException("corrupt");

        public Task<HeadlessAgentRunCheckpoint?> LoadAsync(
            string runId,
            CancellationToken cancellationToken = default) =>
            throw new InvalidDataException("corrupt");

        public Task DeleteAsync(string runId, CancellationToken cancellationToken = default) => Task.CompletedTask;
    }
}
