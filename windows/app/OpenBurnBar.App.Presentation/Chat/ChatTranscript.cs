using System;
using System.Collections.Generic;
using System.Text;

namespace OpenBurnBar.App.Presentation.Chat;

// MARK: - Chat Transcript Model
//
// C# peer of the chat message model in
// `AgentLens/Models/ConversationRecord.swift` (ChatMessageRole /
// ChatTranscriptPiece / ChatMessageRecord / TranscriptGroup) plus the pure
// streaming-append helpers `ChatSessionController.appendStreamingText(...)` /
// `appendStreamingTranscriptChunk(...)`.
//
// The Swift transcript piece is a `struct` with a `var value` so the streaming
// hot path mutates content in place; here it is a small mutable class for the
// same reason (assign `.Value +=` instead of reallocating per token chunk).

public enum ChatMessageRole
{
    User,
    Assistant,
    System,
}

/// Ordered segment kinds for assistant messages (peer of Swift
/// `ChatTranscriptPiece.Kind`).
public enum ChatTranscriptPieceKind
{
    Text,
    Reasoning,
    Refusal,
    ToolUse,
    ToolResult,
}

public sealed record ChatAttachmentRecord(
    string Id,
    string Kind,
    string DisplayName,
    string MimeType,
    long ByteSize,
    string WorkspaceRelativePath,
    string? ExtractedTextPreview = null,
    bool IsMissing = false)
{
    public static ChatAttachmentRecord ReferenceOnly(string id) =>
        new(id, "generic", id, "application/octet-stream", 0, string.Empty, null, IsMissing: true);
}

/// One ordered transcript segment (peer of Swift `ChatTranscriptPiece`).
/// Prose for Text/Reasoning/Refusal; tool label (Read, Bash, …) for tool events.
public sealed class ChatTranscriptPiece
{
    public string Id { get; }

    public ChatTranscriptPieceKind Kind { get; }

    /// Mutable so the streaming hot path can coalesce chunks (`Value += chunk`).
    public string Value { get; set; }

    public string? Detail { get; }

    public ChatTranscriptPiece(
        ChatTranscriptPieceKind kind, string value, string? detail = null, string? id = null)
    {
        Id = id ?? Guid.NewGuid().ToString();
        Kind = kind;
        Value = value;
        Detail = detail;
    }
}

/// One persisted chat message (peer of Swift `ChatMessageRecord`). `Content`
/// and `TranscriptPieces` are mutable for the same per-token hot-path reason as
/// the Swift `var content` / `var transcriptPieces`.
public sealed class ChatMessageRecord
{
    public string Id { get; }

    public ChatMessageRole Role { get; }

    public string Content { get; set; }

    public DateTimeOffset Timestamp { get; }

    /// Backend label shown as a first-response badge; null after the badge shows.
    public string? CliUsed { get; }

    public List<ChatTranscriptPiece> TranscriptPieces { get; set; }

    /// Attachment references staged with this message. Bytes stay in the
    /// WinUI/storage layer; metadata round-trips so missing files can be
    /// surfaced after restart instead of corrupting history.
    public IReadOnlyList<ChatAttachmentRecord> Attachments { get; }

    public IReadOnlyList<string> AttachmentIds { get; }

    public ChatMessageRecord(
        ChatMessageRole role,
        string content,
        string? id = null,
        DateTimeOffset? timestamp = null,
        string? cliUsed = null,
        List<ChatTranscriptPiece>? transcriptPieces = null,
        IReadOnlyList<string>? attachmentIds = null,
        IReadOnlyList<ChatAttachmentRecord>? attachments = null)
    {
        Id = id ?? Guid.NewGuid().ToString();
        Role = role;
        Content = content;
        Timestamp = timestamp ?? DateTimeOffset.UtcNow;
        CliUsed = cliUsed;
        TranscriptPieces = transcriptPieces ?? new List<ChatTranscriptPiece>();
        Attachments = attachments
            ?? AttachmentRecordsFromIds(attachmentIds)
            ?? Array.Empty<ChatAttachmentRecord>();
        AttachmentIds = AttachmentIdsFromRecords(Attachments);
    }

    /// Pieces for display; legacy rows synthesize a single text piece from
    /// <see cref="Content"/> (peer of Swift `displayTranscript`).
    public IReadOnlyList<ChatTranscriptPiece> DisplayTranscript()
    {
        if (TranscriptPieces.Count > 0)
        {
            return TranscriptPieces;
        }
        if (Content.Length == 0)
        {
            return Array.Empty<ChatTranscriptPiece>();
        }
        return new[]
        {
            new ChatTranscriptPiece(ChatTranscriptPieceKind.Text, Content, id: $"{Id}-legacy"),
        };
    }

