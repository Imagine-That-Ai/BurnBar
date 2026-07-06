using Xunit;

namespace OpenBurnBar.App.TextExpansion.Tests;

/// <summary>
/// Mirrors Swift <c>testUSKeyboardMapResolvesShiftedNumberRowSymbols</c>: the
/// keycode fallback that lets the <c>&amp;&amp;</c> prefix build up when a key event
/// carries no unicode payload (Shift+7 → <c>&amp;</c>).
/// </summary>
public sealed class UsKeyboardMapTests
{
    [Fact]
    public void ShiftedSeven_ResolvesToAmpersand()
    {
        Assert.Equal("&", TextExpansionUsKeyboardMap.UsKeyboardCharacter(26, shift: true));
        Assert.Equal("7", TextExpansionUsKeyboardMap.UsKeyboardCharacter(26, shift: false));
    }

    [Fact]
    public void SpaceAndLetters_ResolveFromBaseMap()
    {
        Assert.Equal(" ", TextExpansionUsKeyboardMap.UsKeyboardCharacter(49, shift: false));
        Assert.Equal("a", TextExpansionUsKeyboardMap.UsKeyboardCharacter(0, shift: false));
    }

    [Fact]
    public void ShiftedNumberRow_ResolvesToSymbols()
    {
        Assert.Equal("!", TextExpansionUsKeyboardMap.UsKeyboardCharacter(18, shift: true));
        Assert.Equal("@", TextExpansionUsKeyboardMap.UsKeyboardCharacter(19, shift: true));
        Assert.Equal("_", TextExpansionUsKeyboardMap.UsKeyboardCharacter(27, shift: true));
    }

    [Fact]
    public void UnmappedKeycode_ReturnsNull()
    {
        Assert.Null(TextExpansionUsKeyboardMap.UsKeyboardCharacter(9999, shift: false));
        Assert.Null(TextExpansionUsKeyboardMap.UsKeyboardCharacter(10, shift: false)); // gap in the ANSI map
    }
}
