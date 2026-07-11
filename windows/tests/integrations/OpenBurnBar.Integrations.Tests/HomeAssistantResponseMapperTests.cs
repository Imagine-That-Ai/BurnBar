using OpenBurnBar.Integrations.HomeAssistant.Rest;
using Xunit;

namespace OpenBurnBar.Integrations.Tests;

public class HomeAssistantResponseMapperTests
{
    [Fact]
    public void Probe_401_ConfirmsHomeAssistant_WithVersion()
    {
        var status = HomeAssistantResponseMapper.MapProbe(401, "2024.7.1");
        var ok = Assert.IsType<HomeAssistantProbeStatus.Ok>(status);
        Assert.Equal("2024.7.1", ok.Version);
    }

    [Fact]
    public void Probe_200_ConfirmsHomeAssistant()
    {
        var status = HomeAssistantResponseMapper.MapProbe(200, null);
        var ok = Assert.IsType<HomeAssistantProbeStatus.Ok>(status);
        Assert.Null(ok.Version);
    }

    [Fact]
    public void Probe_404_IsNotHomeAssistant()
    {
        Assert.IsType<HomeAssistantProbeStatus.NoHomeAssistantHere>(HomeAssistantResponseMapper.MapProbe(404, null));
    }

    [Fact]
    public void Probe_OtherStatus_IsOkWithoutVersion()
    {
        var status = HomeAssistantResponseMapper.MapProbe(500, "ignored");
        var ok = Assert.IsType<HomeAssistantProbeStatus.Ok>(status);
        Assert.Null(ok.Version);
    }

    [Fact]
    public void EnsureSuccess_2xx_DoesNotThrow()
    {
        HomeAssistantResponseMapper.EnsureSuccess(200, "{}", "/api/");
        HomeAssistantResponseMapper.EnsureSuccess(204, "", "/api/");
    }

    [Theory]
    [InlineData(401, HomeAssistantClientErrorKind.Unauthorized)]
    [InlineData(403, HomeAssistantClientErrorKind.Forbidden)]
    [InlineData(429, HomeAssistantClientErrorKind.RateLimited)]
    public void EnsureSuccess_MapsStatusToKind(int status, HomeAssistantClientErrorKind kind)
    {
        var ex = Assert.Throws<HomeAssistantClientException>(
            () => HomeAssistantResponseMapper.EnsureSuccess(status, "boom", "/api/states"));
        Assert.Equal(kind, ex.Kind);
    }

    [Fact]
    public void EnsureSuccess_404_CarriesPath()
    {
        var ex = Assert.Throws<HomeAssistantClientException>(
            () => HomeAssistantResponseMapper.EnsureSuccess(404, "", "/api/states"));
        Assert.Equal(HomeAssistantClientErrorKind.NotFound, ex.Kind);
        Assert.Equal("/api/states", ex.Detail);
        Assert.Contains("/api/states", ex.Message);
    }

    [Fact]
    public void EnsureSuccess_ServerError_TruncatesBodyTo160()
    {
        var body = new string('x', 500);
        var ex = Assert.Throws<HomeAssistantClientException>(
            () => HomeAssistantResponseMapper.EnsureSuccess(503, body, "/api/"));
        Assert.Equal(HomeAssistantClientErrorKind.Server, ex.Kind);
        Assert.Equal(503, ex.StatusCode);
        Assert.Equal(160, ex.Detail.Length);
    }

    [Fact]
    public void EnsureSuccess_ServerError_EmptyBodyReportsNoBody()
    {
        var ex = Assert.Throws<HomeAssistantClientException>(
            () => HomeAssistantResponseMapper.EnsureSuccess(500, "", "/api/"));
        Assert.Equal("no body", ex.Detail);
    }

    [Fact]
    public void Errors_AreEquatable_ByKindDetailAndStatus()
    {
        Assert.Equal(HomeAssistantClientException.Unauthorized(), HomeAssistantClientException.Unauthorized());
        Assert.Equal(HomeAssistantClientException.NotFound("/a"), HomeAssistantClientException.NotFound("/a"));
        Assert.NotEqual(HomeAssistantClientException.NotFound("/a"), HomeAssistantClientException.NotFound("/b"));
        Assert.NotEqual(HomeAssistantClientException.Server(500, "x"), HomeAssistantClientException.Server(502, "x"));
    }

    [Fact]
    public void UnauthorizedError_HasActionableCopy()
    {
        Assert.Contains("long-lived access token", HomeAssistantClientException.Unauthorized().Message);
    }
}
