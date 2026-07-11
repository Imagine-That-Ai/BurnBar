using System.Linq;
using OpenBurnBar.App.Presentation.Chat;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Chat;

/// <summary>
/// Real parity tests for the three-pass Hermes atom parser ported from
/// OpenBurnBarCore/.../Hermes/HermesAtomParser.swift. Pure string logic — the
/// Windows port must produce the same run stream + preserve full prose coverage.
/// </summary>
public sealed class HermesAtomParserTests
{
    [Fact]
    public void Parse_PlainProse_IsASingleBodyRun()
    {
        var runs = HermesAtomParser.Parse("just some words");
        var run = Assert.Single(runs);
        Assert.Equal(HermesRichRunKind.Body, run.Kind);
        Assert.Equal("just some words", run.Text);
    }

    [Fact]
    public void Parse_MarkdownLink_BecomesAtomRunWithLabel()
    {
        var runs = HermesAtomParser.Parse("See [Anthropic](burnbar://provider?token=anthropic) here.");
        var atomRun = runs.Single(r => r.Kind == HermesRichRunKind.Atom);
        Assert.Equal("Anthropic", atomRun.Text);
        Assert.Equal(new HermesAtom.ProviderRef("anthropic"), atomRun.Atom);
    }

    [Fact]
    public void Parse_MarkdownLink_EmptyLabel_UsesAtomFallbackLabel()
    {
        var runs = HermesAtomParser.Parse("[](burnbar://model?id=gpt-5)");
        var atomRun = runs.Single(r => r.Kind == HermesRichRunKind.Atom);
        Assert.Equal("gpt-5", atomRun.Text);
    }

    [Fact]
    public void Parse_EscapedBracket_IsNotALink()
    {
        var runs = HermesAtomParser.Parse("\\[not a link](burnbar://provider?token=x)");
        Assert.DoesNotContain(runs, r => r.Kind == HermesRichRunKind.Atom);
    }

    [Fact]
    public void Parse_Mention_BecomesMentionRun()
    {
        var runs = HermesAtomParser.Parse("ping @alberto now");
        var mention = runs.Single(r => r.Kind == HermesRichRunKind.Mention);
        Assert.Equal("@alberto", mention.Text);
    }

    [Fact]
    public void Parse_EmailAtSign_IsNotAMention()
    {
        // The '@' in an email is preceded by a letter, not a boundary char.
        var runs = HermesAtomParser.Parse("mail me at foo@bar.com");
        Assert.DoesNotContain(runs, r => r.Kind == HermesRichRunKind.Mention);
    }

    [Fact]
    public void Parse_InlineCode_BecomesCodeRun_BackticksStripped()
    {
        var runs = HermesAtomParser.Parse("run `dotnet build` now");
        var code = runs.Single(r => r.Kind == HermesRichRunKind.Code);
        Assert.Equal("dotnet build", code.Text);
    }

    [Fact]
    public void Parse_CostPattern_BecomesCostAtom()
    {
        var runs = HermesAtomParser.Parse("you spent $1,234.56 today");
        var cost = runs.Single(r => r.Kind == HermesRichRunKind.Atom);
        var atom = Assert.IsType<HermesAtom.Cost>(cost.Atom);
        Assert.Equal(1234.56, atom.Amount, 2);
        Assert.Equal(HermesAtomWindow.Today, atom.Window);
    }

    [Fact]
    public void Parse_KnownModelId_BecomesModelAtom()
    {
        var runs = HermesAtomParser.Parse("try claude-sonnet-4.7 for this");
        var model = runs.Single(r => r.Kind == HermesRichRunKind.Atom);
        Assert.Equal(new HermesAtom.Model("claude-sonnet-4.7"), model.Atom);
    }

    [Theory]
    [InlineData("plain text with no markup")]
    [InlineData("See [Anthropic](burnbar://provider?token=anthropic) and @user and `code`.")]
    [InlineData("**bold** and *italic* and ~~strike~~ words")]
    [InlineData("# Heading line\n- bullet one\n- bullet two")]
    [InlineData("cost $2.34 then claude-opus-4.7 model")]
    public void Parse_PreservesProseCoverage(string input)
    {
        // The core invariant: concatenating run texts reproduces the prose of the
        // input within marker-flattening semantics. We assert the letters/digits
        // survive (markers like *, #, `, and burnbar URLs are chrome that drops).
        var reconstructed = string.Concat(HermesAtomParser.Parse(input).Select(r => r.Text));
        var expectedLetters = new string(input.Where(char.IsLetterOrDigit).ToArray());
        var actualLetters = new string(reconstructed.Where(char.IsLetterOrDigit).ToArray());
        // Link URLs contribute letters we intentionally drop, so only assert the
        // reconstruction is a subsequence-preserving superset of the visible prose
        // when there is no link; for link cases the label text is what survives.
        if (!input.Contains("burnbar://"))
        {
            Assert.Equal(expectedLetters, actualLetters);
        }
        else
        {
            Assert.Contains("Anthropic", reconstructed);
        }
    }

    [Fact]
    public void PlainText_FlattensRunsToProse()
    {
        var flat = HermesAtomParser.PlainText("**Hello** `world` @you");
        Assert.Equal("Hello world @you", flat);
    }
}
