using System;
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

public sealed class CompanionCliPlannerHandlerTests
{
    [Fact]
    public async Task PlanAsync_SerializesMacCompatibleWireNamesWithoutExecutingTools()
    {
        var handler = new CompanionCliPlannerHandler(new BurnBarPlannerService());
        using JsonDocument request = JsonDocument.Parse("""
            {"prompt":"run npm test","metadata":{"activeFilePath":"app/src/example.ts"}}
            """);

        object? result = await handler.PlanAsync(request.RootElement, CancellationToken.None);
        string wire = JsonSerializer.Serialize(result);

        Assert.Contains("\"kind\":\"run_terminal\"", wire, StringComparison.Ordinal);
        Assert.Contains("\"requestedTools\":[\"run_terminal\"]", wire, StringComparison.Ordinal);
        Assert.Contains("\"riskLevel\":\"low\"", wire, StringComparison.Ordinal);
        Assert.Contains("\"status\":\"pending\"", wire, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Server_PlansOverAuthenticatedLoopback()
    {
        var handler = new CompanionCliPlannerHandler(new BurnBarPlannerService());
        var router = new CompanionCliCommandRouter(plan: handler.PlanAsync);
        await using var server = new CompanionCliServer(0, router, "planner-token");
        server.Start();

        var client = new CompanionCliClient(
            new CompanionCliClientOptions(server.Port),
            () => "planner-token");
        using JsonDocument request = JsonDocument.Parse(
            "{\"op\":\"planner.plan\",\"prompt\":\"search for PlannerService\"}");
        JsonElement response = await client.ExchangeAsync(request.RootElement);
        string line = response.GetRawText();

        Assert.Contains("inspect_workspace", line, StringComparison.Ordinal);
        Assert.Contains("Search the workspace", line, StringComparison.Ordinal);
        Assert.DoesNotContain("planner-token", line, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Router_ReturnsFailClosedPlannerValidationErrorWithoutDroppingClient()
    {
        var handler = new CompanionCliPlannerHandler(new BurnBarPlannerService());
        var router = new CompanionCliCommandRouter(plan: handler.PlanAsync);

        string response = await router.HandleAsync(
            "{\"op\":\"planner.plan\",\"prompt\":\"run tests\",\"metadata\":{\"workspaceWorkflow\":{\"type\":\"unsupported\",\"path\":\"a\",\"from\":\"b\",\"to\":\"c\"}}}",
            CancellationToken.None);

        Assert.Contains("\"ok\":false", response, StringComparison.Ordinal);
        Assert.Contains("\"error\":\"unsupported_workflow\"", response, StringComparison.Ordinal);
        Assert.DoesNotContain("run tests", response, StringComparison.Ordinal);
    }
}
