using System;
using OpenBurnBar.CloudSync.AppCheck.Mint;
using Xunit;

namespace OpenBurnBar.CloudSync.AppCheck.Tests;

/// <summary>Callable URL resolution for the mint endpoint.</summary>
public sealed class AppCheckMintEndpointTests
{
    [Fact]
    public void For_project_builds_the_default_region_callable_url()
    {
        var endpoint = AppCheckMintEndpoint.ForProject("openburnbar-app");
        Assert.Equal(
            "https://us-central1-openburnbar-app.cloudfunctions.net/mintWindowsAppCheckToken",
            endpoint.Url.ToString());
    }

    [Fact]
    public void For_project_honors_an_explicit_region()
    {
        var endpoint = AppCheckMintEndpoint.ForProject("proj", "europe-west1");
        Assert.Equal(
            "https://europe-west1-proj.cloudfunctions.net/mintWindowsAppCheckToken",
            endpoint.Url.ToString());
    }

    [Fact]
    public void Default_region_matches_the_server_functions_region()
    {
        Assert.Equal("us-central1", AppCheckMintEndpoint.DefaultRegion);
        Assert.Equal("mintWindowsAppCheckToken", AppCheckMintEndpoint.FunctionName);
    }

    [Fact]
    public void For_url_accepts_an_absolute_override()
    {
        var url = new Uri("http://127.0.0.1:5001/proj/us-central1/mintWindowsAppCheckToken");
        var endpoint = AppCheckMintEndpoint.ForUrl(url);
        Assert.Equal(url, endpoint.Url);
    }

    [Fact]
    public void For_project_rejects_blank_inputs()
    {
        Assert.Throws<ArgumentException>(() => AppCheckMintEndpoint.ForProject(""));
        Assert.Throws<ArgumentException>(() => AppCheckMintEndpoint.ForProject("proj", ""));
    }
}
