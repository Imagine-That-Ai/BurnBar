using System;
using System.IO;
using System.Linq;
using System.Xml.Linq;
using Xunit;

namespace OpenBurnBar.Dist.Tests;

public sealed class PlaywrightBridgePackagingTests
{
    [Fact]
    public void WinUiPublishCarriesTheReviewedPlaywrightBridge()
    {
        string root = DistTestSupport.RepositoryRoot();
        string projectPath = Path.Combine(
            root,
            "windows",
            "app",
            "OpenBurnBar.App",
            "OpenBurnBar.App.csproj");
        XDocument project = XDocument.Load(projectPath);
        XElement content = project
            .Descendants("Content")
            .Single(element =>
                ((string?)element.Attribute("Include"))?.EndsWith(
                    @"OpenBurnBarDaemon\Resources\PlaywrightBridge\openburnbar-playwright-bridge.js",
                    StringComparison.Ordinal) == true);

        Assert.Equal(
            @"Resources\PlaywrightBridge\openburnbar-playwright-bridge.js",
            (string?)content.Attribute("Link"));
        Assert.Equal("PreserveNewest", (string?)content.Attribute("CopyToOutputDirectory"));
        Assert.Equal("PreserveNewest", (string?)content.Attribute("CopyToPublishDirectory"));
        Assert.True(File.Exists(Path.Combine(
            root,
            "OpenBurnBarDaemon",
            "Resources",
            "PlaywrightBridge",
            "openburnbar-playwright-bridge.js")));
    }
}
