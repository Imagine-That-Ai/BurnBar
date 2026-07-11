using System.Collections.Generic;
using System.Linq;
using System.Text;
using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

/// <summary>Secret-broker request→response contract parity.</summary>
public sealed class SecretBrokerTests
{
    private const string RouteId = "route-1";
    private const string Account = "provider.zai.apiKey";

    private static (CursorConnectorSecretBroker Broker, FakeSecretStore Store) NewBroker()
    {
        var store = new FakeSecretStore();
        var broker = new CursorConnectorSecretBroker(
            store,
            new Dictionary<string, string> { [RouteId] = Account },
            new FixedRandomTokenSource(0xAB));
        return (broker, store);
    }

    private static string Request(string path, string? authorization)
    {
        var builder = new StringBuilder()
            .Append($"GET {path} HTTP/1.1\r\n")
            .Append("Host: 127.0.0.1\r\n");
        if (authorization is not null)
        {
            builder.Append($"Authorization: {authorization}\r\n");
        }

        return builder.Append("\r\n").ToString();
    }

    private static string Respond(CursorConnectorSecretBroker broker, string request) =>
        Encoding.UTF8.GetString(broker.ResponseFor(Encoding.UTF8.GetBytes(request)));

    [Fact]
    public void BearerToken_IsDeterministicHexOfRandomBytes()
    {
        var (broker, _) = NewBroker();
        // 32 bytes, each 0xAB, lowercase-hex encoded.
        Assert.Equal(string.Concat(Enumerable.Repeat("ab", 32)), broker.BearerToken);
    }

    [Fact]
    public void ValidRequest_Returns200WithApiKey()
    {
        var (broker, store) = NewBroker();
        store.Set(Account, "secret-key");

        var response = Respond(broker, Request($"/secret/{RouteId}", $"Bearer {broker.BearerToken}"));

        Assert.StartsWith("HTTP/1.1 200 OK\r\n", response);
        Assert.Contains("{\"api_key\":\"secret-key\"}", response);
    }

    [Fact]
    public void WrongBearer_Returns401()
    {
        var (broker, store) = NewBroker();
        store.Set(Account, "secret-key");

        var response = Respond(broker, Request($"/secret/{RouteId}", "Bearer nope"));

        Assert.StartsWith("HTTP/1.1 401 Unauthorized\r\n", response);
        Assert.Contains("unauthorized", response);
    }

    [Fact]
    public void MissingAuth_Returns401()
    {
        var (broker, _) = NewBroker();
        var response = Respond(broker, Request($"/secret/{RouteId}", authorization: null));
        Assert.StartsWith("HTTP/1.1 401 Unauthorized\r\n", response);
    }

    [Fact]
    public void UnknownRoute_Returns404UnknownRoute()
    {
        var (broker, _) = NewBroker();
        var response = Respond(broker, Request("/secret/does-not-exist", $"Bearer {broker.BearerToken}"));
        Assert.StartsWith("HTTP/1.1 404 Not Found\r\n", response);
        Assert.Contains("unknown_route", response);
    }

    [Fact]
    public void NonSecretPath_Returns404NotFound()
    {
        var (broker, _) = NewBroker();
        var response = Respond(broker, Request("/health", $"Bearer {broker.BearerToken}"));
        Assert.StartsWith("HTTP/1.1 404 Not Found\r\n", response);
        Assert.Contains("not_found", response);
    }

    [Fact]
    public void MissingSecret_Returns424()
    {
        var (broker, _) = NewBroker();
        var response = Respond(broker, Request($"/secret/{RouteId}", $"Bearer {broker.BearerToken}"));
        Assert.StartsWith("HTTP/1.1 424 Failed Dependency\r\n", response);
        Assert.Contains("secret_unavailable", response);
    }

    [Fact]
    public void WhitespaceOnlySecret_Returns424()
    {
        var (broker, store) = NewBroker();
        store.Set(Account, "   ");
        var response = Respond(broker, Request($"/secret/{RouteId}", $"Bearer {broker.BearerToken}"));
        Assert.StartsWith("HTTP/1.1 424 Failed Dependency\r\n", response);
    }

    [Fact]
    public void NullRequest_Returns400EmptyRequest()
    {
        var (broker, _) = NewBroker();
        var response = Encoding.UTF8.GetString(broker.ResponseFor(null));
        Assert.StartsWith("HTTP/1.1 400 Bad Request\r\n", response);
        Assert.Contains("empty_request", response);
    }

    [Fact]
    public void BaseUrlString_UsesPort()
    {
        var (broker, _) = NewBroker();
        broker.Port = 51234;
        Assert.Equal("http://127.0.0.1:51234", broker.BaseUrlString);
    }
}
