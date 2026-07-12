using OpenBurnBar.App.Presentation.Chat;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Chat;

/// <summary>
/// Real parity tests for the `burnbar://` atom URL codec ported from
/// OpenBurnBarCore/.../Hermes/HermesAtomURL.swift. Pure string logic, so the
/// Windows port must encode/decode byte-identically. Runs on the macOS authoring
/// host today via `dotnet test`.
/// </summary>
public sealed class HermesAtomUrlTests
{
    [Fact]
    public void RoundTrip_AllAtomKinds_DecodeBackToEqualAtom()
    {
        HermesAtom[] atoms =
        {
            new HermesAtom.Cost(2.34, HermesAtomWindow.Today),
            new HermesAtom.Session("abc-123"),
            new HermesAtom.ProviderRef("anthropic"),
            new HermesAtom.Model("claude-sonnet-4.7"),
            new HermesAtom.WindowRef(HermesAtomWindow.SevenDays),
            new HermesAtom.Tool("ReadFile"),
            new HermesAtom.Project("BurnBar"),
            new HermesAtom.Tokens(12400, HermesAtomTokenScope.Today),
            new HermesAtom.Quota("anthropic", 78),
            new HermesAtom.Runtime("hermes"),
        };

        foreach (var atom in atoms)
        {
            var url = HermesAtomUrl.Encode(atom);
            var decoded = HermesAtomUrl.Decode(url);
            Assert.Equal(atom, decoded);
        }
    }

    [Fact]
    public void Decode_CostWindow_DefaultsToToday_WhenAbsent()
    {
        var atom = Assert.IsType<HermesAtom.Cost>(HermesAtomUrl.Decode("burnbar://burn?amount=1.5"));
        Assert.Equal(HermesAtomWindow.Today, atom.Window);
        Assert.Equal(1.5, atom.Amount, 3);
    }

    [Fact]
    public void Decode_Tokens_DefaultsScopeToUnspecified_WhenAbsent()
    {
        var atom = Assert.IsType<HermesAtom.Tokens>(HermesAtomUrl.Decode("burnbar://tokens?value=500"));
        Assert.Equal(HermesAtomTokenScope.Unspecified, atom.Scope);
        Assert.Equal(500, atom.Value);
    }

    [Theory]
    [InlineData("https://example.com/burn?amount=1")] // wrong scheme
    [InlineData("burnbar://unknownhost?x=1")]          // unrecognized host
    [InlineData("burnbar://session")]                  // missing required id
    [InlineData("burnbar://session?id=")]              // empty required id
    [InlineData("burnbar://tokens?value=notanumber")]  // non-int value
    [InlineData("burnbar://quota?provider=anthropic")] // missing percent
    [InlineData("burnbar://window?value=bogus")]       // unknown window raw
    public void Decode_InvalidForms_ReturnNull(string url)
    {
        Assert.Null(HermesAtomUrl.Decode(url));
    }

    [Fact]
    public void Decode_DuplicateQueryKey_ReturnsNull()
    {
        // Mirrors the Swift `uniqueQueryParams` guard: a repeated key rejects the URL.
        Assert.Null(HermesAtomUrl.Decode("burnbar://session?id=a&id=b"));
    }

    [Fact]
    public void Decode_IsCaseInsensitiveOnScheme()
    {
        Assert.NotNull(HermesAtomUrl.Decode("BURNBAR://provider?token=openai"));
    }

    [Fact]
    public void Decode_NullOrEmpty_ReturnsNull()
    {
        Assert.Null(HermesAtomUrl.Decode(null));
        Assert.Null(HermesAtomUrl.Decode(string.Empty));
    }
}
