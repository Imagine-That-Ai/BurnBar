using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using OpenBurnBar.App.Components;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Chat;

// MARK: - Chat message row view-models
//
// The WinUI-facing adapter between the portable transcript model
// (OpenBurnBar.App.Presentation.Chat) and the atom-router ItemsRepeater. A
// message renders as an ordered list of typed rows — prose (a Pretext-measured
// rich bubble) and tool groups (the LANDED UnifiedToolCallAccordion) — exactly
// like the macOS ChatMessageView folds displayTranscript into TranscriptGroups.
//
// All the folding + pairing + parsing is the PORTABLE, unit-tested logic:
//   TranscriptGroup.Group         → row partitioning
//   ChatToolCalls.UnifiedToolCalls → tool pairing (toolUse+toolResult, isRunning)
//   HermesAtomParser.Parse         → prose → atom/mention/code/body runs
// This file only maps those results onto WinUI-bindable objects.

/// One rendered row inside a message bubble.
public abstract class ChatMessageRow
{
}

/// A prose row — text / reasoning / refusal — rendered by the Pretext-measured
/// <see cref="StreamingBubble"/>. Reasoning + refusal carry a header label, like
/// the macOS labeled transcript pieces.
public sealed class ChatProseRow : ChatMessageRow
{
    public ChatProseRow(ChatTranscriptPieceKind kind, IReadOnlyList<HermesRichRun> runs, string text)
    {
        Kind = kind;
        Runs = runs;
        Text = text;
    }

    public ChatTranscriptPieceKind Kind { get; }

    public IReadOnlyList<HermesRichRun> Runs { get; }

    public string Text { get; }

    public bool IsReasoning => Kind == ChatTranscriptPieceKind.Reasoning;

    public bool IsRefusal => Kind == ChatTranscriptPieceKind.Refusal;

    /// Header shown above a reasoning/refusal span (null for plain text).
    public string? Label => Kind switch
    {
        ChatTranscriptPieceKind.Reasoning => "Reasoning",
        ChatTranscriptPieceKind.Refusal => "Refusal",
        _ => null,
    };

    public bool HasLabel => Label is not null;
}

/// A tool-call group row — bound straight to the landed
/// <see cref="UnifiedToolCallAccordion"/> via its <see cref="ToolCallDisplay"/> list.
public sealed class ChatToolRow : ChatMessageRow
{
    public ChatToolRow(IReadOnlyList<ToolCallDisplay> calls)
    {
        Calls = calls;
    }

    public IReadOnlyList<ToolCallDisplay> Calls { get; }
}

/// Per-message view-model bound by the atom-router. Rebuilt on every streaming
/// tick from the shared <see cref="ChatMessageRecord"/>.
public sealed class ChatMessageViewModel : INotifyPropertyChanged
{
    private readonly ChatMessageRecord _record;
    private bool _showThinking;

    public ChatMessageViewModel(ChatMessageRecord record)
    {
        _record = record;
        Rows = new ObservableCollection<ChatMessageRow>();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public string Id => _record.Id;

    public bool IsUser => _record.Role == ChatMessageRole.User;

    public bool IsAssistant => _record.Role == ChatMessageRole.Assistant;

    /// Backend badge for the first assistant response (null otherwise).
    public string? CliUsed => _record.CliUsed;

    public bool HasBadge => !string.IsNullOrEmpty(CliUsed);

    /// User bubbles render plain content; assistant bubbles render <see cref="Rows"/>.
    public string UserText => _record.Content;

    public ObservableCollection<ChatMessageRow> Rows { get; }

    /// True while an assistant turn is live but nothing has rendered yet — the
    /// Hermes thinking droplets fill the gap (peer of the macOS thinking view gate).
    public bool ShowThinking
    {
        get => _showThinking;
        private set
        {
            if (_showThinking != value)
            {
                _showThinking = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ShowThinking)));
            }
        }
    }

    /// Rebuild the rows from the record's current transcript. <paramref name="isStreaming"/>
    /// is the machine's live flag — it pulses the trailing tool call and gates the
    /// thinking droplets.
    public void Refresh(bool isStreaming)
    {
        Rows.Clear();
        var hasProse = false;
        var hasTool = false;

        foreach (var group in TranscriptGroup.Group(_record.DisplayTranscript()))
        {
            switch (group)
            {
                case TranscriptGroup.Single single:
                {
                    var piece = single.Piece;
                    var runs = HermesAtomParser.Parse(piece.Value);
                    Rows.Add(new ChatProseRow(piece.Kind, runs, piece.Value));
                    if (piece.Value.Length > 0)
                    {
                        hasProse = true;
                    }
                    break;
                }
                case TranscriptGroup.ToolGroup toolGroup:
                {
                    var folded = ChatToolCalls.UnifiedToolCalls(toolGroup.Pieces, isStreaming);
                    var display = new List<ToolCallDisplay>(folded.Count);
                    foreach (var call in folded)
                    {
                        display.Add(new ToolCallDisplay(
                            id: call.Id,
                            name: call.Name,
                            statusRaw: null,
                            detail: call.Detail,
                            arguments: call.Detail,
                            result: call.Result,
                            isRunning: call.IsRunning));
                    }
                    Rows.Add(new ChatToolRow(display));
                    hasTool = true;
                    break;
                }
            }
        }

        ShowThinking = IsAssistant && isStreaming && !hasProse && !hasTool;
    }
}
