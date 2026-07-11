using System.Collections.Generic;
using OpenBurnBar.App.Components;
using Xunit;

namespace OpenBurnBar.App.Components.Tests;

/// <summary>Asserts the tool-call model against UnifiedToolCallAccordion.swift.</summary>
public sealed class ToolCallModelTests
{
    [Fact]
    public void Running_flag_always_wins()
    {
        var call = new ToolCallDisplay("1", "bash", statusRaw: "done", isRunning: true);
        Assert.Equal(ToolCallState.Running, call.State);
    }

    [Theory]
    [InlineData("failed", ToolCallState.Failed)]
    [InlineData("timeout", ToolCallState.Failed)]
    [InlineData("permission denied", ToolCallState.Failed)]
    [InlineData("done", ToolCallState.Done)]
    [InlineData("completed ok", ToolCallState.Done)]
    [InlineData("running", ToolCallState.Running)]
    [InlineData("in progress", ToolCallState.Running)]
    [InlineData("mystery", ToolCallState.Neutral)]
    [InlineData("", ToolCallState.Neutral)]
    [InlineData(null, ToolCallState.Neutral)]
    public void State_classifies_status_leniently(string? status, ToolCallState expected)
    {
        var call = new ToolCallDisplay("1", "tool", statusRaw: status);
        Assert.Equal(expected, call.State);
    }

    [Fact]
    public void IconGlyph_keyword_order_is_load_bearing()
    {
        // "web_search" must resolve web (globe) BEFORE search.
        Assert.Equal(ToolCallDisplay.IconGlyphFor("web"), ToolCallDisplay.IconGlyphFor("web_search"));
        // "search_files" must resolve search BEFORE file (document).
        Assert.Equal(ToolCallDisplay.IconGlyphFor("search"), ToolCallDisplay.IconGlyphFor("search_files"));
        // bash/exec/terminal share the terminal glyph.
        Assert.Equal(ToolCallDisplay.IconGlyphFor("bash"), ToolCallDisplay.IconGlyphFor("exec_command"));
        // Unknown falls back to the wrench.
        Assert.False(string.IsNullOrEmpty(ToolCallDisplay.IconGlyphFor("frobnicate")));
    }

    [Fact]
    public void HasExpandableDetail_needs_arguments_or_result()
    {
        Assert.False(new ToolCallDisplay("1", "t").HasExpandableDetail);
        Assert.False(new ToolCallDisplay("1", "t", detail: "only a summary").HasExpandableDetail);
        Assert.True(new ToolCallDisplay("1", "t", arguments: "{}").HasExpandableDetail);
        Assert.True(new ToolCallDisplay("1", "t", result: "ok").HasExpandableDetail);
        Assert.False(new ToolCallDisplay("1", "t", arguments: "   ").HasExpandableDetail);
    }

    [Fact]
    public void Accordion_most_recent_is_last_and_extra_count_excludes_it()
    {
        var calls = new List<ToolCallDisplay>
        {
            new("1", "read"),
            new("2", "edit"),
            new("3", "bash"),
        };

        Assert.Equal("3", ToolCallAccordionModel.MostRecent(calls)!.Id);
        Assert.Equal(2, ToolCallAccordionModel.AdditionalCount(calls));

        IReadOnlyList<ToolCallDisplay> older = ToolCallAccordionModel.OlderCalls(calls);
        Assert.Equal(new[] { "2", "1" }, new[] { older[0].Id, older[1].Id });
    }

    [Fact]
    public void Accordion_expandable_when_history_or_detail()
    {
        Assert.False(ToolCallAccordionModel.IsExpandable(new List<ToolCallDisplay> { new("1", "t") }));
        Assert.True(ToolCallAccordionModel.IsExpandable(new List<ToolCallDisplay>
        {
            new("1", "t"),
            new("2", "u"),
        }));
        Assert.True(ToolCallAccordionModel.IsExpandable(new List<ToolCallDisplay>
        {
            new("1", "t", arguments: "{\"path\":\"a\"}"),
        }));
    }

    [Fact]
    public void Accordion_empty_is_safe()
    {
        var empty = new List<ToolCallDisplay>();
        Assert.Null(ToolCallAccordionModel.MostRecent(empty));
        Assert.Equal(0, ToolCallAccordionModel.AdditionalCount(empty));
        Assert.Empty(ToolCallAccordionModel.OlderCalls(empty));
        Assert.False(ToolCallAccordionModel.IsExpandable(empty));
    }
}
