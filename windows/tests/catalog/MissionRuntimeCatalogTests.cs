using System;
using System.Linq;
using OpenBurnBar.App.Presentation.Catalog;
using OpenBurnBar.App.Presentation.Switcher;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Catalog;

public sealed class MissionRuntimeCatalogTests
{
    [Fact]
    public void CatalogCoversWindowsSwitcherJuniePrimeAgentFx()
    {
        var catalog = MissionRuntimeCatalog.LoadFixture();
        Assert.True(catalog.Contains("junie"));
        Assert.True(catalog.Contains("prime-agent"));
        Assert.True(catalog.Contains("fx"));
        Assert.True(catalog.Contains("muse"));
        Assert.True(catalog.Contains("muse-code"));
        Assert.True(catalog.Covers(new[] { "junie", "prime-agent", "fx", "muse" }));
        Assert.True(catalog.Covers(Enum.GetValues<SwitcherCLIProfileType>().Select(t => t.RawValue())));
    }

    [Fact]
    public void UnknownSwitcherTokenIsNotPi()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => ((SwitcherCLIProfileType)int.MaxValue).RawValue());
        Assert.False(MissionRuntimeCatalog.LoadFixture().Contains("not-a-runtime"));
    }
}