    /// Joined answer text for persistence / search parity — only the Text pieces
    /// (Reasoning/Refusal stay labeled). Peer of Swift `joinedText(from:)`.
    public static string JoinedText(IReadOnlyList<ChatTranscriptPiece> pieces)
    {
        var builder = new StringBuilder();
        foreach (var piece in pieces)
        {
            if (piece.Kind == ChatTranscriptPieceKind.Text)
            {
                builder.Append(piece.Value);
            }
        }
        return builder.ToString();
    }

    // MARK: - Streaming append (pure, byte-for-byte with the Swift statics)

    /// Append a plain text chunk (peer of Swift `appendStreamingText`).
    public static void AppendStreamingText(string chunk, List<ChatTranscriptPiece> pieces) =>
        AppendStreamingChunk(chunk, ChatTranscriptPieceKind.Text, pieces);

    /// Append a chunk of the given kind, coalescing into the trailing piece when
    /// it is the same kind (peer of Swift `appendStreamingTranscriptChunk`).
    public static void AppendStreamingChunk(
        string chunk, ChatTranscriptPieceKind kind, List<ChatTranscriptPiece> pieces)
    {
        if (chunk.Length == 0)
        {
            return;
        }
        if (pieces.Count > 0 && pieces[^1].Kind == kind)
        {
            pieces[^1].Value += chunk;
        }
        else
        {
            pieces.Add(new ChatTranscriptPiece(kind, chunk));
        }
    }

    private static IReadOnlyList<ChatAttachmentRecord>? AttachmentRecordsFromIds(IReadOnlyList<string>? ids)
    {
        if (ids is null || ids.Count == 0)
        {
            return null;
        }

        var records = new ChatAttachmentRecord[ids.Count];
        for (var i = 0; i < ids.Count; i++)
        {
            records[i] = ChatAttachmentRecord.ReferenceOnly(ids[i]);
        }

        return records;
    }

    private static IReadOnlyList<string> AttachmentIdsFromRecords(IReadOnlyList<ChatAttachmentRecord> records)
    {
        if (records.Count == 0)
        {
            return Array.Empty<string>();
        }

        var ids = new string[records.Count];
        for (var i = 0; i < records.Count; i++)
        {
            ids[i] = records[i].Id;
        }

        return ids;
    }
}

/// Groups consecutive tool transcript pieces for horizontal-strip rendering
/// (peer of Swift `TranscriptGroup`).
public abstract record TranscriptGroup
{
    private TranscriptGroup()
    {
    }

    public abstract string Id { get; }

    public sealed record ToolGroup(IReadOnlyList<ChatTranscriptPiece> Pieces) : TranscriptGroup
    {
        public override string Id => $"tg-{(Pieces.Count > 0 ? Pieces[0].Id : Guid.NewGuid().ToString())}";
    }

    public sealed record Single(ChatTranscriptPiece Piece) : TranscriptGroup
    {
        public override string Id => Piece.Id;
    }

    /// Partitions transcript pieces into groups: consecutive tool pieces become
    /// a <see cref="ToolGroup"/>, prose/safety-labeled pieces become a
    /// <see cref="Single"/> (peer of Swift `TranscriptGroup.group`).
    public static IReadOnlyList<TranscriptGroup> Group(IReadOnlyList<ChatTranscriptPiece> transcript)
    {
        var groups = new List<TranscriptGroup>();
        var pendingTools = new List<ChatTranscriptPiece>();

        foreach (var piece in transcript)
        {
            switch (piece.Kind)
            {
                case ChatTranscriptPieceKind.ToolUse:
                case ChatTranscriptPieceKind.ToolResult:
                    pendingTools.Add(piece);
                    break;
                case ChatTranscriptPieceKind.Text:
                case ChatTranscriptPieceKind.Reasoning:
                case ChatTranscriptPieceKind.Refusal:
                    if (pendingTools.Count > 0)
                    {
                        groups.Add(new ToolGroup(pendingTools));
                        pendingTools = new List<ChatTranscriptPiece>();
                    }
                    groups.Add(new Single(piece));
                    break;
            }
        }
        if (pendingTools.Count > 0)
        {
            groups.Add(new ToolGroup(pendingTools));
        }
        return groups;
    }
}
