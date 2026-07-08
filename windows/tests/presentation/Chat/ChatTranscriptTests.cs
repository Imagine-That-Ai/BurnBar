using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.Chat;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Chat;

/// <summary>
/// Real parity tests for the transcript model + pure streaming-append helpers
/// ported from AgentLens/Models/ConversationRecord.swift and the static
/// `appendStreamingTranscriptChunk` in ChatSessionController.swift.
/// </summary>
public sealed class ChatTranscriptTests
{
    private static ChatTranscriptPiece Piece(ChatTranscriptPieceKind kind, string value, string? detail = null, string? id = null)
        => new(kind, value, detail, id);

    [Fact]
    public void AppendStreamingText_CoalescesIntoTrailingTextPiece()
    {
        var pieces = new List<ChatTranscriptPiece>();
        ChatMessageRecord.AppendStreamingText("Hel", pieces);
        ChatMessageRecord.AppendStreamingText("lo", pieces);
        var piece = Assert.Single(pieces);
        Assert.Equal(ChatTranscriptPieceKind.Text, piece.Kind);
        Assert.Equal("Hello", piece.Value);
    }

    [Fact]
    public void AppendStreamingChunk_DifferentKind_StartsNewPiece()
    {
        var pieces = new List<ChatTranscriptPiece>();
        ChatMessageRecord.AppendStreamingText("answer", pieces);
        ChatMessageRecord.AppendStreamingChunk("thinking", ChatTranscriptPieceKind.Reasoning, pieces);
        ChatMessageRecord.AppendStreamingText("more", pieces);
        Assert.Equal(3, pieces.Count);
        Assert.Equal(ChatTranscriptPieceKind.Text, pieces[0].Kind);
        Assert.Equal(ChatTranscriptPieceKind.Reasoning, pieces[1].Kind);
        Assert.Equal(ChatTranscriptPieceKind.Text, pieces[2].Kind);
    }

    [Fact]
    public void AppendStreamingChunk_EmptyChunk_IsNoOp()
    {
        var pieces = new List<ChatTranscriptPiece>();
        ChatMessageRecord.AppendStreamingText(string.Empty, pieces);
        Assert.Empty(pieces);
    }

    [Fact]
    public void JoinedText_UsesOnlyTextPieces()
    {
        var pieces = new List<ChatTranscriptPiece>
        {
            Piece(ChatTranscriptPieceKind.Reasoning, "hmm"),
            Piece(ChatTranscriptPieceKind.Text, "Hello "),
            Piece(ChatTranscriptPieceKind.ToolUse, "Read"),
            Piece(ChatTranscriptPieceKind.Text, "world"),
            Piece(ChatTranscriptPieceKind.Refusal, "no"),
        };
        Assert.Equal("Hello world", ChatMessageRecord.JoinedText(pieces));
    }

    [Fact]
    public void DisplayTranscript_LegacyRow_SynthesizesSingleTextPiece()
    {
        var record = new ChatMessageRecord(ChatMessageRole.Assistant, "legacy content");
        var display = record.DisplayTranscript();
        var piece = Assert.Single(display);
        Assert.Equal(ChatTranscriptPieceKind.Text, piece.Kind);
        Assert.Equal("legacy content", piece.Value);
    }

    [Fact]
    public void DisplayTranscript_EmptyContent_IsEmpty()
    {
        var record = new ChatMessageRecord(ChatMessageRole.Assistant, string.Empty);
        Assert.Empty(record.DisplayTranscript());
    }

    [Fact]
    public void TranscriptGroup_GroupsConsecutiveToolPieces()
    {
        var transcript = new List<ChatTranscriptPiece>
        {
            Piece(ChatTranscriptPieceKind.Text, "before"),
            Piece(ChatTranscriptPieceKind.ToolUse, "Read"),
            Piece(ChatTranscriptPieceKind.ToolResult, "Read", "ok"),
            Piece(ChatTranscriptPieceKind.ToolUse, "Bash"),
            Piece(ChatTranscriptPieceKind.Text, "after"),
        };
        var groups = TranscriptGroup.Group(transcript);
        Assert.Equal(3, groups.Count);
        Assert.IsType<TranscriptGroup.Single>(groups[0]);
        var toolGroup = Assert.IsType<TranscriptGroup.ToolGroup>(groups[1]);
        Assert.Equal(3, toolGroup.Pieces.Count);
        Assert.IsType<TranscriptGroup.Single>(groups[2]);
    }

    [Fact]
    public void TranscriptGroup_TrailingTools_FlushIntoFinalGroup()
    {
        var transcript = new List<ChatTranscriptPiece>
        {
            Piece(ChatTranscriptPieceKind.Text, "x"),
            Piece(ChatTranscriptPieceKind.ToolUse, "Read"),
        };
        var groups = TranscriptGroup.Group(transcript);
        Assert.Equal(2, groups.Count);
        Assert.IsType<TranscriptGroup.ToolGroup>(groups[^1]);
    }
}
