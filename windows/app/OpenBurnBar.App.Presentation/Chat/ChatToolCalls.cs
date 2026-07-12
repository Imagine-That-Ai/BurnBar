using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.Chat;

// MARK: - Unified Tool Calls
//
// C# peer of the tool-call folding in `AgentLens/Views/Chat/ChatMessageView.swift`
// (`unifiedToolCalls(from:)`) plus the capability-icon classification in
// `AgentLens/Views/Chat/HermesToolCard.swift` (`capabilityIcon`).
//
// Both are PURE display transforms with subtle rules the WinUI tool-card
// template depends on, so they live in the portable layer and are unit-tested on
// macOS today.

/// One folded tool call for the collapsible tool-card row (peer of Swift
/// `UnifiedToolCallDisplay`). A `.toolUse` paired with the `.toolResult` that
/// immediately follows it; <see cref="IsRunning"/> pulses the still-in-flight
/// final call of a live stream.
public sealed record UnifiedToolCallDisplay(
    string Id,
    string Name,
    string? Detail,
    string? Result,
    bool IsRunning);

/// Semantic category the WinUI tool card maps to a Segoe glyph. The Swift side
/// returns SF Symbol names; the classification rules (substring checks, order)
/// are identical and ported here so parity is unit-testable without pinning to
/// Apple glyph strings.
public enum ChatToolCapability
{
    Document,
    Terminal,
    Search,
    Web,
    Edit,
    Memory,
    Image,
    Voice,
    Generic,
}

public static class ChatToolCalls
{
    /// Fold a transcript group's tool pieces into the shared display model,
    /// pairing a `.toolUse` with its following `.toolResult`. The last *unpaired*
    /// toolUse is the call still in flight during a live stream; orphaned results
    /// are dropped. Byte-for-byte port of Swift `unifiedToolCalls(from:)`.
    ///
    /// <paramref name="isStreaming"/> mirrors the controller's live flag: only
    /// then does the trailing unpaired call pulse.
    public static IReadOnlyList<UnifiedToolCallDisplay> UnifiedToolCalls(
        IReadOnlyList<ChatTranscriptPiece> pieces, bool isStreaming)
    {
        // Track the last *unpaired* toolUse — the call still in flight. Using a
        // toolResult would fire IsRunning on the closing piece, already landed.
        string? lastUnpairedToolUseId = null;
        {
            var i = 0;
            while (i < pieces.Count)
            {
                if (pieces[i].Kind == ChatTranscriptPieceKind.ToolUse)
                {
                    var isPaired = i + 1 < pieces.Count
                        && pieces[i + 1].Kind == ChatTranscriptPieceKind.ToolResult;
                    lastUnpairedToolUseId = pieces[i].Id; // always track
                    if (isPaired)
                    {
                        i++; // skip the result so it's consumed
                    }
                }
                i++;
            }
        }

        var calls = new List<UnifiedToolCallDisplay>();
        var index = 0;
        while (index < pieces.Count)
        {
            var piece = pieces[index];
            switch (piece.Kind)
            {
                case ChatTranscriptPieceKind.ToolUse:
                {
                    string? resultText = null;
                    if (index + 1 < pieces.Count
                        && pieces[index + 1].Kind == ChatTranscriptPieceKind.ToolResult)
                    {
                        var resultPiece = pieces[index + 1];
                        resultText = !string.IsNullOrEmpty(resultPiece.Detail)
                            ? resultPiece.Detail
                            : resultPiece.Value;
                        index++; // consume the paired result
                    }
                    calls.Add(new UnifiedToolCallDisplay(
                        piece.Id,
                        piece.Value,
                        piece.Detail,
                        resultText,
                        isStreaming && piece.Id == lastUnpairedToolUseId));
                    break;
                }
                case ChatTranscriptPieceKind.ToolResult:
                    // Unpaired result surviving the pairing pass = unexpected
                    // ordering; drop silently to avoid a ghost row.
                    break;
                case ChatTranscriptPieceKind.Text:
                case ChatTranscriptPieceKind.Reasoning:
                case ChatTranscriptPieceKind.Refusal:
                    break;
            }
            index++;
        }
        return calls;
    }

    /// Classify a tool name into a capability bucket (peer of Swift
    /// `HermesToolCard.capabilityIcon`, same lowercase substring checks + order).
    public static ChatToolCapability Capability(string toolName)
    {
        var n = toolName.ToLowerInvariant();
        if (n.Contains("read") || n.Contains("file") || n.Contains("write"))
        {
            return ChatToolCapability.Document;
        }
        if (n.Contains("bash") || n.Contains("exec") || n.Contains("run") || n.Contains("terminal"))
        {
            return ChatToolCapability.Terminal;
        }
        if (n.Contains("search") || n.Contains("grep") || n.Contains("glob") || n.Contains("find"))
        {
            return ChatToolCapability.Search;
        }
        if (n.Contains("web") || n.Contains("browser") || n.Contains("fetch") || n.Contains("http"))
        {
            return ChatToolCapability.Web;
        }
        if (n.Contains("edit") || n.Contains("patch") || n.Contains("replace"))
        {
            return ChatToolCapability.Edit;
        }
        if (n.Contains("memory") || n.Contains("skill") || n.Contains("learn"))
        {
            return ChatToolCapability.Memory;
        }
        if (n.Contains("image") || n.Contains("vision") || n.Contains("screenshot"))
        {
            return ChatToolCapability.Image;
        }
        if (n.Contains("tts") || n.Contains("voice") || n.Contains("speak"))
        {
            return ChatToolCapability.Voice;
        }
        return ChatToolCapability.Generic;
    }

    /// The Segoe MDL2 Assets glyph the WinUI tool card renders for a capability
    /// (approximate — final icon parity is a design pass, matching the shell's
    /// own "glyphs are approximate" note). Kept alongside the classifier so the
    /// app layer maps once, consistently.
    public static string SegoeGlyph(ChatToolCapability capability) => capability switch
    {
        ChatToolCapability.Document => "", // Document
        ChatToolCapability.Terminal => "", // CommandPrompt
        ChatToolCapability.Search => "",   // Search
        ChatToolCapability.Web => "",      // Globe
        ChatToolCapability.Edit => "",     // Edit
        ChatToolCapability.Memory => "",   // Lightbulb (learn/memory)
        ChatToolCapability.Image => "",    // Photo
        ChatToolCapability.Voice => "",    // Microphone
        ChatToolCapability.Generic => "",  // Repair (wrench)
        _ => "",
    };
}
