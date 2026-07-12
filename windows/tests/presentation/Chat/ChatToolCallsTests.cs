using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Chat;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Chat;

/// <summary>
/// Real parity tests for the tool-call pairing + capability classification ported
/// from AgentLens/Views/Chat/ChatMessageView.swift (`unifiedToolCalls`) and
/// HermesToolCard.swift (`capabilityIcon`). Both are pure display transforms the
/// WinUI tool card depends on.
/// </summary>
public sealed class ChatToolCallsTests
{
    private static ChatTranscriptPiece Piece(ChatTranscriptPieceKind kind, string value, string? detail = null, string? id = null)
        => new(kind, value, detail, id);

    [Fact]
    public void UnifiedToolCalls_PairsUseWithFollowingResult()
    {
        var pieces = new List<ChatTranscriptPiece>
        {
            Piece(ChatTranscriptPieceKind.ToolUse, "Read", "path=a.txt", id: "u1"),
            Piece(ChatTranscriptPieceKind.ToolResult, "Read", "contents", id: "r1"),
        };
        var calls = ChatToolCalls.UnifiedToolCalls(pieces, isStreaming: false);
        var call = Assert.Single(calls);
        Assert.Equal("Read", call.Name);
        Assert.Equal("path=a.txt", call.Detail);
        Assert.Equal("contents", call.Result);
        Assert.False(call.IsRunning);
    }

    [Fact]
    public void UnifiedToolCalls_ResultPrefersDetailOverValue()
    {
        var pieces = new List<ChatTranscriptPiece>
        {
            Piece(ChatTranscriptPieceKind.ToolUse, "Bash", id: "u1"),
            Piece(ChatTranscriptPieceKind.ToolResult, "Bash", detail: "exit 0", id: "r1"),
        };
        var call = Assert.Single(ChatToolCalls.UnifiedToolCalls(pieces, isStreaming: false));
        Assert.Equal("exit 0", call.Result);
    }

    [Fact]
    public void UnifiedToolCalls_LiveTrailingUnpairedUse_IsRunning()
    {
        var pieces = new List<ChatTranscriptPiece>
        {
            Piece(ChatTranscriptPieceKind.ToolUse, "Read", id: "u1"),
            Piece(ChatTranscriptPieceKind.ToolResult, "Read", id: "r1"),
            Piece(ChatTranscriptPieceKind.ToolUse, "Bash", id: "u2"), // still in flight
        };
        var calls = ChatToolCalls.UnifiedToolCalls(pieces, isStreaming: true);
        Assert.Equal(2, calls.Count);
        Assert.False(calls[0].IsRunning);
        Assert.True(calls[1].IsRunning);
    }

    [Fact]
    public void UnifiedToolCalls_NotStreaming_NeverRunning()
    {
        var pieces = new List<ChatTranscriptPiece>
        {
            Piece(ChatTranscriptPieceKind.ToolUse, "Bash", id: "u2"),
        };
        var call = Assert.Single(ChatToolCalls.UnifiedToolCalls(pieces, isStreaming: false));
        Assert.False(call.IsRunning);
    }

    [Fact]
    public void UnifiedToolCalls_OrphanResult_IsDropped()
    {
        var pieces = new List<ChatTranscriptPiece>
        {
            Piece(ChatTranscriptPieceKind.ToolResult, "Ghost", id: "r1"),
        };
        Assert.Empty(ChatToolCalls.UnifiedToolCalls(pieces, isStreaming: false));
    }

    [Theory]
    [InlineData("ReadFile", ChatToolCapability.Document)]
    [InlineData("WriteFile", ChatToolCapability.Document)]
    [InlineData("Bash", ChatToolCapability.Terminal)]
    [InlineData("run_terminal", ChatToolCapability.Terminal)]
    [InlineData("GrepSearch", ChatToolCapability.Search)]
    [InlineData("WebFetch", ChatToolCapability.Web)]
    [InlineData("EditFile", ChatToolCapability.Document)] // "file" wins before "edit" (order parity)
    [InlineData("patch_apply", ChatToolCapability.Edit)]
    [InlineData("memory_store", ChatToolCapability.Memory)]
    [InlineData("screenshot", ChatToolCapability.Image)]
    [InlineData("speak_tts", ChatToolCapability.Voice)]
    [InlineData("mystery", ChatToolCapability.Generic)]
    public void Capability_ClassifiesByOrderedSubstringRules(string tool, ChatToolCapability expected)
    {
        Assert.Equal(expected, ChatToolCalls.Capability(tool));
    }

    [Fact]
    public void SegoeGlyph_IsNonEmpty_ForEveryCapability()
    {
        foreach (ChatToolCapability cap in System.Enum.GetValues(typeof(ChatToolCapability)))
        {
            Assert.False(string.IsNullOrEmpty(ChatToolCalls.SegoeGlyph(cap)));
        }
    }
}
