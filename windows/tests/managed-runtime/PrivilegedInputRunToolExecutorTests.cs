using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Planning;
using OpenBurnBar.App.ManagedAgentRuntime.Run;
using OpenBurnBar.App.PrivilegedInput;
using OpenBurnBar.ComputerUse.Core.Audit;
using OpenBurnBar.ComputerUse.Core.Crypto;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.Loop;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class PrivilegedInputRunToolExecutorTests : IDisposable
{
    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "obb-input-executor-" + Guid.NewGuid().ToString("N"));
    private readonly DateTimeOffset _now = new(2026, 7, 14, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public async Task ApprovedTypeDispatchesAndRedactsTypedTextFromAudit()
    {
        var dispatcher = new RecordingDispatcher();
        var executor = Executor(dispatcher);
        const string secret = "never-store-this-secret";

        HeadlessAgentInternalToolExecutionResult result = await executor.ExecuteAsync(
            "session-1",
            Call("call-1", BurnBarToolKind.MacInputType, new { text = secret }));

        Assert.True(result.Succeeded);
        Assert.Equal(1, dispatcher.Calls);
        Assert.Equal("approval-1", dispatcher.LastApprovalId);
        Assert.Equal("call-1", dispatcher.LastActionId);
        string chain = File.ReadAllText(Path.Combine(_root, "session-1", "chain.jsonl"));
        Assert.DoesNotContain(secret, chain, StringComparison.Ordinal);
        Assert.Contains("mac.input.type", chain, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ReopenedExecutorValidatesAndResumesExistingAuditChain()
    {
        var dispatcher = new RecordingDispatcher();
        Assert.True((await Executor(dispatcher).ExecuteAsync(
            "session-1",
            Call("call-1", BurnBarToolKind.MacInputKey, new { key = "Escape" }))).Succeeded);
        Assert.True((await Executor(dispatcher).ExecuteAsync(
            "session-1",
            Call("call-2", BurnBarToolKind.MacInputKey, new { key = "Enter" }))).Succeeded);

        string directory = Path.Combine(_root, "session-1");
        byte[] manifest = File.ReadAllBytes(Path.Combine(directory, "manifest.json"));
        byte[] chain = File.ReadAllBytes(Path.Combine(directory, "chain.jsonl"));
        using JsonDocument head = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(directory, "head.json")));
        string expectedHead = head.RootElement.GetProperty("hashHex").GetString()!;
        AuditChainValidationResult validation = new ComputerUseAuditChain().Validate(
            chain,
            AuditHasher.Current.Hash(manifest),
            expectedHead,
            requireExpectedHead: true);

        Assert.True(validation.IsValid);
        Assert.Equal(2, validation.EntryCount);
        Assert.Equal(2, dispatcher.Calls);
    }

    [Fact]
    public async Task InvalidArgumentsNeverReachDispatcherOrCreateAuditSession()
    {
        var dispatcher = new RecordingDispatcher();

        HeadlessAgentInternalToolExecutionResult result = await Executor(dispatcher).ExecuteAsync(
            "session-1",
            Call("call-1", BurnBarToolKind.MacInputClick, new { displayX = "bad", displayY = 2 }));

        Assert.False(result.Succeeded);
        Assert.Equal(0, dispatcher.Calls);
        Assert.False(Directory.Exists(Path.Combine(_root, "session-1")));
    }

    [Fact]
    public async Task MissingApprovalFailsClosedBeforeAuditOrDispatch()
    {
        var dispatcher = new RecordingDispatcher();
        HeadlessAgentToolCall call = Call(
            "call-1",
            BurnBarToolKind.MacInputPointerMove,
            new { displayX = 1, displayY = 2 }) with { ApprovalId = null };

        HeadlessAgentInternalToolExecutionResult result = await Executor(dispatcher)
            .ExecuteAsync("session-1", call);

        Assert.False(result.Succeeded);
        Assert.Equal(BurnBarToolExecutionErrorCode.TrustGated, result.Error!.Code);
        Assert.Equal(0, dispatcher.Calls);
    }

    [Fact]
    public async Task PanicIsAppendedToEveryActiveSession()
    {
        var dispatcher = new RecordingDispatcher();
        var executor = Executor(dispatcher);
        Assert.True((await executor.ExecuteAsync(
            "session-1",
            Call("call-1", BurnBarToolKind.MacInputKey, new { key = "Escape" }))).Succeeded);

        await executor.RecordPanicAsync(ComputerUsePanicSource.Hotkey);

        string chain = File.ReadAllText(Path.Combine(_root, "session-1", "chain.jsonl"));
        Assert.Contains("\"approvedBy\":\"panic\"", chain, StringComparison.Ordinal);
        Assert.Contains("\"denyReason\":\"hotkey\"", chain, StringComparison.Ordinal);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    private PrivilegedInputRunToolExecutor Executor(RecordingDispatcher dispatcher) =>
        new(dispatcher, _root, "windows-local-test", "1.0.0", () => _now);

    private HeadlessAgentToolCall Call(string callId, BurnBarToolKind tool, object arguments) =>
        new(
            callId,
            "run-1",
            tool,
            JsonSerializer.SerializeToElement(arguments),
            BurnBarToolCallStatus.Running,
            "test",
            _now,
            ApprovalId: "approval-1");

    private sealed class RecordingDispatcher : IPrivilegedInputDispatcher
    {
        public int Calls { get; private set; }
        public string? LastApprovalId { get; private set; }
        public string? LastActionId { get; private set; }

        public Task<PrivilegedInputResponse> DispatchAsync(
            string sessionId,
            string approvalId,
            string actionId,
            MacInputAction action,
            int timeoutMilliseconds = 5_000,
            CancellationToken cancellationToken = default)
        {
            Calls++;
            LastApprovalId = approvalId;
            LastActionId = actionId;
            return Task.FromResult(new PrivilegedInputResponse(true, "dispatched"));
        }
    }
}
