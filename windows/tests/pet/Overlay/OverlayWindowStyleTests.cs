using OpenBurnBar.Pal.Overlay;
using Xunit;

namespace OpenBurnBar.App.Pet.Tests.Overlay;

public sealed class OverlayWindowStyleTests
{
    [Fact]
    public void BaseExStyle_HasLayeredToolWindowTopMostNoActivate()
    {
        var s = OverlayWindowStyle.BaseExStyle;
        Assert.True(OverlayWindowStyle.IsLayered(s));
        Assert.True(OverlayWindowStyle.IsToolWindow(s));
        Assert.True(OverlayWindowStyle.IsNonActivating(s));
        Assert.Equal(OverlayWindowStyle.WsExTopMost, s & OverlayWindowStyle.WsExTopMost);
        // The base is NOT click-through by itself; that is layered on explicitly.
        Assert.False(OverlayWindowStyle.IsClickThrough(s));
    }

    [Fact]
    public void ExactBitmaskMatchesWin32Constants()
    {
        // Pin the exact winuser.h values so a typo is caught.
        Assert.Equal(0x0000_0020, OverlayWindowStyle.WsExTransparent);
        Assert.Equal(0x0000_0080, OverlayWindowStyle.WsExToolWindow);
        Assert.Equal(0x0000_0008, OverlayWindowStyle.WsExTopMost);
        Assert.Equal(0x0008_0000, OverlayWindowStyle.WsExLayered);
        Assert.Equal(0x0800_0000, OverlayWindowStyle.WsExNoActivate);

        // BaseExStyle is the OR of the four always-on flags.
        var composed = 0x0008_0000 | 0x0000_0080 | 0x0000_0008 | 0x0800_0000;
        Assert.Equal(OverlayWindowStyle.BaseExStyle, composed);
    }

    [Fact]
    public void WithClickThrough_TogglesOnlyTransparentBit()
    {
        var on = OverlayWindowStyle.WithClickThrough(true);
        var off = OverlayWindowStyle.WithClickThrough(false);
        Assert.True(OverlayWindowStyle.IsClickThrough(on));
        Assert.False(OverlayWindowStyle.IsClickThrough(off));
        // Everything except the transparent bit is identical.
        Assert.Equal(off, on & ~OverlayWindowStyle.WsExTransparent);
    }

    [Fact]
    public void EnableDisable_AreInverses_AndPreserveInvariants()
    {
        var start = OverlayWindowStyle.WithClickThrough(false);
        var enabled = OverlayWindowStyle.EnableClickThrough(start);
        var disabled = OverlayWindowStyle.DisableClickThrough(enabled);

        Assert.True(OverlayWindowStyle.IsClickThrough(enabled));
        Assert.False(OverlayWindowStyle.IsClickThrough(disabled));
        Assert.Equal(start, disabled);

        // Focus-safety invariant: NOACTIVATE + TOOLWINDOW + LAYERED survive both toggles.
        foreach (var s in new[] { start, enabled, disabled })
        {
            Assert.True(OverlayWindowStyle.IsNonActivating(s));
            Assert.True(OverlayWindowStyle.IsToolWindow(s));
            Assert.True(OverlayWindowStyle.IsLayered(s));
        }
    }

    [Fact]
    public void DoubleEnable_IsIdempotent()
    {
        var s = OverlayWindowStyle.EnableClickThrough(OverlayWindowStyle.BaseExStyle);
        Assert.Equal(s, OverlayWindowStyle.EnableClickThrough(s));
    }
}
