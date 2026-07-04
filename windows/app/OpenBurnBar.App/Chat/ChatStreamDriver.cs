using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Chat;

// MARK: - Chat stream driver seam
//
// The atom-router state machine is backend-agnostic: it consumes
// ChatStreamEvent values. On Windows the real driver adapts CLIBridge /
// gateway streams into this seam (the Codex/Claude/Hermes chat*Stream paths in
// AgentLens/Views/Chat/ChatSessionController+Search.swift). Until that native
// bridge lands, the shell ships a scripted driver so the surface animates the
// full idle→streaming→tool_use→tool_result→done walk end-to-end.

/// Produces the backend event stream for one assistant turn (peer of the
/// `AsyncThrowingStream<CLIChatStreamEvent, Error>` the controller awaits).
public interface IChatStreamDriver
{
    IAsyncEnumerable<ChatStreamEvent> StreamAsync(
        string userText,
        IReadOnlyList<ChatMessageRecord> history,
        CancellationToken cancellationToken);
}

/// A deterministic scripted driver that replays a representative turn: a brief
/// think pause, streamed prose (including a burnbar atom + inline code), a tool
/// call that resolves, and a closing line. Used by the WinUI surface for a live
/// demo before the CLIBridge driver is wired; also handy for manual QA.
public sealed class ScriptedChatStreamDriver : IChatStreamDriver
{
    private readonly int _tokenDelayMs;

    public ScriptedChatStreamDriver(int tokenDelayMs = 24)
    {
        _tokenDelayMs = tokenDelayMs;
    }

    public async IAsyncEnumerable<ChatStreamEvent> StreamAsync(
        string userText,
        IReadOnlyList<ChatMessageRecord> history,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        // Initial think pause (no content yet → the thinking droplets show).
        await Task.Delay(320, cancellationToken).ConfigureAwait(true);

        var opening = new[]
        {
            "Here", "'s", " what", " I", " found", ". ",
        };
        foreach (var token in opening)
        {
            cancellationToken.ThrowIfCancellationRequested();
            yield return new ChatStreamEvent.Text(token);
            await Task.Delay(_tokenDelayMs, cancellationToken).ConfigureAwait(true);
        }

        // A tool call that runs then resolves.
        yield return new ChatStreamEvent.ToolUse("ReadFile", "path=notes.md");
        await Task.Delay(220, cancellationToken).ConfigureAwait(true);
        yield return new ChatStreamEvent.ToolResult("ReadFile", "42 lines read");
        await Task.Delay(120, cancellationToken).ConfigureAwait(true);

        var closing = new[]
        {
            "You", " spent", " ", "$2.34", " today", " on ", "`claude-sonnet-4.7`", ".",
        };
        foreach (var token in closing)
        {
            cancellationToken.ThrowIfCancellationRequested();
            yield return new ChatStreamEvent.Text(token);
            await Task.Delay(_tokenDelayMs, cancellationToken).ConfigureAwait(true);
        }

        yield return new ChatStreamEvent.Usage(new CliUsageSnapshot(InputTokens: 128, OutputTokens: 64));
    }
}
