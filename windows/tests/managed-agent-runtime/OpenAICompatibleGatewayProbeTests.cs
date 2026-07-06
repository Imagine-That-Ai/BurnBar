using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.ManagedAgentRuntime.Tests.Fakes;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class OpenAICompatibleGatewayProbeTests
{
    private static readonly Uri Gateway = new("http://127.0.0.1:8765");

    private static byte[] Utf8(string value) => Encoding.UTF8.GetBytes(value);

    [Fact]
    public async Task BuildsModelsEndpointAndAttachesBearer()
    {
        var transport = FakeHttpTransport.Returning(200, """{"data":[]}""");
        var probe = new OpenAICompatibleGatewayProbe(transport);

        await probe.ProbeAsync(Gateway, "  key  ");

        Assert.Equal("http://127.0.0.1:8765/v1/models", transport.LastRequest!.Value.Url.ToString());
        Assert.Equal("GET", transport.LastRequest.Value.Method);
        Assert.Equal("Bearer key", transport.LastRequest.Value.Headers["Authorization"]);
    }

    [Fact]
    public async Task OmitsAuthorizationForBlankToken()
    {
        var transport = FakeHttpTransport.Returning(200, """{"data":[]}""");
        var probe = new OpenAICompatibleGatewayProbe(transport);

        await probe.ProbeAsync(Gateway, "   ");

        Assert.False(transport.LastRequest!.Value.Headers.ContainsKey("Authorization"));
    }

    [Fact]
    public async Task SuccessReportsAvailableWithFirstModelId()
    {
        var probe = new OpenAICompatibleGatewayProbe(
            FakeHttpTransport.Returning(200, """{"data":[{"id":"pi-model-1"},{"id":"pi-model-2"}]}"""));

        var result = await probe.ProbeAsync(Gateway, null);

        Assert.True(result.Available);
        Assert.Equal("pi-model-1", result.ModelName);
    }

    [Fact]
    public async Task NonSuccessReportsUnavailable()
    {
        var probe = new OpenAICompatibleGatewayProbe(FakeHttpTransport.Returning(503, ""));

        var result = await probe.ProbeAsync(Gateway, null);

        Assert.False(result.Available);
        Assert.Null(result.ModelName);
    }

    [Fact]
    public async Task TransportThrowReportsUnavailable()
    {
        var probe = new OpenAICompatibleGatewayProbe(
            FakeHttpTransport.Throwing(new IOException("no route")));

        var result = await probe.ProbeAsync(Gateway, null);

        Assert.False(result.Available);
        Assert.Null(result.ModelName);
    }

    [Fact]
    public async Task SuccessWithUnparseableBodyIsAvailableWithNullModel()
    {
        var probe = new OpenAICompatibleGatewayProbe(FakeHttpTransport.Returning(200, "not json"));

        var result = await probe.ProbeAsync(Gateway, null);

        Assert.True(result.Available);
        Assert.Null(result.ModelName);
    }

    [Fact]
    public void ModelNamePrefersDataArrayId()
    {
        Assert.Equal("m1", OpenAICompatibleGatewayProbe.ModelName(Utf8("""{"data":[{"id":"m1"}]}""")));
    }

    [Fact]
    public void ModelNameFallsBackToTopLevelModel()
    {
        Assert.Equal("solo", OpenAICompatibleGatewayProbe.ModelName(Utf8("""{"model":"solo"}""")));
    }

    [Fact]
    public void ModelNameSkipsEmptyDataIdAndUsesModel()
    {
        Assert.Equal("fallback", OpenAICompatibleGatewayProbe.ModelName(Utf8("""{"data":[{"id":""}],"model":"fallback"}""")));
    }

    [Fact]
    public void ModelNameNullWhenNothingUsable()
    {
        Assert.Null(OpenAICompatibleGatewayProbe.ModelName(Utf8("""{"data":[]}""")));
        Assert.Null(OpenAICompatibleGatewayProbe.ModelName(Utf8("not json")));
        Assert.Null(OpenAICompatibleGatewayProbe.ModelName(Utf8("[1,2,3]")));
    }
}
