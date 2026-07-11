using System.Net.Http;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class LocalHttpGatewayHostTests
{
    [Fact]
    public async Task HealthEndpoint_ReturnsOkJson()
    {
        // Ephemeral port 0 is not supported by HttpListener prefix easily; pick high port.
        int port = 18765 + System.Environment.ProcessId % 1000;
        await using var host = new LocalHttpGatewayHost(port);
        host.Start();

        using var client = new HttpClient { BaseAddress = host.BaseAddress };
        string body = await client.GetStringAsync("/health");
        Assert.Contains("openburnbar-local-gateway", body, System.StringComparison.Ordinal);
        Assert.Contains("\"ok\":true", body.Replace(" ", ""), System.StringComparison.OrdinalIgnoreCase);
    }
}
