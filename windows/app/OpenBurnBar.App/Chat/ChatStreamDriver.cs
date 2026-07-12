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
// bridge lands, production uses an explicit unavailable driver; the scripted driver
// is opt-in sample mode only.

/// Produces the backend event stream for one assistant turn (peer of the
/// `AsyncThrowingStream<CLIChatStreamEvent, Error>` the controller awaits).
public interface IChatStreamDriver
{
    IAsyncEnumerable<ChatStreamEvent> StreamAsync(
        string userText,
        IReadOnlyList<ChatMessageRecord> history,
        CancellationToken cancellationToken);
}

/// Production-default driver when no local/remote chat backend is configured. It is explicit and
/// actionable, not a scripted fake response. The scripted demo driver remains available through
/// <c>OPENBURNBAR_SAMPLE_MODE=1</c>.
public sealed class UnavailableChatStreamDriver : IChatStreamDriver
{
    public async IAsyncEnumerable<ChatStreamEvent> StreamAsync(
        string userText,
        IReadOnlyList<ChatMessageRecord> history,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await Task.Yield();
        cancellationToken.ThrowIfCancellationRequested();
        yield return new ChatStreamEvent.StreamFailure(
            ChatFailureKind.BackendUnavailable,
            "Chat backend is not configured on this Windows build. Connect the Hermes/CLI bridge in Settings -> Data Sources, or launch with OPENBURNBAR_SAMPLE_MODE=1 for a labeled scripted demo.");
    }
}

/// A deterministic scripted driver that replays a representative turn. Used only when sample mode
/// is explicitly enabled, and in tests that inject it directly.
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
