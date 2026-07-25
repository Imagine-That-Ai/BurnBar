using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Planning;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class BurnBarPolicyEngineTests
{
    private readonly BurnBarPolicyEngine _policy = new();
    private readonly BurnBarAgentIntent _intent = new(
        BurnBarAgentIntentKind.RunTerminal,
        "Run tests",
        "Execute terminal command",
        TerminalCommand: new BurnBarTerminalCommandIntent("npm test"),
        RequestedTools: new[] { BurnBarToolKind.RunTerminal });

    public static IEnumerable<object[]> RiskCases()
    {
        yield return new object[] { null!, BurnBarToolRisk.Low };
        yield return new object[] { BurnBarToolKind.ReadFile, BurnBarToolRisk.Low };
        yield return new object[] { BurnBarToolKind.SearchWorkspace, BurnBarToolRisk.Low };
        yield return new object[] { BurnBarToolKind.ApplyPatch, BurnBarToolRisk.Medium };
        foreach (BurnBarToolKind tool in Enum.GetValues<BurnBarToolKind>())
        {
            if (tool is not (BurnBarToolKind.ReadFile or BurnBarToolKind.SearchWorkspace or BurnBarToolKind.ApplyPatch))
            {
                yield return new object[] { tool, BurnBarToolRisk.High };
            }
        }
    }

    [Theory]
    [MemberData(nameof(RiskCases))]
    public void Risk_MatchesMacToolMatrix(BurnBarToolKind? tool, BurnBarToolRisk expected)
    {
        Assert.Equal(expected, _policy.Risk(tool));
        Assert.Equal(expected != BurnBarToolRisk.Low, _policy.ShouldHonorModelRequestedApproval(tool));
    }

    [Fact]
    public void ApprovalDescriptor_RequiresExplicitApprovalAndUsesLastRequestedTool()
    {
        Assert.Null(_policy.ApprovalDescriptor(false, _intent));

        BurnBarApprovalDescriptor approval = Assert.IsType<BurnBarApprovalDescriptor>(
            _policy.ApprovalDescriptor(true, _intent));

        Assert.Equal(BurnBarToolKind.RunTerminal, approval.Tool);
        Assert.Equal(BurnBarToolRisk.High, approval.Risk);
        Assert.Equal("Approve run_terminal", approval.Title);
        Assert.Contains("terminal commands", approval.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ApprovalDescriptor_EmptyRequestedToolsFallsBackToPatchAndHonorsCustomCopy()
    {
        var intent = new BurnBarAgentIntent(
            BurnBarAgentIntentKind.Generic,
            "Work",
            "Do work",
            RequestedTools: Array.Empty<BurnBarToolKind>());

        BurnBarApprovalDescriptor fallback = Assert.IsType<BurnBarApprovalDescriptor>(
            _policy.ApprovalDescriptor(true, intent));
        BurnBarApprovalDescriptor custom = Assert.IsType<BurnBarApprovalDescriptor>(
            _policy.ApprovalDescriptor(true, intent, BurnBarToolKind.BrowserClick, "Custom", "Message"));

        Assert.Equal(BurnBarToolKind.ApplyPatch, fallback.Tool);
        Assert.Equal(BurnBarToolRisk.Medium, fallback.Risk);
        Assert.Equal("Custom", custom.Title);
        Assert.Equal("Message", custom.Message);
    }

    [Theory]
    [InlineData(BurnBarToolExecutionErrorCode.TrustGated, true)]
    [InlineData(BurnBarToolExecutionErrorCode.NoWorkspace, true)]
    [InlineData(BurnBarToolExecutionErrorCode.RemoteUnsupported, true)]
    [InlineData(BurnBarToolExecutionErrorCode.ApplyFailed, true)]
    [InlineData(BurnBarToolExecutionErrorCode.TerminalFailed, false)]
    [InlineData(BurnBarToolExecutionErrorCode.Unknown, false)]
    public void IsRetryable_MatchesMacErrorMatrix(BurnBarToolExecutionErrorCode code, bool expected) =>
        Assert.Equal(expected, _policy.IsRetryable(code));

    [Theory]
    [InlineData(BurnBarToolKind.ReadFile, BurnBarToolCallStatus.Completed, true, true)]
    [InlineData(BurnBarToolKind.ReadFile, BurnBarToolCallStatus.Completed, false, false)]
    [InlineData(BurnBarToolKind.SearchWorkspace, BurnBarToolCallStatus.Running, true, false)]
    [InlineData(BurnBarToolKind.ApplyPatch, BurnBarToolCallStatus.Completed, false, true)]
    [InlineData(BurnBarToolKind.RunTerminal, BurnBarToolCallStatus.Failed, true, false)]
    public void IndicatesProgress_MatchesMacStatusAndOutputRules(
        BurnBarToolKind tool,
        BurnBarToolCallStatus status,
        bool hasOutput,
        bool expected) =>
        Assert.Equal(expected, _policy.IndicatesProgress(tool, status, hasOutput));

    [Fact]
    public async Task PolicyHandler_ExposesCompleteDecisionWithoutExecutingTool()
    {
        var handler = new CompanionCliPolicyHandler(new BurnBarPlannerService(), _policy);
        using JsonDocument request = JsonDocument.Parse("""
            {
              "intent":{"kind":"run_terminal","objective":"Run tests","summary":"Execute terminal command","requestedTools":["run_terminal"]},
              "tool":"run_terminal",
              "explicitApprovalRequired":true,
              "errorCode":"terminal_failed",
              "toolCall":{"tool":"run_terminal","status":"completed","hasOutput":false}
            }
            """);

        object? result = await handler.EvaluateAsync(request.RootElement, CancellationToken.None);
        string wire = JsonSerializer.Serialize(result);

        Assert.Contains("\"risk\":\"high\"", wire, StringComparison.Ordinal);
        Assert.Contains("\"shouldHonorModelRequestedApproval\":true", wire, StringComparison.Ordinal);
        Assert.Contains("\"tool\":\"run_terminal\"", wire, StringComparison.Ordinal);
        Assert.Contains("\"retryable\":false", wire, StringComparison.Ordinal);
        Assert.Contains("\"indicatesProgress\":true", wire, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Server_EvaluatesPolicyOverAuthenticatedLoopback()
    {
        var handler = new CompanionCliPolicyHandler(new BurnBarPlannerService(), _policy);
        var router = new CompanionCliCommandRouter(policy: handler.EvaluateAsync);
        await using var server = new CompanionCliServer(0, router, "policy-token");
        server.Start();

        var client = new CompanionCliClient(
            new CompanionCliClientOptions(server.Port),
            () => "policy-token");
        using JsonDocument request = JsonDocument.Parse(
            "{\"op\":\"policy.evaluate\",\"intent\":{\"kind\":\"generic\",\"objective\":\"Inspect\",\"summary\":\"Inspect\"},\"tool\":\"read_file\",\"explicitApprovalRequired\":true}");
        JsonElement response = await client.ExchangeAsync(request.RootElement);
        string line = response.GetRawText();

        Assert.Contains("\"risk\":\"low\"", line, StringComparison.Ordinal);
        Assert.Contains("Approve read_file", line, StringComparison.Ordinal);
        Assert.DoesNotContain("policy-token", line, StringComparison.Ordinal);
    }
}
