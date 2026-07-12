using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class CompanionCliServerTests
{
    [Fact]
    public void HandleLine_Ping_ReturnsPong()
    {
        string response = CompanionCliServer.HandleLine("{\"op\":\"ping\"}");
        Assert.Contains("\"pong\":true", response.Replace(" ", ""), System.StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void HandleLine_UnknownOp_FailsClosed()
    {
        string response = CompanionCliServer.HandleLine("{\"op\":\"nope\"}");
        Assert.Contains("unknown_op", response, System.StringComparison.Ordinal);
    }

    [Fact]
    public async Task Server_AcceptsClientAndAnswersVersion()
    {
        int port = 19000 + System.Environment.ProcessId % 500;
        await using var server = new CompanionCliServer(port);
        server.Start();

        using var client = new TcpClient();
        await client.ConnectAsync(System.Net.IPAddress.Loopback, port);
        await using NetworkStream stream = client.GetStream();
        using var writer = new StreamWriter(stream, Encoding.UTF8) { AutoFlush = true };
        using var reader = new StreamReader(stream, Encoding.UTF8);
        await writer.WriteLineAsync("{\"op\":\"version\"}");
        string? line = await reader.ReadLineAsync();
        Assert.NotNull(line);
        Assert.Contains("f2-companion-cli-1", line, System.StringComparison.Ordinal);
    }
}
