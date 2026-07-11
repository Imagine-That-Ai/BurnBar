using System.Linq;
using OpenBurnBar.App.Presentation.Chat;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Chat;

/// <summary>
/// Real parity tests for the phase-3 inline-markdown expander ported from
/// OpenBurnBarCore/.../Hermes/HermesInlineMarkdown.swift. Markers are stripped as
/// presentation chrome; the visible prose must survive byte-for-byte.
/// </summary>
public sealed class HermesInlineMarkdownTests
{
    private static string Prose(string input) =>
        string.Concat(HermesAtomParser.Parse(input).Select(r => r.Text));

    private static HermesInlineStyle StyleOf(string input, string fragmentText)
    {
        var run = HermesAtomParser.Parse(input).First(r => r.Text == fragmentText);
        return run.Style;
    }

    [Fact]
    public void Bold_DoubleAsterisk_StripsMarkers_AndStylesBold()
    {
        Assert.Equal("Hello!", Prose("**Hello!**"));
        Assert.True(StyleOf("**Hello!**", "Hello!").HasFlag(HermesInlineStyle.Bold));
    }

    [Fact]
    public void Italic_SingleAsterisk_StylesItalic()
    {
        Assert.True(StyleOf("an *emphasized* word", "emphasized").HasFlag(HermesInlineStyle.Italic));
        Assert.Equal("an emphasized word", Prose("an *emphasized* word"));
    }

    [Fact]
    public void Strikethrough_DoubleTilde_StylesStrike()
    {
        Assert.True(StyleOf("~~gone~~", "gone").HasFlag(HermesInlineStyle.Strikethrough));
    }

    [Fact]
    public void BoldItalic_TripleAsterisk_UnionsStyles()
    {
        var style = StyleOf("***loud***", "loud");
        Assert.True(style.HasFlag(HermesInlineStyle.Bold));
        Assert.True(style.HasFlag(HermesInlineStyle.Italic));
    }

    [Fact]
    public void Heading_StripsHashes_AndStylesLineBold()
    {
        Assert.Equal("Title", Prose("### Title"));
        Assert.True(StyleOf("### Title", "Title").HasFlag(HermesInlineStyle.Bold));
    }

    [Fact]
    public void Bullet_RewritesMarkerToGlyph()
    {
        var prose = Prose("- first\n- second");
        Assert.Contains("• first", prose);
        Assert.Contains("• second", prose);
    }

    [Fact]
    public void SnakeCase_Underscores_StayLiteral()
    {
        // `_` requires a word boundary, so snake_case_names keep their underscores.
        Assert.Equal("snake_case_name", Prose("snake_case_name"));
    }

    [Fact]
    public void UnmatchedMarker_StaysLiteral()
    {
        Assert.Equal("2 * 3 = 6", Prose("2 * 3 = 6"));
    }

    [Fact]
    public void MultiLine_TracksLineStartAcrossNewlines()
    {
        var prose = Prose("# Heading\nplain body\n- item");
        Assert.Contains("Heading", prose);
        Assert.Contains("plain body", prose);
        Assert.Contains("• item", prose);
    }
}
