using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class CompanionCliClientTests
{
    [Fact]
    public async Task ExchangeAsync_AuthenticatesAgainstRealLoopbackServer()
    {
        await using var server = new CompanionCliServer(0, accessToken: "protected-token");
        server.Start();
        var client = new CompanionCliClient(
            new CompanionCliClientOptions(server.Port),
            () => "protected-token");
        using JsonDocument request = JsonDocument.Parse("{\"op\":\"version\"}");

        JsonElement response = await client.ExchangeAsync(request.RootElement);

        Assert.True(response.GetProperty("ok").GetBoolean());
        Assert.Equal("f2-companion-cli-1", response.GetProperty("version").GetString());
        Assert.DoesNotContain("protected-token", response.GetRawText(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task ExchangeAsync_RejectsInlineAuthenticationBeforeConnecting()
    {
        var client = new CompanionCliClient(
            new CompanionCliClientOptions(65534),
            () => "protected-token");
        using JsonDocument request = JsonDocument.Parse("{\"op\":\"health\",\"authToken\":\"leaked\"}");

        CompanionCliClientException exception = await Assert.ThrowsAsync<CompanionCliClientException>(
            () => client.ExchangeAsync(request.RootElement));

        Assert.Equal("inline_auth_forbidden", exception.Code);
        Assert.DoesNotContain("leaked", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ExchangeAsync_RequiresProtectedTokenBeforeConnecting()
    {
        var client = new CompanionCliClient(
            new CompanionCliClientOptions(65534),
            () => null);
        using JsonDocument request = JsonDocument.Parse("{\"op\":\"health\"}");

        CompanionCliClientException exception = await Assert.ThrowsAsync<CompanionCliClientException>(
            () => client.ExchangeAsync(request.RootElement));

        Assert.Equal("protected_token_missing", exception.Code);
    }

    [Fact]
    public async Task ExchangeAsync_AllowsExplicitUnauthenticatedLoopback()
    {
        await using var server = new CompanionCliServer(0);
        server.Start();
        var client = new CompanionCliClient(
            new CompanionCliClientOptions(server.Port, RequireAuthentication: false),
            () => throw new InvalidOperationException("token provider must not run"));
        using JsonDocument request = JsonDocument.Parse("{\"op\":\"ping\"}");

        JsonElement response = await client.ExchangeAsync(request.RootElement);

        Assert.True(response.GetProperty("pong").GetBoolean());
    }

    [Fact]
    public async Task ExchangeAsync_RejectsOversizedAuthenticatedRequestBeforeConnecting()
    {
        var client = new CompanionCliClient(
            new CompanionCliClientOptions(65534),
            () => "protected-token");
        string oversizedValue = new('x', CompanionCliServer.MaxLineBytes);
        using JsonDocument request = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            op = "run.submit",
            prompt = oversizedValue,
        }));

        CompanionCliClientException exception = await Assert.ThrowsAsync<CompanionCliClientException>(
            () => client.ExchangeAsync(request.RootElement));

        Assert.Equal("request_too_large", exception.Code);
        Assert.DoesNotContain("protected-token", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ExchangeAsync_RejectsOversizedResponse()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        Task server = Task.Run(async () =>
        {
            using TcpClient peer = await listener.AcceptTcpClientAsync();
            await using NetworkStream stream = peer.GetStream();
            byte[] oversizedResponse = Encoding.UTF8.GetBytes(new string('x', CompanionCliServer.MaxLineBytes + 1));
            await stream.WriteAsync(oversizedResponse);
            await stream.FlushAsync();
        });

        try
        {
            var client = new CompanionCliClient(
                new CompanionCliClientOptions(port, RequireAuthentication: false),
                () => null);
            using JsonDocument request = JsonDocument.Parse("{\"op\":\"ping\"}");

            CompanionCliClientException exception = await Assert.ThrowsAsync<CompanionCliClientException>(
                () => client.ExchangeAsync(request.RootElement));

            Assert.Equal("response_too_large", exception.Code);
            await server;
        }
        finally
        {
            listener.Stop();
        }
    }
}
