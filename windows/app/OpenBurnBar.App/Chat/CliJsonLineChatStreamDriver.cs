using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Chat;

/// <summary>
/// Production <see cref="IChatStreamDriver"/> that maps CLI NDJSON lines through
/// <see cref="ClaudeCodeStreamJsonParser"/> into chat surface events (H3 F1).
/// Line source is injected so portable tests drive the shipped parser path without ConPTY.
/// </summary>
public sealed class CliJsonLineChatStreamDriver : IChatStreamDriver
{
    private readonly Func<string, IReadOnlyList<ChatMessageRecord>, CancellationToken, IAsyncEnumerable<string>> _lines;

    public CliJsonLineChatStreamDriver(
        Func<string, IReadOnlyList<ChatMessageRecord>, CancellationToken, IAsyncEnumerable<string>> lineSource)
    {
        _lines = lineSource ?? throw new ArgumentNullException(nameof(lineSource));
    }

    public async IAsyncEnumerable<ChatStreamEvent> StreamAsync(
        string userText,
        IReadOnlyList<ChatMessageRecord> history,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await foreach (string line in _lines(userText, history, cancellationToken).ConfigureAwait(false))
        {
            cancellationToken.ThrowIfCancellationRequested();
            foreach (ChatStreamEvent evt in ClaudeCodeStreamJsonParser.EventsFromLine(line))
            {
                yield return evt;
            }
        }
    }
}
