using System.Linq;
using OpenBurnBar.App.Presentation.SessionLogs;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real parity tests for the transcript parser ported from
/// AgentLens/Services/TranscriptBlockParser.swift. Pure string logic, so the Windows
/// port must produce byte-identical block structure for the same transcript inputs.
/// </summary>
public sealed class TranscriptBlockParserTests
{
    [Fact]
    public void Parse_EmptyOrWhitespace_YieldsNoBlocks()
    {
        Assert.Empty(TranscriptBlockParser.Parse(string.Empty));
        Assert.Empty(TranscriptBlockParser.Parse("   \n\n   "));
    }

    [Fact]
    public void Parse_HeadingRoles_SplitUserAndAssistant()
    {
        const string text = "## You\nHow do I center a div?\n\n## Assistant\nUse flexbox.";
        var blocks = TranscriptBlockParser.Parse(text);

        Assert.Equal(2, blocks.Count);
        Assert.Equal(TranscriptBlockKind.UserMessage, blocks[0].Kind);
        Assert.Equal("How do I center a div?", blocks[0].Content);
        Assert.Equal(TranscriptBlockKind.AssistantMessage, blocks[1].Kind);
        Assert.Equal("Use flexbox.", blocks[1].Content);
    }

    [Fact]
    public void Parse_RawRoleMarkers_HumanAssistant()
    {
        const string text = "Human: ping\nAssistant: pong";
        var blocks = TranscriptBlockParser.Parse(text);

        Assert.Equal(2, blocks.Count);
        Assert.Equal(TranscriptBlockKind.UserMessage, blocks[0].Kind);
        Assert.Equal("ping", blocks[0].Content);
        Assert.Equal(TranscriptBlockKind.AssistantMessage, blocks[1].Kind);
        Assert.Equal("pong", blocks[1].Content);
    }

    [Fact]
    public void Parse_FencedCodeBlock_CarriesLanguageLabel()
    {
        const string text = "```swift\nlet x = 1\n```";
        var block = Assert.Single(TranscriptBlockParser.Parse(text));

        Assert.Equal(TranscriptBlockKind.CodeBlock, block.Kind);
        Assert.Equal("swift", block.Label);
        Assert.Equal("let x = 1", block.Content);
    }

    [Fact]
    public void Parse_ToolUseFence_BecomesToolBlock_WithNameLabelAndDetail()
    {
        const string text = "```tool-use\nBash\nls -la\n```";
        var block = Assert.Single(TranscriptBlockParser.Parse(text));

        Assert.Equal(TranscriptBlockKind.ToolUse, block.Kind);
        Assert.Equal("Bash", block.Label);
        Assert.Equal("ls -la", block.Content);
    }

    [Fact]
    public void Parse_AssistantWithInlineCode_FlushesTextThenCode()
    {
        const string text = "## Assistant\nHere you go:\n```python\nprint(1)\n```\nDone.";
        var blocks = TranscriptBlockParser.Parse(text);

        Assert.Equal(3, blocks.Count);
        Assert.Equal(TranscriptBlockKind.AssistantMessage, blocks[0].Kind);
        Assert.Equal("Here you go:", blocks[0].Content);
        Assert.Equal(TranscriptBlockKind.CodeBlock, blocks[1].Kind);
        Assert.Equal("python", blocks[1].Label);
        Assert.Equal("print(1)", blocks[1].Content);
        Assert.Equal(TranscriptBlockKind.AssistantMessage, blocks[2].Kind);
        Assert.Equal("Done.", blocks[2].Content);
    }

    [Fact]
    public void Parse_TopLevelSeparator_EmitsSeparatorBlockBetweenProse()
    {
        // Separators are emitted at the TOP level (between blocks); a plain-text run
        // breaks on the separator line, then the separator is emitted, then the next run.
        var blocks = TranscriptBlockParser.Parse("alpha\n===\nbeta");

        Assert.Equal(3, blocks.Count);
        Assert.Equal(TranscriptBlockKind.AssistantMessage, blocks[0].Kind);
        Assert.Equal("alpha", blocks[0].Content);
        Assert.Equal(TranscriptBlockKind.Separator, blocks[1].Kind);
        Assert.Equal(TranscriptBlockKind.AssistantMessage, blocks[2].Kind);
        Assert.Equal("beta", blocks[2].Content);
    }

    [Fact]
    public void Parse_TopLevelSeparator_IsAbsorbedInsideRoleCollection()
    {
        // Faithful to the Swift parser: a role-collection loop (Human:/Assistant:) only
        // breaks on role markers/headings, so a "---" inside a user turn is kept as text.
        var blocks = TranscriptBlockParser.Parse("Human: hi\n---\nAssistant: yo");

        Assert.Equal(2, blocks.Count);
        Assert.Equal(TranscriptBlockKind.UserMessage, blocks[0].Kind);
        Assert.Equal("hi\n---", blocks[0].Content);
        Assert.Equal(TranscriptBlockKind.AssistantMessage, blocks[1].Kind);
    }

    [Fact]
    public void Parse_SkipsTopLevelMarkdownTables()
    {
        // Tables are skipped when encountered at the TOP level; a plain-text run breaks
        // on the table's opening pipe line, the table is consumed and dropped, then prose resumes.
        const string text = "intro\n| a | b |\n|---|---|\n| 1 | 2 |\nAssistant: done";
        var blocks = TranscriptBlockParser.Parse(text);

        Assert.DoesNotContain(blocks, b => b.Content.Contains("|"));
        Assert.Contains(blocks, b => b.Kind == TranscriptBlockKind.AssistantMessage && b.Content == "intro");
        Assert.Contains(blocks, b => b.Kind == TranscriptBlockKind.AssistantMessage && b.Content == "done");
    }

    [Fact]
    public void StripSystemTags_RemovesReminderBlocksAndBareTags()
    {
        const string text = "before<system-reminder>secret\nmulti-line</system-reminder>after <b>x</b>";
        string stripped = TranscriptBlockParser.StripSystemTags(text);

        Assert.DoesNotContain("system-reminder", stripped);
        Assert.DoesNotContain("secret", stripped);
        Assert.DoesNotContain("<b>", stripped);
        Assert.Contains("before", stripped);
        Assert.Contains("after", stripped);
    }

    [Fact]
    public void Parse_PlainText_AccumulatesIntoAssistantBlock()
    {
        const string text = "just some prose\nspanning two lines";
        var block = Assert.Single(TranscriptBlockParser.Parse(text));

        Assert.Equal(TranscriptBlockKind.AssistantMessage, block.Kind);
        Assert.Equal("just some prose\nspanning two lines", block.Content);
    }

    [Fact]
    public void Parse_H1Heading_IsSkipped()
    {
        // A bare "# Title" line is skipped (shown in the header), but following prose is kept.
        var blocks = TranscriptBlockParser.Parse("# Session Title\nActual content");

        var block = Assert.Single(blocks);
        Assert.Equal("Actual content", block.Content);
    }
}
