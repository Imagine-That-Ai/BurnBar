using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Cli;

/// <summary>
/// A STUB CLI stream: it replays a canned agent transcript with realistic timing so the
/// shell's live-stream view can be exercised end-to-end with NO real process, network, or
/// provider. Stdout arrives token-by-token (a small delay between chunks) to look genuinely
/// live; interspersed tool-call and stderr lines exercise every render path. When the
/// transcript ends it loops after a short pause, so a dev-host recording (WINUI-017) shows
/// continuous motion.
///
/// This is the ONLY stubbed seam in the shell. WINUI-017 / W1-W2 replace it with a
/// ConPTY-backed <see cref="ICliStream"/> that spawns the real CLI; nothing else changes.
/// </summary>
public sealed class StubCliStream : ICliStream
{
    private static readonly (CliStreamEventKind Kind, string Text)[] Script =
    {
        (CliStreamEventKind.System, "$ claude --stream \"summarize the OpenBurnBar Windows port\"\n"),
        (CliStreamEventKind.System, "session 7f3a… started · model claude-opus-4-8\n"),
        (CliStreamEventKind.Stdout, "Reading the master plan"),
        (CliStreamEventKind.Stdout, " and the reuse ledger"),
        (CliStreamEventKind.Stdout, " to scope the shell.\n"),
        (CliStreamEventKind.ToolCall, "→ tool: read_file(docs/WINDOWS_PORT_MASTER_PLAN.md)\n"),
        (CliStreamEventKind.Stdout, "The WinUI 3 shell mirrors the macOS menu-bar app:\n"),
        (CliStreamEventKind.Stdout, "  • Shell_NotifyIcon tray  ← NSStatusItem\n"),
        (CliStreamEventKind.Stdout, "  • Mica borderless flyout ← NSPopover\n"),
        (CliStreamEventKind.Stdout, "  • live CLI stream view   ← CLIProcessStreamRunner\n"),
        (CliStreamEventKind.ToolCall, "→ tool: grep(\"MicaBackdrop\", windows/app)\n"),
        (CliStreamEventKind.Stderr, "warn: Mica requires Windows 11 — falling back to solid on Win10\n"),
        (CliStreamEventKind.Stdout, "Streaming is wired to a stub source for the spike; ConPTY\n"),
        (CliStreamEventKind.Stdout, "lands in WINUI-017.\n"),
        (CliStreamEventKind.System, "session complete · 1,284 tokens · 3.1s\n"),
    };

    private readonly int _chunkDelayMs;
    private readonly int _loopPauseMs;

    /// <param name="chunkDelayMs">Delay between streamed chunks (default keeps motion visible on a recording).</param>
    /// <param name="loopPauseMs">Pause before replaying the transcript.</param>
    public StubCliStream(int chunkDelayMs = 90, int loopPauseMs = 1400)
    {
        _chunkDelayMs = chunkDelayMs;
        _loopPauseMs = loopPauseMs;
    }

    public async IAsyncEnumerable<CliStreamEvent> ReadAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            foreach (var (kind, text) in Script)
            {
                cancellationToken.ThrowIfCancellationRequested();
                yield return new CliStreamEvent(kind, text);
                await DelayQuietly(_chunkDelayMs, cancellationToken).ConfigureAwait(false);
            }

            await DelayQuietly(_loopPauseMs, cancellationToken).ConfigureAwait(false);
        }
    }

    private static async Task DelayQuietly(int milliseconds, CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(milliseconds, cancellationToken).ConfigureAwait(false);
        }
        catch (TaskCanceledException)
        {
            // Cancellation is the normal stop path; let the loop observe the token and exit.
        }
    }
}
