using Xunit;

namespace OpenBurnBar.App.Shell;

public sealed class ShellResponsiveLayoutTests
{
    [Fact]
    public void PhysicalCertificationWidthUsesCompactHeaderAndTabs()
    {
        ShellResponsiveLayout layout = ShellResponsiveLayout.ForWidth(640);

        Assert.False(layout.ShowBrandWordmark);
        Assert.False(layout.ShowPaletteLabel);
        Assert.False(layout.ShowPaletteShortcut);
        Assert.False(layout.ShowTabLabels);
    }

    [Fact]
    public void WideWindowPreservesFullCommandDeck()
    {
        ShellResponsiveLayout layout = ShellResponsiveLayout.ForWidth(1280);

        Assert.True(layout.ShowBrandWordmark);
        Assert.True(layout.ShowPaletteLabel);
        Assert.True(layout.ShowPaletteShortcut);
        Assert.True(layout.ShowTabLabels);
    }
}
